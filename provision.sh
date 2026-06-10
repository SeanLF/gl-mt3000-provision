#!/bin/bash
# Provision a GL-MT3000 from stock firmware to fully configured state.
# Source of truth for all router config. Idempotent -- safe to re-run.
#
# Usage:
#   ./provision.sh              Full provision (SSH key must be on router)
#   ./provision.sh --check      Dry-run: show what would change

set -euo pipefail

ROUTER="${ROUTER:-root@192.168.8.1}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CHECK_ONLY=false

if [ "${1:-}" = "--check" ]; then
    CHECK_ONLY=true
    echo "=== DRY RUN (check only) ==="
    echo ""
fi

ssh_cmd() {
    ssh "$ROUTER" "$1" 2>/dev/null
}

# --- UCI desired state ---
# format: package.key=value
# DNS handled separately in apply_dns_settings() because the schema changed
# between firmware 4.8.x (gl-dns) and 4.9.x (gl-dns-v2).
UCI_SETTINGS="
repeater.@main[0].auto=2
repeater.@main[0].disabled=0
mtkhnat.global.enable=0
dhcp.@dnsmasq[0].cachesize=1000
kmwan.modem_1_1_2.disabled=1
kmwan.modem_1_1_2_6.disabled=1
kmwan.global.sensitivity=10000
"
# repeater note:
#   disabled=0 -- the web UI repeater off-toggle sets disabled=1, which stops
#   the gl-repeater daemon entirely: no scanning, no ubus repeater API, and
#   both the web UI join and 'setup-link wifi' silently break. auto=2 already
#   keeps the daemon idle while ethernet WAN is up, so hard-disabling it is
#   never useful.
# kmwan note:
#   wwan/tethering kept tracked (disabled=0 default) -- kmwan installs their
#   default routes when active. Repeater (auto=2) decides WHEN to bring wwan
#   up; kmwan decides HOW to route once it exists. Orthogonal layers.
#   wan6/wwan6/tethering6 already disabled by firmware default.
#   modem_1_1_2{,_6} disabled here -- MT3000 has no cellular slot, those are
#   phantom interfaces inherited from the shared GL.iNet SDK config.
#   Global sensitivity=10000 already drops ping rate 1s -> 10s for the rest.

# --- WiFi .dat desired state ---
# format: KEY=VALUE (applied to both b0 and b1)
DAT_SETTINGS="
AMSDU_NUM=8
TWTSupport=0
VOW_Airtime_Fairness_En=0
BSSColorValue=1
"
# BssidNum omitted: mtk-wifi-configurator (compiled Lua) overwrites it from UCI interface count

echo "=== Checking connectivity ==="
if ! ssh_cmd "echo ok" | grep -q ok; then
    echo "Cannot SSH to $ROUTER."
    echo ""
    echo "First-time setup? Enable SSH in GL.iNet web UI (System > Security),"
    echo "then install your SSH key:"
    echo "  ssh-copy-id $ROUTER"
    echo ""
    echo "Then re-run this script."
    exit 1
fi
echo "  Connected to $(ssh_cmd 'cat /proc/sys/kernel/hostname')"
echo ""

# --- Firmware version ---
# Tested versions. Adding a new major (e.g. 4.10) without re-validating the
# UCI schema risks silent no-ops on renamed packages.
echo "=== Firmware Version ==="
GLVERSION=$(ssh_cmd "cat /etc/glversion 2>/dev/null" | tr -d '\r\n') || true
case "$GLVERSION" in
    4.7.*|4.8.*|4.9.*) echo "  OK  glversion $GLVERSION (tested)" ;;
    "")                echo "  WARN /etc/glversion missing; proceeding anyway" ;;
    *)                 echo "  WARN glversion $GLVERSION not in tested set (4.7/4.8/4.9). UCI schema may have shifted; review provision output before commit." ;;
esac
echo ""

# --- SSH key ---
echo "=== SSH Key ==="
PUBKEY_FILE="$HOME/.ssh/id_ed25519.pub"
if [ -f "$PUBKEY_FILE" ]; then
    pubkey=$(cat "$PUBKEY_FILE")
    if ssh_cmd "grep -qF '$(echo "$pubkey" | awk '{print $2}')' /etc/dropbear/authorized_keys 2>/dev/null"; then
        echo "  OK  SSH key installed"
    else
        echo "  FIX SSH key not in authorized_keys"
        if ! $CHECK_ONLY; then
            echo "$pubkey" | ssh "$ROUTER" "cat >> /etc/dropbear/authorized_keys" 2>/dev/null
            echo "  Installed"
        fi
    fi
else
    echo "  SKIP $PUBKEY_FILE not found"
fi
echo ""

# --- UCI settings ---
echo "=== UCI Settings ==="
CHANGED_PACKAGES=""
for line in $UCI_SETTINGS; do
    [ -z "$line" ] && continue
    key="${line%%=*}"
    want="${line#*=}"
    current=$(ssh_cmd "uci -q get $key" || echo "UNSET")

    if [ "$current" = "$want" ]; then
        echo "  OK  $key = $want"
    elif [ "$key" = "mtkhnat.global.enable" ] && ssh_cmd "test -f /etc/setup-link.last"; then
        echo "  OK  $key = $current (managed by setup-link)"
    else
        echo "  FIX $key: $current -> $want"
        if ! $CHECK_ONLY; then
            ssh_cmd "uci set $key='$want'"
            pkg="${key%%.*}"
            echo "$CHANGED_PACKAGES" | grep -q "$pkg" || CHANGED_PACKAGES="$CHANGED_PACKAGES $pkg"
        fi
    fi
done

if ! $CHECK_ONLY && [ -n "$CHANGED_PACKAGES" ]; then
    for pkg in $CHANGED_PACKAGES; do
        ssh_cmd "uci commit $pkg"
        echo "  Committed: $pkg"
    done
fi
echo ""

# --- Repeater daemon ---
# disabled=1 in UCI also means the daemon was stopped; flipping the key back
# is not enough, the service must actually run for repeater join to work.
echo "=== Repeater Daemon ==="
if ssh_cmd "ubus -t 3 call repeater status >/dev/null 2>&1"; then
    echo "  OK  gl-repeater running"
else
    echo "  FIX gl-repeater not running"
    if ! $CHECK_ONLY; then
        ssh_cmd "/etc/init.d/repeater enable; /etc/init.d/repeater start; sleep 3"
        if ssh_cmd "ubus -t 3 call repeater status >/dev/null 2>&1"; then
            echo "  Enabled and started"
        else
            echo "  ERROR: daemon still not responding after start. On router: logread | grep repeater" >&2
        fi
    fi
fi
echo ""

# --- WiFi .dat files ---
echo "=== WiFi .dat Tuning ==="
for band in b0 b1; do
    dat="/etc/wireless/mediatek/mt7981.dbdc.${band}.dat"
    echo "  --- $band ---"
    for line in $DAT_SETTINGS; do
        [ -z "$line" ] && continue
        key="${line%%=*}"
        want="${line#*=}"
        current=$(ssh_cmd "grep ^${key}= $dat" | cut -d= -f2)

        if [ "$current" = "$want" ]; then
            echo "  OK  $key = $want"
        else
            echo "  FIX $key: ${current:-UNSET} -> $want"
            if ! $CHECK_ONLY; then
                ssh_cmd "sed -i 's/^${key}=.*/${key}=${want}/' $dat"
            fi
        fi
    done
done
echo ""

# --- Sysctl config ---
echo "=== Sysctl Config ==="
SYSCTL_FILE="/etc/sysctl.d/99-latency-tuning.conf"
SYSCTL_CONTENT='# GL-MT3000 latency tuning
net.ipv4.tcp_rmem = 4096 32768 524288
net.ipv4.tcp_wmem = 4096 16384 524288
net.ipv4.tcp_limit_output_bytes = 131072
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_ecn = 2
net.ipv4.tcp_fastopen = 3
net.netfilter.nf_conntrack_tcp_timeout_established = 3600
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30'

if ssh_cmd "cat $SYSCTL_FILE 2>/dev/null" | grep -q "tcp_ecn = 2"; then
    echo "  OK  $SYSCTL_FILE exists and looks correct"
else
    echo "  FIX $SYSCTL_FILE needs creating/updating"
    if ! $CHECK_ONLY; then
        echo "$SYSCTL_CONTENT" | ssh "$ROUTER" "cat > $SYSCTL_FILE" 2>/dev/null
        ssh_cmd "sysctl -p $SYSCTL_FILE" >/dev/null
        echo "  Written and applied"
    fi
fi
echo ""

# --- DNS settings (encrypted DNS via NextDNS over TLS) ---
# 4.8.x ships gl-dns with: mode/proto=DoT/dot_provider=1/nextdns_id
# 4.9.x ships gl-dns-v2 with: mode/proto=dot/provider=nextdns/nextdns_id
# (4.9 includes a /etc/uci-defaults/99-dns migration that auto-translates old
# values on first boot and deletes /etc/config/gl-dns. We still write the
# new schema directly when running on 4.9+ so a clean reflash also works.)
echo "=== DNS (NextDNS-over-TLS) ==="
if ssh_cmd "test -f /etc/config/gl-dns-v2"; then
    DNS_PKG=gl-dns-v2
    DECLS="mode=secure proto=dot provider=nextdns force_dns=1 override_vpn=1"
elif ssh_cmd "test -f /etc/config/gl-dns"; then
    DNS_PKG=gl-dns
    DECLS="mode=secure proto=DoT dot_provider=1 force_dns=1 override_vpn=1"
else
    echo "  ERROR: no gl-dns or gl-dns-v2 config found on router (or ssh dropped mid-run)" >&2
    exit 1
fi
echo "  Using package: $DNS_PKG"

dns_changed=false
for line in $DECLS; do
    key="${line%%=*}"
    want="${line#*=}"
    current=$(ssh_cmd "uci -q get $DNS_PKG.@dns[0].$key" || echo "UNSET")
    if [ "$current" = "$want" ]; then
        echo "  OK  $DNS_PKG.@dns[0].$key = $want"
    else
        echo "  FIX $DNS_PKG.@dns[0].$key: $current -> $want"
        if ! $CHECK_ONLY; then
            ssh_cmd "uci set $DNS_PKG.@dns[0].$key='$want'"
            dns_changed=true
        fi
    fi
done

nextdns_id=$(ssh_cmd "uci -q get $DNS_PKG.@dns[0].nextdns_id" || echo "")
if [ -n "$nextdns_id" ]; then
    echo "  OK  NextDNS ID = $nextdns_id"
else
    echo "  FIX NextDNS ID not set"
    if ! $CHECK_ONLY; then
        read -rp "  Enter NextDNS profile ID: " nextdns_id
        if [ -z "$nextdns_id" ]; then
            echo "  ERROR: NextDNS ID is required" >&2
            exit 1
        fi
        ssh_cmd "uci set $DNS_PKG.@dns[0].nextdns_id='$nextdns_id'"
        dns_changed=true
    fi
fi

if ! $CHECK_ONLY && $dns_changed; then
    ssh_cmd "uci commit $DNS_PKG"
    echo "  Committed: $DNS_PKG"
fi
echo ""

# --- setup-link script ---
echo "=== setup-link Script ==="
LOCAL_SCRIPT="$SCRIPT_DIR/setup-link"
if [ -f "$LOCAL_SCRIPT" ]; then
    local_hash=$(md5 -r "$LOCAL_SCRIPT" | cut -d' ' -f1)
    remote_hash=$(ssh_cmd "md5sum /usr/bin/setup-link" | cut -d' ' -f1)

    if [ "$local_hash" = "$remote_hash" ]; then
        echo "  OK  /usr/bin/setup-link is current"
    else
        echo "  FIX setup-link differs (local: ${local_hash:0:8}, remote: ${remote_hash:0:8})"
        if ! $CHECK_ONLY; then
            scp -O "$LOCAL_SCRIPT" "$ROUTER:/usr/bin/setup-link" 2>/dev/null
            ssh_cmd "chmod +x /usr/bin/setup-link"
            echo "  Deployed"
        fi
    fi
else
    echo "  SKIP $LOCAL_SCRIPT not found locally"
fi
echo ""

# --- setup-link init script (boot persistence) ---
echo "=== setup-link Boot Service ==="
INIT_SCRIPT="/etc/init.d/setup-link"
INIT_CONTENT='#!/bin/sh /etc/rc.common
START=99
start() {
    /usr/bin/setup-link boot
}'
remote_init=$(ssh_cmd "cat $INIT_SCRIPT 2>/dev/null")
if [ "$remote_init" = "$INIT_CONTENT" ]; then
    if ssh_cmd "test -L /etc/rc.d/S99setup-link"; then
        echo "  OK  Init script installed and enabled"
    else
        echo "  FIX Init script exists but not enabled"
        if ! $CHECK_ONLY; then
            ssh_cmd "$INIT_SCRIPT enable"
            echo "  Enabled"
        fi
    fi
else
    echo "  FIX Init script missing or outdated"
    if ! $CHECK_ONLY; then
        echo "$INIT_CONTENT" | ssh "$ROUTER" "cat > $INIT_SCRIPT && chmod +x $INIT_SCRIPT" 2>/dev/null
        ssh_cmd "$INIT_SCRIPT enable"
        echo "  Installed and enabled"
    fi
fi
echo ""

# --- README ---
echo "=== README ==="
LOCAL_README="$SCRIPT_DIR/README-config.txt"
if [ -f "$LOCAL_README" ]; then
    if $CHECK_ONLY; then
        echo "  OK  $LOCAL_README exists (will sync on apply)"
    else
        scp -O "$LOCAL_README" "$ROUTER:/root/README-config.txt" 2>/dev/null
        echo "  OK  Synced /root/README-config.txt"
    fi
else
    echo "  SKIP $LOCAL_README not found locally"
fi
echo ""

# --- Tailscale ---
echo "=== Tailscale ==="
if ssh_cmd "which tailscale >/dev/null 2>&1"; then
    ts_status=$(ssh_cmd "tailscale status --json 2>/dev/null" | grep -o '"BackendState": *"[^"]*"' | cut -d'"' -f4 || true)
    if [ "$ts_status" = "Running" ]; then
        ts_ip=$(ssh_cmd "tailscale ip -4 2>/dev/null")
        echo "  OK  Tailscale running ($ts_ip)"
    elif [ "$ts_status" = "NeedsLogin" ]; then
        echo "  FIX Tailscale needs login"
        if ! $CHECK_ONLY; then
            echo "  Run on router: tailscale up --accept-routes --advertise-exit-node"
            echo "  Then authenticate via the URL it prints."
        fi
    else
        echo "  FIX Tailscale not running (state: ${ts_status:-unknown})"
        if ! $CHECK_ONLY; then
            ssh_cmd "/etc/init.d/tailscale start 2>/dev/null"
            echo "  Started. May need: tailscale up --accept-routes"
        fi
    fi
else
    echo "  NOT INSTALLED"
    echo "  Install via GL.iNet web UI: Applications > Tailscale"
    echo "  Or: opkg update && opkg install tailscale"
    echo "  Then: tailscale up --accept-routes --advertise-exit-node"
fi
echo ""

# --- Summary ---
if $CHECK_ONLY; then
    echo "=== Dry run complete. Run without --check to apply. ==="
else
    echo "=== Provisioning complete ==="
    echo ""
    echo "Next steps:"
    echo "  1. setup-link arrive    (on router, to configure for current location)"
    echo "  2. Verify: setup-link status"
fi

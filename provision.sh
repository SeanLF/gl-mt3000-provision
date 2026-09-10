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

# Every drift goes through here so --check can exit non-zero when anything
# needs fixing. A dry run that always exits 0 is not an instrument.
FIXES=0
UNRESOLVED=0
fix() {
    echo "  FIX $*"
    FIXES=$((FIXES + 1))
}
# A FIX this script cannot or did not repair; apply mode exits 1 if any remain.
unresolved() {
    echo "  $*" >&2
    UNRESOLVED=$((UNRESOLVED + 1))
}
# Remote mutation: a non-zero exit is reported and counted, never a silent abort.
ssh_do() {
    ssh_cmd "$1" || unresolved "ERROR: remote command failed: $1"
}

# --- UCI desired state ---
# format: package.key=value
# DNS handled separately in apply_dns_settings() because the schema changed
# between firmware 4.8.x (gl-dns) and 4.9.x (gl-dns-v2).
UCI_SETTINGS="
repeater.@main[0].auto=2
repeater.@main[0].disabled=0
mtkhnat.global.enable=0
kmwan.modem_1_1_2.disabled=1
kmwan.modem_1_1_2_6.disabled=1
kmwan.global.sensitivity=10000
firewall.@defaults[0].tcp_ecn=2
"
# firewall note:
#   fw3 writes /proc/sys/net/ipv4/tcp_ecn from this option (default 0) on every
#   firewall reload -- boot and each ifup -- after /etc/sysctl.d has run, so the
#   tcp_ecn line in the sysctl file alone never held (found 2026-09-10).
#   2 = ECN when the peer asks for it; pairs with CAKE.
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
    4.7.* | 4.8.* | 4.9.* | 4.11.*) echo "  OK  glversion $GLVERSION (tested)" ;;
    "") echo "  WARN /etc/glversion missing; proceeding anyway" ;;
    *) echo "  WARN glversion $GLVERSION not in tested set (4.7/4.8/4.9/4.11). UCI schema may have shifted; review provision output before commit." ;;
esac
# Same API the download centre uses; newest RELEASE entry comes first.
latest_fw=$(curl -s --max-time 5 'https://firmware-api.gl-inet.com/cloud-api/model/info?model=mt3000' 2>/dev/null |
    grep -o '"version":"[^"]*","stage":"RELEASE"' | head -1 | cut -d'"' -f4 || true)
# Only nag when stable is actually newer (a beta ahead of stable is fine).
if [ -n "$latest_fw" ] && [ -n "$GLVERSION" ] && [ "$latest_fw" != "$GLVERSION" ] &&
    [ "$(printf '%s\n%s\n' "$GLVERSION" "$latest_fw" | sort -V | tail -1)" = "$latest_fw" ]; then
    echo "  INFO stable firmware $latest_fw available (running $GLVERSION); see README-config.txt upgrade checklist"
fi
echo ""

# --- SSH key ---
echo "=== SSH Key ==="
PUBKEY_FILE="$HOME/.ssh/id_ed25519.pub"
if [ -f "$PUBKEY_FILE" ]; then
    pubkey=$(cat "$PUBKEY_FILE")
    if ssh_cmd "grep -qF '$(echo "$pubkey" | awk '{print $2}')' /etc/dropbear/authorized_keys 2>/dev/null"; then
        echo "  OK  SSH key installed"
    else
        fix "SSH key not in authorized_keys"
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
        fix "$key: $current -> $want"
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
        case "$pkg" in
            firewall)
                ssh_do "/etc/init.d/firewall reload >/dev/null 2>&1"
                echo "  Reloaded: firewall"
                ;;
        esac
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
    fix "gl-repeater not running"
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
dat_changed=false
for band in b0 b1; do
    dat="/etc/wireless/mediatek/mt7981.dbdc.${band}.dat"
    echo "  --- $band ---"
    for line in $DAT_SETTINGS; do
        [ -z "$line" ] && continue
        key="${line%%=*}"
        want="${line#*=}"
        current=$(ssh_cmd "grep ^${key}= $dat" | head -1 | cut -d= -f2 || true)

        if [ "$current" = "$want" ]; then
            echo "  OK  $key = $want"
        else
            fix "$key: ${current:-UNSET} -> $want"
            if ! $CHECK_ONLY; then
                # sed on an absent key is a silent no-op; append instead.
                if [ -n "$current" ]; then
                    ssh_do "sed -i 's/^${key}=.*/${key}=${want}/' $dat"
                else
                    ssh_do "echo '${key}=${want}' >> $dat"
                fi
                dat_changed=true
            fi
        fi
    done
done
# The driver reads the .dat only at (re)load; without this the edit is inert
# until the next reboot. Drops WiFi for a few seconds.
if $dat_changed; then
    ssh_cmd "wifi reload" || true
    echo "  Reloaded: wifi (brief WiFi drop)"
fi
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
    fix "$SYSCTL_FILE needs creating/updating"
    if ! $CHECK_ONLY; then
        echo "$SYSCTL_CONTENT" | ssh "$ROUTER" "cat > $SYSCTL_FILE" 2>/dev/null
        ssh_cmd "sysctl -p $SYSCTL_FILE" >/dev/null
        echo "  Written and applied"
    fi
fi

# The file being right is not the same as the kernel agreeing: something later
# in boot can rewrite a key (fw3 did exactly that to tcp_ecn). Compare live.
# setup-link retunes tcp_rmem/tcp_wmem/tcp_limit_output_bytes per link tier,
# so only the keys it leaves alone are checked here.
SYSCTL_LIVE="
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_ecn=2
net.ipv4.tcp_fastopen=3
net.netfilter.nf_conntrack_tcp_timeout_established=3600
net.netfilter.nf_conntrack_tcp_timeout_time_wait=30
"
for line in $SYSCTL_LIVE; do
    [ -z "$line" ] && continue
    key="${line%%=*}"
    want="${line#*=}"
    current=$(ssh_cmd "sysctl -n $key" | tr -d '\r' || echo "UNSET")
    if [ "$current" = "$want" ]; then
        echo "  OK  live $key = $want"
    else
        fix "live $key: ${current:-UNSET} -> $want"
        if ! $CHECK_ONLY; then
            ssh_do "sysctl -qw $key=$want"
            echo "  Applied"
        fi
    fi
done
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

# dnsmasq cache only matters on the 4.8 stack (dnsmasq -> stubby). From 4.9 the
# forwarder behind dnsmasq keeps its own cache and the firmware strips the
# dnsmasq cachesize key on every boot (seen on 4.11.0), so do not fight it.
if [ "$DNS_PKG" = "gl-dns" ]; then
    current=$(ssh_cmd "uci -q get dhcp.@dnsmasq[0].cachesize" || echo "UNSET")
    if [ "$current" = "1000" ]; then
        echo "  OK  dhcp.@dnsmasq[0].cachesize = 1000"
    else
        fix "dhcp.@dnsmasq[0].cachesize: $current -> 1000"
        if ! $CHECK_ONLY; then
            ssh_cmd "uci set dhcp.@dnsmasq[0].cachesize='1000'; uci commit dhcp"
        fi
    fi
else
    echo "  SKIP dnsmasq cachesize ($DNS_PKG firmware re-applies DNS at boot and deletes it)"
fi

dns_changed=false
for line in $DECLS; do
    key="${line%%=*}"
    want="${line#*=}"
    current=$(ssh_cmd "uci -q get $DNS_PKG.@dns[0].$key" || echo "UNSET")
    if [ "$current" = "$want" ]; then
        echo "  OK  $DNS_PKG.@dns[0].$key = $want"
    else
        fix "$DNS_PKG.@dns[0].$key: $current -> $want"
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
    fix "NextDNS ID not set"
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
    remote_hash=$(ssh_cmd "md5sum /usr/bin/setup-link" | cut -d' ' -f1 || true)

    if [ "$local_hash" = "$remote_hash" ]; then
        echo "  OK  /usr/bin/setup-link is current"
    else
        fix "setup-link differs (local: ${local_hash:0:8}, remote: ${remote_hash:0:8})"
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
remote_init=$(ssh_cmd "cat $INIT_SCRIPT 2>/dev/null" || true)
if [ "$remote_init" = "$INIT_CONTENT" ]; then
    if ssh_cmd "test -L /etc/rc.d/S99setup-link"; then
        echo "  OK  Init script installed and enabled"
    else
        fix "Init script exists but not enabled"
        if ! $CHECK_ONLY; then
            ssh_cmd "$INIT_SCRIPT enable"
            echo "  Enabled"
        fi
    fi
else
    fix "Init script missing or outdated"
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
    local_hash=$(md5 -r "$LOCAL_README" | cut -d' ' -f1)
    remote_hash=$(ssh_cmd "md5sum /root/README-config.txt" | cut -d' ' -f1 || true)
    if [ "$local_hash" = "$remote_hash" ]; then
        echo "  OK  /root/README-config.txt is current"
    else
        fix "README-config.txt differs (local: ${local_hash:0:8}, remote: ${remote_hash:0:8})"
        if ! $CHECK_ONLY; then
            scp -O "$LOCAL_README" "$ROUTER:/root/README-config.txt" 2>/dev/null
            echo "  Synced /root/README-config.txt"
        fi
    fi
else
    echo "  SKIP $LOCAL_README not found locally"
fi
echo ""

# --- Router extras ---
# Things setup-link needs that are not in the GL image and vanish on a flash:
# the Ookla CLI (copied by hand, no package) and luci-base, whose tzdata.lua
# gives 'setup-link timezone' its IANA -> POSIX map. sqm-scripts and
# kmod-sched-cake are user-installed on 4.8.x but ship in the image from 4.9.0.
echo "=== Router Extras ==="
if ssh_cmd "test -x /usr/bin/gl_speedtest"; then
    echo "  OK  gl_speedtest present (4.11+ Cloudflare test; Ookla CLI is the optional fallback)"
elif ssh_cmd "test -x /usr/bin/speedtest"; then
    echo "  OK  speedtest CLI present ($(ssh_cmd 'speedtest --version 2>/dev/null | head -1' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' || echo '?'))"
else
    fix "no speed test binary: fetch the Ookla aarch64 musl tarball and copy speedtest to /usr/bin"
    $CHECK_ONLY || unresolved "no remedy here for the speed test binary"
fi
if ssh_cmd "test -f /usr/lib/lua/luci/sys/zoneinfo/tzdata.lua"; then
    echo "  OK  tzdata.lua present (setup-link timezone)"
else
    fix "tzdata.lua missing"
    if ! $CHECK_ONLY; then
        ssh_cmd "opkg update >/dev/null 2>&1; opkg install luci-base >/dev/null 2>&1" && echo "  Installed: luci-base" || unresolved "ERROR: opkg install luci-base failed"
    fi
fi
if ssh_cmd "test -x /etc/init.d/sqm && test -f /usr/lib/sqm/layer_cake.qos"; then
    echo "  OK  sqm-scripts present"
else
    fix "sqm-scripts missing"
    if ! $CHECK_ONLY; then
        ssh_cmd "opkg update >/dev/null 2>&1; opkg install sqm-scripts kmod-sched-cake >/dev/null 2>&1" && echo "  Installed: sqm-scripts kmod-sched-cake" || unresolved "ERROR: opkg install sqm-scripts failed"
    fi
fi

# opkg packages we want on the router. A flash drops them; re-provisioning
# puts them back. Keep this list short: tcpdump and mtr are the two tools that
# have earned their place debugging hotel links.
OPKG_PKGS="tcpdump mtr"
pkg_missing=""
for pk in $OPKG_PKGS; do
    ssh_cmd "opkg list-installed 2>/dev/null | grep -q '^$pk '" || pkg_missing="$pkg_missing $pk"
done
if [ -z "$pkg_missing" ]; then
    echo "  OK  opkg packages present: $OPKG_PKGS"
else
    fix "opkg packages missing:$pkg_missing"
    if ! $CHECK_ONLY; then
        ssh_cmd "opkg update >/dev/null 2>&1; opkg install$pkg_missing >/dev/null 2>&1" && echo "  Installed:$pkg_missing" || unresolved "ERROR: opkg install failed; on router run 'opkg update && opkg install$pkg_missing'"
    fi
fi

# GL's first-boot SQM script (4.9.0 rewrites, 4.11.0 deletes) acts on
# sqm.@queue[0] without checking what it is. Keep the stock disabled eth1
# stanza in slot 0 so setup-link's eth0 queue is never the one it touches.
# The hazard is setup-link's own queue sitting in slot 0; anything else there
# (the named eth1 stanza, or the anonymous one 4.11 recreates) is fine.
first_name=$(ssh_cmd "uci -q show sqm.@queue[0] | head -1 | cut -d= -f1 | cut -d. -f2" | tr -d '\r' || true)
first_if=$(ssh_cmd "uci -q get sqm.@queue[0].interface" | tr -d '\r' || true)
if [ -z "$first_name" ]; then
    echo "  SKIP no sqm queues yet (setup-link apply creates eth0)"
elif [ "$first_name" = "eth0" ] || [ "$first_if" = "eth0" ]; then
    fix "sqm.@queue[0] is setup-link's eth0 queue; a GL first-boot script would delete it"
    if ! $CHECK_ONLY; then
        ssh_do "uci -q get sqm.eth1 >/dev/null || { uci set sqm.eth1=queue; uci set sqm.eth1.enabled=0; uci set sqm.eth1.interface=eth1; }; uci reorder sqm.eth1=0; uci commit sqm"
        echo "  Reordered: sqm.eth1 -> slot 0"
    fi
else
    echo "  OK  sqm.@queue[0] is $first_name (eth0 shielded from GL first-boot scripts)"
fi
echo ""

# --- Sysupgrade keep list ---
# sysupgrade keeps /etc/config and a fixed list; everything else on the overlay
# is gone after a flash. /etc/sysupgrade.conf is itself on the keep list, and
# any path in it rides along in the config backup. Verified on the 4.8.1 ->
# 4.11.0 flash: setup-link, its boot state and the Ookla binary all vanished.
echo "=== Sysupgrade Keep List ==="
KEEP_PATHS="/usr/bin/setup-link /etc/init.d/setup-link /etc/rc.d/S99setup-link /etc/setup-link.last /etc/sysctl.d/99-latency-tuning.conf /usr/bin/speedtest /root/README-config.txt"
keep_missing=""
for kp in $KEEP_PATHS; do
    ssh_cmd "grep -qxF '$kp' /etc/sysupgrade.conf 2>/dev/null" || keep_missing="$keep_missing $kp"
done
if [ -z "$keep_missing" ]; then
    echo "  OK  /etc/sysupgrade.conf lists setup-link, its state, sysctl file, speedtest"
else
    fix "/etc/sysupgrade.conf missing:$keep_missing"
    if ! $CHECK_ONLY; then
        # Ensure the file ends in a newline first, or the first path glues onto the last line.
        ssh_do "[ ! -s /etc/sysupgrade.conf ] || [ -z \"\$(tail -c1 /etc/sysupgrade.conf)\" ] || echo >> /etc/sysupgrade.conf"
        for kp in $keep_missing; do ssh_do "echo '$kp' >> /etc/sysupgrade.conf"; done
        echo "  Added"
    fi
fi
echo ""

# --- Tailscale ---
# GL's in-UI updater writes a new daemon to /usr/sbin/tailscaled and its CLI to
# /usr/bin/tailscale, but leaves any older /usr/sbin/tailscale in place, which
# shadows the new CLI on PATH and is the binary /usr/bin/gl_tailscale calls.
# gl_tailscale also runs 'tailscale up --reset' on every reload, so flags passed
# by hand (exit node, routes) never survive: set those in the web UI.
echo "=== Tailscale ==="
if ssh_cmd "which tailscaled >/dev/null 2>&1"; then
    daemon_ver=$(ssh_cmd "tailscaled --version 2>/dev/null | head -1" | tr -d '\r' || true)
    cli_ver=$(ssh_cmd "tailscale version 2>/dev/null | head -1" | tr -d '\r' || true)
    if [ -n "$daemon_ver" ] && [ "$cli_ver" = "$daemon_ver" ]; then
        echo "  OK  tailscale CLI and daemon both $daemon_ver"
    else
        fix "tailscale CLI ${cli_ver:-missing} != tailscaled ${daemon_ver:-unknown}"
        if ! $CHECK_ONLY; then
            alt_ver=$(ssh_cmd "/usr/bin/tailscale version 2>/dev/null | head -1" | tr -d '\r' || true)
            if [ -n "$alt_ver" ] && [ "$alt_ver" = "$daemon_ver" ]; then
                ssh_do "ln -sf /usr/bin/tailscale /usr/sbin/tailscale"
                echo "  Linked /usr/sbin/tailscale -> /usr/bin/tailscale ($alt_ver)"
            else
                unresolved "No CLI matching the daemon on the router; update Tailscale from the web UI (Applications > Tailscale)"
            fi
        fi
    fi

    latest_ver=$(curl -s --max-time 5 'https://pkgs.tailscale.com/stable/?mode=json' 2>/dev/null | grep -o '"Version": *"[^"]*"' | cut -d'"' -f4 || true)
    if [ -n "$latest_ver" ] && [ -n "$daemon_ver" ] && [ "$latest_ver" != "$daemon_ver" ]; then
        echo "  INFO tailscale $daemon_ver installed, $latest_ver is current stable (update from the web UI)"
    fi

    ts_status=$(ssh_cmd "tailscale status --json 2>/dev/null" | grep -o '"BackendState": *"[^"]*"' | cut -d'"' -f4 || true)
    if [ "$ts_status" = "Running" ]; then
        ts_ip=$(ssh_cmd "tailscale ip -4 2>/dev/null" || true)
        echo "  OK  Tailscale running ($ts_ip)"
    elif [ "$ts_status" = "NeedsLogin" ]; then
        fix "Tailscale needs login"
        $CHECK_ONLY || unresolved "log in from the web UI (Applications > Tailscale)"
    else
        fix "Tailscale not running (state: ${ts_status:-unknown})"
        if ! $CHECK_ONLY; then
            ssh_cmd "/etc/init.d/tailscale start 2>/dev/null"
            echo "  Started. If it stays down, enable it from the web UI (Applications > Tailscale)"
        fi
    fi
else
    echo "  NOT INSTALLED"
    echo "  Install and enable via the web UI: Applications > Tailscale"
fi
echo ""

# --- Summary ---
if $CHECK_ONLY; then
    if [ "$FIXES" -gt 0 ]; then
        echo "=== Dry run: $FIXES item(s) need fixing. Run without --check to apply. ==="
        exit 1
    fi
    echo "=== Dry run: everything OK. ==="
else
    if [ "$UNRESOLVED" -gt 0 ]; then
        echo "=== Provisioning finished with $UNRESOLVED unresolved item(s); see ERROR lines above ==="
        exit 1
    fi
    echo "=== Provisioning complete ==="
    echo ""
    echo "Next steps:"
    echo "  1. setup-link arrive    (on router, to configure for current location)"
    echo "  2. Verify: setup-link status"
fi

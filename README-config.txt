GL-MT3000 - Configuration Notes
====================================================
Last updated: 2026-09-10 (running 4.11.0 beta1)

LOCATION-SPECIFIC (example: FTTH via ISP router -- update when travelling)
---------------------------------------------------------
Upstream: FTTH ~330/430 Mbps via ISP all-in-one router.
  Uplinks: ethernet WAN into the ISP LAN (primary, metric 10) and
  repeater on the ISP 5GHz SSID (failover, metric 20).
  kmwan swaps the default route automatically when ethernet unplugs.

SQM/CAKE (managed by setup-link script):
  Decision rule (2026-09-10): <50 Mbps CAKE 85%; 50-100 CAKE 92%; >100 shape
  at 92% only if ping under load rises >10 ms over idle (BLOAT_OK_MS), else
  unshaped; >300 (CAKE_MAX_KBPS) always unshaped. On 4.11 gl_speedtest measures
  idle/loaded ping itself and setup-link shapes on its 10 s average, not the
  peak. On older firmware fping/ping samples during the Ookla run.
  Why: this DOCSIS 3.1 line (Technicolor CGA4236, PIE AQM on the modem's
  upstream) bloats a moderate +25-47 ms unshaped and delivers ~100-105 Mbps,
  so the old ">100 = unshaped" rule chose wrong here; a clean fibre line
  still goes unshaped. Measured on the router, 18 pings to 1.1.1.1 during a
  20 s saturating transfer: unshaped avg 46 / max 73 ms; CAKE 92/92 avg 16 /
  max 28 ms (idle 20.6). Tests: tests/setup-link.bats (mise run test).
  setup-link apply <down> <up> dsl       -- ADSL locations (ATM, MTU 1450)
  setup-link apply <down> <up> docsis    -- behind a cable modem (overhead 18)
  setup-link apply <down> <up> ethernet  -- hotel/tether (overhead 34)
  setup-link off                         -- fast links >100 Mbps
  setup-link test                        -- speed test + suggestion
  setup-link timezone [zone]             -- IANA zone -> POSIX with DST rules

  Current (home, 100/100 plan, ethernet WAN into a DOCSIS cable gateway):
    setup-link apply 100 100 docsis  -- CAKE 92/92 Mbit, overhead 18, MTU 1500
    Use the plan rate, not one speedtest: measured 99/85 on 2026-09-10 but
    upload varies with the server. Not 'dsl': DOCSIS has no ATM cells.
  Fast links >100 Mbps get 'setup-link off' (no SQM, HW offload on, MTU 1500).
  The 'dsl' flag sets: ATM linklayer, overhead 40, ack-filter-aggressive, rtt 50ms
  The 'ethernet' flag sets: ethernet linklayer, overhead 34, rtt 50ms
  Both use: layer_cake.qos, diffserv4, nat, split-gso

MTU: managed by setup-link (1450 for dsl, 1500 otherwise).
  1450 is ATM cell alignment (31 cells, zero padding waste); fw3 clamps
  TCP MSS via "clamp to PMTU".

ROUTER-WIDE (keep everywhere)
---------------------------------------------------------

1. REPEATER auto=2 (WAN_ONLY mode), disabled=0
   uci set repeater.@main[0].auto='2' && uci commit repeater
   When ethernet WAN is online, the repeater daemon idles (no scanning).
   When ethernet disconnects, scanning resumes for hotel WiFi.
   Prevents 100-130ms WiFi latency spikes every 5-10s.
   Values: 0=never auto-switch, 1=always scan (default), 2=WAN-only
   disabled MUST stay 0: the web UI off-toggle sets disabled=1, which stops
   the gl-repeater daemon and removes its ubus API -- repeater join then
   fails silently everywhere (found 2026-06-10; provision.sh now enforces 0).
   auto=2 already makes "off while wired" automatic; never hard-disable.
   WARNING: 4.9.x's /etc/uci-defaults/gl-repeater explicitly forces auto=2
   back to 1 on first boot. Re-run provision.sh after any firmware upgrade.
   Daemon binary still appears to honor value 2 (verified via static diff
   of gl-sdk4-repeater-v2 between 4.8.1 and 4.9.0_beta1: no opcode removed),
   but this is unconfirmed at runtime. Watch logread for repeater behavior
   after re-applying.

2. HARDWARE OFFLOAD DISABLED
   uci set mtkhnat.global.enable='0' && uci commit mtkhnat
   mtkhnat bypasses SQM/CAKE when offloading flows.
   MUST stay disabled whenever SQM is active. Re-enable if SQM is off.

3. WIFI .dat TUNING (/etc/wireless/mediatek/mt7981.dbdc.b0,1.dat)
   AMSDU_NUM=8        (default: max aggregation, no meaningful latency cost)
   TWTSupport=0       (was 1: eliminates TWT buffering)
   VOW_Airtime_Fairness_En=0  (was 1: unnecessary with few clients)
   BSSColorValue=1    (was 255: enables proper 802.11ax spatial reuse)
   BssidNum             not managed: mtk-wifi-configurator overwrites from UCI interface count
   Changes require: wifi reload (briefly drops WiFi)

4. SYSCTL TUNING (/etc/sysctl.d/99-latency-tuning.conf)
   tcp_rmem/wmem max=524288    (cap TCP buffers, prevents bloat)
   tcp_limit_output_bytes=131072  (reduce batching on slow links)
   tcp_slow_start_after_idle=0 (keep connections warm)
   tcp_ecn=2                   (request ECN, works with CAKE)
   tcp_fastopen=3              (client + server TFO)
   conntrack established=3600  (1h vs 5d default)
   conntrack time_wait=30      (30s vs 120s default)
   ECN GOTCHA (found 2026-09-10): fw3 writes /proc/sys/net/ipv4/tcp_ecn from
   firewall.@defaults[0].tcp_ecn (default 0) on every firewall reload, which
   runs after sysctl at boot and again on each ifup. The sysctl line was
   silently 0 at runtime for months. provision.sh now sets the firewall
   option to 2 and compares live sysctl values, not just the file.

5. KMWAN HEALTH CHECK
   Sensitivity=10000 (was 3000), pings every 10s not 1s.
   Per-interface disable via kmwan.<iface>.disabled='1' (NOT 'enabled' --
   kmwan ignores that key).
     - modem_1_1_2 / modem_1_1_2_6: disabled. Phantom interfaces, MT3000 has
       no cellular slot.
     - wan6 / wwan6 / tethering6: stay at firmware default (disabled). We
       don't currently use IPv6 over multi-WAN.
     - wwan / tethering: LEFT TRACKED. Repeater (auto=2) handles WHEN to
       bring them up; kmwan handles HOW to route once they're active.
       Disabling them in kmwan would break automatic default-route handoff
       when ethernet drops and repeater connects to hotel WiFi.

6. DNS (NextDNS over TLS)
   dnsmasq cache=1000 (was 150) -- 4.8.x only. On gl-dns-v2 firmware (4.9+)
   /etc/init.d/gl_dns boot() re-applies the DNS config through the dns RPC
   whenever mode != auto, and that rewrite deletes dhcp cachesize, so it is
   back to dnsmasq's default 150 after every boot (verified on 4.11.0: it
   survives service restarts, not boot). The forwarder behind dnsmasq on
   4.11 is AdGuard dnsproxy started WITHOUT --cache. provision.sh skips the
   key on v2 rather than fight the firmware; if the 150-entry cache ever
   shows up as latency, the S99 setup-link boot hook runs after gl_dns (S95)
   and could reinstate it.
   NextDNS via GL.iNet encrypted DNS, override all clients + override VPN DNS.
   NextDNS ID set per-profile (not stored in provision script).

   Backend stack changed in 4.9.x:
     4.8.x: gl-dns package + Stubby (DoT only).
            keys: mode=secure / proto=DoT / dot_provider=1 (NextDNS)
     4.9.x: gl-dns-v2 package + dnscrypt-proxy2 (DoT/DoH/DoQ/DNSCrypt).
            keys: mode=secure / proto=dot / provider=nextdns
   provision.sh detects the live package and writes the right schema.
   On a 4.8 -> 4.9 upgrade WITH config retention, /etc/uci-defaults/99-dns
   migrates old gl-dns config to gl-dns-v2 then deletes /etc/config/gl-dns.

7. TAILSCALE
   Managed by GL's gl-sdk4-tailscale: /etc/init.d/tailscale runs
   /usr/sbin/tailscaled, and /usr/bin/gl_tailscale runs
   'tailscale up --reset --accept-routes ... --accept-dns=false' on every
   reload. Anything passed to 'tailscale up' by hand (exit node, routes) is
   wiped on the next reload: set those in the web UI (Applications > Tailscale).
   The in-UI updater writes the new daemon to /usr/sbin/tailscaled and the
   CLI to /usr/bin/tailscale but leaves an older /usr/sbin/tailscale behind,
   which wins on PATH. provision.sh checks CLI == daemon version and symlinks
   /usr/sbin/tailscale -> /usr/bin/tailscale when they differ.

JOINING WIFI (travel/hotel WiFi)
---------------------------------------------------------
CLI (from laptop or router):  setup-link wifi <ssid> <key>
  Re-enables the repeater if the web UI toggle disabled it, starts the
  daemon, joins via ubus, polls until connected, prints band + signal.
  Status only: setup-link wifi
Web UI alternative: Internet > Repeater.
auto=2 means it only scans when ethernet WAN is down.
When you plug ethernet back in, it idles automatically.

FLASH RECORD: 4.8.1 -> 4.11.0 beta1 (2026-09-10, at home, sysupgrade keep-settings)
---------------------------------------------------------
What first boot did, as predicted by the static diff below:
  repeater auto 2 -> 1; sqm.@queue[0] (eth1) deleted and recreated last, so
  eth0 became queue[0] (setup-link's queue survived because eth1 was first);
  gl-dns migrated to gl-dns-v2 provider=nextdns proto=dot with the ID intact;
  dhcp cachesize removed by the DNS migration; WiFi .dat tuning reset;
  /etc/sysctl.d/99-latency-tuning.conf gone; setup-link, its init script,
  /etc/setup-link.last, /usr/bin/speedtest and the Tailscale 1.102.3 binaries
  gone (overlay is not kept). Two provision.sh runs put everything back; the
  first run exposed that a missing remote file aborted the script (fixed:
  every remote command substitution is now guarded).
Keep list: provision.sh now appends setup-link, its state, the sysctl file
  and speedtest to /etc/sysupgrade.conf, verified present in 'sysupgrade -b'.
WiFi: SKU tables unchanged, Tx-Power still 20 dBm / 100 mW on ch36 CA.
  Driver TEST-23 reports client signal in iwinfo assoclist ~47 dB lower for
  every client (-34 -> -81, -40 -> -91) while the Mac's own RSSI is unchanged
  (-57 -> -59) and the tuned .dat keys are back. Treat assoclist dBm on this
  driver as a different scale, not a power change.
cake-autorate trial (Mac on 5 GHz, networkQuality -v, same afternoon):
  no SQM (HW offload)    up 39 / down 98 Mbps   idle 1246 RPM   loaded 168 RPM (356 ms)
  static CAKE 92/92      up 75 / down 79        idle 1203       loaded 485 RPM (123 ms)
  CAKE + cake-autorate   up 83 / down 81        idle 1324       loaded 462 RPM (130 ms)
  Autorate matched static on latency with more throughput and ramped to its
  100 Mbit ceiling. GOTCHA: cake-autorate.<section>.ul_if must be the device
  (eth0) and dl_if the sqm ifb (ifb4eth0); with ul_if=wan it waits forever for
  'ifb-wan'. Left DISABLED with the section in place: its bounds are static
  numbers too, so on a hotel link setup-link's tiers and autorate's min/max
  would fight. Next step if wanted: have 'setup-link apply' write autorate
  bounds from the measured rate (min 25%, base 85%, max 100%) and enable it,
  replacing the fixed 85/92% tiers. Re-enable for testing:
    uci set cake-autorate.wan.enabled=1 && uci commit cake-autorate && /etc/init.d/cake-autorate start
gl_speedtest (4.11+): /usr/bin/gl_speedtest ping|download|upload against
  speed.cloudflare.com, one result line per phase, max_time bounds each run.
  SQM paused, back to back: Cloudflare 110.5 down / 112.7 up, idle ping 30 ms;
  Ookla 98.4 / 99.2, ping 21 ms. setup-link prefers gl_speedtest when present
  and falls back to the Ookla CLI, so the hand-copied binary is only needed on
  firmware before 4.11. Both measure the cable burst above the 100/100 plan;
  keep shaping on the plan rate at home.
Unshaped uplink measured 39 Mbps vs 75-83 shaped: the cable gateway's own
  upstream buffer throttles ACKs; SQM is worth keeping at home.

FIRMWARE 4.9.0 / 4.11.0 STATIC DIFF (done 2026-09-10 against 4.8.1)
---------------------------------------------------------
Extracted the three sysupgrade images (root squashfs) and compared. Same
kernel 5.4.211 and MTK SDK in all three. What touches this setup:
  - repeater: /etc/uci-defaults/gl-repeater in 4.9.0 AND 4.11.0 forces
    auto=2 back to 1 on first boot. The daemon (Lua bytecode run by eco)
    keeps its kmwan-status hooks in all three, nothing removed, so mode 2
    should still work; re-run provision.sh after the flash and watch logread.
  - DNS: stubby/gl-dns gone in 4.9.0; dnscrypt-proxy2/gl-dns-v2 replaces it.
    99-dns migration maps proto=DoT + dot_provider=1 -> provider=nextdns,
    proto=dot and carries nextdns_id. provision.sh writes the same schema.
  - SQM: sqm-scripts + kmod-sched-cake ship in the image from 4.9.0 (they are
    user-installed on 4.8.x). GL's own SQM UI appears; on first boot
    03_gl_sqm adds a 'service' section and rewrites sqm.@queue[0]. In 4.11.0
    it DELETES sqm.@queue[0] and recreates sqm.eth1. KEEP the stock disabled
    'eth1' stanza first in /etc/config/sqm so queue[0] is eth1, not our eth0.
  - 4.11.0 adds cake-autorate (disabled by default) and a network-quality
    probe (disabled). Both overlap setup-link; leave them off.
  - WiFi: SKU power tables (mt7981-sku.dat, sku_01_config.dat) are byte-
    identical across 4.8.1/4.9.0/4.11.0, so no regulatory power cut for us.
    Only default-profile change is HideSSID=1 in the shipped .dat, which does
    not affect the tuned keys. Driver kmod-mt_wifi TEST-16 -> TEST-23 in 4.11.
    Radio section names mt798111/mt798112 unchanged.
  - Tailscale: image ships 1.92.5 (was 1.80.3). gl_tailscale still runs
    'tailscale up --reset' but gains uci tailscale.settings.run_exit_node=1
    -> --advertise-exit-node, i.e. exit node is a UI/uci setting now.
  - ca-bundle 20210119 -> 20260601. dnsmasq 2.92. dropbear still 2024.86
    with classical kex only. OpenSSL 1.1.1q and curl 7.83 unchanged.
  - firewall/kmwan/mtkhnat defaults unchanged: tcp_ecn fix still needed.
  - Not in any image, so re-add after a flash: /usr/bin/speedtest (Ookla
    binary copied by hand) and luci-base (tzdata.lua for setup-link
    timezone). provision.sh --check reports both under Router Extras.

5 GHz BASELINE (2026-09-10, 4.8.1, country CA, ch36 HE80, txpower 100%)
  Router reports Tx-Power 20 dBm; txpowerlist tops out at 20 dBm (100 mW).
  Router sees this Mac at -34 dBm; Mac sees router at RSSI -57 / noise -94,
  HE-MCS 6, NSS 2, 648 Mbps. Re-measure after any flash:
    iwinfo rax0 info | grep Tx-Power; iwinfo rax0 txpowerlist | tail -1
    iwinfo rax0 assoclist            (router side)
    sudo wdutil info | grep -E "RSSI|Noise|Tx Rate"   (Mac side)

FIRMWARE UPGRADE CHECKLIST
---------------------------------------------------------
Easiest: re-run provision.sh from the laptop. It is idempotent and version-aware.
Manual checks if provisioning by hand:
  1. uci get repeater.@main[0].auto           (should be 2)
     uci get repeater.@main[0].disabled       (should be 0)
  2. uci get mtkhnat.global.enable             (should be 0)
  3. grep AMSDU_NUM /etc/wireless/mediatek/mt7981.dbdc.b1.dat  (should be 8)
  4. cat /etc/sysctl.d/99-latency-tuning.conf  (should exist)
     sysctl -n net.ipv4.tcp_ecn                 (should be 2; if 0, see ECN GOTCHA)
     uci get firewall.@defaults[0].tcp_ecn      (should be 2)
  5. grep rtt /usr/bin/setup-link              (should show rtt 50ms)
  6. NextDNS ID present:
       4.8.x:  uci get gl-dns.@dns[0].nextdns_id
       4.9.x+: uci get gl-dns-v2.@dns[0].nextdns_id
  7. uci show kmwan | grep disabled  (modem_1_1_2{,_6} should be 1)
  8. tailscale version | head -1; tailscaled --version   (should match)
  9. ls /usr/bin/speedtest /usr/lib/lua/luci/sys/zoneinfo/tzdata.lua  (extras)
 10. uci get sqm.@queue[0].interface   (eth1; provision.sh reorders if not)

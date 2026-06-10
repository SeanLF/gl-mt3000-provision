GL-MT3000 - Configuration Notes
====================================================
Last updated: 2026-06-10

LOCATION-SPECIFIC (example: FTTH via ISP router -- update when travelling)
---------------------------------------------------------
Upstream: FTTH ~330/430 Mbps via ISP all-in-one router.
  Uplinks: ethernet WAN into the ISP LAN (primary, metric 10) and
  repeater on the ISP 5GHz SSID (failover, metric 20).
  kmwan swaps the default route automatically when ethernet unplugs.

SQM/CAKE (managed by setup-link script):
  setup-link apply <down> <up> dsl       -- ADSL locations
  setup-link apply <down> <up> ethernet  -- hotel/tether
  setup-link off                         -- fast links >100 Mbps
  setup-link test                        -- speed test + suggestion

  Current: setup-link off  (link >100 Mbps: no SQM, HW offload on, MTU 1500)
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
   dnsmasq cache=1000 (was 150)
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

JOINING WIFI (travel/hotel WiFi)
---------------------------------------------------------
CLI (from laptop or router):  setup-link wifi <ssid> <key>
  Re-enables the repeater if the web UI toggle disabled it, starts the
  daemon, joins via ubus, polls until connected, prints band + signal.
  Status only: setup-link wifi
Web UI alternative: Internet > Repeater.
auto=2 means it only scans when ethernet WAN is down.
When you plug ethernet back in, it idles automatically.

FIRMWARE UPGRADE CHECKLIST
---------------------------------------------------------
Easiest: re-run provision.sh from the laptop. It is idempotent and version-aware.
Manual checks if provisioning by hand:
  1. uci get repeater.@main[0].auto           (should be 2)
     uci get repeater.@main[0].disabled       (should be 0)
  2. uci get mtkhnat.global.enable             (should be 0)
  3. grep AMSDU_NUM /etc/wireless/mediatek/mt7981.dbdc.b1.dat  (should be 8)
  4. cat /etc/sysctl.d/99-latency-tuning.conf  (should exist)
  5. grep rtt /usr/bin/setup-link              (should show rtt 50ms)
  6. NextDNS ID present:
       4.8.x:  uci get gl-dns.@dns[0].nextdns_id
       4.9.x+: uci get gl-dns-v2.@dns[0].nextdns_id
  7. uci show kmwan | grep disabled  (modem_1_1_2{,_6} should be 1)

# gl-mt3000-provision

Provisioning and link management for the GL.iNet GL-MT3000 (Beryl AX) travel router. Built for low latency on bad hotel links; works fine on good ones too.

Two tools, two jobs:

- **`provision.sh`** runs from your laptop. Syncs router-wide desired state over SSH: UCI settings, WiFi driver tuning, sysctl, encrypted DNS, and `setup-link` itself. Idempotent; re-run it after every firmware flash and it repairs whatever the upgrade reset.
- **`setup-link`** lives on the router. Per-location runtime decisions: SQM/CAKE shaping, MTU, hardware offload, WiFi country, repeater uplink. State persists in `/etc/setup-link.last` and replays at boot.

Rule of thumb: true in every country goes in `provision.sh`; depends on this hotel's link goes in `setup-link`.

## Quickstart

```sh
# once: enable SSH in the GL.iNet web UI (System > Security), then
ssh-copy-id root@192.168.8.1

./provision.sh --check     # dry run, shows what would change
./provision.sh             # apply

# then, on the router, at each new location:
setup-link arrive
```

`arrive` checks for an uplink (and offers to join WiFi if there is none), sets the WiFi country from your WAN IP, runs a speed test, and applies the right shaping for the measured link.

The router does not need to be at 192.168.8.1; point `ROUTER` anywhere SSH reaches it (e.g. Tailscale):

```sh
ROUTER=root@100.x.y.z ./provision.sh --check
```

## What provision.sh manages

| Thing | Setting | Why |
|---|---|---|
| Repeater | `auto=2`, `disabled=0` | Scan for WiFi only when ethernet WAN is down; kills periodic 100-130ms latency spikes. Keeps the daemon alive so joining WiFi always works. |
| Hardware offload | off while SQM active | mtkhnat bypasses CAKE when offloading flows |
| WiFi driver (.dat) | `AMSDU_NUM=8`, `TWTSupport=0`, airtime fairness off, BSS color on | Latency over throughput-marketing defaults |
| sysctl | capped TCP buffers, ECN, TFO, short conntrack | Bufferbloat control on slow links |
| DNS | NextDNS over TLS, forced for all clients | Schema differs between firmware 4.8.x (gl-dns) and 4.9.x (gl-dns-v2); detected automatically. Profile ID prompted, never stored. |
| kmwan | phantom modem interfaces disabled, 10s health pings | MT3000 has no cellular slot |
| setup-link | deployed to `/usr/bin`, boot service installed | |

Every item prints `OK` or `FIX` with the current vs desired value. `--check` never writes.

## setup-link commands

```
setup-link arrive                  Auto-detect, test, configure (new location)
setup-link test                    Speed test + SQM recommendation
setup-link apply <down> <up> [dsl|ethernet]   Apply SQM manually
setup-link off                     Fast link: hardware offload, no SQM
setup-link wifi <ssid> <key>       Join WiFi as repeater uplink
setup-link wifi                    Repeater status + scan nearby networks
setup-link country [CC]            Set/detect WiFi country code
setup-link status                  Show current config
```

Shaping tiers: <50 Mbps gets CAKE at 85% with tight TCP buffers, 50-100 Mbps gets 92%, >100 Mbps gets hardware offload and no SQM. The `dsl` link type adds ATM framing overhead and MTU 1450 for clean cell alignment.

WiFi join goes through the same ubus API as the web UI: encryption auto-detected, only SSID and key needed. If the repeater was disabled from the web UI (which silently kills the join API), `setup-link wifi` re-enables it.

## Requirements

- GL-MT3000 on stock GL.iNet firmware 4.7-4.9 (other GL.iNet MTK models likely work; radio names in `setup-link` assume mt7981)
- SSH key auth to the router
- `speedtest` (Ookla CLI) on the router for `test`/`arrive`; GL ships it

## Notes

`README-config.txt` documents every setting and the reasoning, including firmware upgrade gotchas (4.9.x resets `repeater.auto`, migrates the DNS schema). It syncs to `/root/README-config.txt` on the router so the docs travel with the hardware.

#!/usr/bin/env bats
# Runs setup-link against command shims; no router involved. Covers the tier
# and link-type maths, output parsing for both speed test backends, the
# bufferbloat decision, and boot replay.

setup() {
    TMP="$(mktemp -d)"
    export UCI_STORE="$TMP/uci" SYSCTL_LOG="$TMP/sysctl" FPING_CALLS="$TMP/fping" SQM_LOG="$TMP/sqm"
    export SETUP_LINK_LOAD_DELAY=0.1
    export SETUP_LINK_STATE="$TMP/state" SETUP_LINK_SQM_INIT="$BATS_TEST_DIRNAME/shims/common/sqm-init" SETUP_LINK_TZDATA="$TMP/absent"
    : > "$UCI_STORE"
    # Sections that exist on a stock router. sqm.eth0 deliberately absent:
    # apply must create it (GL first-boot scripts can delete it).
    printf '%s\n' "sqm.eth1=queue" "sqm.eth1.enabled=0" "mtkhnat.global=mtkhnat" "mtkhnat.global.enable=1" \
        "wireless.mt798111=wifi-device" "wireless.mt798112=wifi-device" "wireless.mt798112.country=CA" \
        "network.wan=interface" "network.wan.mtu=1500" >> "$UCI_STORE"
    export FAKE_IDLE="20.0/25.0" FAKE_LOADED="21.0/26.0" FAKE_DL="105.2" FAKE_UL="106.4"
    export PATH="$BATS_TEST_DIRNAME/shims/cf:$BATS_TEST_DIRNAME/shims/common:$PATH"
    SL="$BATS_TEST_DIRNAME/../setup-link"
}
teardown() { rm -rf "$TMP"; }
uget() { grep "^$1=" "$UCI_STORE" | tail -1 | cut -d= -f2-; }

@test "apply: slow link gets 85% ethernet overhead 34 and tight buffers" {
    run sh "$SL" apply 30 5 ethernet
    [ "$status" -eq 0 ]
    [ "$(uget sqm.eth0.enabled)" = 1 ]
    [ "$(uget sqm.eth0.download)" = 25500 ]
    [ "$(uget sqm.eth0.upload)" = 4250 ]
    [ "$(uget sqm.eth0.linklayer)" = ethernet ]
    [ "$(uget sqm.eth0.overhead)" = 34 ]
    [ "$(uget mtkhnat.global.enable)" = 0 ]
    [ "$(cat "$SETUP_LINK_STATE")" = "apply 30 5 ethernet" ]
    grep -q "tcp_rmem=4096 32768 524288" "$SYSCTL_LOG"
    grep -q "sqm-init restart" "$SQM_LOG"
}

@test "apply: medium link gets 92%" {
    run sh "$SL" apply 80 20 ethernet
    [ "$status" -eq 0 ]
    [ "$(uget sqm.eth0.download)" = 73600 ]
    [ "$(uget sqm.eth0.upload)" = 18400 ]
}

@test "apply: dsl uses ATM overhead 40 and MTU 1450" {
    run sh "$SL" apply 8.6 0.75 dsl
    [ "$status" -eq 0 ]
    [ "$(uget sqm.eth0.linklayer)" = atm ]
    [ "$(uget sqm.eth0.overhead)" = 40 ]
    [ "$(uget sqm.eth0.download)" = 7310 ]
    [ "$(uget sqm.eth0.upload)" = 637 ]
    [ "$(uget network.wan.mtu)" = 1450 ]
    [[ "$(uget sqm.eth0.eqdisc_opts)" == *ack-filter-aggressive* ]]
}

@test "apply: docsis uses cable overhead 18 and MTU 1500" {
    run sh "$SL" apply 100 100 docsis
    [ "$status" -eq 0 ]
    [ "$(uget sqm.eth0.linklayer)" = ethernet ]
    [ "$(uget sqm.eth0.overhead)" = 18 ]
    [ "$(uget sqm.eth0.download)" = 92000 ]
    [ "$(uget network.wan.mtu)" = 1500 ]
}

@test "apply: above 100 Mbps shapes at 92% when asked explicitly" {
    run sh "$SL" apply 150 150 ethernet
    [ "$(uget sqm.eth0.enabled)" = 1 ]
    [ "$(uget sqm.eth0.download)" = 138000 ]
}

@test "apply: above the CAKE ceiling turns SQM off" {
    run sh "$SL" apply 500 500 ethernet
    [ "$status" -eq 0 ]
    [ "$(uget sqm.eth0.enabled)" != 1 ]
    [ "$(uget mtkhnat.global.enable)" = 1 ]
    [ "$(cat "$SETUP_LINK_STATE")" = "off ethernet" ]
}

@test "off: disables SQM, enables offload, MTU 1500, fast buffers, keeps link type" {
    echo "apply 100 100 docsis" > "$SETUP_LINK_STATE"
    sh "$SL" apply 100 100 docsis >/dev/null
    run sh "$SL" off
    [ "$status" -eq 0 ]
    [ "$(cat "$SETUP_LINK_STATE")" = "off docsis" ]
    [ "$(uget sqm.eth0.enabled)" = 0 ]
    [ "$(uget mtkhnat.global.enable)" = 1 ]
    [ "$(uget network.wan.mtu)" = 1500 ]
    grep -q "tcp_rmem=4096 131072 4194304" "$SYSCTL_LOG"
}

@test "boot: replays the saved apply, creating the sqm section if it is gone" {
    echo "apply 40 10 dsl" > "$SETUP_LINK_STATE"
    run sh "$SL" boot
    [ "$status" -eq 0 ]
    [ "$(uget sqm.eth0)" = queue ]
    [ "$(uget sqm.eth0.download)" = 34000 ]
    [ "$(uget sqm.eth0.linklayer)" = atm ]
}

@test "boot: replays 'off <type>' as off" {
    echo "off docsis" > "$SETUP_LINK_STATE"
    run sh "$SL" boot
    [ "$status" -eq 0 ]
    [ "$(uget mtkhnat.global.enable)" = 1 ]
}

@test "test: parses gl_speedtest and reports bloat" {
    FAKE_LOADED="46.0/72.8"
    run sh "$SL" test
    [ "$status" -eq 0 ]
    [[ "$output" == *"Download: 105.2 Mbps"* ]]
    [[ "$output" == *"Upload:   106.40 Mbps"* ]]
    [[ "$output" == *"(+26 ms)"* ]]
}

@test "test: latency comes from fping, not gl_speedtest's own ping lines" {
    export FAKE_IDLE_BROKEN=both FAKE_IDLE="19.0/23.0" FAKE_LOADED="46.0/72.8"
    run sh "$SL" test
    [ "$status" -eq 0 ]
    [[ "$output" == *"idle 19.0 ms"* ]]
    [[ "$output" == *"(+27 ms)"* ]]
}

@test "test: unmeasured latency on a fast link shapes to be safe" {
    export FAKE_FPING_FAIL=1
    run sh "$SL" test
    [ "$status" -eq 0 ]
    [[ "$output" == *"unmeasured: SQM at 92% to be safe"* ]]
    [[ "$output" == *"Run: setup-link apply 105.2 106.40 ethernet"* ]]
}

@test "test: a stalled transfer is rejected, not persisted" {
    export FAKE_DL=0.7 FAKE_UL=0.02
    export PATH="$BATS_TEST_DIRNAME/shims/cf:$BATS_TEST_DIRNAME/shims/common:/usr/bin:/bin"
    run sh "$SL" test
    [ "$status" -ne 0 ]
    [[ "$output" == *"no usable result"* ]]
    [ ! -e "$SETUP_LINK_STATE" ]
}

@test "test: falls back to Ookla when gl_speedtest gives nothing" {
    export FAKE_CF_DEAD=1
    export PATH="$BATS_TEST_DIRNAME/shims/cf:$BATS_TEST_DIRNAME/shims/ookla:$BATS_TEST_DIRNAME/shims/common:/usr/bin:/bin"
    run sh "$SL" test
    [ "$status" -eq 0 ]
    [[ "$output" == *"Falling back to the Ookla CLI"* ]]
    [[ "$output" == *"Download: 105.2 Mbps"* ]]
}

@test "test: fast link that bloats recommends SQM" {
    FAKE_LOADED="46.0/72.8"
    run sh "$SL" test
    [ "$status" -eq 0 ]
    [[ "$output" == *"bloats under load"* ]]
    [[ "$output" == *"Run: setup-link apply 105.2 106.40 ethernet"* ]]
}

@test "test: fast clean link recommends off" {
    run sh "$SL" test
    [ "$status" -eq 0 ]
    [[ "$output" == *"clean under load (+1 ms"* ]]
    [[ "$output" == *"Run: setup-link off"* ]]
}

@test "test: slow link always recommends SQM even when clean" {
    FAKE_DL=40 FAKE_UL=8
    run sh "$SL" test
    [ "$status" -eq 0 ]
    [[ "$output" == *"Link < 50 Mbps: SQM at 85%"* ]]
    [[ "$output" == *"Run: setup-link apply 40.0 8.00 ethernet"* ]]
}

@test "test: keeps the last link type in its recommendation" {
    echo "apply 100 100 docsis" > "$SETUP_LINK_STATE"
    FAKE_DL=60 FAKE_UL=60
    run sh "$SL" test
    [ "$status" -eq 0 ]
    [[ "$output" == *"apply 60.0 60.00 docsis"* ]]
}

@test "test: pauses SQM for the measurement and restores it" {
    sh "$SL" apply 50 10 ethernet >/dev/null
    : > "$SQM_LOG"
    run sh "$SL" test
    [ "$status" -eq 0 ]
    grep -q "sqm-init stop" "$SQM_LOG"
    grep -q "sqm-init start" "$SQM_LOG"
}

@test "test: Ookla fallback parses JSON when gl_speedtest is absent" {
    export PATH="$BATS_TEST_DIRNAME/shims/ookla:$BATS_TEST_DIRNAME/shims/common:/usr/bin:/bin"
    FAKE_DL=99 FAKE_UL=85
    run sh "$SL" test
    [ "$status" -eq 0 ]
    [[ "$output" == *"Ookla"* ]]
    [[ "$output" == *"Download: 99.0 Mbps"* ]]
    [[ "$output" == *"Upload:   85.00 Mbps"* ]]
}

@test "test: a failed speed test does not write state or rates" {
    FAKE_DL="" FAKE_UL=""
    run sh "$SL" test
    [ "$status" -ne 0 ]
    [ ! -e "$SETUP_LINK_STATE" ]
    [ -z "$(uget sqm.eth0.download)" ]
}

@test "arrive: fast bloated link is shaped; without a tty the type is ethernet, not the remembered one" {
    echo "apply 100 100 dsl" > "$SETUP_LINK_STATE"
    FAKE_LOADED="46.0/72.8"
    run sh "$SL" arrive </dev/null
    [ "$status" -eq 0 ]
    [ "$(uget sqm.eth0.enabled)" = 1 ]
    [ "$(uget sqm.eth0.overhead)" = 34 ]
    [ "$(uget network.wan.mtu)" = 1500 ]
    [ "$(uget sqm.eth0.download)" = 96784 ]
    [ "$(cat "$SETUP_LINK_STATE")" = "apply 105.2 106.40 ethernet" ]
}

@test "arrive: fast clean link goes unshaped" {
    run sh "$SL" arrive </dev/null
    [ "$status" -eq 0 ]
    [ "$(uget sqm.eth0.enabled)" != 1 ]
    [ "$(uget mtkhnat.global.enable)" = 1 ]
    [ "$(cat "$SETUP_LINK_STATE")" = "off ethernet" ]
}

@test "arrive: repeater uplink never gets a dsl or docsis profile" {
    echo "apply 100 100 dsl" > "$SETUP_LINK_STATE"
    export FAKE_WAN_DEV=apclix0 FAKE_DL=30 FAKE_UL=10
    run sh "$SL" arrive </dev/null
    [ "$status" -eq 0 ]
    [ "$(uget sqm.eth0.linklayer)" = ethernet ]
    [ "$(uget sqm.eth0.overhead)" = 34 ]
}

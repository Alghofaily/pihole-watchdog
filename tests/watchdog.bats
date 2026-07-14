#!/usr/bin/env bats
#
# Tests for scripts/network-watchdog.sh
#
# Strategy: run the real script but inject fake `ip`, `ping`, `dig`, `curl`,
# `systemctl`, and `reboot` via PATH, and redirect all state to a temp dir via
# the script's environment overrides. This lets us drive every branch of the
# escalation logic without touching the network or rebooting anything.

setup() {
    SCRIPT="${BATS_TEST_DIRNAME}/../scripts/network-watchdog.sh"
    TMP="$(mktemp -d)"
    BIN="$TMP/bin"
    mkdir -p "$BIN"

    export LOGFILE="$TMP/watchdog.log"
    export STATEDIR="$TMP/state"
    export STATEFILE="$TMP/state/lastreboot"
    export LOCKFILE="$TMP/watchdog.lock"
    export CONFIG_FILE="$TMP/none.conf"   # ensure no real /etc config is sourced
    export REBOOT_COOLDOWN=1800
    export REBOOT_CMD="$BIN/reboot"       # intercept reboot instead of /sbin/reboot

    # Default fakes: everything healthy. Individual tests override these.
    make_fake ip 'echo "default via 192.168.1.1 dev wlan0"'
    make_fake ping 'exit 0'
    make_fake dig 'exit 0'
    make_fake curl 'exit 0'
    make_fake systemctl "echo \"systemctl \$*\" >> \"$TMP/systemctl.log\"; exit 0"
    make_fake reboot "echo rebooted >> \"$TMP/reboot.log\"; exit 0"

    PATH="$BIN:$PATH"
}

teardown() {
    rm -rf "$TMP"
}

# make_fake <name> <body> : create an executable stub on PATH
make_fake() {
    local name="$1" body="$2"
    cat > "$BIN/$name" <<EOF
#!/bin/bash
$body
EOF
    chmod +x "$BIN/$name"
}

@test "logs all-OK and does not reboot when everything is healthy" {
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    grep -q "all OK" "$LOGFILE"
    [ ! -f "$TMP/reboot.log" ]
}

@test "exits cleanly if no default gateway can be determined" {
    make_fake ip 'echo ""'
    run bash "$SCRIPT"
    [ "$status" -eq 1 ]
    grep -q "Could not determine default gateway" "$LOGFILE"
}

@test "restarts pihole-FTL when DNS fails, and recovers without reboot" {
    # dig fails on the first call, succeeds on the second (post-restart).
    make_fake dig 'f="'"$TMP"'/dig.n"; n=$(cat "$f" 2>/dev/null || echo 0); n=$((n+1)); echo $n > "$f"; [ $n -ge 2 ]'
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    grep -q "restart pihole-FTL" "$LOGFILE"
    grep -q "Recovered after pihole-FTL restart" "$LOGFILE"
    grep -q "systemctl restart pihole-FTL" "$TMP/systemctl.log"
    [ ! -f "$TMP/reboot.log" ]
}

@test "reboots when the gateway stays unreachable after a network restart" {
    make_fake ping 'exit 1'
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    grep -q "Rebooting now" "$LOGFILE"
    [ -f "$TMP/reboot.log" ]
}

@test "suppresses reboot when a recent reboot is within the cooldown window" {
    make_fake ping 'exit 1'
    mkdir -p "$STATEDIR"
    date +%s > "$STATEFILE"   # "just rebooted"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    grep -q "Reboot suppressed" "$LOGFILE"
    [ ! -f "$TMP/reboot.log" ]
}

@test "allows reboot when the last reboot is older than the cooldown" {
    make_fake ping 'exit 1'
    mkdir -p "$STATEDIR"
    echo $(( $(date +%s) - 2000 )) > "$STATEFILE"   # older than 1800s
    run bash "$SCRIPT"
    grep -q "Rebooting now" "$LOGFILE"
    [ -f "$TMP/reboot.log" ]
}

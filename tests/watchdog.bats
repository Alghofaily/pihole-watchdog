#!/usr/bin/env bats
#
# Tests for scripts/network-watchdog.sh
#
# Strategy: run the real script but inject fake `ip`, `ping`, `dig`, `curl`,
# `systemctl`, and `reboot` via PATH, and redirect all state to a temp dir via
# the script's environment overrides. This drives every branch of the escalation
# and alerting logic without touching the network or rebooting anything.

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
    export DISK_WARN_PCT=101              # never trip the disk check in tests
    export NOTIFY_CMD='printf "%s\n" "$MSG" >> '"$TMP"'/notify.log'
    export HEARTBEAT_URL="http://heartbeat.local/ping"

    # Default fakes: everything healthy. Individual tests override these.
    make_fake ip 'echo "default via 192.168.1.1 dev wlan0"'
    make_fake ping 'exit 0'
    make_fake dig 'echo "status: NOERROR"; exit 0'
    make_fake curl "echo \"curl \$*\" >> \"$TMP/curl.log\"; exit 0"
    make_fake systemctl "echo \"systemctl \$*\" >> \"$TMP/systemctl.log\"; exit 0"
    make_fake reboot "echo rebooted >> \"$TMP/reboot.log\"; exit 0"

    PATH="$BIN:$PATH"
}

teardown() {
    rm -rf "$TMP"
}

make_fake() {
    local name="$1" body="$2"
    cat > "$BIN/$name" <<EOF
#!/bin/bash
$body
EOF
    chmod +x "$BIN/$name"
}

@test "healthy run: logs all OK, pings heartbeat, no reboot, no notify" {
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    grep -q "all OK" "$LOGFILE"
    grep -q "heartbeat.local/ping" "$TMP/curl.log"
    [ ! -f "$TMP/reboot.log" ]
    [ ! -f "$TMP/notify.log" ]
}

@test "exits cleanly if no default gateway can be determined" {
    make_fake ip 'echo ""'
    run bash "$SCRIPT"
    [ "$status" -eq 1 ]
    grep -q "Could not determine default gateway" "$LOGFILE"
}

@test "DNS fails once: restarts pihole-FTL, recovers, notifies, no reboot" {
    make_fake dig 'for a in "$@"; do case "$a" in wd-*) echo "status: NOERROR"; exit 0;; esac; done; f="'"$TMP"'/dig.n"; n=$(cat "$f" 2>/dev/null || echo 0); n=$((n+1)); echo $n > "$f"; [ $n -ge 2 ]'
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    grep -q "systemctl restart pihole-FTL" "$TMP/systemctl.log"
    grep -q "recovered after restarting pihole-FTL" "$TMP/notify.log"
    [ ! -f "$TMP/reboot.log" ]
}

@test "gateway stays down: reboots and notifies" {
    make_fake ping 'exit 1'
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    grep -q "Rebooting now" "$TMP/notify.log"
    [ -f "$TMP/reboot.log" ]
    # reboot path exits before heartbeat -> no ping
    ! grep -q "heartbeat.local/ping" "$TMP/curl.log"
}

@test "gateway down within cooldown: reboot suppressed and notified" {
    make_fake ping 'exit 1'
    mkdir -p "$STATEDIR"
    date +%s > "$STATEFILE"
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    grep -q "Reboot suppressed" "$TMP/notify.log"
    [ ! -f "$TMP/reboot.log" ]
}

@test "gateway down, cooldown expired: reboots" {
    make_fake ping 'exit 1'
    mkdir -p "$STATEDIR"
    echo $(( $(date +%s) - 2000 )) > "$STATEFILE"
    run bash "$SCRIPT"
    [ -f "$TMP/reboot.log" ]
}

@test "upstream DNS dead but FTL up: alerts, does not reboot" {
    # cached check passes, but the random upstream probe (label wd-*) SERVFAILs.
    make_fake dig 'for a in "$@"; do case "$a" in wd-*) echo "status: SERVFAIL"; exit 0;; esac; done; echo "status: NOERROR"; exit 0'
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    grep -q "UPSTREAM resolution is failing" "$TMP/notify.log"
    [ ! -f "$TMP/reboot.log" ]
}

@test "low disk space: alerts (no reboot)" {
    export DISK_WARN_PCT=10
    make_fake df 'echo "Filesystem 1K Used Avail Use% Mounted"; echo "/dev/root 100 95 5 95% /"'
    make_fake dig 'echo "status: NOERROR"; exit 0'   # keep upstream healthy to isolate the disk alert
    run bash "$SCRIPT"
    grep -q "Disk usage on / is 95%" "$TMP/notify.log"
    [ ! -f "$TMP/reboot.log" ]
}

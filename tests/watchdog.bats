#!/usr/bin/env bats
#
# Tests for scripts/network-watchdog.sh
#
# Strategy: run the real script but inject fake `ip`, `ping`, `dig`, `curl`,
# `systemctl`, `reboot`, etc. via PATH, and redirect all state/health-input to a
# temp dir via the script's environment overrides. This drives every branch of
# the escalation and alerting logic without touching the network or rebooting.

setup() {
    SCRIPT="${BATS_TEST_DIRNAME}/../scripts/network-watchdog.sh"
    TMP="$(mktemp -d)"
    export TMP
    BIN="$TMP/bin"
    mkdir -p "$BIN"

    export LOGFILE="$TMP/watchdog.log"
    export STATEDIR="$TMP/state"
    export STATEFILE="$TMP/state/lastreboot"
    export ALERTDIR="$TMP/state/alerts"
    export LOCKFILE="$TMP/watchdog.lock"
    export CONFIG_FILE="$TMP/none.conf"   # ensure no real /etc config is sourced
    export REBOOT_COOLDOWN=1800
    export REBOOT_CMD="$BIN/reboot"       # intercept reboot instead of /sbin/reboot
    export DISK_WARN_PCT=101              # never trip the disk check in tests
    export NOTIFY_CMD='printf "%s\n" "$MSG" >> '"$TMP"'/notify.log'
    export HEARTBEAT_URL="http://heartbeat.local/ping"

    # Point host-state inputs at fakes and disable the host-dependent checks by
    # default; individual tests re-enable and drive the one they exercise.
    export MOUNTS="$TMP/mounts"
    printf '/dev/root / ext4 rw,relatime 0 0\n' > "$TMP/mounts"
    export DNSMASQ_DIR="$TMP/dnsmasq"          # absent -> DHCP check no-ops
    export GRAVITY_DB="$TMP/gravity.db"        # absent -> gravity check no-ops
    export ENABLE_MEM_CHECK=false
    export ENABLE_TIME_CHECK=false
    export ENABLE_IO_CHECK=false
    export ENABLE_IPV6_CHECK=false

    # Default fakes: everything healthy. Individual tests override these.
    make_fake ip 'echo "default via 192.168.1.1 dev wlan0"'
    make_fake ping 'exit 0'
    make_fake dig 'echo "status: NOERROR"; exit 0'
    make_fake curl 'echo "curl $*" >> "$TMP/curl.log"; case "$*" in *http_code*) printf 200;; esac; exit 0'
    make_fake systemctl 'echo "systemctl $*" >> "$TMP/systemctl.log"; exit 0'
    make_fake reboot 'echo rebooted >> "$TMP/reboot.log"; exit 0'
    make_fake sleep 'exit 0'   # skip the 15s recovery waits so the suite runs fast

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

# --- Core escalation ---------------------------------------------------------

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

@test "DNS wedged once: restarts pihole-FTL, recovers, notifies, no reboot" {
    make_fake dig 'case "$*" in *wd-*) echo "status: NOERROR"; exit 0;; esac; n=$(cat "$TMP/dig.n" 2>/dev/null || echo 0); n=$((n+1)); echo $n > "$TMP/dig.n"; [ "$n" -ge 2 ] && echo "status: NOERROR"; exit 0'
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    grep -q "systemctl restart pihole-FTL" "$TMP/systemctl.log"
    grep -q "recovered after restarting pihole-FTL" "$TMP/notify.log"
    [ ! -f "$TMP/reboot.log" ]
}

@test "web UI down once: restarts pihole-FTL, recovers, notifies, no reboot" {
    make_fake curl 'echo "curl $*" >> "$TMP/curl.log"; case "$*" in *http_code*) n=$(cat "$TMP/curl.n" 2>/dev/null||echo 0); n=$((n+1)); echo $n>"$TMP/curl.n"; if [ "$n" -ge 2 ]; then printf 200; else printf 000; fi;; esac; exit 0'
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    grep -q "web UI unresponsive" "$TMP/notify.log"
    grep -q "recovered after restarting pihole-FTL" "$TMP/notify.log"
    [ ! -f "$TMP/reboot.log" ]
}

@test "web UI returns 401 (auth-gated): treated as up, no restart" {
    make_fake curl 'echo "curl $*" >> "$TMP/curl.log"; case "$*" in *http_code*) printf 401;; esac; exit 0'
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    grep -q "all OK" "$LOGFILE"
    [ ! -f "$TMP/systemctl.log" ] || ! grep -q "restart pihole-FTL" "$TMP/systemctl.log"
}

@test "gateway recovers after network restart: notifies, no reboot" {
    make_fake ping 'n=$(cat "$TMP/ping.n" 2>/dev/null||echo 0); n=$((n+1)); echo $n>"$TMP/ping.n"; [ "$n" -ge 2 ]'
    run bash "$SCRIPT"
    grep -q "recovered after a network restart" "$TMP/notify.log"
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

@test "corrupt reboot state file is treated as expired: reboots" {
    make_fake ping 'exit 1'
    mkdir -p "$STATEDIR"
    echo "garbage" > "$STATEFILE"
    run bash "$SCRIPT"
    [ -f "$TMP/reboot.log" ]
}

@test "DNS SERVFAIL keeps FTL alive: upstream alert only, no restart, no reboot" {
    make_fake dig 'echo "status: SERVFAIL"; exit 0'
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    grep -q "UPSTREAM resolution is failing" "$TMP/notify.log"
    [ ! -f "$TMP/reboot.log" ]
    [ ! -f "$TMP/systemctl.log" ] || ! grep -q "restart pihole-FTL" "$TMP/systemctl.log"
}

@test "second instance skips when the lock is already held" {
    exec 201>"$LOCKFILE"
    flock -n 201
    run bash "$SCRIPT"
    exec 201>&-
    [ "$status" -eq 0 ]
    grep -q "Another watchdog instance is already running" "$LOGFILE"
}

@test "config file is sourced (DISK_WARN_PCT override applies)" {
    echo 'DISK_WARN_PCT=10' > "$TMP/wd.conf"
    export CONFIG_FILE="$TMP/wd.conf"
    make_fake df 'echo "Filesystem 1K Used Avail Use% Mounted"; echo "/dev/root 100 95 5 95% /"'
    run bash "$SCRIPT"
    grep -q "Disk usage on / is 95%" "$TMP/notify.log"
}

# --- FTL restart wrapper -----------------------------------------------------

@test "FTL restart command failure is logged" {
    export FTL_RESTART_CMD="false"
    make_fake dig 'exit 1'    # no "status:" output -> FTL appears wedged
    run bash "$SCRIPT"
    grep -q "FTL restart command failed" "$LOGFILE"
}

@test "FTL_RESTART_CMD override is used instead of systemctl (Docker path)" {
    export FTL_RESTART_CMD="touch $TMP/ftl_restarted"
    make_fake dig 'case "$*" in *wd-*) echo "status: NOERROR"; exit 0;; esac; n=$(cat "$TMP/dig.n" 2>/dev/null||echo 0); n=$((n+1)); echo $n>"$TMP/dig.n"; [ "$n" -ge 2 ] && echo "status: NOERROR"; exit 0'
    run bash "$SCRIPT"
    [ -f "$TMP/ftl_restarted" ]
    [ ! -f "$TMP/systemctl.log" ] || ! grep -q "restart pihole-FTL" "$TMP/systemctl.log"
}

# --- Alert-only health checks ------------------------------------------------

@test "low disk space: alerts (no reboot)" {
    export DISK_WARN_PCT=10
    make_fake df 'echo "Filesystem 1K Used Avail Use% Mounted"; echo "/dev/root 100 95 5 95% /"'
    run bash "$SCRIPT"
    grep -q "Disk usage on / is 95%" "$TMP/notify.log"
    [ ! -f "$TMP/reboot.log" ]
}

@test "read-only rootfs: alerts (no reboot)" {
    printf '/dev/root / ext4 ro,relatime 0 0\n' > "$TMP/mounts"
    run bash "$SCRIPT"
    grep -q "READ-ONLY" "$TMP/notify.log"
    [ ! -f "$TMP/reboot.log" ]
}

@test "low memory: alerts mem-low (no reboot)" {
    export ENABLE_MEM_CHECK=true
    printf 'MemTotal: 100000 kB\nMemAvailable: 5000 kB\nSwapTotal: 0 kB\nSwapFree: 0 kB\n' > "$TMP/meminfo"
    export MEMINFO="$TMP/meminfo"
    make_fake dmesg 'exit 0'
    run bash "$SCRIPT"
    grep -q "Low memory: only 5%" "$TMP/notify.log"
    [ ! -f "$TMP/reboot.log" ]
}

@test "OOM kill in kernel log: alerts" {
    export ENABLE_MEM_CHECK=true
    make_fake dmesg 'echo "[12345.6] Out of memory: Killed process 999 (pihole-FTL)"'
    run bash "$SCRIPT"
    grep -q "out-of-memory kill" "$TMP/notify.log"
}

@test "throttling currently active: alerts throttle-now" {
    make_fake vcgencmd 'case "$*" in *measure_temp*) echo "temp=45.0";; *get_throttled*) echo "throttled=0x50005";; esac'
    run bash "$SCRIPT"
    grep -q "CURRENTLY under-voltage" "$TMP/notify.log"
    [ ! -f "$TMP/reboot.log" ]
}

@test "throttling since boot only: alerts throttle-past" {
    make_fake vcgencmd 'case "$*" in *measure_temp*) echo "temp=45.0";; *get_throttled*) echo "throttled=0x50000";; esac'
    run bash "$SCRIPT"
    grep -q "occurred since boot" "$TMP/notify.log"
}

@test "high CPU temperature: alerts temp-high" {
    make_fake vcgencmd 'case "$*" in *measure_temp*) echo "temp=85.0";; *get_throttled*) echo "throttled=0x0";; esac'
    run bash "$SCRIPT"
    grep -q "CPU temperature is 85.0C" "$TMP/notify.log"
}

@test "pihole blocking disabled: alerts" {
    make_fake pihole 'echo "  [✗] Pi-hole blocking is disabled"; exit 0'
    run bash "$SCRIPT"
    grep -q "blocking is DISABLED" "$TMP/notify.log"
}

@test "stale gravity: alerts gravity-stale" {
    touch -d '30 days ago' "$TMP/gravity.db"
    export GRAVITY_DB="$TMP/gravity.db"
    run bash "$SCRIPT"
    grep -q "gravity (blocklists) last updated" "$TMP/notify.log"
}

@test "clock not NTP-synced: alerts" {
    export ENABLE_TIME_CHECK=true
    make_fake timedatectl 'echo "no"'
    run bash "$SCRIPT"
    grep -q "NOT NTP-synchronized" "$TMP/notify.log"
}

@test "storage I/O errors in kernel log: alerts" {
    export ENABLE_IO_CHECK=true
    make_fake dmesg 'echo "mmc0: error -110 whilst initialising SD card"'
    run bash "$SCRIPT"
    grep -q "storage I/O errors" "$TMP/notify.log"
}

@test "weak WiFi signal: alerts" {
    make_fake iw 'case "$*" in dev) echo "Interface wlan0";; *link*) echo "        signal: -85 dBm";; esac'
    run bash "$SCRIPT"
    grep -q "WiFi signal on wlan0 is -85 dBm" "$TMP/notify.log"
}

@test "DHCP configured but not listening: alerts" {
    export ENABLE_DHCP_CHECK=true
    mkdir -p "$TMP/dnsmasq"
    echo "dhcp-range=192.168.1.100,192.168.1.200,24h" > "$TMP/dnsmasq/02-pihole-dhcp.conf"
    make_fake ss 'echo "Netid State Recv-Q Send-Q Local Peer"; exit 0'
    run bash "$SCRIPT"
    grep -q "nothing is listening on UDP/67" "$TMP/notify.log"
}

@test "IPv6 gateway unreachable: alerts (no reboot)" {
    export ENABLE_IPV6_CHECK=true
    make_fake ip 'case "$*" in *-6*) echo "default via fe80::1 dev wlan0";; *) echo "default via 192.168.1.1 dev wlan0";; esac'
    make_fake ping 'case "$*" in *-6*) exit 1;; *) exit 0;; esac'
    run bash "$SCRIPT"
    grep -q "IPv6 default gateway" "$TMP/notify.log"
    [ ! -f "$TMP/reboot.log" ]
}

@test "upstream DNS dead but FTL up: alerts, does not reboot" {
    # cached check passes, but the random upstream probe (label wd-*) SERVFAILs.
    make_fake dig 'for a in "$@"; do case "$a" in wd-*) echo "status: SERVFAIL"; exit 0;; esac; done; echo "status: NOERROR"; exit 0'
    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    grep -q "UPSTREAM resolution is failing" "$TMP/notify.log"
    [ ! -f "$TMP/reboot.log" ]
}

@test "upstream soft-fix runs the resolver restart before alerting" {
    export ENABLE_UPSTREAM_RESTART=true
    export UPSTREAM_RESTART_CMD="touch $TMP/unbound_restarted"
    make_fake dig 'for a in "$@"; do case "$a" in wd-*) echo "status: SERVFAIL"; exit 0;; esac; done; echo "status: NOERROR"; exit 0'
    run bash "$SCRIPT"
    [ -f "$TMP/unbound_restarted" ]
    grep -q "UPSTREAM resolution is failing" "$TMP/notify.log"
}

# --- Alert de-duplication ----------------------------------------------------

@test "alert dedup: a recently-fired alert is suppressed" {
    export DISK_WARN_PCT=10
    make_fake df 'echo "Filesystem 1K Used Avail Use% Mounted"; echo "/dev/root 100 95 5 95% /"'
    mkdir -p "$ALERTDIR"
    date +%s > "$ALERTDIR/disk-high"
    run bash "$SCRIPT"
    grep -q "suppressed" "$LOGFILE"
    [ ! -f "$TMP/notify.log" ] || ! grep -q "Disk usage" "$TMP/notify.log"
}

@test "alert resolved: sends a one-shot resolved notice and clears state" {
    mkdir -p "$ALERTDIR"
    echo 0 > "$ALERTDIR/disk-high"   # stale condition, not present this run
    run bash "$SCRIPT"
    grep -q "Resolved: 'disk-high'" "$TMP/notify.log"
    [ ! -f "$ALERTDIR/disk-high" ]
}

# --- Notification / heartbeat failure paths ----------------------------------

@test "NOTIFY_CMD failure is logged" {
    export DISK_WARN_PCT=10
    export NOTIFY_CMD="false"
    make_fake df 'echo "Filesystem 1K Used Avail Use% Mounted"; echo "/dev/root 100 95 5 95% /"'
    run bash "$SCRIPT"
    grep -q "notify: NOTIFY_CMD failed" "$LOGFILE"
}

@test "heartbeat ping failure is logged" {
    make_fake curl 'echo "curl $*" >> "$TMP/curl.log"; case "$*" in *http_code*) printf 200; exit 0;; *heartbeat*) exit 1;; *) exit 0;; esac'
    run bash "$SCRIPT"
    grep -q "heartbeat: ping failed" "$LOGFILE"
}

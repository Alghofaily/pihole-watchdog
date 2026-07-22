#!/usr/bin/env bats
#
# Smoke tests for install.sh / uninstall.sh.
#
# The installer/uninstaller support environment path-overrides (PREFIX,
# SYSCONFDIR, ...) plus SKIP_ROOT_CHECK / SKIP_APT, so we can drive them against
# a throwaway temp tree with fake `crontab`, `systemctl`, and `iw` on PATH -
# never touching the real system, apt, cron, or systemd.

setup() {
    REPO="${BATS_TEST_DIRNAME}/.."
    TMP="$(mktemp -d)"
    export TMP
    BIN="$TMP/bin"
    mkdir -p "$BIN"

    export PREFIX="$TMP/usr/local"
    export SYSCONFDIR="$TMP/etc"
    export LOGDIR="$TMP/var/log"
    export STATE_DIR="$TMP/var/lib/network-watchdog"
    export SYSTEMD_DIR="$TMP/etc/systemd/system"
    export LOGROTATE_DIR="$TMP/etc/logrotate.d"
    export SKIP_ROOT_CHECK=1
    export SKIP_APT=1

    make_fake crontab 'case "$1" in -l) cat "$TMP/crontab" 2>/dev/null || exit 1;; *) cat "$1" > "$TMP/crontab";; esac'
    make_fake systemctl 'echo "systemctl $*" >> "$TMP/systemctl.log"; exit 0'
    make_fake iw 'exit 0'          # `iw dev` prints nothing -> Ethernet path (no WiFi step)

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

@test "cron install lays down script, config, logrotate, cron line, and log file" {
    run bash "$REPO/install.sh"
    [ "$status" -eq 0 ]
    [ -x "$PREFIX/bin/network-watchdog.sh" ]
    [ -f "$SYSCONFDIR/network-watchdog.conf" ]
    [ -f "$LOGROTATE_DIR/network-watchdog" ]
    [ -f "$LOGDIR/network-watchdog.log" ]
    [ -d "$STATE_DIR" ]
    grep -q "network-watchdog.sh" "$TMP/crontab"
    grep -q "pihole-watchdog" "$TMP/crontab"
}

@test "install is idempotent: cron line is not duplicated" {
    bash "$REPO/install.sh" >/dev/null
    bash "$REPO/install.sh" >/dev/null
    run grep -c "network-watchdog.sh" "$TMP/crontab"
    [ "$output" -eq 1 ]
}

@test "--use-timer installs systemd units and no cron line" {
    run bash "$REPO/install.sh" --use-timer
    [ "$status" -eq 0 ]
    [ -f "$SYSTEMD_DIR/network-watchdog.service" ]
    [ -f "$SYSTEMD_DIR/network-watchdog.timer" ]
    grep -q "enable --now network-watchdog.timer" "$TMP/systemctl.log"
    # the service's ExecStart should point at the installed (PREFIX) path
    grep -q "$PREFIX/bin/network-watchdog.sh" "$SYSTEMD_DIR/network-watchdog.service"
    ! grep -q "network-watchdog.sh" "$TMP/crontab" 2>/dev/null
}

@test "unknown option is rejected" {
    run bash "$REPO/install.sh" --bogus
    [ "$status" -ne 0 ]
    [[ "$output" == *"Unknown option"* ]]
}

@test "uninstall removes script, config, state, logrotate" {
    bash "$REPO/install.sh" >/dev/null
    [ -x "$PREFIX/bin/network-watchdog.sh" ]
    run bash "$REPO/uninstall.sh"
    [ "$status" -eq 0 ]
    [ ! -e "$PREFIX/bin/network-watchdog.sh" ]
    [ ! -e "$SYSCONFDIR/network-watchdog.conf" ]
    [ ! -e "$STATE_DIR" ]
    [ ! -e "$LOGROTATE_DIR/network-watchdog" ]
}

@test "uninstall removes systemd timer units when timer mode was used" {
    bash "$REPO/install.sh" --use-timer >/dev/null
    [ -f "$SYSTEMD_DIR/network-watchdog.timer" ]
    run bash "$REPO/uninstall.sh"
    [ "$status" -eq 0 ]
    [ ! -e "$SYSTEMD_DIR/network-watchdog.timer" ]
    [ ! -e "$SYSTEMD_DIR/network-watchdog.service" ]
    grep -q "disable --now network-watchdog.timer" "$TMP/systemctl.log"
}

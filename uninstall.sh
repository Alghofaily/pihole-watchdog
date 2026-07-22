#!/bin/bash
# Pi-hole Watchdog - uninstaller
set -e

: "${PREFIX:=/usr/local}"
: "${SYSCONFDIR:=/etc}"
: "${LOGDIR:=/var/log}"
: "${STATE_DIR:=/var/lib/network-watchdog}"
: "${SYSTEMD_DIR:=/etc/systemd/system}"
: "${LOGROTATE_DIR:=/etc/logrotate.d}"
: "${SKIP_ROOT_CHECK:=0}"

WATCHDOG_BIN="$PREFIX/bin/network-watchdog.sh"
CONFIG_PATH="$SYSCONFDIR/network-watchdog.conf"
LOGFILE="$LOGDIR/network-watchdog.log"

if [ "$SKIP_ROOT_CHECK" != "1" ] && [ "$EUID" -ne 0 ]; then
    echo "Please run as root: sudo ./uninstall.sh"
    exit 1
fi

CRON_MARKER="# pihole-watchdog"

echo "=== Pi-hole Watchdog Uninstaller ==="
echo

echo "Removing cron jobs..."
TMP_CRON=$(mktemp)
crontab -l 2>/dev/null | grep -v "$CRON_MARKER" > "$TMP_CRON" || true
crontab "$TMP_CRON" 2>/dev/null || true
rm -f "$TMP_CRON"
echo "  Done"

if [ -f "$SYSTEMD_DIR/network-watchdog.timer" ] || [ -f "$SYSTEMD_DIR/network-watchdog.service" ]; then
    echo "Removing systemd timer/service..."
    systemctl disable --now network-watchdog.timer >/dev/null 2>&1 || true
    rm -f "$SYSTEMD_DIR/network-watchdog.timer" "$SYSTEMD_DIR/network-watchdog.service"
    systemctl daemon-reload 2>/dev/null || true
    echo "  Done"
fi

echo "Removing watchdog script..."
rm -f "$WATCHDOG_BIN"
echo "  Done"

echo "Removing logrotate config..."
rm -f "$LOGROTATE_DIR/network-watchdog"
echo "  Done"

echo "Removing config and state..."
rm -f "$CONFIG_PATH"
rm -rf "$STATE_DIR"
echo "  Done"

if [ -f "$SYSTEMD_DIR/wifi-powersave-off.service" ]; then
    echo "Removing WiFi power management service..."
    systemctl disable wifi-powersave-off.service >/dev/null 2>&1 || true
    systemctl stop wifi-powersave-off.service >/dev/null 2>&1 || true
    rm -f "$SYSTEMD_DIR/wifi-powersave-off.service"
    systemctl daemon-reload 2>/dev/null || true
    echo "  Done (note: WiFi power management will re-enable on next reboot)"
fi

if [ -f /etc/systemd/system.conf.d/watchdog.conf ]; then
    echo "Removing hardware watchdog config..."
    rm -f /etc/systemd/system.conf.d/watchdog.conf
    for c in /boot/firmware/config.txt /boot/config.txt; do
        [ -f "$c" ] && sed -i '/^dtparam=watchdog=on/d' "$c"
    done
    systemctl daemon-reexec 2>/dev/null || true
    echo "  Done (hardware watchdog fully off after next reboot)"
fi

echo
if [ -t 0 ]; then
    read -p "Delete the log file $LOGFILE too? [y/N] " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        rm -f "$LOGFILE"
        echo "  Log file removed"
    fi
fi

echo
echo "=== Uninstall complete ==="

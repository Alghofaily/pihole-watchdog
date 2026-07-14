#!/bin/bash
# Pi-hole Watchdog - uninstaller
set -e

if [ "$EUID" -ne 0 ]; then
    echo "Please run as root: sudo ./uninstall.sh"
    exit 1
fi

CRON_MARKER="# pihole-watchdog"

echo "=== Pi-hole Watchdog Uninstaller ==="
echo

echo "Removing cron jobs..."
TMP_CRON=$(mktemp)
crontab -l 2>/dev/null | grep -v "$CRON_MARKER" > "$TMP_CRON" || true
crontab "$TMP_CRON"
rm -f "$TMP_CRON"
echo "  Done"

echo "Removing watchdog script..."
rm -f /usr/local/bin/network-watchdog.sh
echo "  Done"

echo "Removing logrotate config..."
rm -f /etc/logrotate.d/network-watchdog
echo "  Done"

echo "Removing config and state..."
rm -f /etc/network-watchdog.conf
rm -rf /var/lib/network-watchdog
echo "  Done"

if [ -f /etc/systemd/system/wifi-powersave-off.service ]; then
    echo "Removing WiFi power management service..."
    systemctl disable wifi-powersave-off.service >/dev/null 2>&1 || true
    systemctl stop wifi-powersave-off.service >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/wifi-powersave-off.service
    systemctl daemon-reload
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
read -p "Delete the log file /var/log/network-watchdog.log too? [y/N] " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    rm -f /var/log/network-watchdog.log
    echo "  Log file removed"
fi

echo
echo "=== Uninstall complete ==="

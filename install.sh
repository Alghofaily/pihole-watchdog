#!/bin/bash
# Pi-hole Watchdog - installer
# https://github.com/YOUR_USERNAME/pihole-watchdog
#
# Sets up:
#   1. Daily 3 AM restart of pihole-FTL (cron)
#   2. WiFi power management disabled on boot (systemd) - skipped on Ethernet
#   3. Tiered network/DNS watchdog every 10 min (cron)
#   4. Log rotation for the watchdog log
#
# Usage:
#   sudo ./install.sh

set -e

if [ "$EUID" -ne 0 ]; then
    echo "Please run as root: sudo ./install.sh"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CRON_MARKER="# pihole-watchdog"

echo "=== Pi-hole Watchdog Installer ==="
echo

# --- Dependency check ---
echo "[1/5] Checking dependencies..."
MISSING=0
for cmd in dig ping iwconfig; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "  Missing: $cmd"
        MISSING=1
    fi
done

if [ "$MISSING" -eq 1 ]; then
    echo "  Installing missing packages (dnsutils, iputils-ping, wireless-tools)..."
    apt-get update -qq
    apt-get install -y -qq dnsutils iputils-ping wireless-tools
fi
echo "  OK"
echo

# --- Install watchdog script ---
echo "[2/5] Installing network watchdog script..."
install -m 755 "$SCRIPT_DIR/scripts/network-watchdog.sh" /usr/local/bin/network-watchdog.sh
echo "  Installed to /usr/local/bin/network-watchdog.sh"
echo

# --- Install log rotation ---
install -m 644 "$SCRIPT_DIR/scripts/network-watchdog.logrotate" /etc/logrotate.d/network-watchdog
echo "  Log rotation configured"
echo

# --- WiFi power management fix ---
echo "[3/5] Checking for WiFi interface..."
WIFI_IFACE=$(iw dev 2>/dev/null | awk '$1=="Interface"{print $2}' | head -n1)

if [ -n "$WIFI_IFACE" ]; then
    echo "  Found WiFi interface: $WIFI_IFACE"
    sed "s/WIFI_INTERFACE_PLACEHOLDER/$WIFI_IFACE/" \
        "$SCRIPT_DIR/scripts/wifi-powersave-off.service" > /etc/systemd/system/wifi-powersave-off.service
    systemctl daemon-reload
    systemctl enable wifi-powersave-off.service >/dev/null 2>&1
    systemctl start wifi-powersave-off.service
    CURRENT_PM=$(iwconfig "$WIFI_IFACE" 2>/dev/null | grep -o "Power Management:[a-z]*" || echo "unknown")
    echo "  WiFi power management service installed and started ($CURRENT_PM)"
else
    echo "  No WiFi interface detected (likely running on Ethernet) - skipping this step"
fi
echo

# --- Cron jobs ---
echo "[4/5] Setting up cron jobs..."
TMP_CRON=$(mktemp)
crontab -l 2>/dev/null | grep -v "$CRON_MARKER" > "$TMP_CRON" || true

{
    echo "0 3 * * * systemctl restart pihole-FTL $CRON_MARKER (daily restart)"
    echo "*/10 * * * * /usr/local/bin/network-watchdog.sh $CRON_MARKER (watchdog)"
} >> "$TMP_CRON"

crontab "$TMP_CRON"
rm -f "$TMP_CRON"
echo "  Cron jobs installed:"
echo "    - Daily pihole-FTL restart at 3:00 AM"
echo "    - Network/DNS watchdog every 10 minutes"
echo

# --- Done ---
echo "[5/5] Verifying..."
touch /var/log/network-watchdog.log
chmod 644 /var/log/network-watchdog.log
echo "  Log file ready at /var/log/network-watchdog.log"
echo

echo "=== Install complete ==="
echo
echo "Summary of what's running:"
echo "  - crontab -l          -> view scheduled jobs"
echo "  - tail -f /var/log/network-watchdog.log  -> watch watchdog activity"
if [ -n "$WIFI_IFACE" ]; then
echo "  - systemctl status wifi-powersave-off.service"
fi
echo
echo "To uninstall, run: sudo ./uninstall.sh"

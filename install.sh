#!/bin/bash
# Pi-hole Watchdog - installer
# https://github.com/Alghofaily/pihole-watchdog
#
# Sets up:
#   1. WiFi power management disabled on boot (systemd) - skipped on Ethernet
#   2. Tiered network/DNS/web UI watchdog every 10 min (cron)
#   3. Log rotation for the watchdog log
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
# Map each required command to the apt package that provides it, so we install
# exactly what's missing. `iw` (interface detection + powersave) and `logrotate`
# are required too and were previously assumed to be present.
echo "[1/5] Checking dependencies..."
declare -A PKG_FOR=(
    [dig]=dnsutils
    [ping]=iputils-ping
    [iwconfig]=wireless-tools
    [iw]=iw
    [curl]=curl
    [logrotate]=logrotate
)
MISSING_PKGS=""
for cmd in "${!PKG_FOR[@]}"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "  Missing: $cmd (package: ${PKG_FOR[$cmd]})"
        MISSING_PKGS="$MISSING_PKGS ${PKG_FOR[$cmd]}"
    fi
done

if [ -n "$MISSING_PKGS" ]; then
    # De-duplicate package names.
    MISSING_PKGS=$(echo "$MISSING_PKGS" | tr ' ' '\n' | sort -u | tr '\n' ' ')
    echo "  Installing missing packages:$MISSING_PKGS"
    apt-get update -qq
    # shellcheck disable=SC2086
    apt-get install -y -qq $MISSING_PKGS
fi
echo "  OK"
echo

# --- Install watchdog script ---
echo "[2/5] Installing network watchdog script..."
install -m 755 "$SCRIPT_DIR/scripts/network-watchdog.sh" /usr/local/bin/network-watchdog.sh
echo "  Installed to /usr/local/bin/network-watchdog.sh"

# Persistent state directory for the reboot cooldown (survives reboots).
install -d -m 755 /var/lib/network-watchdog
echo "  State directory ready at /var/lib/network-watchdog"

# Install a default config file only if the user doesn't already have one,
# so their tuned settings survive reinstalls.
if [ ! -f /etc/network-watchdog.conf ]; then
    install -m 644 "$SCRIPT_DIR/scripts/network-watchdog.conf" /etc/network-watchdog.conf
    echo "  Default config installed at /etc/network-watchdog.conf"
else
    echo "  Existing /etc/network-watchdog.conf left untouched"
fi
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
    echo "*/10 * * * * /usr/local/bin/network-watchdog.sh $CRON_MARKER (watchdog)"
} >> "$TMP_CRON"

crontab "$TMP_CRON"
rm -f "$TMP_CRON"
echo "  Cron jobs installed:"
echo "    - Network/DNS/web UI watchdog every 10 minutes"
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
echo "To re-verify at any time, run: sudo ./verify.sh"

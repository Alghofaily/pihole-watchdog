#!/bin/bash
# Pi-hole Watchdog - verification script
# https://github.com/Alghofaily/pihole-watchdog
#
# Checks that everything installed by install.sh is actually configured
# and working correctly. Safe to re-run any time.
#
# Usage:
#   sudo ./verify.sh

if [ "$EUID" -ne 0 ]; then
    echo "Please run as root: sudo ./verify.sh"
    exit 1
fi

PASS=0
FAIL=0
WARN=0

ok()   { echo "  [PASS] $1"; PASS=$((PASS+1)); }
bad()  { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }
warn() { echo "  [WARN] $1"; WARN=$((WARN+1)); }

echo "=== Pi-hole Watchdog Verification ==="
echo

# --- 1. Crontab ---
echo "[1/6] Checking crontab..."
CRON_LINE=$(crontab -l 2>/dev/null | grep "network-watchdog.sh" | grep "pihole-watchdog")
if [ -n "$CRON_LINE" ]; then
    ok "Watchdog cron job is present"
else
    bad "Watchdog cron job NOT found (expected a line with network-watchdog.sh and the pihole-watchdog tag)"
fi

STALE_LINES=$(crontab -l 2>/dev/null | grep -v "^#" | grep -v "pihole-watchdog" | grep -E "pihole|network-watchdog" || true)
if [ -n "$STALE_LINES" ]; then
    warn "Found other pihole/network-related cron lines not tagged by this project - review with 'sudo crontab -l'"
fi
echo

# --- 2. Watchdog script ---
echo "[2/6] Checking watchdog script..."
if [ -x /usr/local/bin/network-watchdog.sh ]; then
    ok "Script installed and executable at /usr/local/bin/network-watchdog.sh"
else
    bad "Script missing or not executable at /usr/local/bin/network-watchdog.sh"
fi

if [ -x /usr/local/bin/network-watchdog.sh ]; then
    echo "  Running it now (this may restart pihole-FTL if something is actually broken)..."
    /usr/local/bin/network-watchdog.sh
    LAST_LOG=$(tail -1 /var/log/network-watchdog.log 2>/dev/null)
    if echo "$LAST_LOG" | grep -q "all OK"; then
        ok "Watchdog ran successfully: $LAST_LOG"
    else
        warn "Watchdog ran but reported an issue: $LAST_LOG"
    fi
fi
echo

# --- 3. WiFi power management ---
echo "[3/6] Checking WiFi power management..."
WIFI_IFACE=$(iw dev 2>/dev/null | awk '$1=="Interface"{print $2}' | head -n1)
if [ -z "$WIFI_IFACE" ]; then
    warn "No WiFi interface detected - skipping (expected if running on Ethernet)"
else
    PM_STATUS=$(iwconfig "$WIFI_IFACE" 2>/dev/null | grep -o "Power Management:[a-zA-Z]*")
    if echo "$PM_STATUS" | grep -qi "off"; then
        ok "WiFi power management is off ($WIFI_IFACE)"
    else
        bad "WiFi power management is NOT off ($WIFI_IFACE: $PM_STATUS)"
    fi

    if systemctl is-enabled wifi-powersave-off.service >/dev/null 2>&1; then
        ok "wifi-powersave-off.service is enabled (will reapply on boot)"
    else
        bad "wifi-powersave-off.service is not enabled"
    fi

    if systemctl is-active wifi-powersave-off.service >/dev/null 2>&1; then
        ok "wifi-powersave-off.service is active"
    else
        bad "wifi-powersave-off.service is not active"
    fi
fi
echo

# --- 4. Log rotation ---
echo "[4/6] Checking log rotation..."
if [ -f /etc/logrotate.d/network-watchdog ]; then
    ok "Logrotate config present at /etc/logrotate.d/network-watchdog"
    if logrotate -d /etc/logrotate.d/network-watchdog >/dev/null 2>&1; then
        ok "Logrotate config is valid"
    else
        bad "Logrotate config has an error - run 'sudo logrotate -d /etc/logrotate.d/network-watchdog' to see details"
    fi
else
    bad "Logrotate config missing at /etc/logrotate.d/network-watchdog"
fi
echo

# --- 5. Leftover manual scripts ---
echo "[5/6] Checking for leftover manual scripts..."
if [ -f /usr/local/bin/pihole_healthcheck.sh ]; then
    warn "Old /usr/local/bin/pihole_healthcheck.sh still present - safe to remove now that the watchdog covers this (sudo rm /usr/local/bin/pihole_healthcheck.sh)"
else
    ok "No leftover pihole_healthcheck.sh found"
fi
echo

# --- 6. Log file health ---
echo "[6/6] Checking watchdog log..."
if [ -f /var/log/network-watchdog.log ]; then
    ok "Log file exists at /var/log/network-watchdog.log"
    RECENT=$(find /var/log/network-watchdog.log -mmin -15 2>/dev/null)
    if [ -n "$RECENT" ]; then
        ok "Log file was updated within the last 15 minutes - cron is actively running it"
    else
        warn "Log file hasn't been updated in the last 15 minutes - cron may not be running yet (wait for the next 10-min interval, or check 'sudo crontab -l')"
    fi
else
    bad "Log file not found - watchdog may never have run"
fi
echo

# --- Summary ---
echo "=== Summary ==="
echo "  Passed:  $PASS"
echo "  Warnings: $WARN"
echo "  Failed:  $FAIL"
echo

if [ "$FAIL" -eq 0 ] && [ "$WARN" -eq 0 ]; then
    echo "Everything looks good."
elif [ "$FAIL" -eq 0 ]; then
    echo "No failures, but some warnings above are worth a look."
else
    echo "One or more checks failed. Review the [FAIL] lines above and re-run 'sudo ./install.sh' if needed."
fi

echo
echo "Tip: for the most reliable confirmation, reboot the Pi and run this script again:"
echo "  sudo reboot"
echo "  # after it comes back up:"
echo "  sudo ./verify.sh"

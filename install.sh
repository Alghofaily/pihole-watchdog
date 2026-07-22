#!/bin/bash
# Pi-hole Watchdog - installer
# https://github.com/Alghofaily/pihole-watchdog
#
# Sets up:
#   1. WiFi power management disabled on boot (systemd) - skipped on Ethernet
#   2. Tiered network/DNS/web UI watchdog every 10 min (cron, or systemd timer)
#   3. Log rotation for the watchdog log
#
# Options:
#   --use-timer            Schedule via a systemd timer instead of cron.
#   --enable-hw-watchdog   Also enable the SoC hardware watchdog (systemd
#                          RuntimeWatchdogSec + dtparam=watchdog=on), which
#                          recovers the Pi from a total kernel hang that cron
#                          can no longer detect. Takes effect after a reboot.
#
# Usage:
#   sudo ./install.sh [--use-timer] [--enable-hw-watchdog]
#
# Install locations can be overridden via the environment (mainly for testing):
#   PREFIX (/usr/local), SYSCONFDIR (/etc), LOGDIR (/var/log),
#   STATE_DIR (/var/lib/network-watchdog), SYSTEMD_DIR (/etc/systemd/system),
#   LOGROTATE_DIR (/etc/logrotate.d), SKIP_ROOT_CHECK, SKIP_APT.

set -e

: "${PREFIX:=/usr/local}"
: "${SYSCONFDIR:=/etc}"
: "${LOGDIR:=/var/log}"
: "${STATE_DIR:=/var/lib/network-watchdog}"
: "${SYSTEMD_DIR:=/etc/systemd/system}"
: "${LOGROTATE_DIR:=/etc/logrotate.d}"
: "${SKIP_ROOT_CHECK:=0}"
: "${SKIP_APT:=0}"

BINDIR="$PREFIX/bin"
WATCHDOG_BIN="$BINDIR/network-watchdog.sh"
CONFIG_PATH="$SYSCONFDIR/network-watchdog.conf"
LOGFILE="$LOGDIR/network-watchdog.log"

if [ "$SKIP_ROOT_CHECK" != "1" ] && [ "$EUID" -ne 0 ]; then
    echo "Please run as root: sudo ./install.sh"
    exit 1
fi

ENABLE_HW_WATCHDOG=0
USE_TIMER=0
for arg in "$@"; do
    case "$arg" in
        --enable-hw-watchdog) ENABLE_HW_WATCHDOG=1 ;;
        --use-timer) USE_TIMER=1 ;;
        *) echo "Unknown option: $arg"; exit 1 ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CRON_MARKER="# pihole-watchdog"

echo "=== Pi-hole Watchdog Installer ==="
echo

# --- Dependency check ---
# Map each required command to the apt package that provides it, so we install
# exactly what's missing.
echo "[1/5] Checking dependencies..."
declare -A PKG_FOR=(
    [dig]=dnsutils
    [ping]=iputils-ping
    [iwconfig]=wireless-tools
    [iw]=iw
    [curl]=curl
    [logrotate]=logrotate
    [ss]=iproute2
)
MISSING_PKGS=""
for cmd in "${!PKG_FOR[@]}"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "  Missing: $cmd (package: ${PKG_FOR[$cmd]})"
        MISSING_PKGS="$MISSING_PKGS ${PKG_FOR[$cmd]}"
    fi
done

if [ -n "$MISSING_PKGS" ] && [ "$SKIP_APT" != "1" ]; then
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
install -d -m 755 "$BINDIR"
install -m 755 "$SCRIPT_DIR/scripts/network-watchdog.sh" "$WATCHDOG_BIN"
echo "  Installed to $WATCHDOG_BIN"

# Persistent state directory for the reboot cooldown (survives reboots).
install -d -m 755 "$STATE_DIR"
echo "  State directory ready at $STATE_DIR"

# Install a default config file only if the user doesn't already have one,
# so their tuned settings survive reinstalls.
install -d -m 755 "$SYSCONFDIR"
if [ ! -f "$CONFIG_PATH" ]; then
    install -m 644 "$SCRIPT_DIR/scripts/network-watchdog.conf" "$CONFIG_PATH"
    echo "  Default config installed at $CONFIG_PATH"
else
    echo "  Existing $CONFIG_PATH left untouched"
fi
echo

# --- Install log rotation ---
install -d -m 755 "$LOGROTATE_DIR"
install -m 644 "$SCRIPT_DIR/scripts/network-watchdog.logrotate" "$LOGROTATE_DIR/network-watchdog"
echo "  Log rotation configured"
echo

# --- WiFi power management fix ---
echo "[3/5] Checking for WiFi interface..."
WIFI_IFACE=$(iw dev 2>/dev/null | awk '$1=="Interface"{print $2}' | head -n1)

if [ -n "$WIFI_IFACE" ]; then
    echo "  Found WiFi interface: $WIFI_IFACE"
    install -d -m 755 "$SYSTEMD_DIR"
    sed "s/WIFI_INTERFACE_PLACEHOLDER/$WIFI_IFACE/" \
        "$SCRIPT_DIR/scripts/wifi-powersave-off.service" > "$SYSTEMD_DIR/wifi-powersave-off.service"
    systemctl daemon-reload
    systemctl enable wifi-powersave-off.service >/dev/null 2>&1
    systemctl start wifi-powersave-off.service
    CURRENT_PM=$(iwconfig "$WIFI_IFACE" 2>/dev/null | grep -o "Power Management:[a-z]*" || echo "unknown")
    echo "  WiFi power management service installed and started ($CURRENT_PM)"
else
    echo "  No WiFi interface detected (likely running on Ethernet) - skipping this step"
fi
echo

# --- Scheduling: systemd timer or cron ---
echo "[4/5] Setting up scheduling..."
if [ "$USE_TIMER" -eq 1 ]; then
    # Remove any cron line first so the two don't both run.
    TMP_CRON=$(mktemp)
    crontab -l 2>/dev/null | grep -v "$CRON_MARKER" > "$TMP_CRON" || true
    crontab "$TMP_CRON" 2>/dev/null || true
    rm -f "$TMP_CRON"

    install -d -m 755 "$SYSTEMD_DIR"
    sed "s#/usr/local/bin/network-watchdog.sh#$WATCHDOG_BIN#" \
        "$SCRIPT_DIR/scripts/network-watchdog.service" > "$SYSTEMD_DIR/network-watchdog.service"
    install -m 644 "$SCRIPT_DIR/scripts/network-watchdog.timer" "$SYSTEMD_DIR/network-watchdog.timer"
    systemctl daemon-reload
    systemctl enable --now network-watchdog.timer >/dev/null 2>&1
    echo "  systemd timer installed and started (network-watchdog.timer, every 10 min)"
else
    TMP_CRON=$(mktemp)
    crontab -l 2>/dev/null | grep -v "$CRON_MARKER" > "$TMP_CRON" || true
    {
        echo "*/10 * * * * $WATCHDOG_BIN $CRON_MARKER (watchdog)"
    } >> "$TMP_CRON"
    crontab "$TMP_CRON"
    rm -f "$TMP_CRON"
    echo "  Cron job installed: network/DNS/web UI watchdog every 10 minutes"
fi
echo

# --- Log file + optional hardware watchdog ---
echo "[5/5] Finalizing..."
install -d -m 755 "$LOGDIR"
touch "$LOGFILE"
chmod 644 "$LOGFILE"
echo "  Log file ready at $LOGFILE"

if [ "$ENABLE_HW_WATCHDOG" -eq 1 ]; then
    echo "  Enabling SoC hardware watchdog..."
    # systemd side: reset the board if the kernel stops petting the watchdog.
    mkdir -p /etc/systemd/system.conf.d
    cat > /etc/systemd/system.conf.d/watchdog.conf << 'EOF'
[Manager]
RuntimeWatchdogSec=15
RebootWatchdogSec=2min
EOF
    systemctl daemon-reexec 2>/dev/null || true
    echo "    systemd RuntimeWatchdogSec=15 configured"

    # firmware side: enable the BCM watchdog device via config.txt.
    BOOTCFG=""
    for c in /boot/firmware/config.txt /boot/config.txt; do
        [ -f "$c" ] && BOOTCFG="$c" && break
    done
    if [ -n "$BOOTCFG" ]; then
        if grep -q "^dtparam=watchdog=on" "$BOOTCFG"; then
            echo "    dtparam=watchdog=on already present in $BOOTCFG"
        else
            echo "dtparam=watchdog=on" >> "$BOOTCFG"
            echo "    Added dtparam=watchdog=on to $BOOTCFG"
        fi
        echo "    Reboot once to fully activate the hardware watchdog."
    else
        echo "    Could not find config.txt - skipped firmware watchdog (systemd part still active)"
    fi
fi
echo

echo "=== Install complete ==="
echo
echo "Summary of what's running:"
if [ "$USE_TIMER" -eq 1 ]; then
echo "  - systemctl status network-watchdog.timer  -> view the timer"
echo "  - systemctl list-timers network-watchdog.timer"
else
echo "  - crontab -l          -> view scheduled jobs"
fi
echo "  - tail -f $LOGFILE  -> watch watchdog activity"
if [ -n "$WIFI_IFACE" ]; then
echo "  - systemctl status wifi-powersave-off.service"
fi
if [ "$ENABLE_HW_WATCHDOG" -ne 1 ]; then
echo
echo "Tip: enable the SoC hardware watchdog (recovers from full kernel hangs) with:"
echo "  sudo ./install.sh --enable-hw-watchdog"
fi
echo
echo "Optional: set NOTIFY_CMD / HEARTBEAT_URL in $CONFIG_PATH to get alerts."
echo "To uninstall, run: sudo ./uninstall.sh"
echo "To re-verify at any time, run: sudo ./verify.sh"

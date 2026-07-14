#!/bin/bash
# Tiered network/DNS/web UI watchdog for Pi-hole
#
# 1. Check gateway -> if unreachable, restart networking, recheck
# 2. Check DNS and web UI -> if either is broken, restart pihole-FTL, recheck
# 3. If still broken after soft fixes, reboot (with cooldown to prevent reboot loops)
#
# Part of: https://github.com/Alghofaily/pihole-watchdog

# --- Defaults (override via /etc/network-watchdog.conf, or env for testing) ---
LOGFILE="${LOGFILE:-/var/log/network-watchdog.log}"
# State must persist across reboots, so the reboot cooldown actually holds after
# a reboot. /var/run (=/run) is tmpfs and is wiped on boot, which defeats the
# whole point of the cooldown, so we use /var/lib instead.
STATEDIR="${STATEDIR:-/var/lib/network-watchdog}"
STATEFILE="${STATEFILE:-$STATEDIR/lastreboot}"
LOCKFILE="${LOCKFILE:-/run/network-watchdog.lock}"
TEST_DOMAIN="${TEST_DOMAIN:-google.com}"
REBOOT_COOLDOWN="${REBOOT_COOLDOWN:-1800}"   # seconds (30 min) min between reboots this script triggers
REBOOT_CMD="${REBOOT_CMD:-/sbin/reboot}"     # overridable so the test suite can intercept it

CONFIG_FILE="${CONFIG_FILE:-/etc/network-watchdog.conf}"
# shellcheck source=/dev/null
[ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"

mkdir -p "$STATEDIR" 2>/dev/null

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOGFILE"
}

# --- Single-instance lock ---
# A slow run (two 15s sleeps plus service restarts) can exceed the cron interval.
# Without a lock, two overlapping runs could both decide to reboot.
exec 9>"$LOCKFILE"
if ! flock -n 9; then
    log "Another watchdog instance is already running. Skipping this run."
    exit 0
fi

# Resolve the default gateway (take the first if several default routes exist -
# a multi-line value would make every ping fail and trigger needless recovery).
GATEWAY=$(ip route | awk '/^default/ {print $3; exit}')

check_gateway() {
    ping -c 1 -W 5 "$GATEWAY" > /dev/null 2>&1
}

check_dns() {
    dig +short +time=5 +tries=1 "$TEST_DOMAIN" @127.0.0.1 > /dev/null 2>&1
}

check_webui() {
    curl -sf --max-time 5 -o /dev/null http://localhost/admin
}

restart_networking() {
    # Cover both legacy (dhcpcd/ifupdown) and modern (NetworkManager, default on
    # Raspberry Pi OS Bookworm) network stacks.
    systemctl restart NetworkManager 2>/dev/null \
        || systemctl restart dhcpcd 2>/dev/null \
        || systemctl restart networking 2>/dev/null
}

can_reboot() {
    if [ -f "$STATEFILE" ]; then
        LAST=$(cat "$STATEFILE")
        NOW=$(date +%s)
        DIFF=$((NOW - LAST))
        if [ "$DIFF" -lt "$REBOOT_COOLDOWN" ]; then
            return 1
        fi
    fi
    return 0
}

do_reboot() {
    if can_reboot; then
        log "Rebooting now."
        date +%s > "$STATEFILE"
        $REBOOT_CMD
    else
        log "Reboot suppressed - within cooldown window (${REBOOT_COOLDOWN}s). Manual check may be needed."
    fi
}

if [ -z "$GATEWAY" ]; then
    log "Could not determine default gateway. Exiting."
    exit 1
fi

# --- Step 1: Gateway check ---
if ! check_gateway; then
    log "Gateway $GATEWAY unreachable. Attempting to restart networking."
    restart_networking
    sleep 15

    if ! check_gateway; then
        log "Gateway still unreachable after network restart."
        do_reboot
        exit 0
    else
        log "Gateway reachable after network restart. Recovered without reboot."
    fi
fi

# --- Step 2: DNS + web UI check (only meaningful if gateway is up) ---
DNS_OK=true
WEBUI_OK=true
check_dns || DNS_OK=false
check_webui || WEBUI_OK=false

if [ "$DNS_OK" = false ] || [ "$WEBUI_OK" = false ]; then
    REASON=""
    [ "$DNS_OK" = false ] && REASON="DNS not responding"
    if [ "$WEBUI_OK" = false ]; then
        if [ -n "$REASON" ]; then
            REASON="$REASON and web UI unresponsive"
        else
            REASON="web UI unresponsive"
        fi
    fi
    log "$REASON. Attempting to restart pihole-FTL."
    systemctl restart pihole-FTL
    sleep 15

    check_dns && DNS_OK=true || DNS_OK=false
    check_webui && WEBUI_OK=true || WEBUI_OK=false

    if [ "$DNS_OK" = false ] || [ "$WEBUI_OK" = false ]; then
        log "Still failing after pihole-FTL restart ($REASON)."
        if ! check_gateway; then
            log "Gateway also down on recheck."
        fi
        do_reboot
        exit 0
    else
        log "Recovered after pihole-FTL restart. No reboot needed."
    fi
fi

log "Network, DNS, and web UI all OK."
exit 0

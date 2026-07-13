#!/bin/bash
# Tiered network/DNS watchdog for Pi-hole
#
# 1. Check gateway -> if unreachable, restart networking, recheck
# 2. Check DNS -> if broken, restart pihole-FTL, recheck
# 3. If still broken after soft fixes, reboot (with cooldown to prevent reboot loops)
#
# Part of: https://github.com/alghofaily/pihole-watchdog

LOGFILE="/var/log/network-watchdog.log"
STATEFILE="/var/run/network-watchdog-lastreboot"
GATEWAY=$(ip route | grep default | awk '{print $3}')
TEST_DOMAIN="google.com"
REBOOT_COOLDOWN=1800   # seconds (30 min) minimum between reboots triggered by this script

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOGFILE"
}

check_gateway() {
    ping -c 1 -W 5 "$GATEWAY" > /dev/null 2>&1
}

check_dns() {
    dig +short +time=5 +tries=1 "$TEST_DOMAIN" @127.0.0.1 > /dev/null 2>&1
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
        /sbin/reboot
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
    systemctl restart dhcpcd 2>/dev/null || systemctl restart networking 2>/dev/null
    sleep 15

    if ! check_gateway; then
        log "Gateway still unreachable after network restart."
        do_reboot
        exit 0
    else
        log "Gateway reachable after network restart. Recovered without reboot."
    fi
fi

# --- Step 2: DNS check (only meaningful if gateway is up) ---
if ! check_dns; then
    log "DNS resolution failed. Attempting to restart pihole-FTL."
    systemctl restart pihole-FTL
    sleep 15

    if ! check_dns; then
        log "DNS still failing after pihole-FTL restart."
        if ! check_gateway; then
            log "Gateway also down on recheck."
        fi
        do_reboot
        exit 0
    else
        log "DNS recovered after pihole-FTL restart. No reboot needed."
    fi
fi

log "Network and DNS OK."
exit 0

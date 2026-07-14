#!/bin/bash
# Tiered network/DNS/web UI watchdog for Pi-hole
#
# Escalation:
#   1. Check gateway -> if unreachable, restart networking, recheck
#   2. Check DNS and web UI -> if either is broken, restart pihole-FTL, recheck
#   3. If still broken after soft fixes, reboot (with cooldown to prevent reboot loops)
#
# Alert-only checks (never reboot - a reboot wouldn't help):
#   - Read-only root filesystem / low disk (SD card failure)
#   - Under-voltage / thermal throttling (bad power supply or cooling)
#   - Upstream DNS dead while FTL itself is up
#
# Optional notifications (NOTIFY_CMD) and dead-man's-switch heartbeat (HEARTBEAT_URL).
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

# Alert-only health thresholds / toggles
DISK_WARN_PCT="${DISK_WARN_PCT:-90}"
ENABLE_UPSTREAM_CHECK="${ENABLE_UPSTREAM_CHECK:-true}"

# Optional integrations (empty = disabled)
NOTIFY_CMD="${NOTIFY_CMD:-}"
HEARTBEAT_URL="${HEARTBEAT_URL:-}"

CONFIG_FILE="${CONFIG_FILE:-/etc/network-watchdog.conf}"
# shellcheck source=/dev/null
[ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"

mkdir -p "$STATEDIR" 2>/dev/null

log() {
    # Best-effort: if the root filesystem has gone read-only this silently fails,
    # which is exactly why notify() does not depend on logging succeeding.
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOGFILE" 2>/dev/null
}

# notify: always log, and additionally run the user's NOTIFY_CMD (if set) with
# the message exposed as $MSG. Runs regardless of whether logging worked.
notify() {
    local msg="$1"
    log "$msg"
    if [ -n "$NOTIFY_CMD" ]; then
        MSG="$msg" bash -c "$NOTIFY_CMD" >/dev/null 2>&1 || log "notify: NOTIFY_CMD failed"
    fi
}

# heartbeat: dead-man's switch. Pinged only on a completed, ultimately-healthy
# run; a reboot path exits before this, so the monitor notices the silence.
heartbeat() {
    [ -n "$HEARTBEAT_URL" ] || return 0
    curl -fsS -m 10 "$HEARTBEAT_URL" >/dev/null 2>&1 || log "heartbeat: ping failed"
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

# Force a real upstream lookup with an uncacheable random label. NOERROR or
# NXDOMAIN both prove the upstream chain is reachable; SERVFAIL/timeout does not.
check_dns_upstream() {
    local probe="wd-check-$(date +%s)-${RANDOM}.${TEST_DOMAIN}"
    dig +time=3 +tries=1 "$probe" @127.0.0.1 2>/dev/null \
        | grep -qE "status: (NOERROR|NXDOMAIN)"
}

restart_networking() {
    # Cover both legacy (dhcpcd/ifupdown) and modern (NetworkManager, default on
    # Raspberry Pi OS Bookworm) network stacks.
    systemctl restart NetworkManager 2>/dev/null \
        || systemctl restart dhcpcd 2>/dev/null \
        || systemctl restart networking 2>/dev/null
}

# Alert-only preflight: conditions a reboot cannot fix. Never blocks or reboots.
check_health() {
    # Read-only root filesystem (classic SD card failure).
    local root_opts
    root_opts=$(awk '$2=="/"{print $4; exit}' /proc/mounts 2>/dev/null)
    case ",$root_opts," in
        *,ro,*) notify "Root filesystem is READ-ONLY - likely SD card failure. A reboot will NOT fix this; replace/check the card." ;;
    esac

    # Low disk space.
    if command -v df >/dev/null 2>&1; then
        local use
        use=$(df -P / 2>/dev/null | awk 'NR==2{gsub("%","",$5); print $5}')
        if [ -n "$use" ] && [ "$use" -ge "$DISK_WARN_PCT" ] 2>/dev/null; then
            notify "Disk usage on / is ${use}% (threshold ${DISK_WARN_PCT}%). Free space or logs may be the real problem."
        fi
    fi

    # Under-voltage / thermal throttling (Raspberry Pi only).
    if command -v vcgencmd >/dev/null 2>&1; then
        local th
        th=$(vcgencmd get_throttled 2>/dev/null | sed 's/.*=//')
        if [ -n "$th" ] && [ "$th" != "0x0" ]; then
            notify "Pi power/thermal throttling detected (get_throttled=$th) - check the power supply and cooling."
        fi
    fi
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
        notify "Rebooting now - soft fixes did not recover the Pi."
        date +%s > "$STATEFILE"
        $REBOOT_CMD
    else
        notify "Reboot suppressed - within cooldown window (${REBOOT_COOLDOWN}s). Persistent failure; manual check needed."
    fi
}

if [ -z "$GATEWAY" ]; then
    log "Could not determine default gateway. Exiting."
    exit 1
fi

# --- Preflight health (alert-only, never blocks the escalation below) ---
check_health

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
        notify "Gateway was unreachable but recovered after a network restart. No reboot needed."
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
        notify "$REASON, but recovered after restarting pihole-FTL. No reboot needed."
    fi
fi

# --- Step 3: Upstream DNS check (alert-only; FTL is up but the internet/upstream
# resolvers may be down - a reboot would not fix that) ---
if [ "$ENABLE_UPSTREAM_CHECK" = true ]; then
    if ! check_dns_upstream; then
        notify "Local DNS is up but UPSTREAM resolution is failing (FTL answering, forwarders/internet unreachable). Not rebooting - check upstream DNS / connectivity."
    fi
fi

log "Network, DNS, and web UI all OK."
heartbeat
exit 0

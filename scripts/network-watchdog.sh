#!/bin/bash
# Tiered network/DNS/web UI watchdog for Pi-hole
#
# Escalation (reboot-eligible):
#   1. Check gateway -> if unreachable, restart networking, recheck
#   2. Check DNS (FTL answering) and web UI -> if either is broken, restart
#      pihole-FTL, recheck
#   3. If still broken after soft fixes, reboot (with cooldown to prevent loops)
#
# Alert-only checks (never reboot - a reboot wouldn't help). All routed through
# alert(), which de-duplicates so a persistent condition doesn't notify every run:
#   - Read-only root filesystem / low disk / storage I/O errors (SD card failure)
#   - Low memory / high swap / OOM kills (FTL getting OOM-killed)
#   - Under-voltage / thermal throttling / high CPU temperature
#   - Pi-hole blocking disabled or stale gravity (blocklists)
#   - Clock not NTP-synced (breaks DNSSEC/TLS)
#   - Weak WiFi signal, DHCP server not listening, IPv6 gateway unreachable
#   - Upstream DNS dead while FTL itself is up (optionally soft-fixed first)
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
ALERTDIR="${ALERTDIR:-$STATEDIR/alerts}"
LOCKFILE="${LOCKFILE:-/run/network-watchdog.lock}"
TEST_DOMAIN="${TEST_DOMAIN:-google.com}"
REBOOT_COOLDOWN="${REBOOT_COOLDOWN:-1800}"   # seconds (30 min) min between reboots this script triggers

# Files read for health checks - overridable so the test suite can point them at fakes.
MEMINFO="${MEMINFO:-/proc/meminfo}"
MOUNTS="${MOUNTS:-/proc/mounts}"
GRAVITY_DB="${GRAVITY_DB:-/etc/pihole/gravity.db}"
DNSMASQ_DIR="${DNSMASQ_DIR:-/etc/dnsmasq.d}"

# Web UI + service-restart commands (overridable for Pi-hole v6 / Docker / testing).
WEBUI_URL="${WEBUI_URL:-http://localhost/admin}"
FTL_RESTART_CMD="${FTL_RESTART_CMD:-systemctl restart pihole-FTL}"

# Reboot command. Prefer systemd's reboot when available (clean shutdown), fall
# back to /sbin/reboot. Overridable so the test suite can intercept it.
if [ -z "${REBOOT_CMD+x}" ]; then
    if command -v systemctl >/dev/null 2>&1; then
        REBOOT_CMD="systemctl reboot"
    else
        REBOOT_CMD="/sbin/reboot"
    fi
fi

# Alert-only health thresholds / toggles
DISK_WARN_PCT="${DISK_WARN_PCT:-90}"
MEM_WARN_PCT="${MEM_WARN_PCT:-10}"           # warn when available RAM drops below this %
SWAP_WARN_PCT="${SWAP_WARN_PCT:-50}"         # warn when swap used exceeds this %
TEMP_WARN_C="${TEMP_WARN_C:-80}"             # warn above this CPU temperature (C)
RSSI_WARN_DBM="${RSSI_WARN_DBM:--75}"        # warn when WiFi signal is weaker than this
GRAVITY_MAX_AGE_DAYS="${GRAVITY_MAX_AGE_DAYS:-14}"
ALERT_COOLDOWN="${ALERT_COOLDOWN:-3600}"     # min seconds between repeats of the same alert
SOFTFIX_WINDOW="${SOFTFIX_WINDOW:-3600}"     # rolling window for the "recovery storm" escalation
SOFTFIX_ESCALATE="${SOFTFIX_ESCALATE:-3}"    # this many soft fixes in the window -> escalate

ENABLE_UPSTREAM_CHECK="${ENABLE_UPSTREAM_CHECK:-true}"
ENABLE_UPSTREAM_RESTART="${ENABLE_UPSTREAM_RESTART:-false}"
UPSTREAM_RESTART_CMD="${UPSTREAM_RESTART_CMD:-}"
ENABLE_MEM_CHECK="${ENABLE_MEM_CHECK:-true}"
ENABLE_BLOCKING_CHECK="${ENABLE_BLOCKING_CHECK:-true}"
ENABLE_TIME_CHECK="${ENABLE_TIME_CHECK:-true}"
ENABLE_IO_CHECK="${ENABLE_IO_CHECK:-true}"
ENABLE_DHCP_CHECK="${ENABLE_DHCP_CHECK:-true}"
ENABLE_IPV6_CHECK="${ENABLE_IPV6_CHECK:-true}"

# Optional integrations (empty = disabled)
NOTIFY_CMD="${NOTIFY_CMD:-}"
HEARTBEAT_URL="${HEARTBEAT_URL:-}"

CONFIG_FILE="${CONFIG_FILE:-/etc/network-watchdog.conf}"
# shellcheck source=/dev/null
[ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"

mkdir -p "$STATEDIR" 2>/dev/null

# Keys of alerts asserted during this run, wrapped in spaces for whole-word matching.
ACTIVE_ALERTS=" "

log() {
    # Best-effort: if the root filesystem has gone read-only this silently fails,
    # which is exactly why notify() does not depend on logging succeeding.
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOGFILE" 2>/dev/null
}

# notify: always log, and additionally run the user's NOTIFY_CMD (if set) with
# the message exposed as $MSG. Runs regardless of whether logging worked. Use
# this for one-off actions (restart/reboot); use alert() for recurring conditions.
notify() {
    local msg="$1"
    log "$msg"
    if [ -n "$NOTIFY_CMD" ]; then
        MSG="$msg" bash -c "$NOTIFY_CMD" >/dev/null 2>&1 || log "notify: NOTIFY_CMD failed"
    fi
}

# alert: notify about a recurring condition, keyed by a short id, but suppress
# repeats within ALERT_COOLDOWN so a persistent problem doesn't spam every run.
# clear_stale_alerts() emits a one-shot "resolved" when the condition goes away.
alert() {
    local key="$1" msg="$2" f now last
    ACTIVE_ALERTS="${ACTIVE_ALERTS}${key} "
    mkdir -p "$ALERTDIR" 2>/dev/null
    f="$ALERTDIR/$key"
    now=$(date +%s)
    if [ -f "$f" ]; then
        last=$(cat "$f" 2>/dev/null)
        case "$last" in ''|*[!0-9]*) last=0 ;; esac
        if [ "$((now - last))" -lt "$ALERT_COOLDOWN" ]; then
            log "alert '$key' still active (suppressed within ${ALERT_COOLDOWN}s): $msg"
            return 0
        fi
    fi
    echo "$now" > "$f" 2>/dev/null
    notify "$msg"
}

# clear_stale_alerts: any alert file whose key was NOT re-asserted this run means
# the condition has cleared - send a one-shot "resolved" and forget it.
clear_stale_alerts() {
    [ -d "$ALERTDIR" ] || return 0
    local f key
    for f in "$ALERTDIR"/*; do
        [ -e "$f" ] || continue
        key=$(basename "$f")
        case "$ACTIVE_ALERTS" in
            *" $key "*) : ;;   # still active this run
            *) notify "Resolved: '$key' condition is no longer present."; rm -f "$f" ;;
        esac
    done
}

# record_softfix: track how often soft fixes fire, and escalate on a recurring
# storm (which usually means a deeper hardware/SD/PSU cause a restart won't fix).
record_softfix() {
    local f="$STATEDIR/softfix.log" now cutoff cnt
    now=$(date +%s)
    echo "$now" >> "$f" 2>/dev/null
    cutoff=$((now - SOFTFIX_WINDOW))
    if [ -f "$f" ]; then
        awk -v c="$cutoff" '$1>=c' "$f" > "$f.tmp" 2>/dev/null && mv "$f.tmp" "$f" 2>/dev/null
        cnt=$(wc -l < "$f" 2>/dev/null | tr -d ' ')
        if [ -n "$cnt" ] && [ "$cnt" -ge "$SOFTFIX_ESCALATE" ] 2>/dev/null; then
            alert softfix-storm "Recovery actions fired ${cnt} times in the last $((SOFTFIX_WINDOW/60)) min - recurring instability. Likely a deeper cause (SD card, power supply, RF). Review /var/log/network-watchdog.log."
        fi
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

# check_dns: prove FTL is *answering* at all. Any DNS response (NOERROR, NXDOMAIN,
# SERVFAIL, REFUSED...) means FTL is alive; only a timeout / no response means it
# is wedged. Upstream reachability is a separate, alert-only concern
# (check_dns_upstream) - a plain ISP outage must NOT restart FTL or trigger a reboot.
check_dns() {
    dig +time=5 +tries=1 "$TEST_DOMAIN" @127.0.0.1 2>/dev/null | grep -q "status:"
}

# check_webui: treat any HTTP response from the server (2xx/3xx, plus auth-gated
# 401/403) as "web server up". Only no response / connection refused / 5xx counts
# as down, so a password-protected or Pi-hole v6 admin page isn't misread as dead.
check_webui() {
    local code
    code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' "$WEBUI_URL" 2>/dev/null)
    case "$code" in
        2??|3??|401|403) return 0 ;;
        *) return 1 ;;
    esac
}

# Force a real upstream lookup with an uncacheable random label. NOERROR or
# NXDOMAIN both prove the upstream chain is reachable; SERVFAIL/timeout does not.
check_dns_upstream() {
    local probe
    probe="wd-check-$(date +%s)-${RANDOM}.${TEST_DOMAIN}"
    dig +time=3 +tries=1 "$probe" @127.0.0.1 2>/dev/null \
        | grep -qE "status: (NOERROR|NXDOMAIN)"
}

restart_networking() {
    # Cover both legacy (dhcpcd/ifupdown) and modern (NetworkManager, default on
    # Raspberry Pi OS Bookworm) network stacks.
    systemctl restart NetworkManager 2>/dev/null \
        || systemctl restart dhcpcd 2>/dev/null \
        || systemctl restart networking 2>/dev/null
    record_softfix
}

# restart_ftl: run the (overridable) FTL restart command and log its result, so a
# failing restart is visible rather than silently ignored. Docker users point
# FTL_RESTART_CMD at e.g. "docker restart pihole".
restart_ftl() {
    local rc
    bash -c "$FTL_RESTART_CMD" >/dev/null 2>&1
    rc=$?
    if [ "$rc" -ne 0 ]; then
        log "FTL restart command failed (rc=$rc): $FTL_RESTART_CMD"
    fi
    record_softfix
    return "$rc"
}

# --- Alert-only health checks. None of these ever reboot or block escalation. ---

check_health() {
    # Read-only root filesystem (classic SD card failure).
    local root_opts
    root_opts=$(awk '$2=="/"{print $4; exit}' "$MOUNTS" 2>/dev/null)
    case ",$root_opts," in
        *,ro,*) alert rootfs-ro "Root filesystem is READ-ONLY - likely SD card failure. A reboot will NOT fix this; replace/check the card." ;;
    esac

    # Low disk space.
    if command -v df >/dev/null 2>&1; then
        local use
        use=$(df -P / 2>/dev/null | awk 'NR==2{gsub("%","",$5); print $5}')
        if [ -n "$use" ] && [ "$use" -ge "$DISK_WARN_PCT" ] 2>/dev/null; then
            alert disk-high "Disk usage on / is ${use}% (threshold ${DISK_WARN_PCT}%). Free space or logs may be the real problem."
        fi
    fi
}

# Low memory, high swap, and OOM kills - a top cause of FTL "going dark" on 512MB boards.
check_memory() {
    [ "$ENABLE_MEM_CHECK" = true ] || return 0
    if [ -r "$MEMINFO" ]; then
        local total avail swaptotal swapfree availpct swappct
        total=$(awk '/^MemTotal:/{print $2}' "$MEMINFO")
        avail=$(awk '/^MemAvailable:/{print $2}' "$MEMINFO")
        swaptotal=$(awk '/^SwapTotal:/{print $2}' "$MEMINFO")
        swapfree=$(awk '/^SwapFree:/{print $2}' "$MEMINFO")
        if [ -n "$total" ] && [ "$total" -gt 0 ] 2>/dev/null && [ -n "$avail" ]; then
            availpct=$((avail * 100 / total))
            if [ "$availpct" -lt "$MEM_WARN_PCT" ]; then
                alert mem-low "Low memory: only ${availpct}% of RAM available (threshold ${MEM_WARN_PCT}%). pihole-FTL may be at risk of an OOM kill."
            fi
        fi
        if [ -n "$swaptotal" ] && [ "$swaptotal" -gt 0 ] 2>/dev/null && [ -n "$swapfree" ]; then
            swappct=$(((swaptotal - swapfree) * 100 / swaptotal))
            if [ "$swappct" -ge "$SWAP_WARN_PCT" ]; then
                alert swap-high "High swap usage: ${swappct}% of swap in use (threshold ${SWAP_WARN_PCT}%). The Pi may be thrashing."
            fi
        fi
    fi
    if command -v dmesg >/dev/null 2>&1; then
        if dmesg 2>/dev/null | grep -qiE "out of memory|oom-kill"; then
            alert oom-kill "Kernel log shows an out-of-memory kill - a process (possibly pihole-FTL) was OOM-killed. Add swap or reduce memory load."
        fi
    fi
}

# CPU temperature warning + under-voltage/throttling, distinguishing a CURRENT
# fault (low bits) from one that merely occurred since boot (high/sticky bits).
check_thermal() {
    command -v vcgencmd >/dev/null 2>&1 || return 0
    local tstr tval th thnum curbits
    tstr=$(vcgencmd measure_temp 2>/dev/null | sed -n 's/temp=\([0-9.]*\).*/\1/p')
    if [ -n "$tstr" ]; then
        tval=${tstr%.*}
        if [ -n "$tval" ] && [ "$tval" -ge "$TEMP_WARN_C" ] 2>/dev/null; then
            alert temp-high "CPU temperature is ${tstr}C (threshold ${TEMP_WARN_C}C) - check cooling and airflow."
        fi
    fi
    th=$(vcgencmd get_throttled 2>/dev/null | sed 's/.*=//')
    if [ -n "$th" ] && [ "$th" != "0x0" ]; then
        thnum=$((th))
        curbits=$((thnum & 0xF))
        if [ "$curbits" -ne 0 ]; then
            alert throttle-now "Pi is CURRENTLY under-voltage/throttled (get_throttled=$th) - check the power supply and cooling now."
        else
            alert throttle-past "Pi under-voltage/throttling has occurred since boot (get_throttled=$th) - a past event; keep an eye on the power supply."
        fi
    fi
}

# Pi-hole actually blocking, and gravity (blocklists) not stale.
check_blocking() {
    [ "$ENABLE_BLOCKING_CHECK" = true ] || return 0
    if command -v pihole >/dev/null 2>&1; then
        if pihole status 2>/dev/null | grep -qi "blocking is disabled"; then
            alert blocking-off "Pi-hole blocking is DISABLED - DNS still resolves but nothing is being blocked. Re-enable with 'pihole enable'."
        fi
    fi
    if [ -f "$GRAVITY_DB" ]; then
        local mtime now age_days
        mtime=$(stat -c %Y "$GRAVITY_DB" 2>/dev/null)
        now=$(date +%s)
        if [ -n "$mtime" ]; then
            age_days=$(((now - mtime) / 86400))
            if [ "$age_days" -ge "$GRAVITY_MAX_AGE_DAYS" ] 2>/dev/null; then
                alert gravity-stale "Pi-hole gravity (blocklists) last updated ${age_days} days ago (threshold ${GRAVITY_MAX_AGE_DAYS}). Run 'pihole -g' or check the update schedule."
            fi
        fi
    fi
}

# Clock sync - drift breaks DNSSEC validation and TLS.
check_time() {
    [ "$ENABLE_TIME_CHECK" = true ] || return 0
    command -v timedatectl >/dev/null 2>&1 || return 0
    local synced
    synced=$(timedatectl show -p NTPSynchronized --value 2>/dev/null)
    if [ "$synced" = "no" ]; then
        alert time-unsynced "System clock is NOT NTP-synchronized - drift can break DNSSEC and TLS. Check the time/NTP service."
    fi
}

# Storage I/O errors in the kernel log - catches a dying SD card before it goes
# fully read-only (the only card signal the rest of the script catches today).
check_io_errors() {
    [ "$ENABLE_IO_CHECK" = true ] || return 0
    command -v dmesg >/dev/null 2>&1 || return 0
    if dmesg 2>/dev/null | grep -qiE "i/o error|mmc0: error|ext4-fs error|blk_update_request"; then
        alert io-errors "Kernel log shows storage I/O errors - the SD card may be failing. Back it up and replace it before it goes read-only."
    fi
}

# Weak WiFi signal (complements the power-save fix - a weak link still drops).
check_wifi_signal() {
    command -v iw >/dev/null 2>&1 || return 0
    local iface sig
    iface=$(iw dev 2>/dev/null | awk '$1=="Interface"{print $2; exit}')
    [ -n "$iface" ] || return 0
    sig=$(iw dev "$iface" link 2>/dev/null | awk '/signal:/{print $2; exit}')
    if [ -n "$sig" ] && [ "$sig" -lt "$RSSI_WARN_DBM" ] 2>/dev/null; then
        alert wifi-weak "WiFi signal on ${iface} is ${sig} dBm (threshold ${RSSI_WARN_DBM} dBm) - a weak link can cause drops. Move the Pi closer to the AP."
    fi
}

# DHCP server health - only relevant when Pi-hole itself hands out leases.
check_dhcp() {
    [ "$ENABLE_DHCP_CHECK" = true ] || return 0
    grep -qsiE "^dhcp-range" "$DNSMASQ_DIR"/*.conf 2>/dev/null || return 0
    command -v ss >/dev/null 2>&1 || return 0
    if ! ss -lun 2>/dev/null | grep -q ":67 "; then
        alert dhcp-down "Pi-hole is configured as a DHCP server but nothing is listening on UDP/67 - clients may fail to get IP leases."
    fi
}

# IPv6 default gateway reachability - alert only. IPv4 stays the sole reboot
# driver so a flaky IPv6 path can never cause a reboot.
check_gateway_ipv6() {
    [ "$ENABLE_IPV6_CHECK" = true ] || return 0
    local gw6
    gw6=$(ip -6 route 2>/dev/null | awk '/^default/{print $3; exit}')
    [ -n "$gw6" ] || return 0
    if ! ping -6 -c 1 -W 5 "$gw6" >/dev/null 2>&1; then
        alert ipv6-gw "IPv6 default gateway ($gw6) is unreachable (IPv4 unaffected; not rebooting). IPv6 connectivity may be degraded."
    fi
}

run_health_checks() {
    check_health
    check_memory
    check_thermal
    check_blocking
    check_time
    check_io_errors
    check_wifi_signal
    check_dhcp
    check_gateway_ipv6
}

can_reboot() {
    if [ -f "$STATEFILE" ]; then
        local last now diff
        last=$(cat "$STATEFILE" 2>/dev/null)
        # Corrupt/non-numeric state must not wedge the cooldown - treat as expired.
        case "$last" in
            ''|*[!0-9]*) return 0 ;;
        esac
        now=$(date +%s)
        diff=$((now - last))
        if [ "$diff" -lt "$REBOOT_COOLDOWN" ]; then
            return 1
        fi
    fi
    return 0
}

do_reboot() {
    if can_reboot; then
        notify "Rebooting now - soft fixes did not recover the Pi."
        date +%s > "$STATEFILE"
        sync 2>/dev/null || true
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
run_health_checks

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
    restart_ftl
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
# resolvers may be down - a reboot would not fix that). Optionally soft-fix a
# local recursive resolver (e.g. unbound) before alerting. ---
if [ "$ENABLE_UPSTREAM_CHECK" = true ]; then
    if ! check_dns_upstream; then
        if [ "$ENABLE_UPSTREAM_RESTART" = true ] && [ -n "$UPSTREAM_RESTART_CMD" ]; then
            log "Upstream DNS failing - attempting recursive resolver restart: $UPSTREAM_RESTART_CMD"
            bash -c "$UPSTREAM_RESTART_CMD" >/dev/null 2>&1
            record_softfix
            sleep 5
        fi
        if ! check_dns_upstream; then
            alert upstream-down "Local DNS is up but UPSTREAM resolution is failing (FTL answering, forwarders/internet unreachable). Not rebooting - check upstream DNS / connectivity."
        fi
    fi
fi

clear_stale_alerts
log "Network, DNS, and web UI all OK."
heartbeat
exit 0

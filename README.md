# Pi-hole Watchdog

Keeps a Raspberry Pi running Pi-hole reachable, by automatically detecting and recovering from the two most common causes of a Pi-hole "going dark": WiFi power-management drops and DNS/FTL hangs.

Built after chasing down exactly this problem on a Pi Zero 2 W: Pi-hole would freeze, and eventually the whole device would drop off the network until it was power-cycled. Root cause was WiFi power saving on the `brcmfmac` chip; this repo fixes that and adds a safety net for anything else that goes wrong.

## What it sets up

| Component | What it does |
|---|---|
| **WiFi power-save fix** | Disables WiFi power management on boot via systemd — the most common cause of a Pi silently dropping off the network (skipped automatically if you're on Ethernet) |
| **Tiered watchdog** | Runs every 10 minutes. Checks gateway reachability, DNS resolution, and the Pi-hole web UI. Tries a soft fix first (restart networking / restart `pihole-FTL`), and only reboots if that doesn't recover it |
| **Reboot cooldown** | Won't reboot more than once per 30 minutes, so a persistent problem doesn't cause a reboot loop — it logs and waits instead |
| **Log rotation** | Keeps `/var/log/network-watchdog.log` from growing unbounded |
| **Health alerts** | Alert-only checks a reboot can't fix: read-only SD card, low disk, **storage I/O errors**, **low memory / high swap / OOM kills**, under-voltage/thermal throttling **and high CPU temperature**, **Pi-hole blocking disabled or stale blocklists**, **clock not NTP-synced**, **weak WiFi signal**, **DHCP not listening**, **IPv6 gateway unreachable**, and "FTL up but upstream DNS dead" |
| **De-duplicated alerts** | A persistent condition notifies once (not every 10 minutes), then sends a one-shot "resolved" when it clears — no alert fatigue |
| **Recovery-storm escalation** | If soft fixes keep firing, sends a distinct "recurring instability" alert pointing at a likely deeper cause (SD card, PSU, RF) |
| **Notifications** | Optional push (ntfy/Slack/webhook/email) whenever it takes action, plus an optional heartbeat so you're told if the watchdog itself stops running |
| **Scheduling** | cron by default, or a systemd timer (`--use-timer`) |
| **Hardware watchdog** | Optional (`--enable-hw-watchdog`): the SoC resets the Pi on a total kernel hang that cron can no longer detect |
| **Works with v6 / Docker / IPv6** | Web-UI check tolerates auth-gated and redirecting admin pages (Pi-hole v6); the FTL restart command is configurable for containerized Pi-hole; IPv6 is monitored alongside IPv4 |

## Requirements

- Raspberry Pi (or any Debian-based system) running Pi-hole
- Run as root / with `sudo`

## Install

```bash
git clone https://github.com/Alghofaily/pihole-watchdog.git
cd pihole-watchdog
sudo ./setup.sh
```

`setup.sh` handles everything in one command: sets executable permissions, runs the installer, and runs verification at the end so you immediately see a pass/fail report.

The installer (`install.sh`) will:
1. Install any missing dependencies (`dnsutils`, `iputils-ping`, `wireless-tools`, `iw`, `curl`, `logrotate`, `iproute2`)
2. Install the watchdog script to `/usr/local/bin/network-watchdog.sh`
3. Detect your WiFi interface and disable power management on it (skipped on Ethernet-only setups)
4. Add the watchdog cron job
5. Set up log rotation

Pass `--enable-hw-watchdog` to also turn on the SoC hardware watchdog (systemd `RuntimeWatchdogSec` + `dtparam=watchdog=on`), which recovers the Pi from a full kernel lock-up that the cron-based watchdog can't catch. It takes effect after one reboot:
```bash
sudo ./setup.sh --enable-hw-watchdog
```

Prefer a systemd timer over cron? Install with `--use-timer` (it installs
`network-watchdog.timer`/`.service` and removes the cron line):
```bash
sudo ./setup.sh --use-timer
```

It's idempotent — safe to re-run `setup.sh` any time you want to reinstall, update, or re-verify.

Prefer to run the steps individually? You still can:
```bash
chmod +x install.sh uninstall.sh verify.sh scripts/network-watchdog.sh
sudo ./install.sh
sudo ./verify.sh
```

## Uninstall

```bash
sudo ./uninstall.sh
```

Removes the cron jobs, the watchdog script, the WiFi power-save service, and log rotation config. Optionally deletes the log file too.

## Checking it's working

Quick spot-check:
```bash
# View scheduled jobs
sudo crontab -l

# Watch the watchdog in real time
tail -f /var/log/network-watchdog.log

# Confirm WiFi power management is off
iwconfig wlan0 | grep "Power Management"

# Confirm the systemd service is enabled
systemctl status wifi-powersave-off.service
```

For a full automated verification (pass/fail report across every component), run:
```bash
sudo ./verify.sh
```

## How the watchdog escalates

```
Every 10 minutes:
  1. Can we reach the gateway?
     No  -> restart networking, recheck
           still no -> reboot (if not in cooldown)
  2. Is FTL answering DNS (127.0.0.1) AND is the web UI up?
     No to either -> restart pihole-FTL, recheck
                    still no -> reboot (if not in cooldown)
  Otherwise -> log OK, exit

Alongside every run (alert-only, never reboots — each de-duplicated):
  - read-only rootfs / low disk / storage I/O errors -> notify (SD card failing)
  - low memory / high swap / OOM kill                -> notify (add swap / reduce load)
  - under-voltage / throttling / high temperature    -> notify (bad PSU / cooling)
  - blocking disabled / stale gravity                -> notify (Pi-hole not blocking)
  - clock not NTP-synced                             -> notify (DNSSEC/TLS at risk)
  - weak WiFi signal / DHCP down / IPv6 gw down      -> notify
  - upstream DNS dead but FTL up                      -> notify (internet/forwarders down)
```

The DNS step deliberately checks that **FTL is answering at all** (any DNS
response), not that a specific external name resolves — so a plain ISP/upstream
outage is reported as an alert instead of needlessly restarting FTL or rebooting.

Reboots are capped to once per 30 minutes. If the watchdog is still failing after a reboot and hits the cooldown again, it logs the failure instead of rebooting again — check `/var/log/network-watchdog.log` if you notice repeated failures, since that points to a deeper issue (bad SD card, failing power supply, etc.) rather than something this script can fix on its own.

## Configuration

Settings live in `/etc/network-watchdog.conf` — edit that file (not the script), and your changes survive reinstalls:

```bash
# Core
REBOOT_COOLDOWN=1800          # minimum seconds between reboots (default 1800 = 30 min)
TEST_DOMAIN="google.com"      # domain used for the DNS check
WEBUI_URL="http://localhost/admin"          # web-UI health check (2xx/3xx/401/403 = up)
FTL_RESTART_CMD="systemctl restart pihole-FTL"   # for Docker: "docker restart pihole"

# Alert de-duplication
ALERT_COOLDOWN=3600           # don't repeat the same alert within this many seconds

# Alert-only health checks (never reboot)
DISK_WARN_PCT=90              # warn when / usage reaches this percent
MEM_WARN_PCT=10               # warn when available RAM drops below this percent
SWAP_WARN_PCT=50              # warn when swap used exceeds this percent
TEMP_WARN_C=80               # warn above this CPU temperature (C)
RSSI_WARN_DBM=-75             # warn when WiFi signal is weaker than this
GRAVITY_MAX_AGE_DAYS=14       # warn when blocklists are older than this
ENABLE_MEM_CHECK=true
ENABLE_BLOCKING_CHECK=true
ENABLE_TIME_CHECK=true
ENABLE_IO_CHECK=true
ENABLE_DHCP_CHECK=true
ENABLE_IPV6_CHECK=true
ENABLE_UPSTREAM_CHECK=true    # detect "FTL up but upstream DNS dead"
ENABLE_UPSTREAM_RESTART=false # optionally restart a local resolver first...
UPSTREAM_RESTART_CMD="systemctl restart unbound"   # ...with this command

# Notifications (optional) - $MSG holds the message
NOTIFY_CMD='curl -s -d "$MSG" https://ntfy.sh/YOUR-TOPIC'

# Dead-man's switch (optional) - pinged after every healthy run
HEARTBEAT_URL='https://hc-ping.com/YOUR-UUID'
```

`NOTIFY_CMD` fires whenever the watchdog restarts something, reboots, or detects a problem it can't fix (read-only SD card, low disk/memory, throttling, blocking disabled, dead upstream, and the rest). Recurring alert-only conditions are de-duplicated: you're notified once, then again only after `ALERT_COOLDOWN`, plus a one-shot "resolved" message when the condition clears. `HEARTBEAT_URL` is pinged only on a completed healthy run — a reboot exits before the ping, so a monitor like healthchecks.io alerts you when the Pi (or the watchdog) goes quiet. See the config file for ntfy/Slack/email examples and every available option.

Edit your crontab (`sudo crontab -e`) to change the watchdog's schedule (default: every 10 minutes).

## Development

Every script is linted with [ShellCheck](https://www.shellcheck.net/) and the escalation logic is covered by a [bats](https://github.com/bats-core/bats-core) test suite (`tests/`), both run on every push via GitHub Actions. To run them locally:

```bash
shellcheck -s bash *.sh scripts/network-watchdog.sh
bats tests/
```

## Why this exists

Pi-hole running on a Pi Zero 2 W (or similar low-power boards) over WiFi is prone to a specific failure mode: the onboard WiFi chip's power-saving mode can cause the device to silently vanish from the network, requiring a physical power cycle to recover. This is often mistaken for SD card corruption or Pi-hole itself being unstable — in most cases it's neither. This repo addresses the actual root cause first, and layers monitoring on top in case something else goes wrong.

## License

MIT

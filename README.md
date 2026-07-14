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
1. Install any missing dependencies (`dnsutils`, `iputils-ping`, `wireless-tools`, `iw`, `curl`, `logrotate`)
2. Install the watchdog script to `/usr/local/bin/network-watchdog.sh`
3. Detect your WiFi interface and disable power management on it (skipped on Ethernet-only setups)
4. Add the watchdog cron job
5. Set up log rotation

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
  2. Can we resolve DNS via Pi-hole (127.0.0.1) AND reach the web UI?
     No to either -> restart pihole-FTL, recheck
                    still no -> reboot (if not in cooldown)
  Otherwise -> log OK, exit
```

Reboots are capped to once per 30 minutes. If the watchdog is still failing after a reboot and hits the cooldown again, it logs the failure instead of rebooting again — check `/var/log/network-watchdog.log` if you notice repeated failures, since that points to a deeper issue (bad SD card, failing power supply, etc.) rather than something this script can fix on its own.

## Configuration

Settings live in `/etc/network-watchdog.conf` — edit that file (not the script), and your changes survive reinstalls:

```bash
REBOOT_COOLDOWN=1800      # minimum seconds between reboots (default 1800 = 30 min)
TEST_DOMAIN="google.com"  # domain used for the DNS check
```

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

#!/bin/bash
# Pi-hole Watchdog - all-in-one setup
# https://github.com/Alghofaily/pihole-watchdog
#
# Runs chmod + install.sh + verify.sh in one go.
# Any options (e.g. --enable-hw-watchdog) are passed through to install.sh.
#
# Usage:
#   sudo ./setup.sh [--enable-hw-watchdog]

set -e

if [ "$EUID" -ne 0 ]; then
    echo "Please run as root: sudo ./setup.sh"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "=== Step 1: Setting permissions ==="
chmod +x install.sh uninstall.sh verify.sh scripts/network-watchdog.sh
echo "  Done"
echo

echo "=== Step 2: Running installer ==="
./install.sh "$@"
echo

echo "=== Step 3: Running verification ==="
./verify.sh

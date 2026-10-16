#!/bin/bash
# ---------------------------------------------------------------------------
# install.sh — one-command driver for all stages.
#
#   sudo ./install.sh
#
# It keeps a state file so you can simply re-run it after the (unavoidable)
# reboot. Stages:
#   1  prepare    (repo, backups, hosts, ifupdown2)
#   2  network    (bridge + rollback guard + reboot)
#   3  proxmox    (install + DietPi compatibility fixes + templates)
#   4  verify
#
#   sudo ./install.sh --smoke   # stage 4 with a live LXC smoke test
# ---------------------------------------------------------------------------
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=00-config.sh
. "$HERE/00-config.sh"

[ "$(id -u)" -eq 0 ] || { echo "run as root: sudo $0 $*" >&2; exit 1; }

mkdir -p "$WORKDIR"
STATE="$WORKDIR/.stage"
next=$(cat "$STATE" 2>/dev/null || echo 1)
SMOKE="${1:-}"

printf 'proxmox-dietpi-rpi4 installer\n'
printf '  next stage: %s\n' "$next"

case "$next" in
  1)
    "$HERE/01-prepare.sh"
    echo 2 > "$STATE"
    printf '\n--- stage 1 done ---\n'
    ;;

  2)
    # Record stage 3 *before* rebooting, so re-running after the reboot proceeds.
    echo 3 > "$STATE"
    printf '\nRebooting now. Reconnect, then run this script again (sudo ./install.sh).\n'
    "$HERE/02-network.sh"
    ;;

  3)
    "$HERE/03-install-proxmox.sh"
    echo 4 > "$STATE"
    printf '\nProxmox installed. Run once more for verification (sudo ./install.sh).\n'
    ;;

  4)
    "$HERE/04-verify.sh" "$SMOKE"
    ;;

  *)
    echo "unknown stage '$next' — resetting to 1"; echo 1 > "$STATE"; exit 1
    ;;
esac

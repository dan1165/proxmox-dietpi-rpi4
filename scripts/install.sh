#!/bin/bash
# ---------------------------------------------------------------------------
# install.sh — guided, resumable driver for all stages.
#
#   sudo ./install.sh            run the next stage (re-run after the reboot)
#   sudo ./install.sh --smoke    stage 4 with a live LXC smoke test
#   sudo ./install.sh --status   show the current stage and exit
#   sudo ./install.sh --reset    forget progress (does not undo anything)
#
# Every stage enforces the three-gate apply protocol itself, so this driver
# only has to sequence stages and survive the mid-install reboot.
# ---------------------------------------------------------------------------
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"
# shellcheck source=00-config.sh
[ -f "$HERE/00-config.sh" ] && . "$HERE/00-config.sh"

WORKDIR="${WORKDIR:-/root/proxmox-setup}"
LOG_FILE="$WORKDIR/install.log"

SMOKE=""; RESET=0; SHOW=0
for a in "$@"; do
  case "$a" in
    --smoke)  SMOKE=--smoke ;;
    --reset)  RESET=1 ;;
    --status) SHOW=1 ;;
    --yes|-y) ASSUME_YES=1 ;;
    --force)  FORCE=1 ;;
  esac
done
export ASSUME_YES="${ASSUME_YES:-0}" FORCE="${FORCE:-0}"

require_root
if [ "$RESET" = 1 ]; then
  rm -f "$(state_file)"
  ok "progress reset (nothing was undone)"
  exit 0
fi

stage=$(state_get 1)
if [ "$SHOW" = 1 ]; then
  printf 'stage %s of 4\n' "$stage"
  exit 0
fi

printf '\n%sproxmox-dietpi-rpi4%s  v%s\n' "$C_BOLD$C_CYAN" "$C_RESET" "$PVE_RPI_VERSION"
printf '  host    %s (%s)\n' "$(hostname)" "$(hostname -I 2>/dev/null | awk '{print $1}')"
printf '  target  %s → %s   %s via %s\n' "$NIC" "$BRIDGE" "$PI_IP" "$PI_GATEWAY"
printf '  stage   %s of 4\n' "$stage"

case "$stage" in
  1)
    "$HERE/01-prepare.sh" || exit 1
    printf '\nNext: %ssudo %s/02-network.sh%s   (reboots; reconnect afterwards)\n\n' "$C_BOLD" "$HERE" "$C_RESET"
    ;;

  2)
    "$HERE/02-network.sh"
    # 02 only returns if it aborted; a successful run reboots the box.
    ;;

  3)
    "$HERE/03-install-proxmox.sh" || exit 1
    printf '\nNext: %ssudo %s/04-verify.sh%s\n\n' "$C_BOLD" "$HERE" "$C_RESET"
    ;;

  4)
    "$HERE/04-verify.sh" $SMOKE
    ;;

  *)
    warn "unknown stage '$stage' — resetting to 1"
    echo 1 > "$(state_file)"
    exit 1
    ;;
esac

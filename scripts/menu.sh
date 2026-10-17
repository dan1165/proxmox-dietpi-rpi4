#!/bin/bash
# ---------------------------------------------------------------------------
# menu.sh — interactive TUI for the whole project.
#
#   sudo ./menu.sh                    arrow-key menu
#   sudo ./menu.sh --action status    run one action non-interactively
#
# Actions: install | preflight | verify | status | repair | tailscale |
#          rollback | help
# ---------------------------------------------------------------------------
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"
# shellcheck source=00-config.sh
[ -f "$HERE/00-config.sh" ] && . "$HERE/00-config.sh"

# parse --action / --yes / --force
ACTION=""
while [ $# -gt 0 ]; do
  case "$1" in
    --action) ACTION="${2:-}"; shift 2 ;;
    --action=*) ACTION="${1#*=}"; shift ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    --force) FORCE=1; shift ;;
    --help|-h) ACTION=help; shift ;;
    *) shift ;;
  esac
done
export ASSUME_YES="${ASSUME_YES:-0}" FORCE="${FORCE:-0}"

pause() {
  [ -t 0 ] || return 0
  printf '\n%sPress Enter to return to the menu…%s' "$C_DIM" "$C_RESET"
  read -r _ || true
}

run_action() {
  case "$1" in
    auto)      "$HERE/autoinstall.sh" ;;
    install)   "$HERE/install.sh" ;;
    preflight) "$HERE/preflight.sh" ;;
    verify)    "$HERE/04-verify.sh" --triple ;;
    config)    "$HERE/config.sh" ;;
    status)    "$HERE/status.sh" ;;
    heal)      heal_menu ;;
    repair)    "$HERE/repair.sh" ;;
    tailscale) "$HERE/tailscale.sh" ;;
    rollback)  "$HERE/rollback.sh" ;;
    help)      show_help ;;
    *)         err "unknown action: $1"; return 1 ;;
  esac
}

# Repair / auto-heal submenu
heal_menu() {
  local timer
  timer=$(systemctl is-enabled pve-pi-heal.timer 2>/dev/null || echo "not installed")
  while :; do
    header=$(printf '  %sRepair / auto-heal%s\n  %sauto-heal timer: %s%s\n' \
      "$C_BOLD$C_CYAN" "$C_RESET" "$C_DIM" "$timer" "$C_RESET")
    if tui_menu "$header" \
        "Heal now (apply every fix — safe, idempotent)" \
        "Check only (change nothing)" \
        "Install the auto-heal timer (boot + hourly)" \
        "Remove the auto-heal timer" \
        "Back"; then
      case "$TUI_CHOICE" in
        1) "$HERE/heal.sh" ;;
        2) "$HERE/heal.sh" --check ;;
        3) "$HERE/heal.sh" --install-timer ;;
        4) "$HERE/heal.sh" --uninstall-timer ;;
        5) return 0 ;;
      esac
      timer=$(systemctl is-enabled pve-pi-heal.timer 2>/dev/null || echo "not installed")
      pause
      [ -t 0 ] && clear 2>/dev/null || true
    else
      return 0
    fi
  done
}

show_help() {
  cat <<EOF

${C_BOLD}proxmox-dietpi-rpi4 — help${C_RESET}

  ${C_BOLD}Safety model (three-gate apply protocol)${C_RESET}
    Gate 1  preflight   automated safety checks must pass (read-only)
    Gate 2  confirm     you type an exact phrase before anything changes
    Gate 3  verify      every applied change is verified by 3 independent checks

  ${C_BOLD}Menu actions${C_RESET}
    1 auto         unattended install; survives the reboot, then installs the
                   hourly auto-heal timer
    2 install      guided install / resume (gated; re-run after the reboot)
    3 preflight    read-only safety checks; nothing is modified
    4 verify       full verification, 3 independent passes
    5 config       view / edit configuration (writes 00-config.local.sh)
    6 heal         repair / auto-heal (now, check, add/remove the timer)
    7 tailscale    install/configure the Tailscale subnet router
    8 rollback     triple-confirmed revert (optionally purge Proxmox)
    9 help         this text            ·  q quits

  ${C_BOLD}Non-interactive${C_RESET}
    sudo ./autoinstall.sh                   # fully unattended, reboots once
    sudo ./autoinstall.sh --status           # progress
    sudo ./heal.sh                           # heal now
    sudo ./heal.sh --check                   # report only
    sudo ./heal.sh --install-timer           # hourly self-heal
    sudo ./menu.sh --action verify
    sudo ./config.sh --show                  # effective configuration
    sudo ./install.sh                        # gated stages 1-4

  ${C_BOLD}Keys${C_RESET}   ↑/↓ or k/j move · Enter select · 1-9 jump · q quit

  ${C_BOLD}Docs${C_RESET}   README.md · docs/safety.md · docs/troubleshooting.md

EOF
}

# one-shot mode
if [ -n "$ACTION" ]; then
  run_action "$ACTION"
  exit $?
fi

# ---- interactive loop ------------------------------------------------------
[ -t 0 ] && clear 2>/dev/null || true
while :; do
  header=$("$HERE/status.sh" --brief 2>/dev/null)
  header="$header
  ${C_DIM}docs: README.md · docs/safety.md${C_RESET}"
  if tui_menu "$header" \
      "Auto install (unattended, survives reboot)" \
      "Install / finish setup (guided)" \
      "Preflight safety checks (read-only)" \
      "Verify installation (3× independent)" \
      "Edit configuration" \
      "Repair / auto-heal" \
      "Tailscale subnet router" \
      "Rollback / uninstall" \
      "Help"; then
    case "$TUI_CHOICE" in
      1) run_action auto ;;
      2) run_action install ;;
      3) run_action preflight ;;
      4) run_action verify ;;
      5) run_action config ;;
      6) run_action heal ;;
      7) run_action tailscale ;;
      8) run_action rollback ;;
      9) run_action help ;;
    esac
    pause
    [ -t 0 ] && clear 2>/dev/null || true
  else
    printf '\n%sbye.%s\n' "$C_DIM" "$C_RESET"
    exit 0
  fi
done

#!/bin/bash
# ---------------------------------------------------------------------------
# rollback.sh — revert the changes this project made.
#
# Triple-confirmed, because it touches networking and can lock you out:
#   1) explicit yes/no          2) typed phrase          3) abortable countdown
#
#   ./rollback.sh                 restore network + hosts only
#   ./rollback.sh --purge         also remove Proxmox packages
#   ./rollback.sh --list          show what would be restored (changes nothing)
# ---------------------------------------------------------------------------
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"
# shellcheck source=00-config.sh
[ -f "$HERE/00-config.sh" ] && . "$HERE/00-config.sh"
require_root

BK="$WORKDIR/backup"
DO_PURGE=0
for a in "$@"; do
  case "$a" in
    --purge) DO_PURGE=1 ;;
    --list)  LIST=1 ;;
  esac
done

say "Rollback — current backups"
if [ ! -d "$BK" ]; then
  die "no backups found at $BK — nothing to roll back (was this project ever run?)"
fi
ls -la "$BK" | sed 's/^/  /'
[ -d "$WORKDIR/disabled" ] && printf '  disabled drop-ins:\n' && ls -la "$WORKDIR/disabled" | sed 's/^/    /'

if [ "${LIST:-0}" = 1 ]; then
  printf '\n%s--list requested — no changes made.%s\n' "$C_DIM" "$C_RESET"
  exit 0
fi

printf '\n%sThis will:%s\n' "$C_BOLD" "$C_RESET"
printf '  • restore /etc/network/interfaces and interfaces.d/ from backup\n'
printf '  • restore /etc/hosts from backup\n'
printf '  • disable the rollback guard\n'
[ "$DO_PURGE" = 1 ] && printf '  • %sREMOVE%s Proxmox packages (proxmox-ve, pve-*, proxmox-*)\n' "$C_RED$C_BOLD" "$C_RESET"

# ---- triple confirmation ---------------------------------------------------
printf '\n'
confirm_yes "Continue with rollback?" || { info "cancelled"; exit 0; }
confirm_phrase "RESTORE-NETWORK" "Type RESTORE-NETWORK to confirm" || { warn "aborted"; exit 1; }
if [ "$DO_PURGE" = 1 ]; then
  confirm_phrase "PURGE-PROXMOX" "Type PURGE-PROXMOX to confirm package removal" || { warn "aborted"; exit 1; }
fi
countdown_abort 10 "Applying rollback" || { warn "aborted by operator"; exit 1; }

# ---- apply -----------------------------------------------------------------
say "Restoring network configuration"
backup_file /etc/network/interfaces "pre-rollback"
[ -f "$BK/interfaces" ] && cp -a "$BK/interfaces" /etc/network/interfaces && ok "restored /etc/network/interfaces"
if [ -d "$BK/interfaces.d" ]; then
  rm -rf /etc/network/interfaces.d
  cp -a "$BK/interfaces.d" /etc/network/interfaces.d
  ok "restored /etc/network/interfaces.d"
fi

say "Restoring /etc/hosts"
backup_file /etc/hosts "pre-rollback"
[ -f "$BK/hosts" ] && cp -a "$BK/hosts" /etc/hosts && ok "restored /etc/hosts"

say "Disabling guards"
systemctl disable net-guard.service >/dev/null 2>&1 && ok "net-guard disabled" || step "net-guard not present"

if [ "$DO_PURGE" = 1 ]; then
  say "Removing Proxmox packages"
  DEBIAN_FRONTEND=noninteractive apt-get remove --purge -y proxmox-ve pve-manager 'pve-*' 'proxmox-*' 2>&1 | tail -5 || warn "package removal reported errors"
  DEBIAN_FRONTEND=noninteractive apt-get autoremove --purge -y 2>&1 | tail -3 || true
  ok "packages removed"
fi

# ---- gate 3: independent triple verification -------------------------------
gate_triple "rollback" \
  "interfaces file matches backup::cmp -s /etc/network/interfaces '$BK/interfaces'" \
  "hosts file matches backup::cmp -s /etc/hosts '$BK/hosts'" \
  "rollback guard is not enabled::! systemctl is-enabled --quiet net-guard.service"

printf '\n%sRollback complete.%s Reboot to apply the restored network config:\n' "$C_BOLD$C_GREEN" "$C_RESET"
printf '    sync && systemctl reboot\n\n'

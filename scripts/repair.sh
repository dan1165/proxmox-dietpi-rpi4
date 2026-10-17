#!/bin/bash
# ---------------------------------------------------------------------------
# repair.sh — re-apply every known fix, idempotently. Safe to run any time.
#
#   ./repair.sh                  apply all fixes, then triple-verify
#   ./repair.sh --check          report the state of each fix, change nothing
#   ./repair.sh --quiet          terse output
#   ./repair.sh --with-network   also attempt `ifup $BRIDGE` if it is down
#   ./repair.sh --install-timer  install the hourly auto-heal timer
#
# The fixes themselves live in lib/fixes.sh, shared with heal.sh, stage 1 and
# stage 3, so there is exactly one implementation of each.
# ---------------------------------------------------------------------------
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"
# shellcheck source=00-config.sh
[ -f "$HERE/00-config.sh" ] && . "$HERE/00-config.sh"

WORKDIR="${WORKDIR:-/root/proxmox-setup}"
LOG_FILE="$WORKDIR/repair.log"

CHECK=0; QUIET=0; WITH_NETWORK=0
for a in "$@"; do
  case "$a" in
    --check|-c)        CHECK=1 ;;
    --quiet|-q)        QUIET=1; QUIET_MODE=1 ;;
    --with-network)    WITH_NETWORK=1 ;;
    --install-timer)   exec "$HERE/heal.sh" --install-timer ;;
    --help|-h)         sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  esac
done
export QUIET_MODE

if [ "$CHECK" = 1 ]; then
  export NO_INSTALL_DEPS=1
  exec "$HERE/heal.sh" --check
fi

require_root
[ "$QUIET" = 1 ] || { say "Repairing known DietPi/Pi/Proxmox issues"; }

# dependencies first — a missing tool is itself a problem to repair
if wait_for_network 30 2>/dev/null; then
  ensure_deps --quiet || warn "dependency check incomplete"
else
  warn "no network — skipping the dependency check"
fi

fix_all $([ "$WITH_NETWORK" = 1 ] && echo --with-network)

if [ "$FIX_CHANGED" = 0 ]; then
  ok "nothing needed repairing"
else
  ok "$FIX_CHANGED item(s) repaired"
fi
[ "$FIX_WARNINGS" -gt 0 ] && warn "$FIX_WARNINGS warning(s) above"

# ---- gate 3: independent triple verification -------------------------------
if pve_installed; then
  gate_triple "repair" \
    "iptables uses the nft backend::iptables -V | grep -q nf_tables" \
    "pve-firewall reports no errors::[ \"\$(journalctl -u pve-firewall -b --no-pager 2>/dev/null | grep -ci error)\" = 0 ]" \
    "core PVE services active::systemctl is-active --quiet pve-cluster pvedaemon pveproxy pvestatd" \
    "memory cgroups active or queued::grep -qw memory /sys/fs/cgroup/cgroup.controllers 2>/dev/null || grep -qw cgroup_enable=memory /boot/firmware/cmdline.txt 2>/dev/null"
fi
exit 0

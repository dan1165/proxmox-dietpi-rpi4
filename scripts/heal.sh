#!/bin/bash
# ---------------------------------------------------------------------------
# heal.sh — self-healing. Re-applies every known fix, restarts dead services,
# and can install a timer so it happens automatically.
#
#   ./heal.sh                  heal now (safe, idempotent, non-interactive)
#   ./heal.sh --check          report the state of each fix, change nothing
#   ./heal.sh --quiet          terse output (this is what the timer uses)
#   ./heal.sh --with-network   also attempt `ifup $BRIDGE` if it is down
#   ./heal.sh --install-timer  install + start the periodic auto-heal timer
#   ./heal.sh --uninstall-timer
#   ./heal.sh --timer-status
#
# Networking is deliberately NOT touched by default: a timer that rewrites the
# network could drop your SSH session. Use --with-network to opt in.
# ---------------------------------------------------------------------------
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"
# shellcheck source=00-config.sh
[ -f "$HERE/00-config.sh" ] && . "$HERE/00-config.sh"

WORKDIR="${WORKDIR:-/root/proxmox-setup}"
LOG_FILE="$WORKDIR/heal.log"
SNAPSHOT="$WORKDIR/scripts"
WITH_NETWORK=0; QUIET=0; MODE="heal"

while [ $# -gt 0 ]; do
  case "$1" in
    --check|-c)          MODE="check" ;;
    --quiet|-q)          QUIET=1; QUIET_MODE=1 ;;
    --with-network)      WITH_NETWORK=1 ;;
    --install-timer)     MODE="install-timer" ;;
    --uninstall-timer)   MODE="uninstall-timer" ;;
    --timer-status)      MODE="timer-status" ;;
    --help|-h)           sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)                   die "unknown option: $1 (try --help)" ;;
  esac
  shift
done
export QUIET_MODE

# ---- state report (read-only) ---------------------------------------------
heal_status() {
  local problems=0
  printf '\n%sSelf-heal status%s\n' "$C_BOLD$C_CYAN" "$C_RESET"; hr
  _s() { # _s <label> <ok|bad> [detail]
    local tag color
    if [ "$2" = ok ]; then tag="[ OK ]"; color="$C_GREEN"
    else tag="[ -- ]"; color="$C_RED"; problems=$((problems+1)); fi
    if [ -n "${3:-}" ]; then printf '  %s%s%s %-34s %s\n' "$color" "$tag" "$C_RESET" "$1" "$3"
    else printf '  %s%s%s %s\n' "$color" "$tag" "$C_RESET" "$1"; fi
  }
  [ "$(update-alternatives --query iptables 2>/dev/null | awk '/^Value:/{print $2}')" = "/usr/sbin/iptables-nft" ] \
    && _s "iptables backend is nft" ok || _s "iptables backend is nft" bad "$(iptables -V 2>/dev/null)"
  [ -f /etc/systemd/system/pve-firewall.service.d/10-pi-nft.conf ] \
    && _s "pve-firewall legacy override cleared" ok || _s "pve-firewall legacy override cleared" bad
  [ -f /etc/apt/apt.conf.d/99pve-pi-fix ] \
    && _s "apt post-invoke hook present" ok || _s "apt post-invoke hook present" bad
  grep -qw memory /sys/fs/cgroup/cgroup.controllers 2>/dev/null \
    && _s "memory cgroup controller active" ok || _s "memory cgroup controller active" bad "container limits unenforced"
  [ "$(systemctl is-enabled systemd-logind 2>&1)" != masked ] \
    && _s "systemd-logind unmasked" ok || _s "systemd-logind unmasked" bad
  [ ! -f /etc/apt/sources.list.d/pxvirt-sources.list ] \
    && _s "bookworm apt source disabled" ok || _s "bookworm apt source disabled" bad
  { [ ! -f /usr/share/perl5/PVE/APLInfo.pm ] || ! grep -q mirrors.lierfang.com /usr/share/perl5/PVE/APLInfo.pm; } \
    && _s "PVE::APLInfo patched" ok || _s "PVE::APLInfo patched" bad
  if have tailscale; then
    [ -f /etc/systemd/system/tailscaled.service.d/10-after-networking.conf ] \
      && _s "tailscaled boot ordering" ok || _s "tailscaled boot ordering" bad
  fi
  local bad=0 s
  for s in pve-cluster pvedaemon pveproxy pvestatd; do
    systemctl is-enabled --quiet "$s" 2>/dev/null || continue
    systemctl is-active --quiet "$s" || bad=$((bad+1))
  done
  [ "$bad" = 0 ] && _s "core PVE services running" ok || _s "core PVE services running" bad "$bad down"
  if [ -n "${PI_IP:-}" ] && ip -br addr show "${BRIDGE:-vmbr0}" 2>/dev/null | grep -q "$PI_IP"; then
    _s "bridge ${BRIDGE:-vmbr0} has $PI_IP" ok
  else
    _s "bridge ${BRIDGE:-vmbr0} has ${PI_IP:-?}" bad
  fi
  hr
  if [ "$problems" = 0 ]; then ok "everything is healthy"; else warn "$problems item(s) need healing — run: $0"; fi
  return "$problems"
}

# ---- timer -----------------------------------------------------------------
install_timer() {
  require_root
  say "Installing the auto-heal timer"
  mkdir -p "$SNAPSHOT"
  cp -a "$HERE/." "$SNAPSHOT/" 2>/dev/null || die "could not snapshot scripts to $SNAPSHOT"
  step "scripts snapshot -> $SNAPSHOT"

  atomic_write /etc/systemd/system/pve-pi-heal.service <<UNIT
[Unit]
Description=Proxmox-on-Pi self-heal (re-apply compatibility fixes)
After=network-online.target pve-cluster.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$SNAPSHOT/heal.sh --quiet
UNIT

  atomic_write /etc/systemd/system/pve-pi-heal.timer <<'UNIT'
[Unit]
Description=Run the Proxmox-on-Pi self-heal periodically

[Timer]
OnBootSec=3min
OnUnitActiveSec=1h
Persistent=true
Unit=pve-pi-heal.service

[Install]
WantedBy=timers.target
UNIT

  systemctl daemon-reload
  systemctl enable --now pve-pi-heal.timer >/dev/null 2>&1
  ok "auto-heal timer installed (on boot + hourly)"
  systemctl list-timers pve-pi-heal.timer --no-pager 2>/dev/null | head -3
}

uninstall_timer() {
  require_root
  systemctl disable --now pve-pi-heal.timer >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/pve-pi-heal.timer /etc/systemd/system/pve-pi-heal.service
  systemctl daemon-reload
  ok "auto-heal timer removed (the scripts snapshot in $SNAPSHOT was kept)"
}

timer_status() {
  if systemctl list-unit-files pve-pi-heal.timer >/dev/null 2>&1 \
     && systemctl is-enabled --quiet pve-pi-heal.timer 2>/dev/null; then
    ok "auto-heal timer is enabled"
    systemctl list-timers pve-pi-heal.timer --no-pager 2>/dev/null | head -3
  else
    warn "auto-heal timer is not installed (add it with: $0 --install-timer)"
  fi
}

# ---- main ------------------------------------------------------------------
case "$MODE" in
  check)          heal_status ;;
  timer-status)   timer_status ;;
  install-timer)  install_timer ;;
  uninstall-timer) uninstall_timer ;;
  heal)
    require_root
    _msg "=== heal run $(date -Is) ==="
    [ "$QUIET" = 1 ] || { printf '\n%sSelf-heal%s  (%s)\n' "$C_BOLD$C_CYAN" "$C_RESET" "$(date -Is)"; hr; }

    # dependencies first — a missing tool is itself something to heal
    if wait_for_network 30 2>/dev/null; then
      ensure_deps --quiet || warn "dependency check incomplete"
    else
      warn "no network — skipping the dependency check"
    fi

    fix_all $([ "$WITH_NETWORK" = 1 ] && echo --with-network)

    _msg "heal run finished: healed=$FIX_CHANGED warnings=$FIX_WARNINGS"

    if [ "$QUIET" != 1 ]; then
      hr
      if [ "$FIX_CHANGED" = 0 ]; then ok "nothing needed healing"
      else ok "$FIX_CHANGED item(s) healed"; fi
      [ "$FIX_WARNINGS" -gt 0 ] && warn "$FIX_WARNINGS warning(s) — see above"
    fi
    exit 0
    ;;
esac

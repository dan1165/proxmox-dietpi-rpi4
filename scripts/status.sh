#!/bin/bash
# ---------------------------------------------------------------------------
# status.sh — read-only overview of host, network, Proxmox and Tailscale.
#   ./status.sh           full report
#   ./status.sh --brief    compact header for the menu
# ---------------------------------------------------------------------------
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"
# shellcheck source=00-config.sh
[ -f "$HERE/00-config.sh" ] && . "$HERE/00-config.sh"

BRIEF=0
[ "${1:-}" = "--brief" ] && BRIEF=1

stage=$(state_get 1)
stage_note=""
# For display: if there is no recorded progress but Proxmox is already
# installed, the remaining useful stage is verification.
if [ ! -s "$(state_file)" ] && pve_installed; then stage=4; stage_note=" (inferred)"; fi
if pve_installed; then pve="installed $(pveversion 2>/dev/null | head -1 | cut -d/ -f2 | cut -d' ' -f1)"; else pve="not installed"; fi
bridge_state="absent"
if bridge_exists "$BRIDGE"; then
  if ip -br addr show "$BRIDGE" 2>/dev/null | grep -q "$PI_IP"; then bridge_state="up ($PI_IP)"; else bridge_state="present"; fi
fi
ts_state="absent"
if have tailscale; then
  ts_state=$(tailscale status --json 2>/dev/null | python3 -c 'import sys,json;print(json.load(sys.stdin).get("BackendState","?"))' 2>/dev/null || echo "?")
  ts_state="present ($ts_state)"
fi

if [ "$BRIEF" = 1 ]; then
  printf '  %sproxmox-dietpi-rpi4%s  v%s\n' "$C_BOLD" "$C_RESET" "$PVE_RPI_VERSION"
  hr
  printf '  host    %s   %s\n' "$(hostname)" "$(hostname -I 2>/dev/null | awk '{print $1}')"
  printf '  net     %s → %s   %s\n' "$NIC" "$BRIDGE" "$bridge_state"
  printf '  proxmox %s\n' "$pve"
  printf '  tailsc. %s\n' "$ts_state"
  printf '  stage   %s of 4%s\n' "$stage" "$stage_note"
  hr
  exit 0
fi

printf '\n%sHost%s\n' "$C_BOLD$C_CYAN" "$C_RESET"
printf '  hostname    %s\n' "$(hostname)"
printf '  ip          %s\n' "$(hostname -I 2>/dev/null | awk '{print $1}')"
printf '  uptime      %s\n' "$(uptime -p 2>/dev/null || uptime)"
printf '  kernel      %s\n' "$(uname -r)"
printf '  os          %s\n' "$( . /etc/os-release && echo "${PRETTY_NAME:-?}" )"
printf '  dietpi      %s\n' "$(is_dietpi && echo yes || echo no)"

printf '\n%sNetwork%s\n' "$C_BOLD$C_CYAN" "$C_RESET"
ip -br addr 2>/dev/null | grep -vE '^lo' | sed 's/^/  /'
ip route 2>/dev/null | grep default | sed 's/^/  default: /'
printf '  ip_forward  %s\n' "$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)"
printf '  bridge      %s\n' "$bridge_state"

printf '\n%sProxmox%s\n' "$C_BOLD$C_CYAN" "$C_RESET"
printf '  installed   %s\n' "$pve"
if pve_installed; then
  printf '  version     %s\n' "$(pveversion 2>/dev/null | head -1)"
  for s in pve-cluster pvedaemon pveproxy pvestatd pvescheduler pve-firewall; do
    printf '  %-11s %s\n' "$s" "$(systemctl is-active "$s" 2>/dev/null)"
  done
  printf '  web ui      %s\n' "$(curl -sk -o /dev/null -w 'HTTP %{http_code}' https://localhost:8006 2>/dev/null || echo 'unreachable')"
  printf '  guests      %s CT / %s VM\n' \
    "$(pct list 2>/dev/null | tail -n +2 | wc -l)" "$(qm list 2>/dev/null | tail -n +2 | wc -l)"
  printf '  storage     %s\n' "$(pvesm status 2>/dev/null | awk 'NR==2{print $1" ("$2") "$3}')"
fi
printf '  iptables    %s\n' "$(iptables -V 2>/dev/null | sed 's/^iptables //')"

printf '\n%sTailscale%s\n' "$C_BOLD$C_CYAN" "$C_RESET"
if have tailscale; then
  printf '  backend     %s\n' "$ts_state"
  printf '  ip          %s\n' "$(tailscale ip -4 2>/dev/null)"
  printf '  advertised  %s\n' "$(tailscale debug netmap 2>/dev/null | python3 -c 'import sys,json;print((json.load(sys.stdin).get("SelfNode",{}).get("Hostinfo") or {}).get("RoutableIPs"))' 2>/dev/null)"
  printf '  approved    %s\n' "$(tailscale debug netmap 2>/dev/null | python3 -c '
import sys,json
d=json.load(sys.stdin); sn=d.get("SelfNode") or {}
a=[x for x in (sn.get("AllowedIPs") or []) if not x.startswith(("100.","fd7a"))]
print(a or "(none)")' 2>/dev/null)"
else
  printf '  not installed\n'
fi

printf '\n%sInstall state%s\n' "$C_BOLD$C_CYAN" "$C_RESET"
printf '  stage       %s of 4%s\n' "$stage" "$stage_note"
printf '  workdir     %s\n' "${WORKDIR:-/root/proxmox-setup}"
[ -d "${WORKDIR:-/root/proxmox-setup}/backup" ] && printf '  backups     present\n' || printf '  backups     none yet\n'
printf '  net-guard   %s\n' "$(ng=$(systemctl is-enabled net-guard.service 2>/dev/null || true); [ -n "$ng" ] && echo "$ng" || echo 'not installed')"

printf '\n%sHealth%s\n' "$C_BOLD$C_CYAN" "$C_RESET"
printf '  failed units %s\n' "$(systemctl --failed --no-legend 2>/dev/null | wc -l)"
printf '  mem cgroup   %s\n' "$(grep -qw memory /sys/fs/cgroup/cgroup.controllers 2>/dev/null && echo active || echo 'MISSING — container memory limits unenforced (run cgroup-fix.sh)')"
if pve_installed; then
  printf '  fw errors    %s (this boot)\n' "$(journalctl -u pve-firewall -b --no-pager 2>/dev/null | grep -ci error)"
fi
printf '\n'

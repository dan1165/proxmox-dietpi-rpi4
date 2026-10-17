#!/bin/bash
# ---------------------------------------------------------------------------
# preflight.sh — read-only safety checks. Nothing is modified.
#
#   ./preflight.sh            full report
#   ./preflight.sh --quiet    only warnings/failures + summary (used as gate 1)
#   ./preflight.sh --strict   treat warnings as failures
#
# Exit: 0 = safe to proceed, 1 = a blocker was found.
# ---------------------------------------------------------------------------
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"
# shellcheck source=00-config.sh
[ -f "$HERE/00-config.sh" ] && . "$HERE/00-config.sh"

QUIET=0; STRICT=0
for a in "$@"; do
  case "$a" in
    --quiet|-q) QUIET=1 ;;
    --strict)   STRICT=1 ;;
  esac
done

PASS=0; WARN=0; FAIL=0
_p() { PASS=$((PASS+1)); [ "$QUIET" = 1 ] || ok "$1"; }
_w() { WARN=$((WARN+1)); warn "$1${2:+ — $2}"; }
_f() { FAIL=$((FAIL+1)); err "$1${2:+ — $2}"; }

# run_chk <hard|soft> <desc> <cmd...>
run_chk() {
  local mode="$1" desc="$2"; shift 2
  if "$@" >/dev/null 2>&1; then _p "$desc"; else
    [ "$mode" = hard ] && _f "$desc" || _w "$desc"
  fi
}

[ "$QUIET" = 1 ] || { printf '\n%sPreflight safety checks%s\n' "$C_BOLD$C_CYAN" "$C_RESET"; hr; }
[ "$QUIET" = 1 ] || printf '%sHost%s   %s  %s\n' "$C_DIM" "$C_RESET" "$(hostname)" "$(hostname -I 2>/dev/null | awk '{print $1}')"
[ "$QUIET" = 1 ] || printf '%sTarget%s %s -> %s   %s -> %s\n\n' "$C_DIM" "$C_RESET" "$NIC" "$BRIDGE" "$PI_IP" "$PI_GATEWAY"

# ---- 1. preconditions -----------------------------------------------------
run_chk hard "running as root" [ "$(id -u)" -eq 0 ]
run_chk hard "systemd is PID 1" bash -c '[ "$(ps -p 1 -o comm= 2>/dev/null)" = systemd ]'
run_chk hard "architecture is arm64" bash -c '[ "$(dpkg --print-architecture)" = arm64 ]'
run_chk hard "OS is Debian (bookworm/trixie)" bash -c '
  . /etc/os-release
  [ "${ID:-}" = debian ] && case "${VERSION_CODENAME:-}" in bookworm|trixie) true;; *) false;; esac'
is_dietpi && _p "DietPi detected" || _w "DietPi not detected" "this guide targets DietPi; other Debian images work but are untested"
case "$(uname -r)" in *rpt-rpi*|*rpi*) _p "Raspberry Pi kernel ($(uname -r))";; *) _w "kernel is not an RPi kernel" "$(uname -r) — Proxmox expects the Raspberry Pi kernel";; esac

# ---- 2. don't lock yourself out -------------------------------------------
systemctl is-active --quiet ssh 2>/dev/null || systemctl is-active --quiet sshd 2>/dev/null \
  && _p "SSH server is running" || _w "no SSH server active" "you are on a headless box — verify console access before rebooting"
if [ "$QUIET" != 1 ] && [ -t 0 ] && [ -z "${SKIP_PARACHUTE:-}" ]; then
  if confirm_yes "Do you have a fallback (monitor+keyboard, serial console, or another SD card) if networking fails?"; then
    _p "recovery method confirmed by operator"
  else
    _w "no recovery method confirmed" "a bad bridge config would need physical access"
  fi
fi

# ---- 3. resources ---------------------------------------------------------
MEM_MB=$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo)
[ "${MEM_MB:-0}" -ge 1800 ] && _p "RAM ${MEM_MB} MB" || _w "low RAM (${MEM_MB} MB)" "containers will be tight below 2 GB"
FREE_MB=$(df -Pm / | awk 'NR==2{print $4}')
[ "${FREE_MB:-0}" -ge 5000 ] && _p "free space on / (${FREE_MB} MB)" || _w "low free space on / (${FREE_MB} MB)" "Proxmox + templates want ~5 GB"
CORES=$(nproc 2>/dev/null || echo 1)
[ "${CORES:-0}" -ge 4 ] && _p "${CORES} CPU cores" || _w "only ${CORES} CPU core(s)"

# ---- 4. network interface -------------------------------------------------
run_chk hard "interface '$NIC' exists" test -d "/sys/class/net/$NIC"
case "$NIC" in
  wl*|wlan*) _f "interface '$NIC' looks wireless" "bridging Wi-Fi is not supported — use Ethernet" ;;
  *) [ -d "/sys/class/net/$NIC" ] && _p "interface '$NIC' is not wireless" ;;
esac
if [ -r "/sys/class/net/$NIC/carrier" ]; then
  [ "$(cat "/sys/class/net/$NIC/carrier" 2>/dev/null)" = 1 ] && _p "'$NIC' has link (carrier up)" \
    || _w "'$NIC' has no carrier" "cable unplugged or switch port down"
fi

# ---- 5. connectivity ------------------------------------------------------
run_chk hard "gateway '$PI_GATEWAY' responds to ping" ping -c2 -W3 "$PI_GATEWAY"
run_chk hard "internet reachable (deb.debian.org)" bash -c 'curl -fsS --max-time 12 -o /dev/null http://deb.debian.org/debian/dists/stable/Release'
run_chk hard "DNS resolution works" bash -c 'getent hosts deb.debian.org >/dev/null'
run_chk hard "PXVirt mirror reachable" bash -c 'curl -fsS --max-time 15 -o /dev/null https://mirrors.lierfang.com/pxcloud/lierfang.gpg'
run_chk hard "tailscale.com reachable (optional component)" bash -c 'curl -fsS --max-time 12 -o /dev/null https://tailscale.com/install.sh' || true

CUR_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
if [ "$CUR_IP" = "$PI_IP" ]; then _p "running IP matches configured ${PI_IP}"
else _w "configured IP ${PI_IP} != current ${CUR_IP:-none}" "set PI_IP in 00-config.sh, or accept the change"; fi

# ---- 6. conflicting network managers --------------------------------------
for svc in NetworkManager systemd-networkd dhcpcd; do
  if systemctl is-active --quiet "$svc" 2>/dev/null; then
    _w "$svc is active" "Proxmox expects to own the network; the guide disables/masks it where present"
  else
    _p "$svc not active"
  fi
done
if [ -f /etc/cloud/cloud.cfg ] && grep -qE '^\s*-\s*update_etc_hosts' /etc/cloud/cloud.cfg 2>/dev/null; then
  _w "cloud-init will rewrite /etc/hosts" "comment out 'update_etc_hosts' in /etc/cloud/cloud.cfg"
else
  _p "cloud-init will not fight /etc/hosts"
fi

# ---- 7. existing config ----------------------------------------------------
if [ -d /etc/network/interfaces.d ] && [ -n "$(ls -A /etc/network/interfaces.d 2>/dev/null)" ]; then
  _w "/etc/network/interfaces.d has drop-ins" "$(ls /etc/network/interfaces.d | tr '\n' ' ')— the guide moves these aside"
else
  _p "no conflicting interfaces.d drop-ins"
fi
if bridge_exists "$BRIDGE"; then
  if ip -br addr show "$BRIDGE" 2>/dev/null | grep -q "$PI_IP"; then
    _p "bridge $BRIDGE already configured with $PI_IP"
  else
    _w "bridge $BRIDGE exists with different config" "inspect with: ip -br addr show $BRIDGE"
  fi
else
  _p "bridge $BRIDGE not yet present (will be created)"
fi
grep -q "$PI_IP" /etc/hosts 2>/dev/null && _p "/etc/hosts maps hostname to $PI_IP" \
  || _w "/etc/hosts not pointing at $PI_IP" "Proxmox needs the node name to resolve to its real IP"

# ---- 8. iptables/kernel reality check -------------------------------------
if modprobe -n ip_tables >/dev/null 2>&1; then
  _w "kernel provides ip_tables (legacy iptables possible)" "on a Pi this is unexpected"
else
  _p "no legacy ip_tables module (nft backend required — handled by pve-pi-fix)"
fi
command -v nft >/dev/null 2>&1 && _p "nftables userspace present" || _w "nft command missing" "iptables-nft still works via libnftables"

# ---- 8b. memory cgroup (Raspberry Pi disables it in the device tree) -------
if grep -qw memory /sys/fs/cgroup/cgroup.controllers 2>/dev/null; then
  _p "memory cgroup controller available (container memory limits enforced)"
else
  _w "memory cgroup controller MISSING" \
     "the Pi device tree passes cgroup_disable=memory, so LXC memory limits are NOT enforced — run cgroup-fix.sh (stage 1 does this automatically)"
fi

# ---- 9. apt / packages ----------------------------------------------------
run_chk hard "apt package lists are usable" bash -c 'apt-get -s update >/dev/null 2>&1 || apt-cache pkgnames >/dev/null'
run_chk soft "ifupdown2 is installable" bash -c 'apt-cache policy ifupdown2 2>/dev/null | grep -q Candidate'

# ---- 9b. required dependencies --------------------------------------------
MISSING_DEPS=$(deps_missing)
if [ -z "$MISSING_DEPS" ]; then
  _p "all required dependencies present"
else
  _w "missing dependencies: $(printf '%s\n' "$MISSING_DEPS" | awk '{print $1}' | tr '\n' ' ')" \
     "installed automatically by the installer / repair.sh / heal.sh"
fi
if pve_installed; then
  _p "Proxmox VE already installed (idempotent re-run)"
  RUNNING_CT=$(pct list 2>/dev/null | tail -n +2 | wc -l)
  RUNNING_VM=$(qm list 2>/dev/null | tail -n +2 | wc -l)
  if [ "${RUNNING_CT:-0}" -gt 0 ] || [ "${RUNNING_VM:-0}" -gt 0 ]; then
    _w "guests are running (${RUNNING_CT} CT / ${RUNNING_VM} VM)" "a rollback/downgrade could disrupt them"
  else
    _p "no running containers/VMs"
  fi
else
  _p "Proxmox VE not yet installed"
fi

# ---- summary --------------------------------------------------------------
TOTAL=$((PASS+WARN+FAIL))
if [ "$QUIET" = 1 ]; then
  printf '%s  preflight: %d/%d passed, %d warning(s), %d failure(s)%s\n' \
    "$C_DIM" "$PASS" "$TOTAL" "$WARN" "$FAIL" "$C_RESET"
else
  hr
  printf '  %s%d passed%s  %s%d warnings%s  %s%d failures%s  (%d checks)\n' \
    "$C_GREEN" "$PASS" "$C_RESET" "$C_YELLOW" "$WARN" "$C_RESET" "$C_RED" "$FAIL" "$C_RESET" "$TOTAL"
fi

if [ "$FAIL" -gt 0 ]; then
  [ "$QUIET" = 1 ] || printf '\n%s%d blocking problem(s) — resolve before continuing.%s\n' "$C_RED$C_BOLD" "$FAIL" "$C_RESET"
  exit 1
fi
if [ "$STRICT" = 1 ] && [ "$WARN" -gt 0 ]; then
  [ "$QUIET" = 1 ] || printf '\n%swarnings present and --strict is set.%s\n' "$C_YELLOW$C_BOLD" "$C_RESET"
  exit 1
fi
exit 0

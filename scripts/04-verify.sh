#!/bin/bash
# ---------------------------------------------------------------------------
# 04-verify.sh — Stage 4
#
# Read-only verification: network layout, PVE services, web UI, storage,
# templates, the nft fix, and (optionally) a full LXC smoke test.
#
# Usage:  ./04-verify.sh          # checks only
#         ./04-verify.sh --smoke  # also create/start/exec/destroy a container
# ---------------------------------------------------------------------------
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=00-config.sh
. "$HERE/00-config.sh"

pass=0; fail=0
check() { # check <description> <expected-substring> <command...>
  local desc="$1" want="$2"; shift 2
  local out; out=$("$@" 2>&1)
  if printf '%s' "$out" | grep -qi -- "$want"; then
    printf '  [ OK ] %s\n' "$desc"; pass=$((pass+1))
  else
    printf '  [FAIL] %s  (got: %s)\n' "$desc" "$(printf '%s' "$out" | head -1)"; fail=$((fail+1))
  fi
}

printf '\n== Network ==\n'
ip -br addr | grep -vE '^lo' || true
ip route | grep default || true
check "bridge $BRIDGE has an address" "$PI_IP" bash -c "ip -br addr show $BRIDGE"
check "default route via $BRIDGE"     "$BRIDGE" bash -c "ip route | grep default"

printf '\n== Proxmox services ==\n'
for s in pve-cluster pvedaemon pveproxy pvestatd pvescheduler pve-firewall; do
  if systemctl is-active --quiet "$s"; then
    printf '  [ OK ] %s active\n' "$s"; pass=$((pass+1))
  else
    printf '  [FAIL] %s not active\n' "$s"; fail=$((fail+1))
  fi
done
printf '  -- failed units --\n'; systemctl --failed --no-legend || true

printf '\n== Web UI ==\n'
check "https://localhost:8006 responds" "200" \
  curl -sk -o /dev/null -w '%{http_code}' "https://localhost:8006"

printf '\n== iptables backend (Pi kernel has no legacy modules) ==\n'
check "iptables is nft"        "nf_tables" bash -c 'iptables -V'
check "firewall has no errors" "0"         bash -c 'journalctl -u pve-firewall -b --no-pager 2>/dev/null | grep -ci error'

printf '\n== Storage & templates ==\n'
pvesm status || true
ls -la /var/lib/vz/template/cache/ 2>/dev/null || true
check "an arm64 template is present" "arm64" bash -c 'ls /var/lib/vz/template/cache/'

if [ "${1:-}" = "--smoke" ]; then
  printf '\n== LXC smoke test ==\n'
  TPL=$(ls /var/lib/vz/template/cache/ 2>/dev/null | grep -i 'debian.*arm64' | head -1)
  if [ -z "$TPL" ]; then
    printf '  [SKIP] no debian arm64 template found\n'
  else
    pct destroy 999 2>/dev/null || true
    pct create 999 "/var/lib/vz/template/cache/$TPL" \
      --hostname pve-smoke-test --memory 256 --cores 1 --rootfs local:2 \
      --net0 "name=eth0,bridge=$BRIDGE,ip=dhcp" --unprivileged 0 --password smoke1234 >/dev/null 2>&1 \
      && printf '  [ OK ] container created\n' && pass=$((pass+1)) \
      || { printf '  [FAIL] container create failed\n'; fail=$((fail+1)); }
    pct start 999 >/dev/null 2>&1 && sleep 12
    check "container is running" "running" pct status 999
    check "container is arm64"   "aarch64" bash -c 'pct exec 999 -- uname -m'
    printf '  -- container networking --\n'; pct exec 999 -- ip -br addr 2>&1 | grep -v '^lo' || true
    pct stop 999 >/dev/null 2>&1 || true
    pct destroy 999 >/dev/null 2>&1 || true
    printf '  (smoke-test container removed)\n'
  fi
fi

printf '\n== Result: %d passed, %d failed ==\n' "$pass" "$fail"
[ "$fail" -eq 0 ] && printf 'Proxmox VE is working. Web UI: https://%s:8006\n' "$PI_IP"
exit $(( fail > 0 ))

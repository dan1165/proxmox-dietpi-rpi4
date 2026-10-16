#!/bin/bash
# ---------------------------------------------------------------------------
# 04-verify.sh — final verification, three INDEPENDENT passes.
#
#   ./04-verify.sh            three independent verification methods
#   ./04-verify.sh --once     single pass
#   ./04-verify.sh --smoke    also create/start/exec/destroy a container
#
# Each pass answers the same questions using a different mechanism
# (systemd state / raw process+port+HTTP / PVE API+data), so a false positive
# in one method is caught by the others. Exit 0 only if every pass is clean.
# ---------------------------------------------------------------------------
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"
# shellcheck source=00-config.sh
. "$HERE/00-config.sh"

WORKDIR="${WORKDIR:-/root/proxmox-setup}"
LOG_FILE="$WORKDIR/04-verify.log"
ONCE=0; SMOKE=0
for a in "$@"; do case "$a" in --once) ONCE=1;; --smoke) SMOKE=1;; esac; done

PASS_N=0; FAIL_N=0
chk() { # chk <desc> <cmd...>
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then
    printf '    %s[ OK ]%s %s\n' "$C_GREEN" "$C_RESET" "$desc"; PASS_N=$((PASS_N+1))
  else
    printf '    %s[FAIL]%s %s\n' "$C_RED" "$C_RESET" "$desc"; FAIL_N=$((FAIL_N+1))
  fi
}

# --- Pass A — systemd's view ------------------------------------------------
pass_systemd() {
  local s
  for s in pve-cluster pvedaemon pveproxy pvestatd pve-firewall; do
    chk "$s is active" systemctl is-active --quiet "$s"
  done
  chk "no failed units" bash -c '[ "$(systemctl --failed --no-legend | wc -l)" = 0 ]'
  chk "pve-firewall logged no errors" bash -c '[ "$(journalctl -u pve-firewall -b --no-pager 2>/dev/null | grep -ci error)" = 0 ]'
  chk "systemd-logind not masked" bash -c '[ "$(systemctl is-enabled systemd-logind 2>&1)" != masked ]'
  chk "networking.service is active" systemctl is-active --quiet networking
  chk "iptables uses the nft backend" bash -c 'iptables -V | grep -q nf_tables'
}

# --- Pass B — raw processes, ports, HTTP (no systemd) -----------------------
pass_process() {
  chk "pveproxy process running" bash -c 'pgrep -f pveproxy >/dev/null'
  chk "pvedaemon process running" bash -c 'pgrep -f pvedaemon >/dev/null'
  chk "pvestatd process running" bash -c 'pgrep -f pvestatd >/dev/null'
  chk "something listens on :8006" bash -c 'ss -tln 2>/dev/null | grep -q ":8006"'
  chk "web UI answers HTTP 200" bash -c '[ "$(curl -sk -o /dev/null -w "%{http_code}" https://localhost:8006)" = 200 ]'
  chk "web UI serves the PVE title" bash -c 'curl -sk https://localhost:8006 | grep -qiE "<title>.*(pve|proxmox|pxvirt)"'
  chk "ip_forward is enabled" bash -c '[ "$(cat /proc/sys/net/ipv4/ip_forward)" = 1 ]'
  chk "plenty of free space on /" bash -c '[ "$(df -Pm / | awk "NR==2{print \$4}")" -ge 2000 ]'
}

# --- Pass C — PVE API + on-disk data ----------------------------------------
pass_pveapi() {
  chk "node reports online via pvesh" bash -c "pvesh get /nodes --output-format json 2>/dev/null | grep -q '\"status\":\"online\"'"
  chk "pveversion runs" bash -c 'pveversion >/dev/null 2>&1'
  chk "cluster fs /etc/pve is mounted" bash -c 'grep -q " /etc/pve " /proc/mounts'
  chk "storage 'local' is active" bash -c 'pvesm status 2>/dev/null | awk "NR>1{print \$3}" | grep -q active'
  chk "pct and qm exist" bash -c 'command -v pct >/dev/null && command -v qm >/dev/null'
  chk "an arm64 template is present" bash -c 'ls /var/lib/vz/template/cache/ 2>/dev/null | grep -q arm64'
  chk "bridge $BRIDGE owns $PI_IP" bash -c "ip -br addr show $BRIDGE | grep -q $PI_IP"
  chk "default route via $BRIDGE" bash -c "ip route | grep -q 'default via $PI_GATEWAY dev $BRIDGE'"
}

# --- driver -----------------------------------------------------------------
printf '\n%sFinal verification — Proxmox VE on %s%s\n' "$C_BOLD$C_CYAN" "$(hostname)" "$C_RESET"
hr
printf '  %s\n\n' "$(pveversion 2>/dev/null | head -1 || echo 'pveversion unavailable')"

TOTAL_FAIL=0
run_pass() { # run_pass <title> <fn>
  local title="$1" fn="$2"
  printf '  %s── %s ─────────────────────────────%s\n' "$C_BOLD" "$title" "$C_RESET"
  PASS_N=0; FAIL_N=0
  "$fn"
  printf '     %s→ %d passed, %d failed%s\n\n' "$C_DIM" "$PASS_N" "$FAIL_N" "$C_RESET"
  TOTAL_FAIL=$((TOTAL_FAIL + FAIL_N))
}

run_pass "Pass A · systemd state" pass_systemd
if [ "$ONCE" = 0 ]; then
  run_pass "Pass B · processes / ports / HTTP" pass_process
  run_pass "Pass C · PVE API / on-disk data" pass_pveapi
fi

# --- optional live smoke test ----------------------------------------------
if [ "$SMOKE" = 1 ]; then
  printf '  %s── live LXC smoke test ─────────────────────%s\n' "$C_BOLD" "$C_RESET"
  TPL=$(ls /var/lib/vz/template/cache/ 2>/dev/null | grep -i 'debian.*arm64' | head -1)
  if [ -z "$TPL" ]; then
    warn "no debian arm64 template — skipping smoke test"
  else
    confirm_yes "Create, boot and destroy a throwaway container (CT 999)?" || warn "skipped by operator"
    if [ "${ASSUME_YES:-0}" = 1 ] || [ -t 0 ]; then
      pct destroy 999 >/dev/null 2>&1 || true
      if pct create 999 "/var/lib/vz/template/cache/$TPL" \
           --hostname pve-smoke-test --memory 256 --cores 1 --rootfs local:2 \
           --net0 "name=eth0,bridge=$BRIDGE,ip=dhcp" --unprivileged 0 --password smoke1234 >/dev/null 2>&1; then
        ok "container created"
        pct start 999 >/dev/null 2>&1 && sleep 12
        PASS_N=0; FAIL_N=0
        chk "container is running" bash -c '[ "$(pct status 999 2>/dev/null)" = "status: running" ]'
        chk "container reports aarch64" bash -c 'pct exec 999 -- uname -m | grep -q aarch64'
        TOTAL_FAIL=$((TOTAL_FAIL + FAIL_N))
        printf '      inside: %s\n' "$(pct exec 999 -- ip -br addr 2>/dev/null | grep -v '^lo' | tr -s ' ' | head -1)"
        pct stop 999 >/dev/null 2>&1 || true
        pct destroy 999 >/dev/null 2>&1 || true
        ok "smoke-test container removed"
      else
        err "container creation failed"
        TOTAL_FAIL=$((TOTAL_FAIL+1))
      fi
    fi
  fi
  printf '\n'
fi

# --- summary ----------------------------------------------------------------
hr
METHODS=1; [ "$ONCE" = 1 ] || METHODS=3
printf '  summary: %s independent method(s) · %s failure(s)\n' "$METHODS" "$TOTAL_FAIL"
if [ "$TOTAL_FAIL" -eq 0 ]; then
  printf '\n%s  VERIFIED — Proxmox VE is healthy.%s\n' "$C_BOLD$C_GREEN" "$C_RESET"
  printf '  web UI: %shttps://%s:8006%s\n\n' "$C_CYAN" "$PI_IP" "$C_RESET"
  exit 0
fi
printf '\n%s  %s check(s) failed.%s Try: sudo %s/repair.sh\n\n' \
  "$C_BOLD$C_RED" "$TOTAL_FAIL" "$C_RESET" "$HERE"
exit 1

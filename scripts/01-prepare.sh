#!/bin/bash
# ---------------------------------------------------------------------------
# 01-prepare.sh — Stage 1 (idempotent, gated)
#
#  * preflight safety checks          (gate 1)
#  * typed confirmation               (gate 2)
#  * PXVirt ARM64 repo, backups, /etc/hosts, ifupdown2, fail-safe
#  * triple verification of the result (gate 3)
#
# Safe to re-run: every step detects work already done.
# ---------------------------------------------------------------------------
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"
# shellcheck source=00-config.sh
. "$HERE/00-config.sh"

WORKDIR="${WORKDIR:-/root/proxmox-setup}"
mkdir -p "$WORKDIR"
LOG_FILE="$WORKDIR/01-prepare.log"
install_error_trap "01-prepare"
require_root
require_tty_or_yes
acquire_lock

# ---- gate 1 ---------------------------------------------------------------
gate_preflight "$HERE" || exit 1

# ---- gate 2 ---------------------------------------------------------------
cat <<EOF

  Stage 1 will:
    • add the PXVirt ARM64 Proxmox repository
    • back up /etc/network/interfaces, /etc/hosts, /etc/resolv.conf, apt sources
    • point $(hostname) at $PI_IP in /etc/hosts
    • replace ifupdown with ifupdown2 (+ bridge-utils)
EOF
gate_confirm "PREPARE" "Type PREPARE to apply stage 1" || exit 1

CHANGED=0
note() { CHANGED=$((CHANGED+1)); step "$*"; }

# ---- backups (only once; keep the original) --------------------------------
say "Backups"
BK="$WORKDIR/backup"
mkdir -p "$BK" "$WORKDIR/disabled"
if [ -f "$BK/interfaces" ]; then
  step "backups already present (preserving the original set)"
else
  cp -a /etc/network/interfaces   "$BK/interfaces" 2>/dev/null || true
  rm -rf "$BK/interfaces.d"
  cp -a /etc/network/interfaces.d "$BK/interfaces.d" 2>/dev/null || true
  cp -a /etc/hosts                "$BK/hosts"
  cp -a /etc/resolv.conf          "$BK/resolv.conf" 2>/dev/null || true
  cp -a /etc/apt/sources.list.d   "$BK/sources.list.d" 2>/dev/null || true
  note "backed up network/hosts/resolv/apt-sources to $BK"
fi

# ---- repository ------------------------------------------------------------
say "PXVirt ARM64 repository"
CODENAME=$(os_codename)
if [ -s /usr/share/keyrings/lierfang.gpg ] && grep -q mirror.lierfang.com /etc/apt/sources.list.d/pveport.list 2>/dev/null; then
  step "repository and key already present"
else
  have curl || { DEBIAN_FRONTEND=noninteractive apt-get install -y curl; }
  curl -fsSL https://mirrors.lierfang.com/pxcloud/lierfang.gpg -o /usr/share/keyrings/lierfang.gpg
  atomic_write /etc/apt/sources.list.d/pveport.list <<EOF
deb [arch=arm64 signed-by=/usr/share/keyrings/lierfang.gpg] https://mirrors.lierfang.com/pxcloud/pxvirt $CODENAME main
EOF
  note "added PXVirt repo for $CODENAME"
fi

say "Refreshing package lists"
apt-get update -qq 2>&1 | tail -3 || warn "apt update reported issues"
POLICY=$(apt-cache policy proxmox-ve 2>/dev/null | awk '/Candidate/{print $2}')
[ -n "$POLICY" ] && [ "$POLICY" != "(none)" ] && ok "proxmox-ve candidate: $POLICY" || warn "proxmox-ve not visible in apt yet"

# ---- hosts -----------------------------------------------------------------
say "/etc/hosts"
if grep -qE "^$PI_IP[[:space:]]+$(hostname)\b" /etc/hosts 2>/dev/null; then
  step "hostname already maps to $PI_IP"
else
  atomic_write /etc/hosts <<EOF
127.0.0.1       localhost
$PI_IP      $(hostname)

# The following lines are desirable for IPv6 capable hosts
::1     localhost ip6-localhost ip6-loopback
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
EOF
  note "/etc/hosts -> $PI_IP $(hostname)"
fi

# ---- fail-safe -------------------------------------------------------------
say "Enabling the memory cgroup controller (Raspberry Pi disables it)"
# The Pi device tree passes cgroup_disable=memory, so LXC memory limits are
# silently unenforced. Stage 2 reboots, which activates this.
if "$HERE/cgroup-fix.sh" >/dev/null 2>&1; then
  step "memory cgroup already active"
else
  rc=$?
  if [ "$rc" = 10 ]; then
    note "queued the memory-cgroup kernel cmdline fix (activated by the stage-2 reboot)"
  else
    warn "cgroup-fix.sh reported an error (rc=$rc) — container memory limits may not work"
  fi
fi

say "Arming fail-safe (guards the ifupdown → ifupdown2 swap)"
sed "s|__GATEWAY__|$PI_GATEWAY|g" "$HERE/net-failsafe.sh" > "$WORKDIR/net-failsafe.sh"
install -m 755 "$WORKDIR/net-failsafe.sh" /usr/local/sbin/net-failsafe.sh
rm -f /var/lib/.net-failsafe-ran
setsid nohup /usr/local/sbin/net-failsafe.sh >/dev/null 2>&1 &
step "fail-safe armed (pid $!)"

# ---- ifupdown2 -------------------------------------------------------------
say "ifupdown2 + bridge-utils"
if dpkg -s ifupdown2 >/dev/null 2>&1; then
  step "ifupdown2 already installed"
else
  rm -f /tmp/.ifupdown2-first-install
  if ! DEBIAN_FRONTEND=noninteractive apt-get install -y ifupdown2 bridge-utils; then
    warn "first attempt failed; applying the .ifupdown2-first-install workaround"
    rm -f /tmp/.ifupdown2-first-install
    dpkg --configure -a || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y ifupdown2 bridge-utils
  fi
  note "installed ifupdown2 + bridge-utils (ifupdown removed)"
fi

# ---- gate 3 ----------------------------------------------------------------
gate_triple "stage 1" \
  "PXVirt key installed::test -s /usr/share/keyrings/lierfang.gpg" \
  "pveport.list present and uses the right codename::grep -q \"$CODENAME\" /etc/apt/sources.list.d/pveport.list" \
  "hostname resolves to $PI_IP::grep -qE \"^$PI_IP[[:space:]]+$(hostname)\\\\b\" /etc/hosts && [ \"\$(hostname --ip-address)\" = \"$PI_IP\" ]" \
  "ifupdown2 installed::dpkg -s ifupdown2 >/dev/null 2>&1" \
  "ifup command works::command -v ifup >/dev/null" \
  "memory cgroups active or queued::grep -qw memory /sys/fs/cgroup/cgroup.controllers 2>/dev/null || grep -qw cgroup_enable=memory /boot/firmware/cmdline.txt 2>/dev/null" \
  "original interfaces backed up::test -f $WORKDIR/backup/interfaces"

state_set 2
printf '\n%sStage 1 complete%s (%d change(s)). Next: sudo %s/02-network.sh\n' "$C_BOLD$C_GREEN" "$C_RESET" "$CHANGED" "$HERE"

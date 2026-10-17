#!/bin/bash
# ---------------------------------------------------------------------------
# lib/fixes.sh — every known fix, as idempotent functions.
#
# Sourced by lib/common.sh so repair.sh, heal.sh, 01-prepare.sh and
# 03-install-proxmox.sh all share ONE implementation of each fix.
#
# Conventions
#   * every fix_* returns 0 on success and never prompts
#   * FIX_CHANGED counts the fixes that actually changed something
#   * QUIET_MODE=1 suppresses the "already fine" chatter (for the timer)
#   * $HERE must already point at the scripts directory (set by the caller)
# ---------------------------------------------------------------------------

FIX_CHANGED=0
FIX_WARNINGS=0

fx_changed() { FIX_CHANGED=$((FIX_CHANGED+1));      step "$*"; }
fx_ok()      { [ "${QUIET_MODE:-0}" = 1 ] || ok "$*"; }
fx_warn()    { FIX_WARNINGS=$((FIX_WARNINGS+1));    warn "$*"; }
fx_skip()    { [ "${QUIET_MODE:-0}" = 1 ] || step "$*"; }

_unit_file() { # find a unit in the common locations
  local u="$1" d
  for d in /etc/systemd/system /usr/lib/systemd/system /lib/systemd/system; do
    [ -f "$d/$u" ] && { echo "$d/$u"; return 0; }
  done
  return 1
}

# ---- 1. nft iptables backend ----------------------------------------------
# The Pi kernel has no ip_tables module AND pve-firewall.service forces the
# legacy backend via ExecStartPre, so the firewall fails on every start.
fix_nft_backend() {
  install -m 755 "$HERE/pve-pi-fix.sh" /usr/local/sbin/pve-pi-fix
  local cur
  cur=$(update-alternatives --query iptables 2>/dev/null | awk '/^Value:/{print $2}')
  if [ "$cur" != "/usr/sbin/iptables-nft" ]; then
    /usr/local/sbin/pve-pi-fix >/dev/null 2>&1 && fx_changed "iptables alternatives -> nft backend"
  else
    fx_skip "iptables already on the nft backend"
  fi

  if [ ! -f /etc/systemd/system/pve-pi-fix.service ]; then
    cat > /etc/systemd/system/pve-pi-fix.service <<'UNIT'
[Unit]
Description=Proxmox-on-Pi compatibility: force nft iptables backend
DefaultDependencies=no
After=local-fs.target
Before=pve-firewall.service pvestatd.service networking.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/pve-pi-fix

[Install]
WantedBy=sysinit.target
UNIT
    systemctl daemon-reload
    fx_changed "added pve-pi-fix.service (re-asserts nft at boot)"
  fi
  systemctl is-enabled --quiet pve-pi-fix.service 2>/dev/null \
    || { systemctl enable pve-pi-fix.service >/dev/null 2>&1 && fx_changed "enabled pve-pi-fix.service"; }

  if [ ! -f /etc/apt/apt.conf.d/99pve-pi-fix ]; then
    printf 'DPkg::Post-Invoke {"/usr/local/sbin/pve-pi-fix";};\n' > /etc/apt/apt.conf.d/99pve-pi-fix
    fx_changed "added apt hook (re-asserts nft after every apt run)"
  fi

  if _unit_file pve-firewall.service >/dev/null; then
    if [ ! -f /etc/systemd/system/pve-firewall.service.d/10-pi-nft.conf ]; then
      mkdir -p /etc/systemd/system/pve-firewall.service.d
      cat > /etc/systemd/system/pve-firewall.service.d/10-pi-nft.conf <<'CONF'
# The Raspberry Pi kernel has no ip_tables/ebtables legacy modules.
# Clear the hardcoded ExecStartPre lines that force the legacy backend.
[Service]
ExecStartPre=
ExecStartPre=
ExecStartPre=
CONF
      systemctl daemon-reload
      fx_changed "added pve-firewall drop-in (clears legacy ExecStartPre)"
    else
      fx_skip "pve-firewall drop-in present"
    fi
    # if the firewall is running with the wrong backend, bounce it
    if systemctl is-active --quiet pve-firewall 2>/dev/null; then
      systemctl restart pve-firewall >/dev/null 2>&1 || true
    fi
  fi
  return 0
}

# ---- 2. memory cgroup controller ------------------------------------------
# The Pi device tree passes cgroup_disable=memory, so LXC memory limits are
# silently unenforced. Needs the cmdline fix + a reboot.
fix_cgroup() {
  if grep -qw memory /sys/fs/cgroup/cgroup.controllers 2>/dev/null; then
    fx_skip "memory cgroup controller active"
    return 0
  fi
  if [ ! -x "$HERE/cgroup-fix.sh" ]; then
    fx_warn "cgroup-fix.sh missing — cannot enable the memory cgroup controller"
    return 0
  fi
  "$HERE/cgroup-fix.sh" >/dev/null 2>&1
  case $? in
    0)  fx_changed "memory cgroup controller enabled" ;;
    10) fx_changed "queued the memory-cgroup cmdline fix (REBOOT REQUIRED)" ;;
    *)  fx_warn "cgroup-fix.sh failed" ;;
  esac
  return 0
}

# ---- 3. systemd-logind -----------------------------------------------------
# DietPi masks it, which produces pam_systemd errors on every login.
fix_logind() {
  if [ "$(systemctl is-enabled systemd-logind 2>&1)" = "masked" ]; then
    systemctl unmask systemd-logind >/dev/null 2>&1
    systemctl enable --now systemd-logind >/dev/null 2>&1
    fx_changed "unmasked and started systemd-logind"
  else
    fx_skip "systemd-logind not masked"
  fi
  return 0
}

# ---- 4. bogus bookworm apt source -----------------------------------------
# pve-manager installs a bookworm source on a trixie system.
fix_apt_source() {
  if [ -f /etc/apt/sources.list.d/pxvirt-sources.list ]; then
    mv /etc/apt/sources.list.d/pxvirt-sources.list \
       /etc/apt/sources.list.d/pxvirt-sources.list.disabled
    fx_changed "disabled the bookworm apt source shipped by pve-manager"
  else
    fx_skip "bookworm apt source not present"
  fi
  return 0
}

# ---- 5. unverifiable PVE::APLInfo template mirror --------------------------
fix_aplinfo() {
  local f=/usr/share/perl5/PVE/APLInfo.pm
  if [ -f "$f" ] && grep -q 'mirrors.lierfang.com' "$f" 2>/dev/null; then
    if [ -x "$HERE/patch-aplinfo.py" ] || [ -f "$HERE/patch-aplinfo.py" ]; then
      python3 "$HERE/patch-aplinfo.py" >/dev/null 2>&1 && fx_changed "patched PVE::APLInfo (dropped the unverifiable mirror)"
    else
      fx_warn "patch-aplinfo.py missing — pveam update may fail"
    fi
  else
    fx_skip "PVE::APLInfo already patched (or pve-manager not installed)"
  fi
  return 0
}

# ---- 6. tailscaled boot ordering ------------------------------------------
# Without this, tailscaled starts before the bridge is up and logs DNS errors.
fix_tailscale_order() {
  have tailscale || { fx_skip "tailscale not installed"; return 0; }
  if [ ! -f /etc/systemd/system/tailscaled.service.d/10-after-networking.conf ]; then
    mkdir -p /etc/systemd/system/tailscaled.service.d
    cat > /etc/systemd/system/tailscaled.service.d/10-after-networking.conf <<'CONF'
[Unit]
After=networking.service
Wants=networking.service
CONF
    systemctl daemon-reload
    fx_changed "added tailscaled network-ordering drop-in"
  else
    fx_skip "tailscaled ordering already set"
  fi
  return 0
}

# ---- 7. dead services ------------------------------------------------------
# Restart anything enabled that should be running but is not.
fix_services() {
  local s
  for s in pve-cluster pvedaemon pveproxy pvestatd pvescheduler pve-firewall; do
    systemctl is-enabled --quiet "$s" 2>/dev/null || continue
    if ! systemctl is-active --quiet "$s"; then
      if systemctl restart "$s" >/dev/null 2>&1; then
        fx_changed "restarted inactive service: $s"
      else
        fx_warn "could not restart $s"
      fi
    fi
  done
  if have tailscale && systemctl is-enabled --quiet tailscaled 2>/dev/null \
     && ! systemctl is-active --quiet tailscaled; then
    systemctl restart tailscaled >/dev/null 2>&1 \
      && fx_changed "restarted inactive service: tailscaled" \
      || fx_warn "could not restart tailscaled"
  fi
  # pve-proxy sometimes needs a nudge once pve-cluster is back
  if systemctl is-active --quiet pve-cluster && ! systemctl is-active --quiet pveproxy; then
    systemctl restart pveproxy >/dev/null 2>&1 && fx_changed "restarted pveproxy"
  fi
  [ "$FIX_CHANGED" -gt 0 ] || fx_skip "all services that should be running are running"
  return 0
}

# ---- 8. network (report-only by default) ----------------------------------
# Deliberately conservative: changing networking from a timer could drop your
# SSH session. Set REPAIR_NETWORK=1 to allow an `ifup <bridge>` attempt.
fix_network() {
  local br="${BRIDGE:-vmbr0}" ip="${PI_IP:-}"
  if [ -z "$ip" ]; then fx_skip "PI_IP not configured"; return 0; fi
  if ip -br addr show "$br" 2>/dev/null | grep -q "$ip"; then
    fx_skip "bridge $br has $ip"
    return 0
  fi
  if ! ip link show "$br" >/dev/null 2>&1; then
    fx_warn "bridge $br is missing (configured in /etc/network/interfaces?)"
  else
    fx_warn "bridge $br exists but does not have $ip"
  fi
  if [ "${REPAIR_NETWORK:-0}" = 1 ]; then
    step "attempting: ifup $br"
    ifup "$br" >/dev/null 2>&1 && fx_changed "brought up $br" || fx_warn "ifup $br failed"
  else
    fx_skip "not touching networking (set REPAIR_NETWORK=1 to allow)"
  fi
  return 0
}

# ---- driver ---------------------------------------------------------------
# fix_all [--with-network]
fix_all() {
  FIX_CHANGED=0; FIX_WARNINGS=0
  fix_nft_backend
  fix_cgroup
  fix_logind
  fix_apt_source
  fix_aplinfo
  fix_tailscale_order
  fix_services
  [ "${1:-}" = "--with-network" ] && fix_network
  return 0
}

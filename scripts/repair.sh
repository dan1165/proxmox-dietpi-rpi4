#!/bin/bash
# ---------------------------------------------------------------------------
# repair.sh — re-apply every known fix, idempotently. Safe to run any time.
#
# Useful after an `apt upgrade` restores a package-shipped file. Ends with an
# independent triple verification (gate 3).
#
#   ./repair.sh            apply + verify
#   ./repair.sh --check    report only, change nothing
# ---------------------------------------------------------------------------
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"
# shellcheck source=00-config.sh
[ -f "$HERE/00-config.sh" ] && . "$HERE/00-config.sh"
require_root

CHECK=0
[ "${1:-}" = "--check" ] && CHECK=1
changed=0
note() { changed=$((changed+1)); step "$*"; }

say "Repairing known DietPi/Pi/Proxmox issues"

# ---- 1. nft iptables backend ----------------------------------------------
if have tailscale || pve_installed; then
  if [ ! -x /usr/local/sbin/pve-pi-fix ]; then
    [ "$CHECK" = 1 ] || { install -m 755 "$HERE/pve-pi-fix.sh" /usr/local/sbin/pve-pi-fix; note "installed /usr/local/sbin/pve-pi-fix"; }
  fi
  cur=$(update-alternatives --query iptables 2>/dev/null | awk '/^Value:/{print $2}')
  if [ "$cur" != "/usr/sbin/iptables-nft" ]; then
    [ "$CHECK" = 1 ] || { /usr/local/sbin/pve-pi-fix >/dev/null 2>&1; note "iptables alternatives -> nft"; }
  else
    step "iptables already on the nft backend"
  fi

  if ! systemctl is-enabled --quiet pve-pi-fix.service 2>/dev/null && [ -f /etc/systemd/system/pve-pi-fix.service ]; then
    [ "$CHECK" = 1 ] || { systemctl enable pve-pi-fix.service >/dev/null 2>&1; note "enabled pve-pi-fix.service"; }
  fi
  if [ ! -f /etc/apt/apt.conf.d/99pve-pi-fix ]; then
    [ "$CHECK" = 1 ] || { printf 'DPkg::Post-Invoke {"/usr/local/sbin/pve-pi-fix";};\n' > /etc/apt/apt.conf.d/99pve-pi-fix; note "installed apt post-invoke hook"; }
  fi
  if [ ! -f /etc/systemd/system/pve-firewall.service.d/10-pi-nft.conf ]; then
    [ "$CHECK" = 1 ] || {
      mkdir -p /etc/systemd/system/pve-firewall.service.d
      cat > /etc/systemd/system/pve-firewall.service.d/10-pi-nft.conf <<'CONF'
[Service]
ExecStartPre=
ExecStartPre=
ExecStartPre=
CONF
      systemctl daemon-reload
      note "installed pve-firewall drop-in (clears legacy ExecStartPre)"
    }
  else
    step "pve-firewall drop-in present"
  fi
  if [ "$CHECK" = 0 ]; then systemctl restart pve-firewall >/dev/null 2>&1 || true; fi
fi

# ---- 2. systemd-logind -----------------------------------------------------
if [ "$(systemctl is-enabled systemd-logind 2>&1)" = "masked" ]; then
  [ "$CHECK" = 1 ] || { systemctl unmask systemd-logind >/dev/null 2>&1; systemctl enable --now systemd-logind >/dev/null 2>&1; note "unmasked systemd-logind"; }
else
  step "systemd-logind not masked"
fi

# ---- 3. bogus bookworm apt source -----------------------------------------
if [ -f /etc/apt/sources.list.d/pxvirt-sources.list ]; then
  [ "$CHECK" = 1 ] || { mv /etc/apt/sources.list.d/pxvirt-sources.list /etc/apt/sources.list.d/pxvirt-sources.list.disabled; note "disabled pxvirt bookworm source"; }
else
  step "bookworm source not present"
fi

# ---- 4. PVE::APLInfo mirror ------------------------------------------------
if [ -f /usr/share/perl5/PVE/APLInfo.pm ] && grep -q 'mirrors.lierfang.com' /usr/share/perl5/PVE/APLInfo.pm 2>/dev/null; then
  [ "$CHECK" = 1 ] || { python3 "$HERE/patch-aplinfo.py" >/dev/null 2>&1 && note "patched PVE::APLInfo (template mirror)"; }
else
  step "PVE::APLInfo already patched"
fi

# ---- 5. tailscaled boot ordering ------------------------------------------
if have tailscale && [ ! -f /etc/systemd/system/tailscaled.service.d/10-after-networking.conf ]; then
  [ "$CHECK" = 1 ] || {
    mkdir -p /etc/systemd/system/tailscaled.service.d
    cat > /etc/systemd/system/tailscaled.service.d/10-after-networking.conf <<'CONF'
[Unit]
After=networking.service
Wants=networking.service
CONF
    systemctl daemon-reload
    note "added tailscaled network-ordering drop-in"
  }
else
  step "tailscaled ordering ok (or tailscale absent)"
fi

# ---- 6. memory cgroup controller (Pi device tree disables it) --------------
if grep -qw memory /sys/fs/cgroup/cgroup.controllers 2>/dev/null; then
  step "memory cgroup controller active"
else
  if [ "$CHECK" = 1 ]; then
    warn "memory cgroup controller missing — run cgroup-fix.sh, then reboot"
  else
    if "$HERE/cgroup-fix.sh" >/dev/null 2>&1; then
      note "memory cgroup already active"
    else
      rc=$?
      if [ "$rc" = 10 ]; then
        note "applied the memory-cgroup kernel cmdline fix (REBOOT REQUIRED to activate)"
      else
        warn "cgroup-fix.sh failed (rc=$rc)"
      fi
    fi
  fi
fi

# ---- 7. guards -------------------------------------------------------------
[ -f /etc/systemd/system/net-guard.service ] && [ "$CHECK" = 0 ] && systemctl disable net-guard.service >/dev/null 2>&1 && step "boot guard disabled (setup complete)"

if [ "$changed" -eq 0 ]; then ok "nothing needed repairing"; else ok "$changed item(s) repaired"; fi

# ---- gate 3: independent triple verification ------------------------------
if [ "$CHECK" = 0 ] && pve_installed; then
  gate_triple "repair" \
    "iptables uses the nft backend::iptables -V | grep -q nf_tables" \
    "pve-firewall reports no errors::[ \"\$(journalctl -u pve-firewall -b --no-pager 2>/dev/null | grep -ci error)\" = 0 ]" \
    "core PVE services active::systemctl is-active --quiet pve-cluster pvedaemon pveproxy pvestatd" \
    "memory cgroups active or queued::grep -qw memory /sys/fs/cgroup/cgroup.controllers 2>/dev/null || grep -qw cgroup_enable=memory /boot/firmware/cmdline.txt 2>/dev/null"
fi
exit 0

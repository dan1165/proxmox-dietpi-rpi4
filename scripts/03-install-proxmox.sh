#!/bin/bash
# ---------------------------------------------------------------------------
# 03-install-proxmox.sh — Stage 3 (gated)
#
#   gate 1  preflight safety checks
#           + confirms the network survived stage 2's reboot
#   gate 2  you type INSTALL-PROXMOX
#   gate 3  install, apply every compatibility fix, then triple-verify
#
# Idempotent: re-running repairs rather than reinstalls.
# ---------------------------------------------------------------------------
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"
# shellcheck source=00-config.sh
. "$HERE/00-config.sh"

WORKDIR="${WORKDIR:-/root/proxmox-setup}"
mkdir -p "$WORKDIR"
LOG_FILE="$WORKDIR/03-proxmox.log"
install_error_trap "03-install-proxmox"
require_root
require_tty_or_yes
acquire_lock
export DEBIAN_FRONTEND=noninteractive

# ---- gate 1: preflight + confirm the bridge survived the reboot ------------
gate_preflight "$HERE" || exit 1

say "Confirming the stage-2 network survived the reboot"
gate_triple "network after reboot" \
  "bridge $BRIDGE is up::ip link show $BRIDGE >/dev/null 2>&1" \
  "bridge holds $PI_IP::ip -br addr show $BRIDGE | grep -q \"$PI_IP\"" \
  "default route via $BRIDGE::ip route | grep -q \"default via $PI_GATEWAY dev $BRIDGE\"" \
  "gateway reachable::ping -c2 -W3 $PI_GATEWAY >/dev/null 2>&1" \
  "NIC has no IP of its own::! ip -4 addr show $NIC | grep -q 'inet '" \
  "rollback guard stood down::! systemctl is-enabled --quiet net-guard.service" \
  || die "the network did not come up as expected — inspect /root/proxmox-setup/guard.log and /etc/network/interfaces"

# ---- gate 2 ---------------------------------------------------------------
cat <<EOF

  Stage 3 will install:
    ${PVE_PACKAGES}
  plus the DietPi/RPi compatibility fixes (nft iptables backend, logind,
  apt source, template mirror) and download: ${PVE_TEMPLATES:-none}

  This pulls ~440 packages and takes several minutes.
EOF
gate_confirm "INSTALL-PROXMOX" "Type INSTALL-PROXMOX to begin installation" || exit 1

# ---- install --------------------------------------------------------------
if pve_installed; then
  say "Proxmox already installed ($(pveversion 2>/dev/null | head -1)) — checking for missing pieces"
else
  say "Installing Proxmox VE"
  echo "postfix postfix/main_mailer_type select Local only" | debconf-set-selections
  echo "postfix postfix/mailname string $(hostname)"        | debconf-set-selections
  ok=0
  for try in 1 2 3; do
    step "attempt $try"
    if apt-get install -y $PVE_PACKAGES; then ok=1; break; fi
    warn "attempt $try failed — repairing (pxvirt-spdk workaround) and retrying"
    rm -f /tmp/.ifupdown2-first-install
    dpkg --configure -a || true
    apt-get -f install -y || true
    sleep 5
  done
  [ "$ok" = 1 ] || die "installation failed after 3 attempts — see $LOG_FILE"
  ok "installed"
fi

# ---- compatibility fixes (shared with repair.sh) ---------------------------
say "Applying DietPi/RPi compatibility fixes"
"$HERE/repair.sh" ${CHECK:+} 2>&1 | sed 's/^/  /' || warn "repair.sh reported issues — review the output above"

# ---- templates ------------------------------------------------------------
if [ -n "${PVE_TEMPLATES:-}" ]; then
  say "Container templates"
  for t in $PVE_TEMPLATES; do
    if [ -s "/var/lib/vz/template/cache/$t" ]; then
      step "already have $t"
    else
      step "downloading $t"
      pveam download local "$t" >/dev/null 2>&1 || warn "download of $t failed (retry later: pveam download local $t)"
    fi
  done
fi

# ---- services -------------------------------------------------------------
say "Ensuring PVE services are enabled"
for s in pve-cluster pvedaemon pveproxy pvestatd; do systemctl enable "$s" >/dev/null 2>&1 || true; done
sleep 5

# ---- gate 3 ---------------------------------------------------------------
gate_triple "stage 3 (Proxmox host)" \
  "proxmox-ve is installed::dpkg -s proxmox-ve >/dev/null 2>&1" \
  "core services active::systemctl is-active --quiet pve-cluster pvedaemon pveproxy pvestatd" \
  "pve-cluster is running::systemctl is-active --quiet pve-cluster" \
  "no failed units::[ \"\$(systemctl --failed --no-legend | wc -l)\" = 0 ]" \
  "iptables uses nft::iptables -V | grep -q nf_tables" \
  "pve-firewall has no errors::[ \"\$(journalctl -u pve-firewall -b --no-pager 2>/dev/null | grep -ci error)\" = 0 ]" \
  "pveproxy listens on 8006::ss -tln 2>/dev/null | grep -q ':8006'" \
  "web UI answers::curl -sk -o /dev/null https://localhost:8006" \
  "logind is not masked::[ \"\$(systemctl is-enabled systemd-logind 2>&1)\" != masked ]" \
  "bookworm apt source disabled::[ ! -f /etc/apt/sources.list.d/pxvirt-sources.list ]" \
  || die "post-install verification failed — run '$HERE/repair.sh' and re-check, or see $LOG_FILE"

state_set 4
printf '\n%sStage 3 complete.%s Web UI: %shttps://%s:8006%s\nNext: sudo %s/04-verify.sh --triple\n' \
  "$C_BOLD$C_GREEN" "$C_RESET" "$C_CYAN" "$PI_IP" "$C_RESET" "$HERE"

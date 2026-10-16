#!/bin/bash
# ---------------------------------------------------------------------------
# 03-install-proxmox.sh — Stage 3
#
#  * preseed postfix (non-interactive)
#  * install Proxmox VE + supporting packages
#  * apply the DietPi/Pi compatibility fixes:
#      - force the nft iptables backend (boot + apt hook + firewall drop-in)
#      - unmask systemd-logind
#      - disable the bogus bookworm APT source
#      - drop the unverifiable PVE::APLInfo template mirror
#  * refresh templates and pre-download arm64 ones
# ---------------------------------------------------------------------------
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=00-config.sh
. "$HERE/00-config.sh"

say() { printf '\n==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run as root (sudo $0)"
export DEBIAN_FRONTEND=noninteractive

say "Preseed postfix"
echo "postfix postfix/main_mailer_type select Local only" | debconf-set-selections
echo "postfix postfix/mailname string $(hostname)"        | debconf-set-selections

say "Install Proxmox VE ($PVE_PACKAGES)"
ok=0
for try in 1 2 3; do
  echo "  attempt $try"
  if apt-get install -y $PVE_PACKAGES; then ok=1; break; fi
  echo "  attempt $try failed — repairing (pxvirt-spdk workaround) and retrying"
  rm -f /tmp/.ifupdown2-first-install
  dpkg --configure -a || true
  apt-get -f install -y || true
  sleep 5
done
[ "$ok" = 1 ] || die "Proxmox installation failed after 3 attempts — see the output above"

say "Stand down the boot guard (network proven)"
systemctl disable net-guard.service 2>/dev/null || true
: > /var/lib/.net-guard-ran

# --- compatibility fix 1: nft iptables backend, persistent -------------------
say "Force the nft iptables backend"
install -m 755 "$HERE/pve-pi-fix.sh" /usr/local/sbin/pve-pi-fix
/usr/local/sbin/pve-pi-fix || true

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

printf 'DPkg::Post-Invoke {"/usr/local/sbin/pve-pi-fix";};\n' > /etc/apt/apt.conf.d/99pve-pi-fix

mkdir -p /etc/systemd/system/pve-firewall.service.d
cat > /etc/systemd/system/pve-firewall.service.d/10-pi-nft.conf <<'CONF'
# The Raspberry Pi kernel has no ip_tables/ebtables legacy modules.
# Clear the hardcoded ExecStartPre lines that force the legacy backend, so the
# nft backend selected by /usr/local/sbin/pve-pi-fix is kept.
[Service]
ExecStartPre=
ExecStartPre=
ExecStartPre=
CONF

systemctl daemon-reload
systemctl enable pve-pi-fix.service
/usr/local/sbin/pve-pi-fix || true
systemctl restart pve-firewall || true

# --- compatibility fix 2: unmask systemd-logind ------------------------------
say "Unmask systemd-logind (DietPi masks it)"
systemctl unmask systemd-logind || true
systemctl enable --now systemd-logind || true
echo "  systemd-logind: $(systemctl is-active systemd-logind)"

# --- compatibility fix 3: disable the bogus bookworm apt source --------------
say "Disable the bookworm APT source shipped by pve-manager"
if [ -f /etc/apt/sources.list.d/pxvirt-sources.list ]; then
  mv /etc/apt/sources.list.d/pxvirt-sources.list \
     /etc/apt/sources.list.d/pxvirt-sources.list.disabled
fi
ls -la /etc/apt/sources.list.d/

# --- compatibility fix 4: drop the unverifiable aplinfo mirror ---------------
say "Fix pveam template mirror"
if [ -f "$HERE/patch-aplinfo.py" ]; then
  python3 "$HERE/patch-aplinfo.py" || true
fi
pveam update || true

# --- templates ---------------------------------------------------------------
if [ -n "${PVE_TEMPLATES:-}" ]; then
  say "Download arm64 container templates"
  pveam available 2>/dev/null | grep arm64 || true
  for t in $PVE_TEMPLATES; do
    echo "  downloading $t"
    pveam download local "$t" || echo "  (download of $t failed — you can retry later with: pveam download local $t)"
  done
fi

say "Enable PVE services"
for s in pve-cluster pvedaemon pveproxy pvestatd; do systemctl enable "$s" >/dev/null 2>&1 || true; done
sleep 5
systemctl --no-pager --no-legend list-units 'pve*' | head -20 || true

printf '\n==> Stage 3 complete. Next: sudo %s/04-verify.sh\n' "$HERE"

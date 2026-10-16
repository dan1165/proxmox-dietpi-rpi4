#!/bin/bash
# ---------------------------------------------------------------------------
# pve-pi-fix.sh — Proxmox-on-Raspberry-Pi / DietPi compatibility shim.
#
# The Raspberry Pi kernel ships NO ip_tables/ip6tables/ebtables legacy modules,
# so the iptables alternatives MUST point at the nft backend or pve-firewall
# fails every status update with:
#   iptables-restore: unable to initialize table 'filter'
# Some packages (and pve-firewall.service's ExecStartPre lines) reselect the
# legacy backend, so re-assert nft here. Installed to /usr/local/sbin/pve-pi-fix
# and invoked at boot + after every apt operation. Idempotent and quiet unless
# it actually changes something.
# ---------------------------------------------------------------------------
set -u
changed=0
for pair in "iptables:/usr/sbin/iptables-nft" \
            "ip6tables:/usr/sbin/ip6tables-nft" \
            "ebtables:/usr/sbin/ebtables-nft"; do
  grp=${pair%%:*}
  target=${pair##*:}
  [ -x "$target" ] || continue
  cur=$(update-alternatives --query "$grp" 2>/dev/null | awk '/^Value:/{print $2}')
  if [ "$cur" != "$target" ]; then
    if update-alternatives --set "$grp" "$target" >/dev/null 2>&1; then
      changed=1
    fi
  fi
done
[ "$changed" = 1 ] && echo "pve-pi-fix: iptables alternatives re-pointed to nft backend"
exit 0

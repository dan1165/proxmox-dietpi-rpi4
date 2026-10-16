#!/bin/bash
# ---------------------------------------------------------------------------
# net-guard.sh — one-shot network rollback guard.
#
# Installed to /usr/local/sbin/net-guard.sh by 02-network.sh and enabled as
# net-guard.service. Runs once at boot, after a network change was applied.
#
# If the gateway is unreachable ~80s after boot, it restores the backed-up
# network configuration and reboots once, so a bad bridge config cannot lock
# you out of a headless Pi. It never loops: a flag file records that it ran.
# ---------------------------------------------------------------------------
LOGDIR="${WORKDIR:-/root/proxmox-setup}"
BK="$LOGDIR/backup"
FLAG=/var/lib/.net-guard-ran
GATEWAY=__GATEWAY__

exec >>"$LOGDIR/guard.log" 2>&1
echo "=== net-guard $(date -Is) ==="

if [ -e "$FLAG" ]; then
  echo "already ran once - exiting (no loop)"
  exit 0
fi
: > "$FLAG"

for i in 1 2 3 4 5 6 7 8 9 10; do
  sleep 8
  if ping -c2 -W2 "$GATEWAY" >/dev/null 2>&1 || ping -c2 -W2 1.1.1.1 >/dev/null 2>&1; then
    echo "network reachable after $((i*8))s - standing down"
    systemctl disable net-guard.service 2>/dev/null
    exit 0
  fi
done

echo "NETWORK DOWN after 80s - attempting rollback"
if [ ! -f "$BK/interfaces" ] || [ ! -d "$BK/interfaces.d" ]; then
  echo "backup missing - refusing to roll back (avoid making it worse)"
  exit 1
fi

cp -a "$BK/interfaces" /etc/network/interfaces
rm -rf /etc/network/interfaces.d
cp -a "$BK/interfaces.d" /etc/network/interfaces.d
if [ -f "$LOGDIR/disabled/eth0.conf" ] && [ ! -f /etc/network/interfaces.d/eth0.conf ]; then
  cp -a "$LOGDIR/disabled/eth0.conf" /etc/network/interfaces.d/eth0.conf
fi

echo "rollback complete - rebooting"
systemctl disable net-guard.service 2>/dev/null
sync
sleep 2
systemctl reboot

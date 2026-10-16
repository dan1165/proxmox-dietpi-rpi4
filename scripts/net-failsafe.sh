#!/bin/bash
# ---------------------------------------------------------------------------
# net-failsafe.sh — short-lived watchdog used around the ifupdown -> ifupdown2
# package transition (dpkg briefly stops networking.service while swapping the
# package). If the gateway stays unreachable for ~5 minutes, reboot: boot
# brings the interfaces up again cleanly via networking.service.
#
# Armed (detached) by 01-prepare.sh. One-shot; never loops.
# ---------------------------------------------------------------------------
LOGDIR="${WORKDIR:-/root/proxmox-setup}"
FLAG=/var/lib/.net-failsafe-ran
GATEWAY=__GATEWAY__

exec >>"$LOGDIR/failsafe.log" 2>&1
echo "=== net-failsafe $(date -Is) ==="

if [ -e "$FLAG" ]; then
  echo "already ran - exiting"
  exit 0
fi
: > "$FLAG"

for i in $(seq 1 20); do
  sleep 15
  if ping -c2 -W2 "$GATEWAY" >/dev/null 2>&1 || ping -c2 -W2 1.1.1.1 >/dev/null 2>&1; then
    echo "network OK after $((i*15))s - exiting"
    exit 0
  fi
done

echo "network down for 300s -> rebooting to recover"
sync
systemctl reboot

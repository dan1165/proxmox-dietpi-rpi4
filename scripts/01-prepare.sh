#!/bin/bash
# ---------------------------------------------------------------------------
# 01-prepare.sh — Stage 1
#
#  * sanity checks (arch, OS codename, wired NIC)
#  * add the PXVirt ARM64 Proxmox repository
#  * back up everything we are about to touch
#  * point the hostname at the real IP in /etc/hosts
#  * arm a short-lived fail-safe
#  * replace ifupdown with ifupdown2 (+ bridge-utils)
#
# Safe to re-run (idempotent).
# ---------------------------------------------------------------------------
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=00-config.sh
. "$HERE/00-config.sh"

say() { printf '\n==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run as root (sudo $0)"

say "Sanity checks"
CODENAME=$(. /etc/os-release && echo "$VERSION_CODENAME")
ARCH=$(dpkg --print-architecture)
echo "  OS codename : $CODENAME"
echo "  architecture: $ARCH"
[ "$ARCH" = "arm64" ] || die "this guide requires a 64-bit (arm64) system; got $ARCH"
[ -d "/sys/class/net/$NIC" ] || die "interface '$NIC' not found (see: ip -br link)"
case "$NIC" in
  wl*|wlan*) die "interface '$NIC' looks wireless — bridging Wi-Fi is not supported, use Ethernet" ;;
esac
echo "  NIC         : $NIC (wired, OK)"
echo "  bridge      : $BRIDGE"
echo "  address     : $PI_IP/$PI_CIDR via $PI_GATEWAY"

mkdir -p "$WORKDIR" "$WORKDIR/backup" "$WORKDIR/disabled"

say "Backups"
cp -a /etc/network/interfaces   "$WORKDIR/backup/interfaces"   2>/dev/null || true
rm -rf "$WORKDIR/backup/interfaces.d"
cp -a /etc/network/interfaces.d "$WORKDIR/backup/interfaces.d" 2>/dev/null || true
cp -a /etc/hosts                "$WORKDIR/backup/hosts"
cp -a /etc/resolv.conf          "$WORKDIR/backup/resolv.conf"  2>/dev/null || true
cp -a /etc/apt/sources.list.d   "$WORKDIR/backup/sources.list.d" 2>/dev/null || true
ls -laR "$WORKDIR/backup"

say "Base packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y curl

say "Add PXVirt ARM64 repository"
curl -fsSL https://mirrors.lierfang.com/pxcloud/lierfang.gpg -o /usr/share/keyrings/lierfang.gpg
echo "deb [arch=arm64 signed-by=/usr/share/keyrings/lierfang.gpg] https://mirrors.lierfang.com/pxcloud/pxvirt $CODENAME main" \
  > /etc/apt/sources.list.d/pveport.list
cat /etc/apt/sources.list.d/pveport.list
apt-get update
apt-cache policy proxmox-ve | sed -n '1,3p'

say "Fix /etc/hosts (hostname -> real IP)"
cat > /etc/hosts <<EOF
127.0.0.1       localhost
$PI_IP      $PI_HOSTNAME

# The following lines are desirable for IPv6 capable hosts
::1     localhost ip6-localhost ip6-loopback
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
EOF
cat /etc/hosts
echo "  hostname --ip-address -> $(hostname --ip-address)"

say "Arm fail-safe (guards the ifupdown -> ifupdown2 swap)"
sed "s|__GATEWAY__|$PI_GATEWAY|g" "$HERE/net-failsafe.sh" > "$WORKDIR/net-failsafe.sh"
install -m 755 "$WORKDIR/net-failsafe.sh" /usr/local/sbin/net-failsafe.sh
rm -f /var/lib/.net-failsafe-ran
setsid nohup /usr/local/sbin/net-failsafe.sh >/dev/null 2>&1 &
echo "  fail-safe armed (pid $!)"

say "Install ifupdown2 + bridge-utils"
rm -f /tmp/.ifupdown2-first-install
if ! apt-get install -y ifupdown2 bridge-utils; then
  echo "  first attempt failed; applying the .ifupdown2-first-install workaround"
  rm -f /tmp/.ifupdown2-first-install
  dpkg --configure -a
  apt-get install -y ifupdown2 bridge-utils
fi
dpkg -l ifupdown ifupdown2 2>&1 | grep -E '^ii|^un' || true
command -v ifup && ifup --version 2>&1 | head -2

printf '\n==> Stage 1 complete. Next: sudo %s/02-network.sh\n' "$HERE"

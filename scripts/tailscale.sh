#!/bin/bash
# ---------------------------------------------------------------------------
# tailscale.sh — install Tailscale and run it as a subnet router for $PI_SUBNET.
#
#   ./tailscale.sh             install + configure (asks to confirm)
#   ./tailscale.sh --check      report only
#
# Requires an interactive login (prints an auth URL) unless already logged in.
# ---------------------------------------------------------------------------
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"
# shellcheck source=00-config.sh
[ -f "$HERE/00-config.sh" ] && . "$HERE/00-config.sh"
require_root

CHECK=0
AUTO=0
for a in "$@"; do
  case "$a" in
    --check) CHECK=1 ;;
    --auto)  AUTO=1 ;;
  esac
done
[ "$AUTO" = 1 ] && { export ASSUME_YES=1 FORCE=1; }
SUBNET="${PI_SUBNET:-}"
[ -n "$SUBNET" ] || die "PI_SUBNET is empty — set it in 00-config.sh (e.g. 192.168.0.0/24)"
LOG="$WORKDIR/tailscale.log"
mkdir -p "$WORKDIR"; : > "$LOG"

advertised() { tailscale debug netmap 2>/dev/null | python3 -c 'import sys,json;print((json.load(sys.stdin).get("SelfNode",{}).get("Hostinfo") or {}).get("RoutableIPs"))' 2>/dev/null; }
approved() {
  tailscale debug netmap 2>/dev/null | python3 -c '
import sys,json
d=json.load(sys.stdin); sn=d.get("SelfNode") or {}
a=[x for x in (sn.get("AllowedIPs") or []) if not x.startswith(("100.","fd7a"))]
print(a or "(none)")' 2>/dev/null
}

say "Tailscale subnet router → $SUBNET"

# ---- 1. install -----------------------------------------------------------
if have tailscale; then
  ok "tailscale already installed ($(tailscale version 2>/dev/null | head -1))"
else
  info "tailscale is not installed"
  if [ "$CHECK" = 1 ]; then info "--check requested; would install via tailscale.com/install.sh"; exit 0; fi
  confirm_yes "Install Tailscale from the official repository?" || die "cancelled"
  say "Gate 2/3 — installing"
  curl -fsSL https://tailscale.com/install.sh | sh 2>&1 | tail -5
  have tailscale || die "installation failed"
  ok "installed $(tailscale version 2>/dev/null | head -1)"
fi
systemctl enable --now tailscaled >/dev/null 2>&1 || true

# ---- 2. forwarding + tuning + ordering ------------------------------------
if [ "$CHECK" = 0 ]; then
  say "Applying host prerequisites"
  cat > /etc/sysctl.d/99-tailscale.conf <<'CONF'
# Subnet-router requirements for Tailscale
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
net.ipv4.conf.all.src_valid_mark = 1
CONF
  sysctl --system >/dev/null 2>&1 || true
  step "ip_forward=$(cat /proc/sys/net/ipv4/ip_forward)"

  if have ethtool && [ -d "/sys/class/net/$NIC" ]; then
    ethtool -K "$NIC" rx-udp-gro-forwarding on rx-gro-list off 2>/dev/null || true
    cat > /etc/systemd/system/tailscale-ethtool.service <<UNIT
[Unit]
Description=Tailscale UDP GRO forwarding tuning for subnet router
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/ethtool -K $NIC rx-udp-gro-forwarding on rx-gro-list off

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
    systemctl enable --now tailscale-ethtool.service >/dev/null 2>&1 || true
    step "UDP GRO tuning applied to $NIC (persistent)"
  fi

  mkdir -p /etc/systemd/system/tailscaled.service.d
  cat > /etc/systemd/system/tailscaled.service.d/10-after-networking.conf <<'CONF'
[Unit]
After=networking.service
Wants=networking.service
CONF
  systemctl daemon-reload
  step "tailscaled ordered after networking.service"
fi

# ---- 3. bring up ----------------------------------------------------------
state=$(tailscale status --json 2>/dev/null | python3 -c 'import sys,json;print(json.load(sys.stdin).get("BackendState","?"))' 2>/dev/null)
if [ "$state" = "Running" ]; then
  ok "already logged in"
else
  if [ "$CHECK" = 1 ]; then info "--check: would run 'tailscale up --advertise-routes=$SUBNET'"; exit 0; fi
  if [ "$AUTO" = 1 ]; then
    [ -n "${TAILSCALE_AUTHKEY:-}" ] || die "--auto needs TAILSCALE_AUTHKEY (put it in scripts/00-config.local.sh)"
    say "Authenticating with TAILSCALE_AUTHKEY (unattended)"
    tailscale up --advertise-routes="$SUBNET" --accept-dns=false \
      --auth-key="$TAILSCALE_AUTHKEY" 2>&1 | tail -5
    sleep 5
  else
    confirm_yes "Authenticate this device as a subnet router for $SUBNET?" || die "cancelled"
    say "Gate 2/3 — starting tailscale"
    setsid nohup tailscale up --advertise-routes="$SUBNET" --accept-dns=false --timeout=0 >"$LOG" 2>&1 &
    sleep 10
    url=$(grep -oE 'https://login\.tailscale\.com/[a-z]/[A-Za-z0-9]+' "$LOG" | head -1)
    if [ -n "$url" ]; then
      printf '\n%s  ACTION REQUIRED — open this URL and approve the device:%s\n\n    %s%s%s\n\n' \
        "$C_BOLD$C_YELLOW" "$C_RESET" "$C_BOLD$C_CYAN" "$url" "$C_RESET"
      info "waiting up to 5 minutes for authentication…"
    fi
  fi

  # common: wait for the backend to come up
  for _ in $(seq 1 30); do
    state=$(tailscale status --json 2>/dev/null | python3 -c 'import sys,json;print(json.load(sys.stdin).get("BackendState","?"))' 2>/dev/null)
    [ "$state" = "Running" ] && break
    sleep 10
  done
fi

# ---- gate 3: triple verification ------------------------------------------
if [ "$state" = "Running" ]; then
  gate_triple "tailscale" \
    "backend is Running::[ \"\$(tailscale status --json 2>/dev/null | python3 -c 'import sys,json;print(json.load(sys.stdin).get(\"BackendState\"))')\" = Running ]" \
    "has a tailnet address::tailscale ip -4 | grep -q '^100\.'" \
    "advertising $SUBNET::tailscale debug netmap 2>/dev/null | grep -q '${SUBNET%/*}'"
  printf '\n  advertised: %s\n  approved  : %s\n' "$(advertised)" "$(approved)"
  if ! approved | grep -q "${SUBNET%/*}"; then
    printf '\n%s  The route is advertised but NOT yet enabled.%s Approve it at:\n' "$C_YELLOW$C_BOLD" "$C_RESET"
    printf '    https://login.tailscale.com/admin/machines  →  this node  →  ⋯  →  Edit route settings\n\n'
  else
    ok "route $SUBNET is enabled"
  fi
else
  warn "tailscale is not logged in yet (state: ${state:-unknown})"
fi

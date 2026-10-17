#!/bin/bash
# ---------------------------------------------------------------------------
# 00-config.sh — edit this, then run ./install.sh (or the numbered scripts).
# Source, don't execute:  . ./00-config.sh
# ---------------------------------------------------------------------------

# Hostname of the Pi (must match what `hostname` prints).
: "${PI_HOSTNAME:=DietPi}"

# The Pi's static LAN address. This is the address the Proxmox web UI uses.
: "${PI_IP:=192.168.0.15}"

# Prefix length / netmask.
: "${PI_CIDR:=24}"

# Your router / default gateway.
: "${PI_GATEWAY:=192.168.0.1}"

# DNS resolvers written into the bridge stanza.
: "${PI_DNS:=1.1.1.1 1.0.0.1}"

# Physical network interface (must be wired; do NOT use wlan0).
: "${NIC:=eth0}"

# Name of the Proxmox bridge to create.
: "${BRIDGE:=vmbr0}"

# LAN subnet to advertise if you use the Tailscale subnet-router helper.
: "${PI_SUBNET:=192.168.0.0/24}"

# Where this tooling keeps backups, logs and helper scripts on the Pi.
: "${WORKDIR:=/root/proxmox-setup}"

# Safety: 1 = require the three-gate apply protocol (preflight + typed
# confirmation + triple verification). Do not disable unless you mean it.
: "${REQUIRE_TRIPLE:=1}"

# --- unattended install (autoinstall.sh) -----------------------------------
# Install a systemd timer that re-applies the compatibility fixes hourly.
: "${AUTO_INSTALL_HEAL_TIMER:=1}"
# Also set up the Tailscale subnet router during an unattended install.
: "${AUTO_INSTALL_TAILSCALE:=0}"
# Auth key for unattended Tailscale (tskey-auth-...). SECRET — keep it in
# scripts/00-config.local.sh (gitignored), never in this file.
: "${TAILSCALE_AUTHKEY:=}"
# How many times a failing stage is retried across reboots before giving up.
: "${AUTO_MAX_ATTEMPTS:=3}"

# ---------------------------------------------------------------------------
# Optional local overrides — created by the TUI "Edit configuration" screen.
# Not tracked by git, so it survives `git pull` and keeps the repo clean.
# Any variable set here wins over the defaults above.
# ---------------------------------------------------------------------------
_cfg_self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/00-config.local.sh"
if [ -f "$_cfg_self" ]; then
  # shellcheck source=/dev/null
  . "$_cfg_self"
fi
unset _cfg_self

# Proxmox packages to install.
: "${PVE_PACKAGES:=proxmox-ve postfix open-iscsi pve-edk2-firmware-aarch64}"

# arm64 LXC templates to pre-download (space-separated). "" to skip.
: "${PVE_TEMPLATES:=debian-13-standard_13.6-1_arm64.tar.zst alpine-3.24-default_20260803_arm64.tar.xz}"

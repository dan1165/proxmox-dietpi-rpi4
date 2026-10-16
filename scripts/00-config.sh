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

# Proxmox packages to install.
: "${PVE_PACKAGES:=proxmox-ve postfix open-iscsi pve-edk2-firmware-aarch64}"

# arm64 LXC templates to pre-download (space-separated). "" to skip.
: "${PVE_TEMPLATES:=debian-13-standard_13.6-1_arm64.tar.zst alpine-3.24-default_20260803_arm64.tar.xz}"

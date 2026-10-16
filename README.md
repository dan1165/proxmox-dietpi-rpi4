# Proxmox VE 9 on a Raspberry Pi 4 running DietPi

> A complete, tested, copy‑paste walkthrough for turning a Raspberry Pi 4 with **DietPi** (Debian 13 *trixie*, arm64) into a **Proxmox VE 9** virtualization host — including every DietPi/Raspberry‑Pi‑kernel incompatibility you will hit, why it happens, and how to fix it permanently.

![Platform](https://img.shields.io/badge/platform-Raspberry%20Pi%204-red)
![OS](https://img.shields.io/badge/DietPi-Debian%2013%20trixie-blue)
![Proxmox](https://img.shields.io/badge/Proxmox%20VE-9.0-orange)
![Arch](https://img.shields.io/badge/arch-arm64-lightgrey)
![License](https://img.shields.io/badge/license-MIT-green)

---

## Table of contents

- [What this is](#what-this-is)
- [Why not just use Raspberry Pi OS Lite?](#why-not-just-use-raspberry-pi-os-lite)
- [What you get](#what-you-get)
- [Requirements](#requirements)
- [The five things that will break](#the-five-things-that-will-break)
- [Quick start](#quick-start)
- [Interactive menu (TUI)](#interactive-menu-tui)
- [Configuration](#configuration)
- [Safety model — at a glance](#safety-model--at-a-glance)
- [Repository layout](#repository-layout)
- [Detailed walkthrough](#detailed-walkthrough)
  - [Step 0 — Prep the Pi](#step-0--prep-the-pi)
  - [Step 1 — Add the PXVirt ARM64 repository](#step-1--add-the-pxvirt-arm64-repository)
  - [Step 2 — Fix `/etc/hosts`](#step-2--fix-etchosts)
  - [Step 3 — Replace `ifupdown` with `ifupdown2`](#step-3--replace-ifupdown-with-ifupdown2)
  - [Step 4 — Rebuild networking around a bridge](#step-4--rebuild-networking-around-a-bridge)
  - [Step 5 — Reboot (with an automatic rollback guard)](#step-5--reboot-with-an-automatic-rollback-guard)
  - [Step 6 — Install Proxmox VE](#step-6--install-proxmox-ve)
  - [Step 7 — DietPi compatibility fixes](#step-7--dietpi-compatibility-fixes)
  - [Step 8 — Verify](#step-8--verify)
- [Using Proxmox](#using-proxmox)
- [Troubleshooting](#troubleshooting)
- [Maintenance & upgrades](#maintenance--upgrades)
- [Rollback / uninstall](#rollback--uninstall)
- [Security notes](#security-notes)
- [FAQ](#faq)
- [Credits](#credits)
- [License](#license)

---

## What this is

Proxmox VE — the open‑source virtualization platform — now supports ARM64, but **the Proxmox team ships no ARM64 builds**. The ARM port is maintained by the third‑party **PXVirt** fork ([`jiangcuo/pxvirt`](https://github.com/jiangcuo/pxvirt)), which keeps feature parity with upstream Proxmox VE and adds Raspberry‑Pi‑friendly optimisations.

This guide installs **Proxmox VE 9** on a **Raspberry Pi 4B (8 GB)** running **DietPi**, and documents the non‑obvious parts:

- DietPi is **not** Raspberry Pi OS Lite, and Proxmox's assumptions differ.
- The Raspberry Pi kernel is **not** a normal Debian kernel — some modules simply do not exist.
- A Proxmox host wants to **own the network** (it replaces your interface config with a bridge). Getting that wrong on a headless box locks you out.

Everything here was run end‑to‑end on real hardware, rebooted three times to confirm persistence, and verified by booting an actual LXC container that pulled a DHCP lease through the new bridge.

**Result:** `https://<pi-ip>:8006` serves the Proxmox web UI, LXC containers and arm64 VMs work, and the host survives `apt upgrade` without re‑breaking.

---

## Why not just use Raspberry Pi OS Lite?

You can — and upstream tutorials (see [Credits](#credits)) target it. But if you already run **DietPi** (lighter, great tooling, excellent for headless servers), you will hit **DietPi‑specific** friction that no Raspberry Pi OS guide mentions:

| DietPi default | What it breaks with Proxmox |
|---|---|
| **masks `systemd-logind`** | `pam_systemd` errors on every login; non‑standard vs. Debian/Proxmox expectations |
| **`iptables` alternatives** | irrelevant on its own, but combined with Proxmox's firewall unit it's fatal (see below) |
| **manages `eth0` via `/etc/network/interfaces.d/`** | must be reconciled with Proxmox's single‑file bridge model |
| **ships `nftables` by default** | correct, but Proxmox's `pve-firewall.service` **forces the legacy backend** |
| **no `cloud-init`** | (a *good* thing — one less thing to disable) |

None of these are blockers. All of them need handling, and this guide handles them.

---

## What you get

```
┌─────────────────────────────────────────────────────────────┐
│  Proxmox VE 9.0.0  (pve-manager 9.0.10-2, PXVirt arm64)     │
│  Kernel: 6.18.50+rpt-rpi-v8  (the Raspberry Pi kernel — kept)│
├─────────────────────────────────────────────────────────────┤
│  Web UI   https://<pi-ip>:8006                              │
│  LXC      pct create / pct enter        ← works, tested     │
│  VMs      qm create (arm64 UEFI guests)                     │
│  Storage  local (dir) → /var/lib/vz                         │
│  Templates  debian-13 arm64, alpine arm64 (pre-downloaded)  │
└─────────────────────────────────────────────────────────────┘
              │
        vmbr0 (bridge, holds <pi-ip>/24)
              │
        eth0  (physical NIC, no IP of its own)
              │
          your LAN  →  router / gateway
```

---

## Requirements

- **Raspberry Pi 4** (4 GB minimum, 8 GB recommended). Pi 5 works too. A Pi 3 is too slow to be pleasant.
- **64‑bit DietPi** on **Debian 13 (trixie)** arm64. Check with:
  ```bash
  grep VERSION_CODENAME /etc/os-release   # → trixie
  dpkg --print-architecture               # → arm64
  ```
  On Bookworm you will get Proxmox VE 8 instead of 9; the procedure is otherwise identical.
- **Wired Ethernet (`eth0`)**. This guide bridges `eth0`. **Do not do this over Wi‑Fi** — bridging a Wi‑Fi interface is not supported and you will lose the network.
- **A static IP** (or a DHCP reservation) for the Pi. DietPi's `dietpi-network` already produces a static config; we keep the same address.
- **SSH access** as `root` (or a user that can `sudo`), plus — see the warning below — a monitor/keyboard or a second SD card as a **parachute**.
- ~2 GB free disk space for the install plus templates.

> [!WARNING]
> A Proxmox install fundamentally **takes over the machine**: it replaces your network stack with a bridge and installs a large suite of daemons. On a headless Pi, a bad bridge config means physical recovery. This guide includes an **automatic rollback guard** so a failure reverts itself and reboots — but read [Security notes](#security-notes) and keep a parachute.

---

## The five things that will break

Read this once. It's the section that saves you hours.

### 1. The Pi kernel has no `ip_tables` module — legacy iptables can never work

```console
$ modprobe ip_tables
modprobe: FATAL: Module ip_tables not found in directory /lib/modules/6.18.50+rpt-rpi-v8
```

The Raspberry Pi kernel is built around **nftables** and does **not** include the legacy `ip_tables`/`ip6tables`/`ebtables` modules. Only the **nft** iptables backend works.

**And** — this is the killer — the PXVirt/Proxmox build of `pve-firewall.service` ships:

```ini
ExecStartPre=-/usr/bin/update-alternatives --set ebtables  /usr/sbin/ebtables-legacy
ExecStartPre=-/usr/bin/update-alternatives --set iptables  /usr/sbin/iptables-legacy
ExecStartPre=-/usr/bin/update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy
```

So **every time the firewall starts, it forces the broken legacy backend**, and then fails:

```
pve-firewall[812]: status update error: iptables_restore_cmdlist: Try `iptables-restore -h' ...
```

**Fix:** override those lines with a systemd drop‑in, point the alternatives at nft, and add an `apt` hook so upgrades can't undo it. ([Step 7](#step-7--dietpi-compatibility-fixes))

### 2. `pve-manager` installs a *bookworm* APT source on a *trixie* system

The package ships `/etc/apt/sources.list.d/pxvirt-sources.list`:

```
deb https://download.lierfang.com/pxcloud/pxvirt bookworm main
```

That is wrong for trixie and can pull mismatched builds on a future upgrade. **Fix:** disable it and rely on the correct trixie repo you add in [Step 1](#step-1--add-the-pxvirt-arm64-repository).

### 3. `pveam update` fails signature verification

The PXVirt template mirror (`mirrors.lierfang.com`) serves an `aplinfo.dat` signed by a key that is **not** in `pve-manager`'s `trustedkeys.gpg`, so template listing exits with an error. **Fix:** drop that mirror entry; the official Proxmox mirror already ships the arm64 templates you need.

### 4. DietPi masks `systemd-logind`

DietPi replaces `/etc/systemd/system/systemd-logind.service` with a symlink to `/dev/null`. Because `dbus-org.freedesktop.login1.service` points at it, every SSH login logs:

```
sshd-session: pam_systemd(sshd:session): Failed to create session: Unit
dbus-org.freedesktop.login1.service failed to load properly ... File exists
```

Harmless, but noisy and non‑standard for a Debian/Proxmox host. **Fix:** unmask it.

### 5. Proxmox wants to own `/etc/network/interfaces`

DietPi configures the NIC through a drop‑in (`/etc/network/interfaces.d/eth0.conf`) that the main file sources. Proxmox expects a single authoritative file containing a bridge. If you leave both, you get double‑configuration and a broken boot. **Fix:** move DietPi's drop‑in aside and write one explicit file ([Step 4](#step-4--rebuild-networking-around-a-bridge)).

---

## Quick start

> [!NOTE]
> Every stage enforces a **three-gate apply protocol** (preflight → typed
> confirmation → triple verification). Nothing changes without it. See
> [`docs/safety.md`](docs/safety.md).

```bash
git clone https://github.com/dan1165/proxmox-dietpi-rpi4.git
cd proxmox-dietpi-rpi4/scripts

# 1. Review and edit your network details
$EDITOR 00-config.sh

# 2. Interactive menu (recommended)
sudo ./menu.sh

#   … or drive it directly:
sudo ./install.sh          # runs the next stage; re-run after the reboot
```

The rest of this document explains and reproduces every step manually, so you can do it by hand or debug the script.

---

## Interactive menu (TUI)

```console
$ sudo ./menu.sh

  proxmox-dietpi-rpi4  v1.2.0
  ────────────────────────────────────────────────────────────
  host    DietPi   192.168.0.15
  net     eth0 → vmbr0   up (192.168.0.15)
  proxmox installed 9.0.10-2
  tailsc. present (Running)
  stage   4 of 4 (inferred)
  ────────────────────────────────────────────────────────────
  docs: README.md · docs/safety.md

  ▸ Install / finish setup (guided)
    Preflight safety checks (read-only)
    Verify installation (3× independent)
    Edit configuration
    Show status (read-only)
    Repair known issues
    Tailscale subnet router
    Rollback / uninstall
    Help

  ↑/↓ or k/j move · Enter select · 1-9 jump · q quit
```

| Menu item | Runs | Changes anything? |
|---|---|---|
| Install / finish setup | `install.sh` (gated stages 1–4) | yes, after the gates |
| Preflight safety checks | `preflight.sh` | **no** — read-only |
| Verify installation | `04-verify.sh` (3 independent passes) | **no** (except `--smoke`) |
| **Edit configuration** | `config.sh` | writes `00-config.local.sh` |
| Show status | `status.sh` | **no** — read-only |
| Repair known issues | `repair.sh` (idempotent) | yes |
| Tailscale subnet router | `tailscale.sh` | yes |
| Rollback / uninstall | `rollback.sh` (triple-confirmed) | yes |
| Help | inline help | no |

Non-interactive equivalents:

```bash
sudo ./menu.sh --action status
sudo ./menu.sh --action verify
sudo ./menu.sh --action preflight
sudo ./preflight.sh --strict       # warnings become failures
sudo ./repair.sh --check           # report only, change nothing
sudo ./rollback.sh --list          # show what rollback would restore
```

On a non-TTY (CI, piped) the menu degrades gracefully to a numbered prompt.

---

## Configuration

All settings live in **[`scripts/00-config.sh`](scripts/00-config.sh)** — set them
there, or edit them from the menu (**Edit configuration**), which validates every
value before accepting it.

```console
$ sudo ./config.sh --show

Effective configuration  (with overrides from 00-config.local.sh)
────────────────────────────────────────────────────────────
    PI_HOSTNAME     DietPi
  * PI_IP           192.168.0.21
    PI_CIDR         24
    PI_GATEWAY      192.168.0.1
    PI_DNS          1.1.1.1 1.0.0.1
    NIC             eth0
    BRIDGE          vmbr0
    PI_SUBNET       192.168.0.0/24
    WORKDIR         /root/proxmox-setup
    PVE_PACKAGES    proxmox-ve postfix open-iscsi pve-edk2-firmware-aarch64
    PVE_TEMPLATES   debian-13-standard_13.6-1_arm64.tar.zst alpine-3.24-default_20260803_arm64.tar.xz
────────────────────────────────────────────────────────────
  * = overridden in 00-config.local.sh
```

| Key | Meaning |
|---|---|
| `PI_HOSTNAME` | hostname (must match `hostname`) |
| `PI_IP` / `PI_CIDR` | static address for the Pi / the Proxmox bridge |
| `PI_GATEWAY` | router |
| `PI_DNS` | resolvers (space-separated) |
| `NIC` | physical **wired** interface to enslave |
| `BRIDGE` | Proxmox bridge name |
| `PI_SUBNET` | LAN subnet to advertise over Tailscale |
| `WORKDIR` | where backups/logs/helpers live on the Pi |
| `PVE_PACKAGES` / `PVE_TEMPLATES` | what to install / pre-download |

**How edits are stored.** The editor never rewrites `00-config.sh`. It writes
only the values you changed to **`scripts/00-config.local.sh`**, which is
gitignored and sourced *after* `00-config.sh`, so your settings win and survive
`git pull`. Delete it (or **Reset ALL values to defaults**) to go back.

Validation is built in — bad IPv4, bad CIDR, bad hostname, non-absolute paths and
invalid interface names are rejected with a reason, and interface/subnet changes
add a reminder about the Tailscale route:

```console
$ ./config.sh --set PI_IP=999.1.1.1
  [FAIL] PI_IP: not a valid IPv4 address
$ ./config.sh --set PI_SUBNET=192.168.0.0/99
  [FAIL] PI_SUBNET: not a valid CIDR (e.g. 192.168.0.0/24)
```

Also available: `--detect` (fill values from the running system —
address, prefix, gateway, DNS, NIC beneath a bridge, and the derived subnet) and
`--unset KEY`.

---

## Safety model — at a glance

**Gate 1 · preflight** — automated, read-only checks: arch/OS, wired NIC, gateway
+ internet + DNS + mirror reachability, disk/RAM, recovery-method confirmation,
conflicting network managers, existing bridge/drop-ins, `/etc/hosts` correctness,
and the "no legacy `ip_tables`" reality check. Blockers abort; warnings must be
acknowledged.

**Gate 2 · confirmation** — you type an exact phrase per stage
(`PREPARE`, `APPLY-NETWORK`, `INSTALL-PROXMOX`, `RESTORE-NETWORK`,
`PURGE-PROXMOX`). Stage 2 also runs an abortable countdown before rebooting.

**Gate 3 · triple verification** — every applied change is checked three
independent ways: **A** systemd state, **B** raw processes/ports/HTTP,
**C** the PVE API and on-disk data. Any failure aborts the run.

Reliability extras: an flock run-lock, an `ERR` trap that prints the failing line
plus the last 20 log lines, atomic config writes (`tmp` + `mv`), timestamped
backups, idempotent stages, resumable state across the reboot, fail-closed
confirmations (non-interactive = *no*), a boot-time **rollback guard** that can
lock you out of nothing, and an `apt` hook that re-asserts the nft backend so
upgrades can't silently break the firewall.

📖 Full detail: [`docs/safety.md`](docs/safety.md).

---

## Repository layout

```
proxmox-dietpi-rpi4/
├── README.md                     this guide
├── CHANGELOG.md
├── LICENSE                       MIT
├── docs/
│   ├── safety.md                 the three-gate protocol, checks, recovery ladder
│   └── troubleshooting.md        deep diagnostics + locked-out-Pi recovery
└── scripts/
    ├── 00-config.sh              ★ edit this first (IP, gateway, NIC, bridge, subnet)
    ├── 00-config.local.sh        your overrides — gitignored, created by config.sh
    ├── menu.sh                   interactive TUI
    ├── config.sh                 view / edit configuration (TUI + CLI, validated)
    ├── install.sh                guided, resumable driver (stages 1–4)
    ├── preflight.sh              gate 1 — read-only safety checks
    ├── 01-prepare.sh             gate 2+3 — repo, backups, hosts, ifupdown2
    ├── 02-network.sh             gate 2+3 — bridge + rollback guard + reboot
    ├── 03-install-proxmox.sh     gate 2+3 — install + compat fixes + templates
    ├── 04-verify.sh              gate 3 — three independent verification passes
    ├── repair.sh                 re-apply every known fix, idempotently
    ├── rollback.sh               triple-confirmed revert / uninstall
    ├── status.sh                 read-only overview (host/net/Proxmox/Tailscale)
    ├── tailscale.sh              install + configure the subnet router
    ├── pve-pi-fix.sh             force the nft iptables backend
    ├── net-guard.sh              boot-time network rollback guard
    ├── net-failsafe.sh           guards the ifupdown→ifupdown2 swap
    ├── patch-aplinfo.py          drop the unverifiable template mirror
    └── lib/common.sh             logging, gates, confirmations, TUI primitives
```

Every script is `bash -n`-clean and safe to read before you run it.

---

## Detailed walkthrough

Throughout, replace these with **your** values:

| Variable | Meaning | Example |
|---|---|---|
| `<pi-ip>` | the Pi's static IP | `192.168.0.15` |
| `<gateway>` | your router | `192.168.0.1` |
| `<hostname>` | the Pi's hostname | `DietPi` |
| `<nic>` | physical interface | `eth0` |
| `<bridge>` | Proxmox bridge name | `vmbr0` |

Everything below is run **on the Pi** as `root`.

---

### Step 0 — Prep the Pi

```bash
apt update
apt upgrade -y
apt install -y curl
```

Confirm the essentials and note them down:

```bash
cat /proc/device-tree/model; echo          # → Raspberry Pi 4 Model B Rev 1.5
grep -E 'VERSION_CODENAME|VERSION_ID' /etc/os-release
dpkg --print-architecture                  # → arm64
ip -br addr                                # note your IP
ip route | grep default                    # note your gateway
```

> **Why curl?** It fetches the repository GPG key in the next step.

---

### Step 1 — Add the PXVirt ARM64 repository

Proxmox's own repos have no arm64 packages. PXVirt publishes an arm64 build of Proxmox VE that tracks upstream versions.

**1.1 — Import the repository key:**

```bash
curl -fsSL https://mirrors.lierfang.com/pxcloud/lierfang.gpg \
  -o /usr/share/keyrings/lierfang.gpg
```

**1.2 — Add the repo, using your OS codename:**

```bash
. /etc/os-release
echo "deb [arch=arm64 signed-by=/usr/share/keyrings/lierfang.gpg] \
https://mirrors.lierfang.com/pxcloud/pxvirt $VERSION_CODENAME main" \
  > /etc/apt/sources.list.d/pveport.list
```

That writes `.../pveport.list`:

```
deb [arch=arm64 signed-by=/usr/share/keyrings/lierfang.gpg] https://mirrors.lierfang.com/pxcloud/pxvirt trixie main
```

**1.3 — Refresh and confirm the packages are visible:**

```bash
apt update
apt-cache policy proxmox-ve pve-manager pve-edk2-firmware-aarch64
```

Expected:

```
proxmox-ve:      Candidate: 9.0.0
pve-manager:     Candidate: 9.0.10-2
pve-edk2-firmware-aarch64: Candidate: 4.2025.02-3
```

> On Bookworm the candidate will be Proxmox VE **8**. That's expected.

---

### Step 2 — Fix `/etc/hosts`

Proxmox requires the node's hostname to resolve to its **real** IP address, not `127.0.1.1`. A wrong `/etc/hosts` is the number‑one cause of "Proxmox boots but the web UI never appears".

DietPi ships:

```
127.0.0.1 localhost
127.0.1.1 DietPi
```

Replace the `127.0.1.1` line with the real address:

```bash
HN=$(hostname)
cat > /etc/hosts <<EOF
127.0.0.1       localhost
<pi-ip>      $HN

# The following lines are desirable for IPv6 capable hosts
::1     localhost ip6-localhost ip6-loopback
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
EOF
```

Verify:

```bash
hostname --ip-address     # → <pi-ip>
getent hosts "$(hostname)"  # → <pi-ip>  DietPi
```

> **DietPi bonus:** DietPi does **not** ship cloud‑init, so the usual "comment out `update_etc_hosts` in `/etc/cloud/cloud.cfg`" step that Raspberry Pi OS guides require is **unnecessary here**. (If you later see your `/etc/hosts` revert on boot, that's cloud‑init and you should disable it.)

---

### Step 3 — Replace `ifupdown` with `ifupdown2`

Proxmox manages bridges with **`ifupdown2`**, which knows how to create and enslave bridge interfaces natively. Classic `ifupdown` cannot do this without extra scripts.

```bash
apt install -y ifupdown2 bridge-utils
```

`ifupdown2` `Conflicts: ifupdown` and `Provides: ifupdown`, so this **removes** `ifupdown` automatically and takes over `networking.service`. Expect:

```
The following packages will be REMOVED:
  ifupdown
```

> **If you see `error: Another instance of this program is already running.`** delete the stale flag file and retry:
> ```bash
> rm -f /tmp/.ifupdown2-first-install
> apt install -y ifupdown2
> ```
> This is a known `ifupdown2` first‑install quirk.

> **Heads‑up:** swapping the package briefly stops `networking.service` while dpkg replaces it. Your SSH session may blip. That's normal; the boot guard in [Step 5](#step-5--reboot-with-an-automatic-rollback-guard) covers the rare case where it doesn't come back.

---

### Step 4 — Rebuild networking around a bridge

Every Proxmox VM/container attaches to a **bridge**. The bridge carries the IP; the physical NIC becomes a plain uplink.

**4.1 — Write the authoritative config:**

```bash
cat > /etc/network/interfaces <<EOF
# /etc/network/interfaces -- Proxmox VE bridge layout
auto lo
iface lo inet loopback

# Physical NIC: no IP of its own, enslaved to the bridge
auto <nic>
iface <nic> inet manual

# Proxmox management bridge
auto <bridge>
iface <bridge> inet static
        address <pi-ip>/24
        gateway <gateway>
        dns-nameservers 1.1.1.1 1.0.0.1
        bridge-ports <nic>
        bridge-stp off
        bridge-fd 0
EOF
```

Concretely:

```
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet manual

auto vmbr0
iface vmbr0 inet static
        address 192.168.0.15/24
        gateway 192.168.0.1
        dns-nameservers 1.1.1.1 1.0.0.1
        bridge-ports eth0
        bridge-stp off
        bridge-fd 0
```

> **`iface vmbr0 inet static`** — some ARM guides use `manual` here. Use `static`: that's what Proxmox's own installer generates, and it's what actually brings the address up.

**4.2 — Retire DietPi's drop‑in** so nothing double‑configures the NIC:

```bash
mkdir -p /root/proxmox-setup/disabled
[ -f /etc/network/interfaces.d/eth0.conf ] && \
  mv /etc/network/interfaces.d/eth0.conf /root/proxmox-setup/disabled/eth0.conf
rm -f /etc/network/interfaces.d/*
```

**4.3 — Sanity‑parse (read‑only, changes nothing):**

```bash
ifquery -a
```

---

### Step 5 — Reboot (with an automatic rollback guard)

This is the scary step: if the bridge config is wrong, the Pi disappears. So arm a one‑shot guard **before** rebooting.

**5.1 — Install the guard** at `/usr/local/sbin/net-guard.sh`:

```bash
#!/bin/bash
# One-shot network rollback guard.
# If the gateway is unreachable ~80s after boot, restore the pre-Proxmox
# network config and reboot once. Never loops (flag file).
LOGDIR=/root/proxmox-setup
BK=$LOGDIR/backup
FLAG=/var/lib/.net-guard-ran
exec >>"$LOGDIR/guard.log" 2>&1
echo "=== net-guard $(date -Is) ==="
[ -e "$FLAG" ] && { echo "already ran once - exiting"; exit 0; }
: > "$FLAG"

for i in 1 2 3 4 5 6 7 8 9 10; do
  sleep 8
  if ping -c2 -W2 <gateway> >/dev/null 2>&1 || ping -c2 -W2 1.1.1.1 >/dev/null 2>&1; then
    echo "network reachable after $((i*8))s - standing down"
    systemctl disable net-guard.service 2>/dev/null
    exit 0
  fi
done

echo "NETWORK DOWN after 80s - attempting rollback"
[ -f "$BK/interfaces" ] && [ -d "$BK/interfaces.d" ] || { echo "backup missing - refusing"; exit 1; }
cp -a "$BK/interfaces" /etc/network/interfaces
rm -rf /etc/network/interfaces.d
cp -a "$BK/interfaces.d" /etc/network/interfaces.d
echo "rollback complete - rebooting"
systemctl disable net-guard.service 2>/dev/null
sync; sleep 2; systemctl reboot
```

**5.2 — Back up the current network config first** (the guard needs it):

```bash
mkdir -p /root/proxmox-setup/backup
cp -a /etc/network/interfaces   /root/proxmox-setup/backup/interfaces
cp -a /etc/network/interfaces.d /root/proxmox-setup/backup/interfaces.d
```

**5.3 — Install and enable the unit:**

```bash
install -m 755 /root/proxmox-setup/net-guard.sh /usr/local/sbin/net-guard.sh
cat > /etc/systemd/system/net-guard.service <<'UNIT'
[Unit]
Description=Network rollback guard
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/net-guard.sh
TimeoutStartSec=300

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable net-guard.service
rm -f /var/lib/.net-guard-ran
```

**5.4 — Reboot:**

```bash
systemctl reboot
```

**5.5 — Reconnect and check.** If the bridge works you will see:

```console
$ ip -br addr | grep -v lo
eth0       UP                      ← no IP
vmbr0      UP      192.168.0.15/24  ← IP lives here

$ ip route | grep default
default via 192.168.0.1 dev vmbr0 proto kernel onlink

$ cat /root/proxmox-setup/guard.log
=== net-guard 2026-10-16T18:46:24+08:00 ===
network reachable after 8s - standing down
```

If you instead get **rolled back** (old config restored, Pi reachable again), re‑check the address/gateway/`bridge-ports` names in `/etc/network/interfaces` and try again.

---

### Step 6 — Install Proxmox VE

**6.1 — Preseed Postfix** so the install is fully non‑interactive:

```bash
echo "postfix postfix/main_mailer_type select Local only" | debconf-set-selections
echo "postfix postfix/mailname string $(hostname)"        | debconf-set-selections
```

**6.2 — Install:**

```bash
export DEBIAN_FRONTEND=noninteractive
apt install -y proxmox-ve postfix open-iscsi pve-edk2-firmware-aarch64
```

This pulls **~440 packages**. Confirmed characteristics:

- **Expected removals: exactly one** — `ifupdown` (replaced by `ifupdown2`).
- **No kernel is installed or replaced** — Proxmox rides on the Raspberry Pi kernel.
- `pve-qemu-kvm` is ~112 MB, so give it time on a slow link.

> **If the install ends with `Errors were encountered while processing: pxvirt-spdk`**, just re‑run:
> ```bash
> rm -f /tmp/.ifupdown2-first-install
> dpkg --configure -a
> apt install -y proxmox-ve postfix open-iscsi pve-edk2-firmware-aarch64
> ```

**6.3 — Confirm it's alive:**

```bash
systemctl is-active pve-cluster pvedaemon pveproxy pvestatd
ss -tlnp | grep 8006
pveversion
```

Expected:

```
active active active active

LISTEN 0 4096 *:8006 *:* users:(("pveproxy worker",pid=8480,fd=6), ...)

pve-manager/9.0.10-2/74d1bcc54a6e6730 (running kernel: 6.18.50+rpt-rpi-v8)
```

The web UI is now at **`https://<pi-ip>:8006`** (log in as `root` with the system root password). There will be a self‑signed‑certificate warning — that's expected.

---

### Step 7 — DietPi compatibility fixes

Do these now, or the firewall will spam errors forever and upgrades may bite you later.

**7.1 — Force the nft iptables backend (and keep it forced).** Because the Pi kernel has no legacy modules *and* `pve-firewall.service` forces legacy, you need three pieces.

The shim `/usr/local/sbin/pve-pi-fix`:

```bash
#!/bin/bash
# Pi kernel has no ip_tables/ebtables legacy modules -> force the nft backend.
# Idempotent; silent unless it changes something.
set -u
changed=0
for pair in "iptables:/usr/sbin/iptables-nft" \
            "ip6tables:/usr/sbin/ip6tables-nft" \
            "ebtables:/usr/sbin/ebtables-nft"; do
  grp=${pair%%:*}; target=${pair##*:}
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
```

Install it, run it, and wire it into boot **and** `apt`:

```bash
install -m 755 pve-pi-fix.sh /usr/local/sbin/pve-pi-fix
/usr/local/sbin/pve-pi-fix

# run at every boot, before the firewall
cat > /etc/systemd/system/pve-pi-fix.service <<'UNIT'
[Unit]
Description=Proxmox-on-Pi: force nft iptables backend
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

# and after every apt operation, so upgrades can't silently re-break it
printf 'DPkg::Post-Invoke {"/usr/local/sbin/pve-pi-fix";};\n' > /etc/apt/apt.conf.d/99pve-pi-fix

# clear the ExecStartPre lines that force the legacy backend
mkdir -p /etc/systemd/system/pve-firewall.service.d
cat > /etc/systemd/system/pve-firewall.service.d/10-pi-nft.conf <<'CONF'
[Service]
ExecStartPre=
ExecStartPre=
ExecStartPre=
CONF

systemctl daemon-reload
systemctl enable pve-pi-fix.service
systemctl restart pve-firewall
```

Verify the fix stuck:

```console
$ update-alternatives --query iptables | awk '/^Value:/{print $2}'
/usr/sbin/iptables-nft

$ iptables -V
iptables v1.8.11 (nf_tables)          ← nft, not legacy

$ journalctl -u pve-firewall -b | grep -c error
0
```

**7.2 — Unmask `systemd-logind`** (DietPi masks it):

```bash
systemctl unmask systemd-logind
systemctl enable --now systemd-logind
systemctl is-active systemd-logind      # → active
```

After the next login there should be **zero** `pam_systemd` errors:
```bash
journalctl -b | grep -c pam_systemd     # → 0
```

> Prefer DietPi's lean default? Skip this and accept the login noise. Revert with `systemctl mask systemd-logind`.

**7.3 — Disable the bogus bookworm APT source:**

```bash
mv /etc/apt/sources.list.d/pxvirt-sources.list \
   /etc/apt/sources.list.d/pxvirt-sources.list.disabled
```

**7.4 — Fix `pveam update`** by removing the unverifiable template mirror. The mirror list is hardcoded in `/usr/share/perl5/PVE/APLInfo.pm` inside `sub get_apl_sources`. Remove this block:

```perl
        {
            host => "mirrors.lierfang.com",
            url => "https://mirrors.lierfang.com/pxcloud/pxvirt",
            file => 'lxcs/aplinfo.dat',
        },
```

then:

```bash
perl -c /usr/share/perl5/PVE/APLInfo.pm   # → syntax OK
pveam update                              # → update successful
```

A ready‑made, idempotent patcher is in [`scripts/patch-aplinfo.py`](scripts/patch-aplinfo.py).

**7.5 — Pull the arm64 container templates:**

```bash
pveam available | grep arm64
pveam download local debian-13-standard_13.6-1_arm64.tar.zst
pveam download local alpine-3.24-default_20260803_arm64.tar.xz
```

> Contrary to older reports, Proxmox's official `aplinfo` **does** list arm64 templates — you do **not** have to hand‑download from `images.linuxcontainers.org`.

---

### Step 8 — Verify

```bash
# Network
ip -br addr | grep -v lo
ip route | grep default

# Services — expect 8× "active", zero failed
systemctl is-active pve-cluster pvedaemon pveproxy pvestatd \
                    pvescheduler pve-firewall pve-ha-crm pve-ha-lrm
systemctl --failed

# Web UI
curl -sk -o /dev/null -w 'HTTP %{http_code}\n' https://localhost:8006

# Node, storage, templates
pvesh get /nodes --output-format json | head -c 200
pvesm status
ls /var/lib/vz/template/cache/
```

Then a **real** smoke test — create, start, exec into, and destroy a container:

```bash
pct create 999 /var/lib/vz/template/cache/debian-13-standard_13.6-1_arm64.tar.zst \
  --hostname pve-smoke-test --memory 256 --cores 1 --rootfs local:2 \
  --net0 name=eth0,bridge=vmbr0,ip=dhcp --unprivileged 0 --password smoke1234

pct start 999 && sleep 12
pct status 999                       # → status: running
pct exec 999 -- uname -m             # → aarch64
pct exec 999 -- ip -br addr          # → eth0 ... 192.168.0.x/24   (DHCP worked)
pct stop 999 && pct destroy 999
```

If `ip -br addr` inside the container shows a leased address, **your bridge works** and Proxmox is fully functional.

---

## Using Proxmox

### Web UI

Browse to `https://<pi-ip>:8006`, log in as `root`. You'll see the node, storage, and can create containers/VMs from the UI. The "no valid subscription" banner is cosmetic — PXVirt doesn't need one.

### Containers (LXC) — the recommended path on a Pi

```bash
pct create 100 /var/lib/vz/template/cache/debian-13-standard_13.6-1_arm64.tar.zst \
  --hostname web01 --memory 512 --cores 1 --rootfs local:8 \
  --net0 name=eth0,bridge=vmbr0,ip=dhcp --unprivileged 1 \
  --password 'ChangeMe123' --start 1

pct enter 100        # shell inside
pct list             # all containers
```

Unprivileged containers are the safer default. If `--unprivileged 1` complains about `/etc/subuid`, PVE normally manages this automatically; ensure `root:100000:65536` exists in `/etc/subuid` and `/etc/subgid`.

### Virtual machines (QEMU)

```bash
qm create 200 --name vm01 --memory 1024 --cores 2 \
  --net0 virtio,bridge=vmbr0 --scsihw virtio-scsi-pci
```

You need an **arm64** guest image and the aarch64 UEFI firmware (installed as `pve-edk2-firmware-aarch64`). On a Pi 4 keep guests light — one or two small VMs is realistic; LXC is much cheaper.

---

## Troubleshooting

### The Pi vanished after reboot

Almost always a `/etc/network/interfaces` problem. If you installed the guard, it should have reverted automatically — reconnect and inspect `guard.log`. Common causes:

- `bridge-ports eth0` but your NIC is named something else (`enx…`, `end0`). Check with `ip -br link`.
- Wrong `gateway` (must be your router's IP, e.g. `192.168.0.1`).
- `address` without a prefix (write `192.168.0.15/24`).
- You bridged **Wi‑Fi** (`wlan0`). Not supported — use Ethernet.

### `pve-firewall[NNN]: status update error: iptables_restore_cmdlist …`

You skipped [7.1](#step-7--dietpi-compatibility-fixes), or something reset the alternatives. Check:

```bash
update-alternatives --query iptables | awk '/^Value:/{print $2}'   # must be iptables-nft
systemctl show pve-firewall.service -p ExecStartPre                # must be empty
modprobe ip_tables                                                 # must FAIL on a Pi
```

Re‑run `/usr/local/sbin/pve-pi-fix` and confirm the drop‑in exists.

### `iptables: can't initialize iptables table 'filter'`

You are on the legacy backend. Same fix as above.

### Web UI never loads / connection refused on 8006

```bash
systemctl status pveproxy pve-cluster
ss -tlnp | grep 8006
journalctl -u pveproxy -n 50
```

Also verify `/etc/hosts` ([Step 2](#step-2--fix-etchosts)) and that DNS resolves.

### `pct create` fails with an architecture error

You grabbed an `amd64` template. Use an `_arm64` one: `pveam available | grep arm64`.

### `pveam update` fails

Re‑apply [7.4](#step-7--dietpi-compatibility-fixes); a `pve-manager` upgrade restores the bad mirror entry.

### `ifupdown2` "Another instance of this program is already running"

```bash
rm -f /tmp/.ifupdown2-first-install && apt install -y ifupdown2
```

### `dietpi-config` network changes do nothing

Correct — and intentional. DietPi writes to `/etc/network/interfaces.d/`, which Proxmox's single‑file layout no longer sources. **Edit `/etc/network/interfaces` instead.**

> For deeper diagnostics — recovering a locked‑out headless Pi, where every log
> lives, bridge/LXC debugging, and re‑applying fixes after upgrades — see
> [`docs/troubleshooting.md`](docs/troubleshooting.md). For how the safety gates
> work and the full recovery ladder, see [`docs/safety.md`](docs/safety.md).

---

## Maintenance & upgrades

```bash
apt update && apt full-upgrade -y
```

After a `pve-manager` upgrade, re‑check the two things packages like to restore:

```bash
ls /etc/apt/sources.list.d/ | grep pxvirt          # pxvirt-sources.list should be .disabled
pveam update                                       # should say "update successful"
```

The **iptables fix is automatic** (the `apt` Post‑Invoke hook re‑asserts nft after every apt run), so upgrades can't silently break the firewall.

Backups:

```bash
# DietPi's own backup
dietpi-backup

# Proxmox container/VM backups (add a storage target first)
vzdump 100 --storage local --compress zstd
```

---

## Rollback / uninstall

Everything this guide changes is backed up under `/root/proxmox-setup/backup/`:

```
backup/interfaces        # original /etc/network/interfaces
backup/interfaces.d/     # original drop-ins (eth0.conf)
backup/hosts             # original /etc/hosts
backup/resolv.conf
backup/cmdline.txt
backup/sources.list.d/
```

Restore the network and hosts:

```bash
cp -a /root/proxmox-setup/backup/interfaces   /etc/network/interfaces
cp -a /root/proxmox-setup/backup/interfaces.d/. /etc/network/interfaces.d/
cp -a /root/proxmox-setup/backup/hosts        /etc/hosts
```

Remove Proxmox:

```bash
apt-get remove --purge proxmox-ve pve-manager 'pve-*' 'proxmox-*' 2>/dev/null
apt-get autoremove --purge -y
systemctl mask systemd-logind    # (only if you want DietPi's masked default back)
```

Then reboot and confirm the old DietPi network config comes up.

---

## Security notes

- **`root` password = Proxmox web UI access.** Use a strong, unique password. The web UI is served over HTTPS with a self‑signed certificate; traffic is encrypted but you should still restrict `:8006` to your LAN (the Proxmox firewall, or your router).
- **SSH:** prefer keys over passwords. Disable password auth once keys work:
  ```bash
  # on your workstation
  ssh-copy-id root@<pi-ip>
  # on the Pi
  sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
  systemctl restart ssh
  ```
- **Never expose `:8006` or SSH directly to the internet.** Put them behind a VPN (WireGuard/Tailscale) if you need remote access.
- The **rollback guard** and **failsafe** scripts are local, one‑shot, and disabled once networking is proven. They contain no secrets.

---

## FAQ

**Does this work on a Pi 5?** Yes — PXVirt and this procedure target ARM64 generally; the Pi 5 is faster and handles more VMs. This guide was validated on a Pi 4B.

**Bookworm instead of trixie?** Use the same steps; you'll get Proxmox VE 8, and `$VERSION_CODENAME` handles the repo automatically.

**Can I bridge Wi‑Fi?** No. Use Ethernet. (`bridge-ports wlan0` will not work.)

**Will an `apt upgrade` break it?** The iptables fix survives upgrades automatically. The bookworm repo and the `APLInfo` patch can be restored by a `pve-manager` upgrade — re‑apply 7.3/7.4 (both are one‑liners; see [Maintenance](#maintenance--upgrades)).

**Do I need a Proxmox subscription?** No. The subscription banner is cosmetic.

**Why PXVirt and not upstream Proxmox?** Upstream publishes no ARM64 packages. PXVirt is the maintained ARM fork.

---

## Credits

- **[Pi My Life Up — Installing Proxmox on the Raspberry Pi](https://pimylifeup.com/raspberry-pi-proxmox/)** — the baseline procedure this guide extends.
- **[PXVirt (`jiangcuo/pxvirt`)](https://github.com/jiangcuo/pxvirt)** — the ARM64 Proxmox VE port.
- **[Proxmox VE](https://www.proxmox.com/)** — upstream.
- **[DietPi](https://dietpi.com/)** — the OS.

This guide's contribution is the **DietPi‑specific compatibility layer**: the iptables/nft, logind, APT source, `APLInfo`, and rollback‑guard work, all verified on real hardware.

## License

[MIT](LICENSE) © 2026 dan1165. Not affiliated with Proxmox, DietPi, or Raspberry Pi Ltd.

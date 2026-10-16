# Changelog

All notable changes to this guide/tooling are documented here.
Format loosely follows [Keep a Changelog](https://keepachangelog.com/).

## [1.0.0] — 2026-10-16

Initial release. Validated end-to-end on real hardware:

* **Hardware:** Raspberry Pi 4 Model B Rev 1.5 (4 cores, 8 GB)
* **OS:** DietPi 10.7.2 · Debian GNU/Linux 13 (trixie) · arm64
* **Kernel:** 6.18.50+rpt-rpi-v8 (unchanged — Proxmox rides the Pi kernel)
* **Proxmox:** VE 9.0.0 (`pve-manager 9.0.10-2`, PXVirt arm64 fork)

### Added
- Full written tutorial (`README.md`) covering every step, with expected outputs.
- `scripts/` — reproducible, idempotent stage scripts:
  - `00-config.sh` — single place to set IP/gateway/NIC/bridge.
  - `01-prepare.sh` — repo, backups, `/etc/hosts`, fail-safe, `ifupdown2`.
  - `02-network.sh` — bridge `vmbr0`, rollback guard, reboot.
  - `03-install-proxmox.sh` — install + all compatibility fixes + templates.
  - `04-verify.sh` — verification, optional live LXC smoke test.
  - `install.sh` — resumable driver (survives the mid-install reboot).
  - `pve-pi-fix.sh` — force the nft iptables backend.
  - `net-guard.sh` / `net-failsafe.sh` — network rollback safety nets.
  - `patch-aplinfo.py` — remove the unverifiable template mirror.

### Fixed (DietPi / Raspberry Pi kernel incompatibilities)
- **iptables:** the Pi kernel has no `ip_tables` module and `pve-firewall.service`
  forces the legacy backend via `ExecStartPre`, so the firewall failed on every
  start. Fixed with a systemd drop-in, an alternatives shim, a boot unit, and an
  `apt` post-invoke hook so upgrades cannot undo it.
- **`systemd-logind`:** unmasked (DietPi masks it), removing `pam_systemd`
  session errors on every login.
- **APT:** disabled the `bookworm` source that `pve-manager` installs on a
  trixie system.
- **`pveam update`:** removed the `PVE::APLInfo` mirror whose `aplinfo.dat` is
  signed by a key absent from `trustedkeys.gpg`.
- **Networking:** moved DietPi's `/etc/network/interfaces.d/` drop-in aside so a
  single authoritative bridge config owns the NIC.

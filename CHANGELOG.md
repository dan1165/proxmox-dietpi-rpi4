# Changelog

All notable changes to this guide/tooling are documented here.
Format loosely follows [Keep a Changelog](https://keepachangelog.com/).

## [1.2.0] — 2026-10-16

### Added
- **Edit configuration from the TUI** — a new menu entry opens
  `scripts/config.sh`: pick any setting, type a new value, and it is validated
  and saved. Also supports autodetect, preflight re-run, and reset.
- **`scripts/config.sh`** — view/edit configuration:
  - `--show` effective configuration (marks overridden keys)
  - `--set KEY=VALUE` / `--unset KEY` (scriptable)
  - `--detect` fills address, prefix, gateway, DNS, the physical NIC beneath a
    bridge, and the derived subnet from the running system
  - `--reset` deletes all overrides
- **Per-key validation** before anything is accepted: IPv4, CIDR, hostname
  syntax, absolute paths, interface-name syntax; interface and subnet changes
  print targeted reminders.
- **`scripts/00-config.local.sh`** — overrides written here instead of editing
  `00-config.sh`. It is **gitignored** and sourced after the defaults, so your
  settings win and survive `git pull`. Only keys that differ from the built-in
  defaults are stored (a minimal diff). Managed via `.gitignore`.

### Changed
- `menu.sh` gained an **Edit configuration** entry (menu stays 9 items so number
  jumping keeps working); the header now carries a docs hint.
- Configuration is applied via a gitignored override file, so the repository is
  never dirtied by local settings.

### Notes
- Values containing spaces (e.g. `PI_DNS`, `PVE_TEMPLATES`) are persisted with
  shell-safe quoting, and `config.sh` avoids `eval` for assignment so they
  round-trip exactly.

## [1.1.0] — 2026-10-16

Safety, UX and reliability release. Nothing about the install procedure changed;
this adds guardrails around it. Verified live on the reference Pi (preflight,
status, menu rendering, triple verification, and gate-abort behaviour).

### Added
- **Interactive TUI menu** (`scripts/menu.sh`) — arrow-key/`k`/`j`/number
  navigation, live status header, and a graceful numbered fallback on a non-TTY.
  Also supports `--action <name>` for scripting.
- **`scripts/preflight.sh` — Gate 1**: ~32 automated, read-only safety checks
  (arch/OS, wired NIC + carrier, gateway/internet/DNS/mirror reachability,
  disk/RAM/CPU, recovery-method confirmation, conflicting network managers,
  cloud-init, existing bridge and drop-ins, `/etc/hosts` correctness, the
  "no legacy `ip_tables` module" reality check, running guests, and more).
  `--quiet` for use as a gate, `--strict` to fail on warnings.
- **Three-gate apply protocol** (`lib/common.sh`): Gate 1 preflight → Gate 2
  exact-phrase confirmation (`PREPARE`, `APPLY-NETWORK`, `INSTALL-PROXMOX`,
  `RESTORE-NETWORK`, `PURGE-PROXMOX`) → Gate 3 **triple verification**.
- **Triple verification** — every applied change is checked by three independent
  methods (A: systemd state, B: raw processes/ports/HTTP, C: PVE API + on-disk
  data). `04-verify.sh` now runs all three (plus `--once`, `--smoke`).
- **`scripts/repair.sh`** — re-applies every known fix idempotently, with
  `--check` for a dry run and a triple verification at the end.
- **`scripts/rollback.sh`** — triple-confirmed revert (yes/no → typed phrase →
  abortable countdown), with `--list`.
- **`scripts/status.sh`** — read-only overview of host, network, Proxmox,
  Tailscale and install state; `--brief` for the menu header.
- **`scripts/tailscale.sh`** — install + configure the Tailscale subnet router
  (forwarding, UDP tuning, boot ordering, route advertisement, approval hint).
- **`docs/safety.md`** — the safety model, every check, the reliability
  features, non-interactive usage and the recovery ladder.
- Boot-ordering drop-in for `tailscaled` (ordered after `networking.service`,
  removing 13 spurious `bootstrapDNS` boot errors).

### Changed
- All stage scripts now: share `lib/common.sh`, log to `$WORKDIR/*.log`, acquire
  a run lock (`flock`), install an `ERR` trap, write configs atomically, keep
  timestamped backups, and **verify themselves** before/after applying.
- Stages are now fully **idempotent** — re-running detects completed work.
- `02-network.sh` proves the config parses **and the rollback guard is armed**
  before it will reboot.
- Confirmations now **fail closed**: non-interactive without `--yes`/`--force`
  means *no*, never *yes*.
- `install.sh` became a resumable, gated driver with `--status`, `--reset`,
  `--yes`, `--force`.

### Fixed
- Duplicate output in the logging helpers (lines were printed twice).
- `status.sh` showed the OS codename twice, and `net-guard: disabled` followed by
  a spurious `n/a`.
- `04-verify.sh` false-failed the web-UI title check — the ARM fork serves
  `<title>… Pxvirt</title>`, not "Proxmox".

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

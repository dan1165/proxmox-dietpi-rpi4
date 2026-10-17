# Changelog

All notable changes to this guide/tooling are documented here.
Format loosely follows [Keep a Changelog](https://keepachangelog.com/).

## [1.4.0] — 2026-10-17

Automation and self-healing release. Everything is now unattended‑capable, keeps
itself repaired, and installs whatever it needs.

### Added
- **`scripts/lib/deps.sh` — dependency manifest + auto-install.** Declares the
  tools the scripts use (`curl`, `python3`, `iproute2`, `iputils-ping`,
  `libc-bin`, `util-linux`, `ca-certificates`) and installs anything missing via
  apt, with a package-list refresh and retry. `ensure_deps` is called by stage 1,
  stage 3, `repair.sh` and `heal.sh`; `deps_report` feeds preflight and status;
  `NO_INSTALL_DEPS=1` gives check-only behaviour. Optional extras (`ethtool`,
  `gnupg`, `bridge-utils`) are installed best-effort by `ensure_optional_deps`.
- **`scripts/lib/fixes.sh` — every fix as an idempotent function**
  (`fix_nft_backend`, `fix_cgroup`, `fix_logind`, `fix_apt_source`,
  `fix_aplinfo`, `fix_tailscale_order`, `fix_services`, `fix_network`). `repair.sh`
  and the new healer now share ONE implementation; nothing is duplicated.
- **`scripts/heal.sh` — self-healing.** `--check` reports the state of every fix
  (read-only); the default applies them all; `--with-network` opts in to an
  `ifup` attempt; `--install-timer` / `--uninstall-timer` / `--timer-status`
  manage a systemd timer that heals at boot and hourly. Restarts services that
  should be running but are not. Quiet runs still leave a trace in
  `/root/proxmox-setup/heal.log`. Networking is deliberately **not** touched
  automatically.
- **`scripts/autoinstall.sh` — fully unattended install that survives the
  reboot.** Snapshots the scripts to `$WORKDIR/scripts`, drives the normal gated
  stages in order using `$WORKDIR/.stage`, and installs a one-shot
  `pve-pi-autoinstall.service` that resumes after the reboot and removes itself
  when finished. Fails safe: retries a failing stage up to `AUTO_MAX_ATTEMPTS`
  (default 3) across boots, then stops instead of looping. `--status`, `--abort`,
  `--clean`, `--foreground`.
- **Unattended Tailscale.** `tailscale.sh --auto` authenticates with
  `TAILSCALE_AUTHKEY` (keep it in the gitignored `00-config.local.sh`), and
  `autoinstall.sh` runs it when `AUTO_INSTALL_TAILSCALE=1`.
- **New config keys** (editable from the TUI): `AUTO_INSTALL_HEAL_TIMER`,
  `AUTO_INSTALL_TAILSCALE`, `AUTO_MAX_ATTEMPTS`; plus `TAILSCALE_AUTHKEY`
  (secret, intentionally not shown by the config editor).
- **Documentation for humans:**
  - **`docs/quickstart.md`** — a plain-English tutorial: what to type, what you
    will see at each stage, how long it takes, how to know it worked, how to make
    your first container, and how to undo it.
  - **`docs/glossary.md`** — every term in one line (bridge, container, cgroup,
    device tree, subnet router, …).
  - README: a **Documentation** table up front, a new **Automation &
    self-healing** section, and an updated menu/layout.
  - `docs/safety.md`: how the gates behave under the unattended installer.
  - `docs/troubleshooting.md`: a new "Auto-heal, dependencies and unattended
    runs" section.

### Changed
- `repair.sh` is now a thin wrapper over `lib/fixes.sh` (`--check` delegates to
  `heal.sh --check`), so there is a single source of truth for each fix.
- `01-prepare.sh` and `03-install-proxmox.sh` install dependencies automatically
  before doing anything else.
- `preflight.sh` reports the dependency state (34 checks now); `04-verify.sh`
  checks the required command-line tools are present.
- The menu leads with **Auto install** and gains a **Repair / auto-heal**
  submenu (heal now / check / add timer / remove timer).

### Fixed
- `autoinstall.sh --status` printed a duplicated "not installed" line, and
  showed "1 of 4" for a run that had never started — it now says "not started".
- `heal.sh --check` no longer emits trailing padding on short result lines.

## [1.3.0] — 2026-10-16

### Fixed
- **Container memory limits were silently unenforced on Raspberry Pi.** The Pi
  device tree (`bcm2711-rpi-4-b.dtb` → `/chosen/bootargs`) passes
  `cgroup_disable=memory`, which the firmware prepends to `cmdline.txt`. The
  result is that `/sys/fs/cgroup/cgroup.controllers` has **no `memory`**, so an
  LXC configured for e.g. 2 GB uses more and `free` inside reports the host's
  RAM — while Proxmox still shows `memory: 2048`. The token appears in
  `/proc/cmdline`/`dmesg` but in **no file under `/boot`**, which is why it is
  so hard to track down.
  Fix: append `cgroup_no_v1=all cgroup_enable=memory` to `cmdline.txt`
  (`cgroup_enable=memory` re-enables the controller the device tree disabled),
  then reboot.

### Added
- **`scripts/cgroup-fix.sh`** — idempotently enables the memory cgroup
  controller. `--check` reports only, `--revert` removes the tokens, backs up
  `cmdline.txt`, and exits `10` to signal "applied, reboot required".
- Stage 1 (`01-prepare.sh`) applies the fix automatically, so the stage-2
  reboot activates it — the correct place, since a reboot is unavoidable there.
  Its triple verification now checks memory cgroups are active *or* queued.
- `repair.sh` re-applies it; `preflight.sh` warns when the memory controller is
  missing; `04-verify.sh` fails verification when it is missing;
  `status.sh` reports it under Health.
- README: new **thing #6 — "The Raspberry Pi device tree disables the memory
  cgroup"** (the list is now "The six things that will break"), plus a 3.1
  walkthrough step and `cgroup-fix.sh` in the layout.
- `docs/troubleshooting.md`: "Containers ignore their memory limit" — symptom,
  root cause, fix, and the `lxc/<vmid>` vs systemd-scope gotcha.
- `docs/safety.md`: the new preflight warning and the reliability-table entry.

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

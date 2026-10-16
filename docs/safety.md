# Safety model

This project makes large, hard-to-reverse changes to a headless machine's
networking and package set. Everything here exists to make that safe.

---

## The three-gate apply protocol

Every stage that changes the system must pass **three independent gates**. If
any gate fails, nothing is applied.

```
        ┌─────────────┐   ┌──────────────┐   ┌────────────────────┐
        │  GATE 1     │   │  GATE 2      │   │  GATE 3            │
        │  PREFLIGHT  │──▶│  CONFIRM     │──▶│  TRIPLE VERIFY     │
        │  automated  │   │  typed phrase│   │  3 independent     │
        │  safety     │   │  + countdown │   │  checks on the     │
        │  checks     │   │              │   │  applied change    │
        └─────────────┘   └──────────────┘   └────────────────────┘
             fails ──────────▶ abort              fails ──▶ abort
```

### Gate 1 — preflight (`preflight.sh`, read-only)

Automated checks; nothing is modified. Run it any time with `./preflight.sh`.
It reports `pass / warn / fail` and exits non-zero if anything is a **blocker**.

**Blockers (fail):**

| Check |
|---|
| running as root |
| systemd is PID 1 |
| architecture is arm64 |
| OS is Debian *bookworm* or *trixie* |
| interface `$NIC` exists |
| interface is **not** wireless (bridging Wi-Fi is unsupported) |
| gateway responds to ping |
| internet reachable (`deb.debian.org`) |
| DNS resolution works |
| PXVirt mirror reachable |

**Warnings (require acknowledgement, don't block unless `--strict`):**

| Check |
|---|
| DietPi not detected (other Debian images are untested) |
| kernel is not a Raspberry Pi kernel |
| no SSH server active *(you are on a headless box)* |
| no recovery method confirmed *(monitor/serial/another SD card)* |
| low RAM (< 2 GB) or low disk (< 5 GB free) |
| fewer than 4 CPU cores |
| `$NIC` has no link/carrier |
| configured `PI_IP` differs from the running IP |
| `NetworkManager` / `systemd-networkd` / `dhcpcd` active |
| cloud-init is set to rewrite `/etc/hosts` |
| conflicting `/etc/network/interfaces.d/` drop-ins |
| bridge exists with a different configuration |
| `/etc/hosts` not pointing at `PI_IP` |
| guests are running (a rollback could disrupt them) |
| `nft` userspace command missing |
| **memory cgroup controller missing** — the Pi device tree passes `cgroup_disable=memory`, so LXC memory limits would be silently unenforced (stage 1 fixes this automatically) |

### Gate 2 — explicit confirmation

You must **type an exact phrase**. No `y`/Enter shortcut. Each stage has its own:

| Stage | Phrase |
|---|---|
| Stage 1 — prepare | `PREPARE` |
| Stage 2 — network | `APPLY-NETWORK` (+ a 12 s abortable countdown) |
| Stage 3 — install | `INSTALL-PROXMOX` |
| Rollback | `RESTORE-NETWORK` (+ `PURGE-PROXMOX` to remove packages) |

A wrong phrase (or EOF) aborts immediately and cleanly.

### Gate 3 — triple verification

After applying, the change is verified by **three independent methods**, so a
bug or false reading in one method is caught by the others:

| Pass | Mechanism |
|---|---|
| **A** | systemd's view — unit states, `--failed`, journal error counts |
| **B** | raw processes/ports/HTTP — `pgrep`, `ss`, `curl`, `iptables -V` |
| **C** | PVE's own API/data — `pvesh`, `pveversion`, `pvesm`, `/etc/pve`, `ip` |

Run it yourself any time:

```bash
sudo ./04-verify.sh            # three independent passes
sudo ./04-verify.sh --once     # single pass
sudo ./04-verify.sh --smoke    # + create/boot/destroy a real container
```

Stage 2 is special: it verifies the config **and proves the rollback guard is
armed** *before* it will reboot, then stage 3 re-verifies the live network after
the reboot.

---

## Reliability features

| Feature | Where | What it does |
|---|---|---|
| **Rollback guard** | `net-guard.sh` / `net-guard.service` | If the gateway is unreachable ~80 s after boot, restore the backed-up network config and reboot once. Never loops. |
| **Fail-safe** | `net-failsafe.sh` | Guards the brief window where dpkg swaps `ifupdown` → `ifupdown2`; reboots if the network does not come back within 5 min. |
| **Locking** | `acquire_lock` (flock) | Prevents two runs from racing each other. |
| **Error trap** | `install_error_trap` | `set -Eeuo pipefail` + a handler that prints the failing line, the command, and the last 20 log lines. |
| **Atomic writes** | `atomic_write` | Config files are written to a temp file and `mv`'d into place — never a half-written file. |
| **Timestamped backups** | `backup_file` | Anything overwritten is copied to `backup-orig/` or `backup/` first. |
| **Idempotency** | all stages | Re-running detects completed work and skips it. `repair.sh` re-applies fixes safely. |
| **Resumable state** | `$WORKDIR/.stage` | Survives the mandatory mid-install reboot; `install.sh` continues where it left off. |
| **Fail-closed confirmations** | `confirm_yes` / `confirm_phrase` | Non-interactive without `--yes`/`--force` = *no*, never *yes*. |
| **Post-apply repair** | `apt` post-invoke hook | Re-asserts the nft iptables backend after every apt operation, so upgrades cannot silently break the firewall. |
| **Memory-cgroup fix** | `cgroup-fix.sh` (applied by stage 1 / `repair.sh`) | The Raspberry Pi device tree passes `cgroup_disable=memory`, which silently disables container memory limits. Applied to `cmdline.txt` idempotently, with a backup; activated by the next reboot. |

---

## Non-interactive / automation use

The gates are designed to be loud, not to be bypassed casually. For CI or
unattended runs:

```bash
sudo ./install.sh --yes                 # auto-answer yes/no prompts
sudo ./install.sh --yes --force         # also skip typed phrases (use with care)
```

`--force` skips **only** the typed-phrase gate; preflight (gate 1) and
verification (gate 3) still run and can still abort the run. There is no flag
that disables preflight or verification.

Read-only commands are always safe to run:

```bash
./preflight.sh          ./status.sh          ./04-verify.sh --once
./repair.sh --check     ./rollback.sh --list ./menu.sh --action help
```

---

## Recovery ladder

If something goes wrong, work down this list:

1. **Did it self-heal?** Wait ~2 minutes. The rollback guard reverts a bad
   bridge config and reboots automatically. Check `guard.log`.
2. **Reconnect and inspect.** `status.sh`, `preflight.sh`, `guard.log`.
3. **Re-apply fixes.** `repair.sh` is idempotent and safe.
4. **Revert fully.** `rollback.sh` (triple-confirmed) restores the original
   network config and `/etc/hosts` from `backup/`.
5. **Physical access.** Worst case, boot with a keyboard/monitor or put the SD
   card in another machine — the backups under `/root/proxmox-setup/` are enough
   to make the box reachable again (see `docs/troubleshooting.md`).

---

## What is *not* protected

- **`--force` bypasses the typed-phrase gate.** Don't use it unless you know why.
- **A truly wrong bridge config plus a missing backup** would need physical
  access. Preflight checks for the backup before stage 2 will run.
- **A `pve-manager` upgrade** can restore the bogus *bookworm* apt source and the
  unverifiable template mirror; `repair.sh` re-fixes both, and the iptables fix
  is re-applied automatically by the apt hook.
- **Wi-Fi bridging** is not supported and preflight refuses to proceed on a
  wireless interface.

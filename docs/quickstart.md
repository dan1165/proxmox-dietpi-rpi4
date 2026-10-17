# Quick start — in plain English

No jargon, no theory. This page is "what do I type, what will I see, how do I
know it worked".

If a word looks unfamiliar, [`glossary.md`](glossary.md) explains it in one line.

---

## What this does

It turns a Raspberry Pi 4 running **DietPi** into a machine that can run lots of
small "computers" (containers) and manages them from a web page — that software
is called **Proxmox VE**. Everything here is scripted, checks itself, and can
heal itself afterwards.

Takes about 20–30 minutes. The Pi's network is reconfigured once, so it reboots
once, on its own.

---

## Before you start

Tick these off:

- [ ] Raspberry Pi 4 with **DietPi** (Debian 13 "trixie", 64-bit) already
      installed and booting.
- [ ] The Pi is connected with an **Ethernet cable** (not Wi‑Fi).
- [ ] You can log into it over SSH: `ssh root@<the-pi-ip>`.
- [ ] You know its **IP address** and your **router's IP** (usually `192.168.0.1`
      or `192.168.1.1`).
- [ ] You have a **fallback**: a monitor + keyboard, a serial console, or a spare
      SD card. (You will almost certainly not need it. The scripts include an
      automatic undo for the risky step, but please have one anyway.)
- [ ] The Pi has an internet connection.

You do **not** need to know Linux well. You just need to be able to paste
commands.

---

## The whole thing, in three commands

```bash
# 1. get the scripts onto the Pi
git clone https://github.com/dan1165/proxmox-dietpi-rpi4.git
cd proxmox-dietpi-rpi4/scripts

# 2. tell it your network details (the only thing it cannot guess)
sudo ./config.sh --detect        # or: sudo ./config.sh   for a menu

# 3. let it run
sudo ./autoinstall.sh
```

That's it. Command 3 does everything — including rebooting the Pi once — and
then sets up an hourly health check that keeps fixing things automatically.

> Can't or don't want to use the terminal? After step 2 run `sudo ./menu.sh` and
> pick **1) Auto install** from the arrow‑key menu.

---

## What you will see

`autoinstall.sh` prints its progress and writes a full log. The play‑by‑play:

| Stage | What it does | Rough time | Will it reboot? |
|---|---|---|---|
| **1 · Prepare** | Installs any missing tools, adds the Proxmox package source, saves backups, fixes `/etc/hosts` | 1–2 min | no |
| **2 · Network** | Moves the Pi's IP onto a "bridge" so containers can share the network | seconds | **yes, once** |
| **3 · Install** | Downloads and installs Proxmox VE (~440 packages) and applies 8 compatibility fixes | 10–20 min | no |
| **4 · Verify** | Checks the whole install three different ways | 1 min | no |
| **Done** | Installs the auto‑heal timer and prints the web address | — | no |

The reboot in stage 2 is the only moment you need to pay attention to: your SSH
session will drop. It comes back by itself. If it does not come back within a
couple of minutes, the built‑in guard puts the old network settings back and
reboots again — so you cannot get locked out.

You can watch progress at any time:

```bash
sudo ./autoinstall.sh --status     # how far along is it?
sudo ./menu.sh                     # or just open the menu
tail -f /root/proxmox-setup/autoinstall.log
```

---

## How do I know it worked?

Two ways.

**1. The scripts tell you.** The last thing you see is:

```
==> Auto-install complete
  [ OK ] auto-heal timer installed (at boot + hourly)
  [ OK ] Proxmox VE is installed and verified
  web UI : https://192.168.0.15:8006   (user: root)
```

**2. Ask it.** At any time:

```bash
sudo ./heal.sh --check
```

You want every line to read `[ OK ]`:

```
Self-heal status
────────────────────────────────────────────────────────────
  [ OK ] iptables backend is nft
  [ OK ] pve-firewall legacy override cleared
  [ OK ] apt post-invoke hook present
  [ OK ] memory cgroup controller active
  [ OK ] systemd-logind unmasked
  [ OK ] bookworm apt source disabled
  [ OK ] PVE::APLInfo patched
  [ OK ] tailscaled boot ordering
  [ OK ] core PVE services running
  [ OK ] bridge vmbr0 has 192.168.0.15
────────────────────────────────────────────────────────────
  [ OK ] everything is healthy
```

For a deeper check (`sudo ./04-verify.sh`) you'll see three independent
verification passes, all reporting 0 failures.

---

## Opening the web page

In a browser on your laptop, go to:

```
https://<the-pi-ip>:8006
```

for example `https://192.168.0.15:8006`.

- Log in as **root** with the Pi's root password.
- Your browser will warn that the certificate is not trusted. That is expected —
  it is a self‑signed certificate. Click through the warning.
- You will see a banner about subscriptions. Ignore it; it is cosmetic.

---

## Making your first container

A "container" is a lightweight little Linux system. In the web page: **Create
CT**, give it a name, pick the *debian-13* template, set RAM/disk, and click
through. Or from the terminal:

```bash
pct create 100 /var/lib/vz/template/cache/debian-13-standard_13.6-1_arm64.tar.zst \
  --hostname myct --memory 2048 --cores 3 --rootfs local:8 \
  --net0 name=eth0,bridge=vmbr0,ip=dhcp --unprivileged 1 \
  --password 'pick-a-password' --start 1

pct enter 100        # a shell inside it — no password needed
```

Check it is really limited to 2 GB:

```bash
pct exec 100 -- free -h        # should say 2.0Gi, not the host's RAM
```

Want it to start automatically when the Pi boots? `pct set 100 --onboot 1`.

---

## Something looks wrong. What now?

Run these in order — each one checks more and fixes more:

```bash
sudo ./heal.sh --check     # what is broken?   (changes nothing)
sudo ./heal.sh             # fix it            (safe, repeatable)
sudo ./menu.sh --action verify
```

`heal.sh` fixes the eight known problems automatically. If it cannot, it tells
you exactly what it found. For the long version see
[`troubleshooting.md`](troubleshooting.md).

---

## Keeping it healthy automatically

The installer already turned on an **auto‑heal timer**: once at boot and once an
hour, the Pi quietly re‑checks the eight fixes and repairs anything that drifted
(for example after an update). It logs to `/root/proxmox-setup/heal.log`.

```bash
sudo ./heal.sh --timer-status       # is it on, and when does it run next?
sudo ./heal.sh --uninstall-timer    # turn it off
sudo ./heal.sh --install-timer      # turn it back on
```

---

## Changing the network settings later

**Do not use `dietpi-config` → Network options.** DietPi writes its settings
somewhere the new bridge ignores, so your change would silently do nothing.

Instead:

```bash
sudo ./config.sh            # menu: edit the IP, gateway, DNS, ...
sudo ./config.sh --show     # what is it using now?
```

To apply a change to the bridge itself, edit `/etc/network/interfaces` (the
`vmbr0` block) and reboot.

---

## Undoing it

Everything the scripts overwrite is backed up first.

```bash
sudo ./rollback.sh --list      # show what would be restored
sudo ./rollback.sh             # put the old network + hosts back
sudo ./rollback.sh --purge     # ...and also remove the Proxmox packages
```

You have to type a confirmation phrase, so it cannot happen by accident.

---

## Learn more

| Page | What's in it |
|---|---|
| [`glossary.md`](glossary.md) | every term in one line (bridge, container, cgroup, subnet route…) |
| [`safety.md`](safety.md) | how the safety checks work, and the recovery ladder |
| [`troubleshooting.md`](troubleshooting.md) | deep diagnostics and how to recover a machine you cannot reach |
| [`../README.md`](../README.md) | the full technical walkthrough and why each fix is needed |

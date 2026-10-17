# Glossary

Every term used by this project, in one line. Plain English first, then the
detail if you want it.

---

### Bridge (`vmbr0`)
A virtual network switch built inside the Pi. Your real network card plugs into
it, and so does every container. The Pi's own IP lives on the bridge.
*Why:* containers need their own IP addresses on your LAN, and a bridge is how
they get them.

### DietPi
A very small Debian‑based Linux distribution for single‑board computers. It is
lighter than Raspberry Pi OS but makes a few choices (masking `systemd-logind`,
managing the network with drop‑in files) that Proxmox does not expect — this
project reconciles them.

### Container (LXC / CT)
A lightweight Linux system that shares the Pi's kernel. Starts in about a second,
uses little RAM, and behaves like a separate machine. Much cheaper than a full
virtual machine.
*Proxmox commands:* `pct create`, `pct enter`, `pct list`.

### Virtual machine (VM / QEMU)
A full emulated computer with its own kernel. Slower and hungrier than a
container, but can run a completely different OS. On a Pi 4, keep these small.
*Proxmox commands:* `qm create`, `qm start`.

### Template
A pre‑built filesystem image used as the starting point for a container. This
project pre‑downloads the arm64 Debian 13 and Alpine templates.
*Command:* `pveam available` / `pveam download local <name>`.

### VMID
The number that identifies a container or VM. `100` is the first one Proxmox
usually creates. `--rootfs local:8` means "8 GB on the `local` storage".

### Unprivileged container
A container whose root user is *not* the real root of the Pi. Safer: if something
escapes the container, it does not own the host. Recommended default.

### Proxmox VE
The software that manages containers and VMs and gives you the web interface. The
official builds are x86‑only, so this project uses the **PXVirt** fork, which
publishes ARM64 builds.

### PXVirt
The third‑party ARM64 port of Proxmox VE (`github.com/jiangcuo/pxvirt`). Same
interface and features; supports Raspberry Pi hardware.

### Node
Proxmox's name for "this machine". Your Pi is a one‑node cluster.

### Storage (`local`)
Where container disks and templates live. Here it is `/var/lib/vz`, a plain
directory on the SD card/SSD. No RAID, so **back up anything important**.

### cgroup (control group)
The Linux kernel feature that enforces limits: "this container may use at most
2 GB of RAM and 3 CPU cores". Without the `memory` cgroup controller, memory
limits are silently ignored — which is exactly what the Raspberry Pi does by
default, and one of the things this project fixes.

### `cgroup_disable=memory`
A kernel boot option that switches memory limits off. On a Pi it is baked into
the **device tree**, not into any file you can edit — which is why it is hard to
find. This project re‑enables the controller with `cgroup_enable=memory`.

### Device tree (DTB)
A small data file that tells the Linux kernel what hardware exists. The
Raspberry Pi firmware feeds it to the kernel *before* the boot options in
`cmdline.txt`, which is how hidden settings like `cgroup_disable=memory` sneak in.

### `cmdline.txt`
The kernel's boot options, at `/boot/firmware/cmdline.txt`. It must be a single
line. This project appends two options to it (after taking a backup).

### nftables / iptables
Two firewalls. `iptables` is the classic tool; it can talk to either the old
kernel interface (`legacy`) or the new one (`nft`). The Raspberry Pi kernel only
supports `nft`, so the legacy mode simply cannot work — another thing this
project fixes.

### `ifupdown` / `ifupdown2`
The programs that read `/etc/network/interfaces` and configure the network at
boot. Proxmox needs **`ifupdown2`** because it understands bridges natively.

### `/etc/network/interfaces`
The single file that now defines the Pi's networking (bridged `eth0` + `vmbr0`).
Edit this — not the DietPi network tool — to change the IP.

### The three gates
This project refuses to change your machine unless three things pass:
**1) preflight** (automated checks), **2) your typed confirmation**,
**3) triple verification** (three independent checks that the change worked).
The unattended installer skips only gate 2 — the confirmation — because nobody
is there to type it.

### Auto‑heal timer
A systemd timer that re‑runs the eight fixes once at boot and once an hour, so a
later update cannot quietly break the setup. Managed with `heal.sh`.

### systemd unit / timer
systemd is Linux's service manager. A **unit** describes something to run; a
**timer** schedules a unit. The auto‑heal timer runs the heal unit hourly.

### Tailscale / subnet router
Tailscale builds a private network between your own devices. A **subnet router**
makes one machine share its whole local network (here `192.168.0.0/24`) with the
rest of your devices, so you can reach your home LAN from anywhere.

### Masks a service
Replacing a service's definition with a link to `/dev/null`, which stops it from
starting. DietPi does this to `systemd-logind`; this project undoes it.

### Preflight / dry run
Checks that only look; they change nothing. Safe to run any time.

### SD card wear
The Pi writes to its SD card. Lots of container activity means lots of writes.
For anything long‑term, boot from a USB SSD instead.

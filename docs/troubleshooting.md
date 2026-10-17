# Deep troubleshooting & recovery

Companion to the [Troubleshooting section of the README](../README.md#troubleshooting).
This page is about **diagnosing** and **recovering**, especially on a headless Pi.

---

## 1. Recovering a locked-out headless Pi

Symptoms: after a reboot you cannot ping, SSH, or reach `:8006`.

### If you installed the rollback guard

Give it ~2 minutes. The guard fires ~80 s after boot, restores the backup and
reboots. Once the Pi is reachable again, read the log:

```bash
cat /root/proxmox-setup/guard.log
```

Look for `NETWORK DOWN after 80s - attempting rollback` followed by
`rollback complete - rebooting`. If you see `network reachable ... standing down`
but you still could not connect, the problem is **not** the network config
(check the Pi is powered, cable, and your own host's routing).

### If it did not recover

You need a keyboard + monitor, or the SD card in another machine, or a USB-TTL
serial console. Then:

1. Boot (the console may come up even without the network).
2. Inspect and fix the config by hand:

   ```bash
   cat /etc/network/interfaces
   ip -br link              # is the NIC name really 'eth0'?
   cat /etc/resolv.conf
   journalctl -b -u networking -n 50
   ```

3. Restore the original config from the backup and reboot:

   ```bash
   cp -a /root/proxmox-setup/backup/interfaces   /etc/network/interfaces
   cp -a /root/proxmox-setup/backup/interfaces.d/. /etc/network/interfaces.d/
   systemctl reboot
   ```

### Most common causes, in order

| Cause | Fix |
|---|---|
| `bridge-ports` names a non-existent NIC | `ip -br link` to find the real name |
| Wrong gateway | must be your router, e.g. `192.168.0.1` |
| `address` without `/24` | write `192.168.0.15/24` |
| Bridged `wlan0` | unsupported — use Ethernet |
| Two configs fighting (`interfaces` **and** `interfaces.d/`) | empty `interfaces.d/` |
| `/etc/hosts` wrong | hostname must map to the real IP (breaks Proxmox, not the network) |

---

## 2. Where the logs live

| What | Where |
|---|---|
| Installer stage logs | `/root/proxmox-setup/0*.log` |
| Rollback guard | `/root/proxmox-setup/guard.log` |
| Package-transition fail-safe | `/root/proxmox-setup/failsafe.log` |
| Template download | `/root/proxmox-setup/tpl.log` |
| Proxmox template updates | `/var/log/pveam.log` |
| Cluster / pmxcfs | `journalctl -u pve-cluster` |
| Web UI proxy | `journalctl -u pveproxy` |
| API daemon | `journalctl -u pvedaemon` |
| Status daemon | `journalctl -u pvestatd` |
| Firewall | `journalctl -u pve-firewall` |
| Everything, this boot, errors only | `journalctl -b -p err` |

---

## 3. iptables / nft (the Pi-specific one)

The Pi kernel has **no** legacy modules:

```bash
modprobe ip_tables      # → FATAL: Module ip_tables not found
```

So the nft backend is mandatory. Check the current state:

```bash
update-alternatives --query iptables  | awk '/^Value:/{print $2}'   # → /usr/sbin/iptables-nft
update-alternatives --query ip6tables | awk '/^Value:/{print $2}'   # → /usr/sbin/ip6tables-nft
iptables -V                                                          # → iptables v1.8.11 (nf_tables)
systemctl show pve-firewall.service -p ExecStartPre                  # → empty
journalctl -u pve-firewall -b | grep -c error                        # → 0
```

If the value is `...-legacy`:

```bash
/usr/local/sbin/pve-pi-fix
systemctl restart pve-firewall
```

If `pve-pi-fix` is missing, or `ExecStartPre` is not empty, the drop-in is gone
— re-create both (see README step 7.1). A `pve-manager` upgrade can restore the
upstream unit, but the `/etc/systemd/system/pve-firewall.service.d/` drop-in
and the apt hook normally survive.

---

## 4. The bridge

```bash
ip -br addr show vmbr0          # must hold <pi-ip>
ip -br addr show eth0           # must have NO ip
ip route | grep default         # via vmbr0
bridge link                     # eth0 should appear as a port of vmbr0
bridge fdb show br vmbr0 | head # MACs learned through the bridge
cat /proc/net/bonding/* 2>/dev/null
```

Bring the bridge up/down manually (careful — this can drop your SSH):

```bash
ifdown vmbr0 && ifup vmbr0      # or: ifreload -a
```

Check the config parses:

```bash
ifquery vmbr0
ifquery -a
```

---

## 5. Services

```bash
systemctl --failed                       # anything red
systemctl status pve-cluster pveproxy pvedaemon pvestatd --no-pager
ss -tlnp | grep 8006                     # is the UI actually listening?
curl -sk https://localhost:8006 | head   # does it answer?
```

If `pve-cluster` is down, everything else follows. Its log is the most useful:

```bash
journalctl -u pve-cluster -n 100 --no-pager
ls -la /etc/pve                          # pmxcfs mount should be present
```

If `/etc/pve` is empty or missing, `pmxcfs` failed to start — usually a
`/etc/hosts` problem (the node name must resolve to its real IP).

---

## 6. Containers (LXC)

```bash
pct list
pct status 100
pct config 100
journalctl -u pve-container@100 -n 80 --no-pager
lxc-ls -f 2>/dev/null
```

- **`pct create` architecture error** → you used an `amd64` template; use
  `pveam available | grep arm64`.
- **Container has no network** → check `bridge=vmbr0` in `pct config`, and that
  the bridge works on the host.
- **Unprivileged create fails** → ensure `root:100000:65536` is in `/etc/subuid`
  and `/etc/subgid`.

### Containers ignore their memory limit (the Pi-specific one)

Symptom: a container configured for 2 GB reports the **host's** RAM inside, and
the host's cgroup shows no effective limit.

```console
$ pct exec 100 -- free -h
Mem:           7.7Gi       1.4Gi       ...      # host RAM, not 2 GiB
$ cat /sys/fs/cgroup/cgroup.controllers
cpuset cpu io pids                               # <- no "memory"
```

Cause: the Raspberry Pi **device tree** (`bcm2711-rpi-4-b.dtb` →
`/chosen/bootargs`) passes `cgroup_disable=memory`, and the firmware prepends it
to `cmdline.txt`. That is why the token appears in `/proc/cmdline` and `dmesg`
but in **no file under `/boot`**.

```console
$ dmesg | grep -i cgroup
cgroup: Disabling memory control group subsystem
```

Fix (idempotent, backs up `cmdline.txt`, needs a reboot):

```bash
sudo ./cgroup-fix.sh          # exit 10 = applied, reboot required
sudo ./cgroup-fix.sh --check  # report only
sudo ./cgroup-fix.sh --revert # remove the tokens
```

After rebooting, `dmesg` shows the controller being re-enabled and the limits
become real:

```console
$ dmesg | grep -i cgroup
cgroup: Enabling memory control group subsystem
$ cat /sys/fs/cgroup/cgroup.controllers
cpuset cpu io memory pids
$ cat /sys/fs/cgroup/lxc/100/memory.max        # the PAYLOAD cgroup
2147483648
$ pct exec 100 -- free -h
Mem:           2.0Gi       ...
```

> **Gotcha when checking:** the systemd scope `pve-container@100.service` holds
> only the *monitor* process and reports `memory.max = max`. The enforced limit
> lives in `/sys/fs/cgroup/lxc/<vmid>/memory.max`. Looking in the wrong place
> makes it seem like nothing is enforced.

Also confirm what PVE generated:

```bash
grep -E 'cgroup2|memory' /var/lib/lxc/100/config
# lxc.cgroup2.memory.max = 2147483648
# lxc.cgroup2.memory.high = 2130706432
```

---

## 7. Re-applying fixes after an upgrade

`apt full-upgrade` may restore package-shipped files. Two things to re-check:

```bash
# 1. the bogus bookworm repo
ls /etc/apt/sources.list.d/ | grep pxvirt
# if it reappeared as pxvirt-sources.list:
mv /etc/apt/sources.list.d/pxvirt-sources.list \
   /etc/apt/sources.list.d/pxvirt-sources.list.disabled

# 2. the unverifiable template mirror
python3 /path/to/scripts/patch-aplinfo.py
pveam update
```

The **iptables/nft fix is automatic** — `/etc/apt/apt.conf.d/99pve-pi-fix` runs
`/usr/local/sbin/pve-pi-fix` after every apt operation.

---

## 8. Useful one-liners

```bash
# full health snapshot
{ ip -br addr; echo; systemctl --failed; echo; systemctl is-active \
  pve-cluster pvedaemon pveproxy pvestatd pvescheduler pve-firewall; \
  echo; pveversion; echo; pvesm status; } 2>&1

# is the node name resolvable?
hostname; hostname --ip-address; getent hosts "$(hostname)"

# what changed under /etc on this boot?
journalctl -b -u networking --no-pager

# re-run verification
/path/to/scripts/04-verify.sh --smoke
```

---

## 9. Auto-heal, dependencies and unattended runs

### Is anything broken right now?

```bash
sudo ./heal.sh --check          # one line per known problem; changes nothing
```

Everything should read `[ OK ]`. If not, `sudo ./heal.sh` fixes the eight known
issues and prints what it changed.

### The auto-heal timer

Once installed it runs at boot and hourly, logging to
`/root/proxmox-setup/heal.log`:

```bash
sudo ./heal.sh --timer-status       # enabled? when does it run next?
systemctl list-timers pve-pi-heal.timer
journalctl -u pve-pi-heal.service -n 30
tail -20 /root/proxmox-setup/heal.log
sudo ./heal.sh --uninstall-timer
```

A run looks like this in the log:

```
=== heal run 2026-10-17T08:07:14+08:00 ===
heal run finished: healed=0 warnings=0
```

Networking is intentionally **not** repaired by the timer (a timer that rewrites
the network could drop your SSH session). To allow an `ifup` attempt:

```bash
sudo ./heal.sh --with-network
```

### Dependencies

The scripts declare what they need and install anything missing:

```bash
. scripts/lib/common.sh; echo "$(deps_report)"
# all required dependencies present
```

To see what *would* be installed without installing it:

```bash
NO_INSTALL_DEPS=1 sudo ./preflight.sh
```

### Unattended install

```bash
sudo ./autoinstall.sh            # start / continue
sudo ./autoinstall.sh --status   # stage, attempts, whether the resume unit is armed
sudo ./autoinstall.sh --abort    # stop and disarm (does not roll back)
sudo ./autoinstall.sh --clean    # remove the snapshot + state files
```

It gives up after `AUTO_MAX_ATTEMPTS` failures per stage (default 3) to avoid
boot loops, and tells you where to look. Log:
`/root/proxmox-setup/autoinstall.log`.

If it stopped mid-way, fix the cause and continue with
`sudo /root/proxmox-setup/scripts/autoinstall.sh --foreground`.

---

## 10. Nuclear option

Worst case, re-flash DietPi and start again — but you almost never need to.
Because everything is backed up under `/root/proxmox-setup/backup/`, restoring
the network and hosts is enough to get a bootable, reachable DietPi back; you can
then `apt-get remove --purge 'pve-*' 'proxmox-*'` if you want it fully gone.

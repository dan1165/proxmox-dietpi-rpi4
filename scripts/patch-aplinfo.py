#!/usr/bin/env python3
"""Remove the unreachable/unverifiable lierfang aplinfo mirror from PVE::APLInfo.

Proxmox's template mirror list is hardcoded in
/usr/share/perl5/PVE/APLInfo.pm (sub get_apl_sources). The PXVirt build adds a
mirror whose aplinfo.dat is signed by key
09D2068B4E9AAFF16B27F7FA9A5C09A2D150E209, which is absent from
/usr/share/doc/pve-manager/trustedkeys.gpg -- so every `pveam update` ends in a
signature-verification failure.

The official Proxmox mirror already supplies arm64 templates, so dropping this
entry is safe. Idempotent; keeps a .proxmox-setup.bak copy of the original.
"""
import shutil
import sys

PATH = "/usr/share/perl5/PVE/APLInfo.pm"

BLOCK = """        {
            host => "mirrors.lierfang.com",
            url => "https://mirrors.lierfang.com/pxcloud/pxvirt",
            file => 'lxcs/aplinfo.dat',
        },
"""

REPLACEMENT = """        # Removed by proxmox-setup:
        # this mirror's aplinfo.dat is signed by key
        # 09D2068B4E9AAFF16B27F7FA9A5C09A2D150E209, which is not in
        # pve-manager's trustedkeys.gpg, so `pveam update` always failed.
        # The official Proxmox mirror above already provides arm64 templates.
"""

try:
    src = open(PATH).read()
except OSError as exc:
    print(f"cannot read {PATH}: {exc}")
    sys.exit(1)

if BLOCK not in src:
    if "Removed by proxmox-setup" in src:
        print("ALREADY-PATCHED")
        sys.exit(0)
    print("BLOCK-NOT-FOUND (PVE::APLInfo layout changed?)")
    sys.exit(2)

shutil.copy(PATH, PATH + ".proxmox-setup.bak")
open(PATH, "w").write(src.replace(BLOCK, REPLACEMENT))
print("PATCHED")

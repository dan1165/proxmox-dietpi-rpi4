#!/bin/bash
# ---------------------------------------------------------------------------
# cgroup-fix.sh — enable the memory cgroup controller on Raspberry Pi.
#
# THE PROBLEM
#   The Raspberry Pi device tree (e.g. bcm2711-rpi-4-b.dtb) sets
#   `cgroup_disable=memory` in /chosen/bootargs. The firmware appends
#   cmdline.txt *after* those built-in arguments, which is why the token shows
#   up in /proc/cmdline and dmesg but in NO file under /boot. Consequence:
#
#       /sys/fs/cgroup/cgroup.controllers = "cpuset cpu io pids"   (no memory!)
#
#   So Proxmox/LXC memory limits are silently NOT enforced, and `free` inside a
#   container reports the host's RAM instead of the container's limit.
#
# THE FIX
#   Append `cgroup_no_v1=all cgroup_enable=memory` to the kernel command line.
#   `cgroup_enable=memory` re-enables the controller that the device tree
#   disabled (verified: dmesg prints "Disabling memory control group subsystem"
#   then "Enabling memory control group subsystem").
#
#   Requires a reboot.
#
# USAGE
#   ./cgroup-fix.sh            apply (idempotent); reports if a reboot is needed
#   ./cgroup-fix.sh --check    report only, change nothing
#   ./cgroup-fix.sh --revert   remove the added tokens (reboot to take effect)
#
# EXIT
#   0  memory controller is active — nothing to do
#   10 change applied, reboot required
#   1  error
# ---------------------------------------------------------------------------
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"
# shellcheck source=00-config.sh
[ -f "$HERE/00-config.sh" ] && . "$HERE/00-config.sh"
require_root

WORKDIR="${WORKDIR:-/root/proxmox-setup}"
TOKENS=(cgroup_no_v1=all cgroup_enable=memory)
MARK_BEGIN="# --- proxmox-dietpi-rpi4: memory cgroup ---"

cmdline_file() {
  if [ -f /boot/firmware/cmdline.txt ]; then echo /boot/firmware/cmdline.txt
  elif [ -f /boot/cmdline.txt ]; then echo /boot/cmdline.txt
  else echo ""; fi
}

mem_active() { grep -qw memory /sys/fs/cgroup/cgroup.controllers 2>/dev/null; }

# Collapse the cmdline file to exactly ONE line (the firmware reads a single
# line; a stray newline would silently drop everything after it).
normalize_cmdline() {
  local f="$1" tmp line
  tmp=$(mktemp) || return 1
  line=$(tr '\n' ' ' < "$f" | tr -s '[:space:]' ' ' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
  printf '%s\n' "$line" > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$f"
}

has_token() { # has_token <file> <token>
  grep -qE "(^|[[:space:]])$2([[:space:]]|$)" "$1" 2>/dev/null
}

all_tokens_present() {
  local f="$1" t
  for t in "${TOKENS[@]}"; do has_token "$f" "$t" || return 1; done
  return 0
}

report() {
  local f="$1"
  printf '\n'
  hr
  printf '  memory cgroup controller : %s\n' "$(mem_active && echo "${C_GREEN}active${C_RESET}" || echo "${C_RED}NOT available${C_RESET}")"
  printf '  /sys/fs/cgroup/cgroup.controllers : %s\n' "$(cat /sys/fs/cgroup/cgroup.controllers 2>/dev/null)"
  printf '  kernel cmdline file      : %s\n' "${f:-none found}"
  if [ -n "$f" ]; then
    printf '  fix present in cmdline   : %s\n' "$(all_tokens_present "$f" && echo yes || echo no)"
  fi
  printf '  running kernel cmdline   : %s\n' "$(tr ' ' '\n' < /proc/cmdline | grep -E '^cgroup_' | tr '\n' ' ')"
  hr
}

ACTION="${1:-apply}"

case "$ACTION" in
  --check|check)
    f="$(cmdline_file)"; report "$f"
    if mem_active; then
      ok "memory cgroup is active — container memory limits are enforced"
      exit 0
    fi
    warn "memory cgroup is MISSING — LXC/Proxmox memory limits are not enforced"
    printf '  Fix it with: sudo %s/cgroup-fix.sh   (then reboot)\n\n' "$HERE"
    exit 10
    ;;

  --revert|revert)
    f="$(cmdline_file)"
    [ -n "$f" ] || die "no kernel cmdline file found"
    cp -a "$f" "$WORKDIR/backup/$(basename "$f").pre-cgroup-revert" 2>/dev/null || true
    for t in "${TOKENS[@]}"; do
      sed -i -E "s/(^|[[:space:]])$t([[:space:]]|\$)/\1\2/g" "$f"
    done
    sed -i "/$MARK_BEGIN/d" "$f"
    normalize_cmdline "$f"
    ok "removed the memory-cgroup tokens from $f (reboot to take effect)"
    exit 0
    ;;

  apply|--apply|"")
    f="$(cmdline_file)"
    [ -n "$f" ] || die "no kernel cmdline file found (expected /boot/firmware/cmdline.txt)"

    if all_tokens_present "$f"; then
      step "already present in $f"
      if mem_active; then
        report "$f"; ok "memory cgroup is active"
        exit 0
      fi
      report "$f"
      warn "applied in $f but NOT active yet — a reboot is required"
      exit 10
    fi

    say "Enabling the memory cgroup controller"
    warn "the Raspberry Pi device tree passes 'cgroup_disable=memory' — it is not in any boot file"
    step "appending: ${TOKENS[*]}"

    # back up once, before the first change
    if [ ! -f "$WORKDIR/backup/$(basename "$f").pre-cgroup" ]; then
      mkdir -p "$WORKDIR/backup"
      cp -a "$f" "$WORKDIR/backup/$(basename "$f").pre-cgroup"
      ok "backed up $f -> $WORKDIR/backup/$(basename "$f").pre-cgroup"
    fi

    # cmdline.txt must stay one single line
    normalize_cmdline "$f"
    printf ' %s' "${TOKENS[@]}" >> "$f"
    normalize_cmdline "$f"
    ok "updated $f (single line, $(wc -c < "$f") bytes)"

    report "$f"
    if mem_active; then
      # this can happen if the tokens were already effective somehow
      ok "memory cgroup is active"
      exit 0
    fi
    warn "REBOOT REQUIRED for the memory cgroup controller to appear"
    printf '  after rebooting, verify with: %s/cgroup-fix.sh --check\n\n' "$HERE"
    exit 10
    ;;

  --help|-h)
    sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
    ;;

  *) die "unknown option '$ACTION' (try --help)" ;;
esac

#!/bin/bash
# ---------------------------------------------------------------------------
# autoinstall.sh — fully unattended install that survives the mid-install
# reboot. One command, no prompts, then it heals itself forever after.
#
#   sudo ./autoinstall.sh              start (or continue)
#   sudo ./autoinstall.sh --status     show progress
#   sudo ./autoinstall.sh --abort      stop and disarm the resume unit
#   sudo ./autoinstall.sh --clean      remove the snapshot + state files
#   sudo ./autoinstall.sh --foreground continue the run here (same as --resume)
#
# How it works
#   1. snapshots these scripts to $WORKDIR/scripts, so it keeps working even if
#      you move or delete the repository
#   2. runs the normal gated stages in order, recording progress in
#      $WORKDIR/.stage (the same state file install.sh uses)
#   3. installs a one-shot systemd unit that resumes automatically after the
#      reboot the network stage needs, and removes itself when finished
#   4. installs the auto-heal timer so the machine stays healthy afterwards
#
# What still runs (safety is not disabled, only the prompts):
#   gate 1 preflight            always
#   gate 2 typed confirmation   skipped — this is what makes it unattended
#   gate 3 triple verification  always
# ---------------------------------------------------------------------------
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"
# shellcheck source=00-config.sh
[ -f "$HERE/00-config.sh" ] && . "$HERE/00-config.sh"

WORKDIR="${WORKDIR:-/root/proxmox-setup}"
SNAPSHOT="$WORKDIR/scripts"
LOCKFILE="$WORKDIR/.autoinstall.lock"
UNIT=/etc/systemd/system/pve-pi-autoinstall.service
FINISHED="$WORKDIR/.autoinstall.done"
TRIES="$WORKDIR/.autostage.try"
AUTO_MAX_ATTEMPTS="${AUTO_MAX_ATTEMPTS:-3}"
LOG_FILE="$WORKDIR/autoinstall.log"

MODE="start"
for a in "$@"; do
  case "$a" in
    --resume|--foreground) MODE="resume" ;;
    --status)              MODE="status" ;;
    --abort)               MODE="abort" ;;
    --clean)               MODE="clean" ;;
    --help|-h)             sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  esac
done

# Unattended means: auto-yes everywhere, and skip the typed confirmation only.
export ASSUME_YES=1 FORCE=1
export DEBIAN_FRONTEND=noninteractive

require_root
mkdir -p "$WORKDIR"

# ---- helpers ---------------------------------------------------------------
attempts()       { cat "$TRIES" 2>/dev/null || echo 0; }
bump_attempts()  { echo $(( $(attempts) + 1 )) > "$TRIES"; }
reset_attempts() { echo 0 > "$TRIES"; }
stage()          { state_get 1; }

lock() {
  exec 8>"$LOCKFILE"
  flock -n 8 || die "another autoinstall is already running (lock: $LOCKFILE)"
}

# ---- systemd resume unit ---------------------------------------------------
arm_unit() {
  atomic_write "$UNIT" <<UNIT
[Unit]
Description=Proxmox-on-Pi unattended install (resumes after reboot)
After=network-online.target
Wants=network-online.target
# only present while an auto-install is in progress
ConditionPathExists=$SNAPSHOT/autoinstall.sh

[Service]
Type=oneshot
TimeoutStartSec=infinity
ExecStart=$SNAPSHOT/autoinstall.sh --resume

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable pve-pi-autoinstall.service >/dev/null 2>&1
  rm -f "$FINISHED"
}

disarm_unit() {
  systemctl disable pve-pi-autoinstall.service >/dev/null 2>&1 || true
  rm -f "$UNIT"
  systemctl daemon-reload 2>/dev/null || true
}

# ---- stage runner ----------------------------------------------------------
# 0 = ok, 1 = failed (retry on next boot), 2 = gave up
run_stage() {
  local script="$1" label="$2"
  say "auto-install · $label"

  if [ ! -x "$SNAPSHOT/$script" ]; then
    warn "missing $SNAPSHOT/$script — re-run ./autoinstall.sh to refresh the snapshot"
    return 1
  fi

  local rc=0
  "$SNAPSHOT/$script" || rc=$?
  if [ "$rc" = 0 ]; then
    reset_attempts
    return 0
  fi

  bump_attempts
  local n; n=$(attempts)
  warn "$script failed (rc=$rc, attempt $n/$AUTO_MAX_ATTEMPTS) — see $LOG_FILE"
  if [ "$n" -ge "$AUTO_MAX_ATTEMPTS" ]; then
    err "giving up after $n attempts"
    warn "fix it, then continue with: sudo $SNAPSHOT/autoinstall.sh --foreground"
    warn "or use the interactive menu: sudo $SNAPSHOT/menu.sh"
    disarm_unit
    return 2
  fi
  warn "will retry automatically on the next boot"
  return 1
}

# ---- finishing -------------------------------------------------------------
finish() {
  say "Auto-install complete"
  if [ "${AUTO_INSTALL_HEAL_TIMER:-1}" = 1 ]; then
    "$SNAPSHOT/heal.sh" --install-timer >/dev/null 2>&1 \
      && ok "auto-heal timer installed (at boot + hourly)" \
      || warn "could not install the auto-heal timer"
  fi

  if [ "${AUTO_INSTALL_TAILSCALE:-0}" = 1 ]; then
    if [ -n "${TAILSCALE_AUTHKEY:-}" ]; then
      say "Tailscale (unattended, using TAILSCALE_AUTHKEY)"
      "$SNAPSHOT/tailscale.sh" --auto >/dev/null 2>&1 \
        && ok "tailscale configured as a subnet router for ${PI_SUBNET:-?}" \
        || warn "tailscale setup failed — run: sudo $SNAPSHOT/tailscale.sh"
    else
      warn "AUTO_INSTALL_TAILSCALE=1 but TAILSCALE_AUTHKEY is empty — skipping"
      warn "set it in scripts/00-config.local.sh, or run tailscale.sh interactively"
    fi
  fi

  disarm_unit
  echo done > "$FINISHED"
  state_set 4

  hr
  ok "Proxmox VE is installed and verified"
  printf '  web UI : %shttps://%s:8006%s   (user: root)\n' "$C_CYAN" "${PI_IP:-<pi-ip>}" "$C_RESET"
  printf '  health : sudo %s/heal.sh --check\n' "$SNAPSHOT"
  printf '  menu   : sudo %s/menu.sh\n\n' "$SNAPSHOT"
  exit 0
}

# ---- resume ----------------------------------------------------------------
resume() {
  lock
  if [ -f "$FINISHED" ]; then
    ok "auto-install already finished (delete $FINISHED to redo)"
    exit 0
  fi

  # a reboot can leave the resume unit marked failed; clear it so the final
  # verification does not trip over a stale failure
  systemctl reset-failed 2>/dev/null || true

  [ -d "$SNAPSHOT" ] || die "no scripts snapshot at $SNAPSHOT — run ./autoinstall.sh first"

  say "Waiting for the network"
  if wait_for_network 180; then ok "network is up"; else warn "network not reachable yet — continuing anyway"; fi

  while :; do
    local s rc; s=$(stage)
    case "$s" in
      1)
        run_stage 01-prepare.sh "stage 1/4 · prepare (repo, backups, hosts, dependencies)"
        rc=$?
        [ "$rc" = 0 ] || exit $([ "$rc" = 2 ] && echo 1 || echo 0)
        # 01 sets .stage=2 itself; loop round and continue
        ;;
      2)
        arm_unit
        run_stage 02-network.sh "stage 2/4 · network bridge (reboots when it succeeds)"
        # reaching here means stage 2 aborted or failed and did not reboot
        rc=$?
        warn "stage 2 did not reboot the machine"
        exit $([ "$rc" = 2 ] && echo 1 || echo 0)
        ;;
      3)
        run_stage 03-install-proxmox.sh "stage 3/4 · install Proxmox VE + compatibility fixes"
        rc=$?
        [ "$rc" = 0 ] || exit $([ "$rc" = 2 ] && echo 1 || echo 0)
        ;;
      4)
        run_stage 04-verify.sh "stage 4/4 · verify (three independent passes)"
        rc=$?
        if [ "$rc" = 0 ]; then finish; fi
        if [ "$rc" = 2 ]; then
          warn "verification failed repeatedly — installing the auto-heal timer anyway"
          "$SNAPSHOT/heal.sh" --install-timer >/dev/null 2>&1 || true
          exit 1
        fi
        warn "verification failed — will retry on the next boot"
        exit 0
        ;;
      *)
        finish
        ;;
    esac
  done
}

# ---- modes -----------------------------------------------------------------
case "$MODE" in
  status)
    if [ -s "$WORKDIR/.stage" ]; then st="$(stage) of 4"; else st="not started (defaults to 1)"; fi
    unit=$(systemctl is-enabled pve-pi-autoinstall.service 2>/dev/null || true)
    printf 'auto-install status\n'
    printf '  stage       : %s\n' "$st"
    printf '  attempts    : %s\n' "$(attempts)"
    printf '  snapshot    : %s%s\n' "$SNAPSHOT" "$( [ -d "$SNAPSHOT" ] && echo "" || echo "   (missing)")"
    printf '  resume unit : %s\n' "${unit:-not installed}"
    printf '  finished    : %s\n' "$( [ -f "$FINISHED" ] && echo yes || echo no)"
    printf '  log         : %s\n' "$LOG_FILE"
    ;;

  abort)
    disarm_unit
    state_set 1
    reset_attempts
    ok "auto-install aborted and the resume unit removed (nothing was rolled back)"
    ;;

  clean)
    disarm_unit
    rm -f "$WORKDIR/.stage" "$TRIES" "$FINISHED" "$LOCKFILE"
    rm -rf "$SNAPSHOT"
    ok "removed the scripts snapshot and state (the installation itself is untouched)"
    ;;

  resume)
    resume
    ;;

  start)
    lock
    if [ -f "$FINISHED" ]; then
      ok "already installed — nothing to do"
      printf '  check it with: sudo %s/heal.sh --check\n' "$SNAPSHOT"
      exit 0
    fi

    say "Preparing the unattended install"
    mkdir -p "$SNAPSHOT"
    cp -a "$HERE/." "$SNAPSHOT/" 2>/dev/null || die "could not snapshot $HERE -> $SNAPSHOT"
    chmod +x "$SNAPSHOT"/*.sh 2>/dev/null || true
    ok "scripts snapshot -> $SNAPSHOT"

    [ -s "$WORKDIR/.stage" ] || state_set 1
    reset_attempts
    arm_unit
    ok "resume unit armed (the run continues automatically after a reboot)"

    printf '\n%sUnattended run starting — it may reboot once.%s\n' "$C_BOLD$C_YELLOW" "$C_RESET"
    printf '  progress : sudo %s/autoinstall.sh --status\n' "$SNAPSHOT"
    printf '  log      : %s\n\n' "$LOG_FILE"

    exec "$SNAPSHOT/autoinstall.sh" --resume
    ;;
esac

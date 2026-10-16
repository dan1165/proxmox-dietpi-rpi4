#!/bin/bash
# ---------------------------------------------------------------------------
# lib/common.sh — shared helpers: logging, safety gates, confirmations, TUI.
#
# Source it, don't execute it:
#     . "$(dirname "$0")/lib/common.sh"
#
# Design goals: loud, safe, resumable. Nothing destructive happens without
# passing the three-gate apply protocol (see docs/safety.md).
# ---------------------------------------------------------------------------

# shellcheck disable=SC2034
PVE_RPI_VERSION="1.2.0"

# ---- colours (only when stdout is a terminal) -----------------------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'; C_CYAN=$'\033[36m'; C_MAGENTA=$'\033[35m'
else
  C_RESET=; C_BOLD=; C_DIM=; C_RED=; C_GREEN=; C_YELLOW=; C_BLUE=; C_CYAN=; C_MAGENTA=
fi
export NO_COLOR="${NO_COLOR:-}"

# ---- output helpers -------------------------------------------------------
LOG_FILE="${LOG_FILE:-}"

_msg() { # append a plain-text line to $LOG_FILE (never prints)
  [ -n "$LOG_FILE" ] || return 0
  printf '%s  %s\n' "$(date -Is)" "$1" >> "$LOG_FILE" 2>/dev/null
  return 0
}

say()  { printf '\n%s==> %s%s\n' "$C_BOLD$C_CYAN" "$*" "$C_RESET"; _msg "==> $*"; }
step() { printf '%s  · %s%s\n' "$C_DIM" "$*" "$C_RESET"; _msg "    $*"; }
ok()   { printf '%s  [ OK ]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; _msg "[ OK ] $*"; }
info() { printf '%s  [info]%s %s\n' "$C_BLUE" "$C_RESET" "$*"; _msg "[info] $*"; }
warn() { printf '%s  [warn]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; _msg "[warn] $*"; }
err()  { printf '%s  [FAIL]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; _msg "[FAIL] $*"; }

die() { err "$*"; printf '\n%sAborting.%s\n' "$C_RED$C_BOLD" "$C_RESET" >&2; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

# ---- error trap -----------------------------------------------------------
# Call `install_error_trap <script-name>` near the top of any script that must
# fail loudly with context. Reads $LOG_FILE (if set) and the line that failed.
install_error_trap() {
  local name="${1:-script}"
  set -Eeuo pipefail
  trap '_pve_on_error "$name"' ERR
}
_pve_on_error() {
  local name="$1" code=$? line=${BASH_LINENO[0]:-?} cmd=${BASH_COMMAND:-?}
  err "$name failed (exit $code) at line $line: $cmd"
  if [ -n "$LOG_FILE" ] && [ -f "$LOG_FILE" ]; then
    printf '\n%sLast 20 log lines (%s):%s\n' "$C_DIM" "$LOG_FILE" "$C_RESET" >&2
    tail -n 20 "$LOG_FILE" >&2 || true
  fi
  exit "$code"
}

# ---- preconditions --------------------------------------------------------
require_root() { [ "$(id -u)" -eq 0 ] || die "must run as root (use sudo)"; }

require_tty_or_yes() {
  [ -t 0 ] && return 0
  [ "${ASSUME_YES:-0}" = 1 ] && return 0
  die "not a terminal; re-run with --yes for non-interactive use"
}

os_codename() { ( . /etc/os-release && printf '%s' "${VERSION_CODENAME:-}" ); }
is_dietpi()   { [ -f /boot/dietpi/.version ] || [ -d /boot/dietpi ]; }
pve_installed() { dpkg -s proxmox-ve >/dev/null 2>&1; }
bridge_exists() { ip link show "$1" >/dev/null 2>&1; }

# ---- state (resumable install) --------------------------------------------
state_file() { printf '%s/.stage' "${WORKDIR:-/root/proxmox-setup}"; }
state_get()  { cat "$(state_file)" 2>/dev/null || echo "${1:-1}"; }
state_set()  { mkdir -p "${WORKDIR:-/root/proxmox-setup}"; echo "$1" > "$(state_file)"; }

# ---- locking (prevent concurrent runs) ------------------------------------
acquire_lock() {
  local lockdir="${WORKDIR:-/root/proxmox-setup}"
  mkdir -p "$lockdir"
  exec 9>"$lockdir/.lock"
  if ! flock -n 9; then
    die "another proxmox-dietpi-rpi4 process is already running (lock: $lockdir/.lock)"
  fi
}

# ---- filesystem safety -----------------------------------------------------
# atomic_write <path>   — read stdin, write to a temp file, then rename.
atomic_write() {
  local path="$1" tmp
  tmp=$(mktemp "${path}.tmp.XXXXXX") || return 1
  cat > "$tmp" || { rm -f "$tmp"; return 1; }
  chmod --reference="$path" "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$path"
}

# backup_file <path> [label]  — timestamped copy under $WORKDIR/backup-orig
backup_file() {
  local path="$1" label="${2:-}" dest
  [ -e "$path" ] || return 0
  dest="${WORKDIR:-/root/proxmox-setup}/backup-orig"
  mkdir -p "$dest"
  cp -a "$path" "$dest/$(basename "$path")${label:+.$label}" && \
    step "backed up $path -> $dest/$(basename "$path")${label:+.$label}"
}

# ---- confirmations ---------------------------------------------------------
# Yes/no (defaults to No). Non-interactive without ASSUME_YES => "no".
confirm_yes() {
  local prompt="$1" ans
  if [ "${ASSUME_YES:-0}" = 1 ]; then info "auto-yes: $prompt"; return 0; fi
  if [ ! -t 0 ]; then warn "not a terminal — treating as 'no': $prompt"; return 1; fi
  read -r -p "${C_BOLD}${prompt}${C_RESET} [y/N] " ans || return 1
  case "$ans" in y|Y|yes|YES) return 0;; *) return 1;; esac
}

# Type an exact phrase. Non-interactive without FORCE => failure.
confirm_phrase() {
  local phrase="$1" prompt="${2:-Type '$1' to proceed}"
  local ans
  if [ "${FORCE:-0}" = 1 ]; then
    warn "FORCE=1 — skipping typed confirmation for: $phrase"
    return 0
  fi
  if [ ! -t 0 ]; then
    warn "typed confirmation required but stdin is not a terminal"
    return 1
  fi
  printf '\n%s%s%s\n' "$C_BOLD$C_YELLOW" "$prompt" "$C_RESET"
  read -r -p "  > " ans || return 1
  if [ "$ans" != "$phrase" ]; then
    warn "phrase did not match (got '$ans'); aborting"
    return 1
  fi
  return 0
}

# Abortable countdown (e.g. before a reboot). Returns 1 if the user aborts.
countdown_abort() {
  local secs="$1" msg="$2" i
  [ "${ASSUME_YES:-0}" = 1 ] && return 0
  if [ ! -t 0 ]; then sleep 2; return 0; fi
  printf '%s%s%s  (Ctrl-C or 'a' to abort)\n' "$C_BOLD" "$msg" "$C_RESET"
  for ((i=secs; i>0; i--)); do
    printf '\r  %s%2ds%s ' "$C_DIM" "$i" "$C_RESET"
    if read -rsn1 -t1 key; then
      case "$key" in a|A|q|Q) printf '\n'; warn "aborted by operator"; return 1;; esac
    fi
  done
  printf '\n'
  return 0
}

# ---- three-gate apply protocol --------------------------------------------
# Gate 1 — preflight (automated safety checks) must be green.
gate_preflight() {
  local here="$1"
  say "Gate 1/3 — preflight safety checks"
  if "$here/preflight.sh" --quiet; then
    ok "preflight passed"
    return 0
  fi
  err "preflight did not pass — refusing to continue"
  printf '  Run the checks in detail with:  %s/preflight.sh\n' "$here"
  return 1
}

# Gate 2 — explicit, typed confirmation.
gate_confirm() {
  local phrase="$1" prompt="$2"
  say "Gate 2/3 — operator confirmation"
  confirm_phrase "$phrase" "$prompt" || return 1
  ok "confirmed"
  return 0
}

# Gate 3 — independent triple verification of what was just applied.
# Usage: gate_triple "label" "desc1::cmd1" "desc2::cmd2" "desc3::cmd3"
gate_triple() {
  local label="$1"; shift
  say "Gate 3/3 — triple verification: $label"
  local pair desc cmd n=0 pass=0
  for pair in "$@"; do
    desc="${pair%%::*}"; cmd="${pair#*::}"
    n=$((n+1))
    if bash -c "$cmd" >/dev/null 2>&1; then
      ok "$desc"
      pass=$((pass+1))
    else
      err "$desc"
    fi
  done
  if [ "$pass" -eq "$n" ]; then
    ok "$label verified ($pass/$n independent checks)"
    return 0
  fi
  err "$label verification FAILED ($pass/$n)"
  return 1
}

# ---- TUI ------------------------------------------------------------------
tui_available() { [ -t 0 ] && [ -t 1 ] && [ -z "${NO_TUI:-}" ]; }

_menu_draw() { # _menu_draw <selected> <opt...>
  local sel="$1"; shift
  local -a opts=("$@")
  local i
  for i in "${!opts[@]}"; do
    if [ "$i" -eq "$sel" ]; then
      printf '  %s▸ %s%s%s\033[K\n' "$C_GREEN$C_BOLD" "$C_RESET$C_BOLD" "${opts[$i]}" "$C_RESET"
    else
      printf '    %s%s%s\033[K\n' "$C_DIM" "${opts[$i]}" "$C_RESET"
    fi
  done
  printf '  %s↑/↓ or k/j move · Enter select · 1-%d jump · q quit%s\033[K\n' \
    "$C_DIM" "${#opts[@]}" "$C_RESET"
}

# tui_menu <header-string> <option...>
# Sets TUI_CHOICE (1-based). Returns 1 on quit/cancel.
tui_menu() {
  local header="$1"; shift
  local -a opts=("$@")
  local n=${#opts[@]} sel=0 key rest drawn

  printf '%s\n' "$header"

  if ! tui_available; then
    printf '\n'
    local i
    for i in "${!opts[@]}"; do printf '  %d) %s\n' "$((i+1))" "${opts[$i]}"; done
    local ans
    read -r -p "Choice [1-$n, q to quit]: " ans || return 1
    case "$ans" in ''|q|Q) return 1;; esac
    if [[ "$ans" =~ ^[0-9]+$ ]] && [ "$ans" -ge 1 ] && [ "$ans" -le "$n" ]; then
      TUI_CHOICE=$ans; return 0
    fi
    return 1
  fi

  printf '\n'
  _menu_draw "$sel" "${opts[@]}"
  drawn=$(( n + 1 ))

  while :; do
    IFS= read -rsn1 key || { printf '\n'; return 1; }

    case "$key" in
      $'\033')
        IFS= read -rsn2 -t 0.05 rest || rest=""
        case "$rest" in
          '[A') [ "$sel" -gt 0 ] && sel=$((sel-1)) ;;
          '[B') [ "$sel" -lt $((n-1)) ] && sel=$((sel+1)) ;;
        esac
        ;;
      k|K) [ "$sel" -gt 0 ] && sel=$((sel-1)) ;;
      j|J) [ "$sel" -lt $((n-1)) ] && sel=$((sel+1)) ;;
      q|Q) printf '\n'; return 1 ;;
      '')  TUI_CHOICE=$((sel+1)); printf '\n'; return 0 ;;
      *)
        if [[ "$key" =~ ^[1-9]$ ]] && [ "$key" -ge 1 ] && [ "$key" -le "$n" ]; then
          TUI_CHOICE=$key; printf '\n'; return 0
        fi
        ;;
    esac

    printf '\033[%dA' "$drawn"
    _menu_draw "$sel" "${opts[@]}"
  done
}

# ---- misc -----------------------------------------------------------------
hr() { printf '%s%s%s\n' "$C_DIM" "────────────────────────────────────────────────────────────" "$C_RESET"; }

json_get() { # json_get <file> <python-expr-on-d>
  python3 -c '
import sys, json
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print(""); sys.exit(0)
print(eval(sys.argv[2]))
' "$1" "$2" 2>/dev/null || true
}

#!/bin/bash
# ---------------------------------------------------------------------------
# lib/deps.sh — required-dependency manifest, detection and auto-install.
#
# Sourced by lib/common.sh, so every script gets it. Nothing here runs on
# source; call ensure_deps when you need the tools.
#
#   deps_missing            print "command package" for each missing item
#   deps_missing_packages   print just the package names, deduped
#   deps_report             human-readable one-liner (used by preflight)
#   ensure_deps [--quiet]   install whatever is missing (needs root + network)
#
# Environment:
#   NO_INSTALL_DEPS=1       detect only, never install (used by checks)
# ---------------------------------------------------------------------------

# "command:package" pairs. Keep this to what the scripts actually use.
PVE_RPI_CMD_DEPS=(
  "curl:curl"
  "python3:python3"
  "ip:iproute2"
  "ss:iproute2"
  "ping:iputils-ping"
  "getent:libc-bin"
  "flock:util-linux"
)

# Useful extras: installed by `ensure_deps --all`, never treated as blockers.
PVE_RPI_OPT_DEPS=(
  "ethtool:ethtool"
  "gpg:gnupg"
  "brctl:bridge-utils"
)

# Packages required even when no command from them is used directly.
PVE_RPI_PKG_DEPS=( ca-certificates )

have_pkg() { dpkg -s "$1" >/dev/null 2>&1; }

deps_missing() {
  local pair cmd pkg p
  for pair in "${PVE_RPI_CMD_DEPS[@]}"; do
    cmd="${pair%%:*}"; pkg="${pair##*:}"
    have "$cmd" || printf '%s %s\n' "$cmd" "$pkg"
  done
  for p in "${PVE_RPI_PKG_DEPS[@]}"; do
    have_pkg "$p" || printf '%s %s\n' "(package $p)" "$p"
  done
}

deps_missing_optional() {
  local pair cmd pkg
  for pair in "${PVE_RPI_OPT_DEPS[@]}"; do
    cmd="${pair%%:*}"; pkg="${pair##*:}"
    have "$cmd" || printf '%s %s\n' "$cmd" "$pkg"
  done
}

deps_missing_packages() { deps_missing | awk '{print $2}' | sort -u; }

# One-line summary for preflight / status output.
deps_report() {
  local m
  m=$(deps_missing)
  if [ -z "$m" ]; then
    printf 'all required dependencies present'
  else
    printf 'missing: %s' "$(printf '%s\n' "$m" | awk '{print $1}' | tr '\n' ' ')"
  fi
}

# Install anything missing. Returns 0 if everything is present afterwards.
ensure_deps() {
  local quiet=0
  [ "${1:-}" = "--quiet" ] && quiet=1

  local missing; missing=$(deps_missing)
  if [ -z "$missing" ]; then
    [ "$quiet" = 1 ] || ok "all required dependencies are present"
    return 0
  fi

  local cmd pkg
  while read -r cmd pkg; do
    [ -n "$pkg" ] && warn "missing dependency: $cmd  (package: $pkg)"
  done <<< "$missing"

  if [ "${NO_INSTALL_DEPS:-0}" = 1 ]; then
    err "dependencies are missing and NO_INSTALL_DEPS=1 — not installing"
    return 1
  fi

  local pkgs; pkgs=$(printf '%s\n' "$missing" | awk '{print $2}' | sort -u | tr '\n' ' ')
  [ -n "$pkgs" ] || return 0

  say "Installing missing dependencies: $pkgs"
  export DEBIAN_FRONTEND=noninteractive

  if ! apt-get install -y $pkgs; then
    warn "install failed — refreshing package lists and retrying"
    apt-get update -qq || true
    if ! apt-get install -y $pkgs; then
      err "could not install: $pkgs"
      return 1
    fi
  fi

  missing=$(deps_missing)
  if [ -n "$missing" ]; then
    err "still missing after install: $(printf '%s\n' "$missing" | awk '{print $1}' | tr '\n' ' ')"
    return 1
  fi
  ok "dependencies installed: $pkgs"
  return 0
}

# Optional extras (ethtool, gnupg, bridge-utils) — best effort.
ensure_optional_deps() {
  local missing; missing=$(deps_missing_optional)
  [ -n "$missing" ] || { ok "optional tools already present"; return 0; }
  local pkgs; pkgs=$(printf '%s\n' "$missing" | awk '{print $2}' | sort -u | tr '\n' ' ')
  [ -n "$pkgs" ] || return 0
  [ "${NO_INSTALL_DEPS:-0}" = 1 ] && return 0
  say "Installing optional tools: $pkgs"
  DEBIAN_FRONTEND=noninteractive apt-get install -y $pkgs >/dev/null 2>&1 \
    && ok "optional tools installed: $pkgs" \
    || warn "optional tools not installed: $pkgs (not required)"
  return 0
}

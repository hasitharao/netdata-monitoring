#!/usr/bin/env bash
#
# cleanup.sh - Remove the Netdata agent and test leftovers.
#
# Usage:  ./cleanup.sh [--purge] [--yes]
#   --purge   also delete config, data, cache and logs (including the custom alert)
#   --yes     do not ask for confirmation (for automation / CI)
#
# Tools installed by setup.sh (curl, jq, stress-ng) are left in place on purpose.

set -euo pipefail

KICKSTART_URL="https://get.netdata.cloud/kickstart.sh"
PURGE=0
ASSUME_YES=0

log()  { printf '\033[1;34m[cleanup]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[cleanup] WARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[cleanup] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

usage() { sed -n '3,9p' "$0" | sed 's/^# \{0,1\}//'; }

run_root() {
  if [ "$(id -u)" -eq 0 ]; then "$@"; else sudo "$@"; fi
}

netdata_installed() {
  command -v netdata >/dev/null 2>&1 || [ -x /usr/sbin/netdata ] || [ -x /opt/netdata/bin/netdata ]
}

parse_args() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --purge)   PURGE=1 ;;
      -y|--yes)  ASSUME_YES=1 ;;
      -h|--help) usage; exit 0 ;;
      *)         die "Unknown option: $arg (see --help)" ;;
    esac
  done
}

confirm() {
  [ "$ASSUME_YES" -eq 1 ] && return 0
  [ -t 0 ] || die "Not a terminal; re-run with --yes to confirm."
  local ans
  read -r -p "This will remove Netdata$([ "$PURGE" -eq 1 ] && echo ' AND all its config/data') from this machine. Continue? [y/N] " ans
  case "$ans" in y|Y|yes|YES) return 0 ;; *) log "Aborted."; exit 0 ;; esac
}

main() {
  [ "$(uname -s)" = "Linux" ] || die "Run this inside the Linux host/VM (see ./mac-vm.sh cleanup)."
  parse_args "$@"
  confirm

  log "Stopping any leftover load generators..."
  pkill stress-ng 2>/dev/null || true
  rm -f /tmp/netdata_io_test.* /tmp/netdata_stress.*.log

  if netdata_installed; then
    local tmp
    tmp="$(mktemp)"
    log "Downloading kickstart.sh and uninstalling Netdata..."
    curl -fsSL "$KICKSTART_URL" -o "$tmp"
    run_root sh "$tmp" --uninstall --non-interactive
    rm -f "$tmp"
  else
    log "Netdata binary not found - nothing to uninstall."
  fi

  if [ "$PURGE" -eq 1 ]; then
    log "Purging config, data, cache and logs..."
    run_root rm -rf /etc/netdata /var/lib/netdata /var/cache/netdata /var/log/netdata /opt/netdata
  fi

  # Verify
  if netdata_installed; then
    die "Netdata binary is still present - uninstall did not complete."
  fi
  if curl -fsS --max-time 3 http://127.0.0.1:19999/api/v1/info >/dev/null 2>&1; then
    die "Something is still answering on port 19999."
  fi
  log "Clean: Netdata is removed and port 19999 is closed."
}

main "$@"

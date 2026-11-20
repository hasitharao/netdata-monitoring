#!/usr/bin/env bash
#
# test_dashboard.sh - Put load on the system and verify the Netdata dashboard reacts.
#
# What it does:
#   - Generates CPU, memory and disk I/O load at the same time
#   - Sends a custom StatsD gauge (devops.demo.heartbeat) so a custom chart appears
#   - Polls Netdata's API and reports when the 'cpu_usage_high' alert changes state
#   - Exits 0 if the alert fired (WARNING/CRITICAL), 1 otherwise (CI-friendly)
#
# Usage:  ./test_dashboard.sh
# Env:    DURATION=120                       load duration in seconds
#         ALERT_NAME=cpu_usage_high          alert to watch
#         NETDATA_API=http://127.0.0.1:19999

set -euo pipefail

DURATION="${DURATION:-120}"
ALERT_NAME="${ALERT_NAME:-cpu_usage_high}"
API="${NETDATA_API:-http://127.0.0.1:19999}"
STATSD_PORT="${STATSD_PORT:-8125}"
IO_FILE="/tmp/netdata_io_test.$$"
STRESS_LOG="/tmp/netdata_stress.$$.log"
STRESS_PID=""
DISK_PID=""

log()  { printf '\033[1;34m[test]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[test] WARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[test] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

run_root() {
  if [ "$(id -u)" -eq 0 ]; then "$@"; else sudo "$@"; fi
}

cleanup() {
  if [ -n "$DISK_PID" ]; then kill "$DISK_PID" 2>/dev/null || true; fi
  if [ -n "$STRESS_PID" ]; then kill "$STRESS_PID" 2>/dev/null || true; fi
  rm -f "$IO_FILE" "$STRESS_LOG"
}
trap cleanup EXIT INT TERM

# Fire-and-forget StatsD packet over UDP using bash's /dev/udp (no nc needed).
send_statsd() {
  { printf '%s' "$1" > "/dev/udp/127.0.0.1/${STATSD_PORT}"; } 2>/dev/null || true
}

alert_status() {
  curl -fsS "$API/api/v1/alarms?all" 2>/dev/null \
    | jq -r --arg n "$ALERT_NAME" '[.alarms[]? | select(.name==$n) | .status][0] // "NOT_FOUND"' 2>/dev/null \
    || echo "API_ERROR"
}

preflight() {
  [ "$(uname -s)" = "Linux" ] || die "Run this inside the Linux host/VM (see ./mac-vm.sh test)."
  command -v curl >/dev/null 2>&1 || die "curl is required."
  command -v jq   >/dev/null 2>&1 || die "jq is required (run setup.sh first)."

  if ! command -v stress-ng >/dev/null 2>&1; then
    command -v apt-get >/dev/null 2>&1 || die "stress-ng is required; install it with your package manager."
    log "Installing stress-ng..."
    run_root env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq stress-ng
  fi

  curl -fsS "$API/api/v1/info" >/dev/null 2>&1 \
    || die "Netdata is not answering on $API. Did you run ./setup.sh?"
}

disk_load() {
  # Direct (uncached) writes and reads so the activity shows up in Netdata's disk charts.
  local end=$((SECONDS + DURATION))
  while [ "$SECONDS" -lt "$end" ]; do
    dd if=/dev/zero of="$IO_FILE" bs=1M count=256 oflag=direct status=none 2>/dev/null \
      || dd if=/dev/zero of="$IO_FILE" bs=1M count=256 conv=fsync status=none 2>/dev/null || true
    dd if="$IO_FILE" of=/dev/null bs=1M iflag=direct status=none 2>/dev/null || true
  done
}

main() {
  preflight

  local cpus mem_mb
  cpus="$(nproc)"
  mem_mb="$(awk '/MemAvailable/ {printf "%d", $2/1024*0.4}' /proc/meminfo)"

  log "Starting load for ${DURATION}s: ${cpus} CPU workers, ${mem_mb} MB memory, disk I/O loop."
  log "Open the dashboard now and watch the CPU, RAM and Disk sections."

  stress-ng --cpu 0 --vm 1 --vm-bytes "${mem_mb}M" --timeout "${DURATION}s" >"$STRESS_LOG" 2>&1 &
  STRESS_PID=$!
  disk_load &
  DISK_PID=$!

  send_statsd "devops.demo.test_runs:1|c"

  local elapsed=0 fired="no" status
  while [ "$elapsed" -lt $((DURATION + 10)) ]; do
    sleep 10
    elapsed=$((elapsed + 10))
    status="$(alert_status)"
    send_statsd "devops.demo.heartbeat:${elapsed}|g"
    printf '  t=%3ss  load1=%s  alert[%s]=%s\n' \
      "$elapsed" "$(cut -d' ' -f1 /proc/loadavg)" "$ALERT_NAME" "$status"
    case "$status" in WARNING|CRITICAL) fired="yes" ;; esac
  done

  wait "$STRESS_PID" 2>/dev/null || { warn "stress-ng exited with an error:"; cat "$STRESS_LOG" >&2; }
  STRESS_PID=""
  wait "$DISK_PID" 2>/dev/null || true
  DISK_PID=""

  # Soft check: did the custom StatsD chart appear?
  if curl -fsS "$API/api/v1/charts" 2>/dev/null | jq -r '.charts | keys[]' 2>/dev/null | grep -i heartbeat >/dev/null; then
    log "Custom StatsD chart detected (look for 'heartbeat' under the StatsD section)."
  else
    warn "Custom StatsD chart not detected yet; check the StatsD section of the dashboard."
  fi

  echo
  if [ "$fired" = "yes" ]; then
    log "PASS: alert '${ALERT_NAME}' fired under load. It will return to CLEAR within a couple of minutes."
  else
    echo "[test] FAIL: alert '${ALERT_NAME}' never reached WARNING/CRITICAL." >&2
    echo "       Try a longer run (DURATION=240) or check: curl -s '$API/api/v1/alarms?all' | jq ." >&2
    exit 1
  fi
}

main "$@"

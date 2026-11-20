#!/usr/bin/env bash
#
# setup.sh - Install and configure Netdata on a Debian/Ubuntu-family Linux host.
#
# What it does:
#   1. Installs prerequisites (curl, jq, stress-ng)
#   2. Installs the Netdata agent using the official kickstart.sh
#   3. Binds the dashboard to all interfaces (needed to reach a VM from your Mac)
#   4. Adds a custom alert: CPU usage above 80% (1-minute average)
#   5. Restarts Netdata and waits until the dashboard answers
#
# Usage:  sudo ./setup.sh
# Env:    NETDATA_CHANNEL=stable|nightly   (default: stable)
#         NETDATA_BIND=*                   (default: *; use 127.0.0.1 to keep it local)
#         CPU_WARN=80 CPU_CRIT=95          (alert thresholds in percent)
#
# The script is idempotent: running it twice is safe.

set -euo pipefail

NETDATA_CHANNEL="${NETDATA_CHANNEL:-stable}"
NETDATA_BIND="${NETDATA_BIND:-*}"
CPU_WARN="${CPU_WARN:-80}"
CPU_CRIT="${CPU_CRIT:-95}"
KICKSTART_URL="https://get.netdata.cloud/kickstart.sh"
API="http://127.0.0.1:19999"
CONF_DIR="/etc/netdata"

log()  { printf '\033[1;34m[setup]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[setup] WARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[setup] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

run_root() {
  if [ "$(id -u)" -eq 0 ]; then "$@"; else sudo "$@"; fi
}

netdata_installed() {
  command -v netdata >/dev/null 2>&1 || [ -x /usr/sbin/netdata ] || [ -x /opt/netdata/bin/netdata ]
}

preflight() {
  [ "$(uname -s)" = "Linux" ] || die "Netdata must be installed on Linux. On macOS, run ./mac-vm.sh up (it creates an Ubuntu VM and runs this script inside it)."
  if [ "$(id -u)" -ne 0 ]; then
    command -v sudo >/dev/null 2>&1 || die "Run as root or install sudo."
  fi
}

install_prereqs() {
  if command -v apt-get >/dev/null 2>&1; then
    log "Installing prerequisites with apt (curl, jq, stress-ng)..."
    run_root env DEBIAN_FRONTEND=noninteractive apt-get update -qq
    run_root env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl ca-certificates jq stress-ng
  elif command -v dnf >/dev/null 2>&1; then
    log "Installing prerequisites with dnf (curl, jq)..."
    run_root dnf install -y curl jq
    warn "stress-ng is not in the default RHEL-family repos; install it (EPEL) before running test_dashboard.sh."
  else
    command -v curl >/dev/null 2>&1 || die "curl is required."
    command -v jq   >/dev/null 2>&1 || warn "jq is missing; test_dashboard.sh needs it."
  fi
}

install_netdata() {
  if netdata_installed; then
    log "Netdata is already installed - skipping the install step."
    return
  fi
  local tmp
  tmp="$(mktemp)"
  log "Downloading kickstart.sh..."
  curl -fsSL "$KICKSTART_URL" -o "$tmp"
  log "Installing Netdata (channel: ${NETDATA_CHANNEL}). This can take a few minutes..."
  # DISABLE_TELEMETRY=1 opts out of anonymous install statistics.
  run_root env DISABLE_TELEMETRY=1 sh "$tmp" --non-interactive --release-channel "$NETDATA_CHANNEL"
  rm -f "$tmp"
}

configure_netdata() {
  # Static (non-package) installs keep their config under /opt/netdata.
  if [ -d /opt/netdata/etc/netdata ]; then CONF_DIR="/opt/netdata/etc/netdata"; fi
  [ -d "$CONF_DIR" ] || die "Netdata config directory not found at $CONF_DIR."

  # 1) Make the dashboard reachable from outside the VM.
  if ! run_root grep -qs "managed by setup.sh" "$CONF_DIR/netdata.conf"; then
    log "Setting dashboard bind address to '${NETDATA_BIND}'..."
    printf '\n# --- managed by setup.sh ---\n[web]\n\tbind to = %s\n' "$NETDATA_BIND" \
      | run_root tee -a "$CONF_DIR/netdata.conf" >/dev/null
  fi

  # 2) Custom alert: warn above CPU_WARN%, critical above CPU_CRIT%.
  log "Writing custom alert 'cpu_usage_high' (warn > ${CPU_WARN}%, crit > ${CPU_CRIT}%)..."
  run_root mkdir -p "$CONF_DIR/health.d"
  run_root tee "$CONF_DIR/health.d/custom_cpu_alert.conf" >/dev/null <<EOF
# Custom alert created by setup.sh
alarm: cpu_usage_high
   on: system.cpu
lookup: average -1m unaligned of user,system,softirq,irq,guest
 units: %
 every: 10s
  warn: \$this > ${CPU_WARN}
  crit: \$this > ${CPU_CRIT}
  info: CPU utilization (1-minute average) is above ${CPU_WARN}%
    to: sysadmin
EOF
}

restart_and_wait() {
  if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    run_root systemctl enable netdata >/dev/null 2>&1 || true
    log "Restarting Netdata..."
    run_root systemctl restart netdata
  else
    warn "systemd not detected - restart Netdata manually to apply the config."
  fi

  log "Waiting for the dashboard to come up..."
  for _ in $(seq 1 60); do
    if curl -fsS "$API/api/v1/info" >/dev/null 2>&1; then
      log "Netdata is responding on $API"
      return
    fi
    sleep 2
  done
  die "Netdata did not respond within 2 minutes. Check: sudo journalctl -u netdata -n 50"
}

verify_alert() {
  for _ in $(seq 1 12); do
    if curl -fsS "$API/api/v1/alarms?all" 2>/dev/null \
        | jq -e '[.alarms[]? | select(.name=="cpu_usage_high")] | length > 0' >/dev/null 2>&1; then
      log "Custom alert 'cpu_usage_high' is loaded."
      return
    fi
    sleep 5
  done
  warn "Could not confirm the custom alert is loaded yet (the health engine can take a minute). Check: curl -s '$API/api/v1/alarms?all' | jq ."
}

print_summary() {
  local ip
  ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  echo
  log "Done."
  echo "  Dashboard (on this host): http://localhost:19999"
  [ -n "$ip" ] && echo "  Dashboard (from outside): http://${ip}:19999"
  echo "  Next: ./test_dashboard.sh   (generate load and watch the alert fire)"
}

main() {
  preflight
  install_prereqs
  install_netdata
  configure_netdata
  restart_and_wait
  verify_alert
  print_summary
}

main "$@"

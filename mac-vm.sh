#!/usr/bin/env bash
#
# mac-vm.sh - Run the Linux-only Netdata project from your MacBook.
#
# Netdata (for this project) must run on Linux, so this script creates a small
# Ubuntu 24.04 ARM64 VM with Multipass and runs setup.sh / test_dashboard.sh /
# cleanup.sh inside it. Run this on macOS, NOT inside the VM.
#
# Prerequisite:  brew install --cask multipass
#
# Usage:  ./mac-vm.sh <command>
#   up        create the VM (if needed), run setup.sh, open the dashboard
#   test      run test_dashboard.sh inside the VM (DURATION=120 by default)
#   cleanup   run cleanup.sh --purge inside the VM (removes Netdata, keeps the VM)
#   status    show the VM state and the dashboard URL
#   shell     open a shell inside the VM
#   destroy   delete the VM completely
#
# Env:  VM_NAME=netdata-lab  VM_CPUS=2  VM_MEM=2G  VM_DISK=15G  VM_IMAGE=24.04

set -euo pipefail

VM_NAME="${VM_NAME:-netdata-lab}"
VM_CPUS="${VM_CPUS:-2}"
VM_MEM="${VM_MEM:-2G}"
VM_DISK="${VM_DISK:-15G}"
VM_IMAGE="${VM_IMAGE:-24.04}"
REMOTE_DIR="/home/ubuntu"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() { printf '\033[1;34m[mac-vm]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[mac-vm] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

usage() { sed -n '3,19p' "$0" | sed 's/^# \{0,1\}//'; }

preflight() {
  [ "$(uname -s)" = "Darwin" ] || die "This helper is for macOS. On Linux, run ./setup.sh directly."
  command -v multipass >/dev/null 2>&1 || die "Multipass not found. Install it with: brew install --cask multipass"
}

vm_exists() { multipass info "$VM_NAME" >/dev/null 2>&1; }

vm_ip() { multipass info "$VM_NAME" | awk '/^IPv4/ {print $2; exit}'; }

push_scripts() {
  log "Copying scripts into the VM..."
  multipass transfer \
    "$SCRIPT_DIR/setup.sh" "$SCRIPT_DIR/test_dashboard.sh" "$SCRIPT_DIR/cleanup.sh" \
    "${VM_NAME}:${REMOTE_DIR}/"
}

in_vm() { multipass exec "$VM_NAME" -- "$@"; }

cmd_up() {
  if vm_exists; then
    log "VM '$VM_NAME' already exists - reusing it."
    multipass start "$VM_NAME" >/dev/null 2>&1 || true
  else
    log "Creating VM '$VM_NAME' (Ubuntu $VM_IMAGE, ${VM_CPUS} CPUs, ${VM_MEM} RAM, ${VM_DISK} disk)..."
    multipass launch "$VM_IMAGE" --name "$VM_NAME" --cpus "$VM_CPUS" --memory "$VM_MEM" --disk "$VM_DISK"
  fi
  push_scripts
  in_vm sudo bash "${REMOTE_DIR}/setup.sh"
  local ip url
  ip="$(vm_ip)"
  url="http://${ip}:19999"
  log "Dashboard: $url"
  open "$url" || true
}

cmd_test() {
  vm_exists || die "VM '$VM_NAME' not found. Run: ./mac-vm.sh up"
  push_scripts
  in_vm env DURATION="${DURATION:-120}" bash "${REMOTE_DIR}/test_dashboard.sh"
}

cmd_cleanup() {
  vm_exists || die "VM '$VM_NAME' not found."
  push_scripts
  in_vm sudo bash "${REMOTE_DIR}/cleanup.sh" --purge --yes
}

cmd_status() {
  vm_exists || die "VM '$VM_NAME' not found. Run: ./mac-vm.sh up"
  multipass info "$VM_NAME" | sed -n '1,8p'
  log "Dashboard: http://$(vm_ip):19999"
}

main() {
  local cmd="${1:-}"
  case "$cmd" in
    up)      preflight; cmd_up ;;
    test)    preflight; cmd_test ;;
    cleanup) preflight; cmd_cleanup ;;
    status)  preflight; cmd_status ;;
    shell)   preflight; vm_exists || die "VM '$VM_NAME' not found."; multipass shell "$VM_NAME" ;;
    destroy) preflight; vm_exists || die "VM '$VM_NAME' not found."
             multipass delete --purge "$VM_NAME"; log "VM '$VM_NAME' deleted." ;;
    -h|--help|help|"") usage ;;
    *)       usage; die "Unknown command: $cmd" ;;
  esac
}

main "$@"

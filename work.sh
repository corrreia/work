#!/bin/bash
# work.sh: single entry point for the corporate work environment (VPN,
# Windows VM, Linux container). The commands live in lib/; code that runs
# inside the VPN container or Windows lives in scripts/.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/vpn.sh
source "$SCRIPT_DIR/lib/vpn.sh"
# shellcheck source=lib/guests.sh
source "$SCRIPT_DIR/lib/guests.sh"
# shellcheck source=lib/windows.sh
source "$SCRIPT_DIR/lib/windows.sh"
# shellcheck source=lib/setup.sh
source "$SCRIPT_DIR/lib/setup.sh"

case "${1:-help}" in
  connect)    shift; cmd_connect "$@" ;;
  disconnect) cmd_disconnect ;;
  reconnect)  shift; cmd_reconnect "$@" ;;
  setup)      cmd_setup ;;
  migrate)    cmd_migrate ;;
  paths)      cmd_paths ;;
  open)       shift; cmd_open "$@" ;;
  doctor)     cmd_doctor ;;
  status)     cmd_status ;;
  test)       shift; cmd_test "$@" ;;
  up)         cmd_up ;;
  down)       cmd_down ;;
  logs)       shift; cmd_logs "$@" ;;
  windows)    shift; cmd_windows "$@" ;;
  linux)      shift; cmd_linux "$@" ;;
  help | --help | -h) cmd_help ;;
  *)          die "Unknown command: $1. Run './work.sh help' for usage." ;;
esac

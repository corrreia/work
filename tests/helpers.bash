# Shared by tests/*.bats. Every test gets its own temp home: all work.sh paths
# are pinned inside it, so no test can touch the real ~/.config/work.

REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

isolate() {
  TEST_HOME="$(mktemp -d)"
  export HOME="$TEST_HOME"
  export XDG_CONFIG_HOME="$TEST_HOME/.config"
  export XDG_DATA_HOME="$TEST_HOME/.local/share"
  export WORK_CONFIG_DIR="$XDG_CONFIG_HOME/work"
  export WORK_DATA_DIR="$XDG_DATA_HOME/work"
  export WORK_SHARED_DIR="$TEST_HOME/shared"
  unset VPN_EXTRA_ROUTES SSO_SITES AD_DOMAIN AD_USER AD_PASSWORD VPN_PASSWORD
}

# Source the libraries into the test shell.
load_libs() {
  export SCRIPT_DIR="$REPO"
  local lib
  for lib in common vpn guests windows setup; do
    # shellcheck source=/dev/null
    source "$REPO/lib/$lib.sh"
  done
}

# Run "$@" in a fresh bash with work.sh's strict mode, so unset variables and
# pipe failures behave as they do in the real script.
strict() {
  bash -euo pipefail -c '
    SCRIPT_DIR="$1"; shift
    for lib in common vpn guests windows setup; do source "$SCRIPT_DIR/lib/$lib.sh"; done
    "$@"' _ "$REPO" "$@"
}

setup() {
  isolate
  load_libs
}

teardown() {
  [ -n "${TEST_HOME:-}" ] && rm -rf "$TEST_HOME"
}

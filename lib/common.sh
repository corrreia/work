# shellcheck shell=bash
# Shared by every lib/*.sh: paths, colors, output helpers, the env file,
# docker compose and container checks. Sourced by work.sh after it sets
# SCRIPT_DIR; side-effect free apart from setting variables.

COMPOSE_FILE="$SCRIPT_DIR/docker-compose.yml"
VM_SUBNET="172.30.0.0/24"   # dockurr's bridge inside work-vpn

# --- Paths ---
# The repo holds only code. Everything else lives outside it, grouped by how
# often you touch it (./work.sh paths prints them):
#   WORK_CONFIG_DIR  env, certificates/, ssh/   edited now and then, mode 0700
#   WORK_SHARED_DIR  exchange folder for the host and both guests
#   WORK_DATA_DIR    windows/ (VM disk), linux/ (container home), state/
# WORK_CONFIG_DIR can be overridden from the environment; the other two from
# the environment or the env file.
WORK_CONFIG_DIR="${WORK_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/work}"
WORK_ENV="$WORK_CONFIG_DIR/env"

set_paths() {
  WORK_DATA_DIR="${WORK_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/work}"
  WORK_SHARED_DIR="${WORK_SHARED_DIR:-$HOME/Work/shared}"
  CERT_DIR="$WORK_CONFIG_DIR/certificates"   # CAs trusted by both guests
  GUEST_SSH_DIR="$WORK_CONFIG_DIR/ssh"       # files copied into ~/.ssh of both guests
  # Windows sync: the host pushes certificates, keys and SSO credentials into
  # the VM over SSH, so none of them ever lands in the shared folder.
  WORK_STATE_DIR="$WORK_DATA_DIR/state"      # generated, never mounted into a guest
  WIN_SSH_KEY="$WORK_STATE_DIR/windows_ed25519"
  WIN_KNOWN_HOSTS="$WORK_STATE_DIR/known_hosts"
  WIN_SYNCED="$WORK_STATE_DIR/windows-synced"   # set after the first successful sync
  # docker-compose.yml mounts these.
  export WORK_CONFIG_DIR WORK_DATA_DIR WORK_SHARED_DIR
}
set_paths

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# --- Helpers ---

die() { echo -e "${RED}ERROR: $*${NC}" >&2; exit 1; }
info() { echo -e "${CYAN}$*${NC}"; }
success() { echo -e "${GREEN}$*${NC}"; }
warn() { echo -e "${YELLOW}$*${NC}"; }

# Contracted for display: /home/me/.config/work -> ~/.config/work
tilde() {
  printf '%s' "${1/#$HOME/\~}"
}

# mkdir -p with the mode on every directory it creates, not only the last
# (mkdir -p -m applies the mode to the deepest one alone).
mkdir_private() {
  local dir
  for dir in "$@"; do
    mkdir -p "$dir"
    chmod 700 "$dir"
  done
}

# Random alphanumeric password for a local guest account. Alphanumeric only, so it
# survives the dockur unattended install and RDP without quoting or escaping issues.
# 512 random bytes leave ~120 alphanumerics; reading a fixed amount avoids the
# SIGPIPE that `tr < /dev/urandom | head` raises under pipefail.
gen_password() {
  local chars
  chars=$(head -c 512 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9')
  printf '%s' "${chars:0:20}"
}

# Single-quote a value for safe inclusion in the env file, which load_env sources.
# Without this a value with a space, $, #, quote or backslash breaks sourcing:
# each embedded ' becomes '\'' and the whole is wrapped in single quotes.
env_quote() {
  printf "'%s'" "${1//\'/\'\\\'\'}"
}

load_env() {
  if [ ! -f "$WORK_ENV" ]; then
    [ -f "$SCRIPT_DIR/.env" ] && die "Found the old layout (.env in the repo). Run: ./work.sh migrate"
    die "$(tilde "$WORK_ENV") not found. Run: ./work.sh setup"
  fi
  set -a
  # shellcheck source=/dev/null
  source "$WORK_ENV"
  set +a
  set_paths
}

# Fail with a named error instead of letting an empty credential reach a guest
# or the tunnel. VM_PASSWORD and VPN_PASSWORD are deliberately independent:
# VPN_PASSWORD rotates on the corporate schedule, VM_PASSWORD does not.
require_env() {
  local var missing=()
  for var in "$@"; do
    [ -n "${!var:-}" ] || missing+=("$var")
  done
  if [ ${#missing[@]} -gt 0 ]; then
    die "Missing in $(tilde "$WORK_ENV"): ${missing[*]}. See .env.example in the repo."
  fi
}

# docker compose with the env loaded (it interpolates USERNAME, VM_PASSWORD and
# the paths). Bind-mount sources are created here, since Docker would create
# missing ones owned by root.
compose() {
  load_env
  mkdir -p "$WORK_DATA_DIR/windows" "$WORK_DATA_DIR/linux" "$WORK_SHARED_DIR"
  mkdir_private "$WORK_CONFIG_DIR"
  mkdir -p "$CERT_DIR" "$GUEST_SSH_DIR"
  docker compose -f "$COMPOSE_FILE" "$@"
}

container_running() {
  [ "$(docker inspect -f '{{.State.Status}}' "$1" 2>/dev/null)" = "running" ]
}

vpn_connected() {
  docker exec work-vpn ip link show snx-tun &>/dev/null
}

# Files directly in GUEST_SSH_DIR (keys, config, known_hosts), one per line,
# for ~/.ssh in both guests. Names are validated: they become file names in
# both guests.
guest_ssh_files() {
  local name
  [ -d "$GUEST_SSH_DIR" ] || return 0
  find "$GUEST_SSH_DIR" -maxdepth 1 -type f -printf '%f\n' | sort | while read -r name; do
    if [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]]; then
      printf '%s\n' "$name"
    else
      warn "Skipping ssh/$name: only letters, digits, '.', '_' and '-' are allowed in names." >&2
    fi
  done
}

# shellcheck shell=bash
# First-run and housekeeping: help, folders, migrate, doctor, setup.

cmd_help() {
  echo -e "${BOLD}work.sh${NC} — Corporate remote environment manager"
  echo ""
  echo -e "${BOLD}Setup:${NC}"
  echo "  ./work.sh setup              Create the env file interactively (first run)"
  echo "  ./work.sh doctor             Check prerequisites (Docker, KVM, tun, tools)"
  echo "  ./work.sh migrate            Move an old in-repo layout to the folders below"
  echo ""
  echo -e "${BOLD}Folders:${NC}"
  echo "  ./work.sh paths              Show where config, certificates, keys and data live"
  echo "  ./work.sh open <what>        Open a folder (config|certs|ssh|shared|data)"
  echo ""
  echo -e "${BOLD}VPN:${NC}"
  echo "  ./work.sh connect [--debug]  Connect VPN (prompts for 2FA)"
  echo "  ./work.sh disconnect         Disconnect VPN"
  echo "  ./work.sh reconnect [--debug] Disconnect + reconnect"
  echo ""
  echo -e "${BOLD}Environment:${NC}"
  echo "  ./work.sh up                 Start all containers"
  echo "  ./work.sh down               Stop all containers"
  echo "  ./work.sh status             Show VPN + VM status"
  echo "  ./work.sh test [host]        Check internal DNS + reachability from both guests"
  echo "  ./work.sh logs [vpn|windows|linux]  Tail container logs"
  echo ""
  echo -e "${BOLD}VMs:${NC}"
  echo "  ./work.sh windows <cmd>      Manage Windows VM (start|stop|restart|rdp|sync|bootstrap|web|logs)"
  echo "  ./work.sh linux <cmd>        Manage Linux container (start|stop|restart|shell|rebuild|logs)"
  echo ""
  echo -e "${BOLD}Examples:${NC}"
  echo "  ./work.sh connect            Connect VPN, type 2FA, done"
  echo "  ./work.sh windows restart    Restart Windows VM"
  echo "  ./work.sh windows rdp        Open RDP session"
  echo "  ./work.sh linux shell        Open shell in Arch container"
  echo "  ./work.sh status             Quick overview of everything"
}

# --- Folders ---

path_row() {
  printf '  %-9s %-34s %s\n' "$1" "$(tilde "$2")" "$3"
}

cmd_paths() {
  if [ -f "$WORK_ENV" ]; then load_env; fi
  echo -e "${BOLD}Folders${NC}"
  echo ""
  path_row env "$WORK_ENV" "settings and passwords (mode 0600)"
  path_row certs "$CERT_DIR" "CAs trusted by both guests"
  path_row ssh "$GUEST_SSH_DIR" "copied into ~/.ssh of both guests"
  path_row shared "$WORK_SHARED_DIR" "mounted in both guests (Linux: ~/Shared)"
  path_row data "$WORK_DATA_DIR" "windows/ disk, linux/ home, state/"
  path_row code "$SCRIPT_DIR" "this repo"
  echo ""
  echo -e "${DIM}Certificates and keys reach the guests on every start, or now with:"
  echo -e "  ./work.sh windows sync   ./work.sh linux restart${NC}"
  if legacy_items >/dev/null; then
    echo ""
    warn "Old in-repo layout found. Run: ./work.sh migrate"
  fi
}

cmd_open() {
  if [ -f "$WORK_ENV" ]; then load_env; fi
  local dir
  case "${1:-}" in
    config) dir="$WORK_CONFIG_DIR" ;;
    certs | certificates) dir="$CERT_DIR" ;;
    ssh) dir="$GUEST_SSH_DIR" ;;
    shared) dir="$WORK_SHARED_DIR" ;;
    data) dir="$WORK_DATA_DIR" ;;
    *) die "Usage: ./work.sh open config|certs|ssh|shared|data" ;;
  esac
  mkdir -p "$dir"
  command -v xdg-open >/dev/null || { echo "$dir"; return; }
  xdg-open "$dir" >/dev/null 2>&1 &
  info "Opened $(tilde "$dir")"
}

# --- Migrate from the old in-repo layout ---

# Old in-repo items still present, one per line. Fails when there are none.
legacy_items() {
  local item found=1
  for item in .env certificates .work windows linux shared; do
    if [ -e "$SCRIPT_DIR/$item" ]; then
      printf '%s\n' "$item"
      found=0
    fi
  done
  return $found
}

# Move one item to its new home. Refuses to overwrite: an empty directory left
# at the destination is replaced, anything else stops the migration.
migrate_move() {
  local src="$1" dest="$2" sudo=()
  [ -e "$src" ] || return 0
  if [ -d "$dest" ] && [ -z "$(ls -A "$dest" 2>/dev/null)" ]; then
    rmdir "$dest"
  elif [ -e "$dest" ]; then
    die "$(tilde "$dest") already exists. Move $(tilde "$src") by hand, then re-run ./work.sh migrate."
  fi
  mkdir -p "$(dirname "$dest")"
  # Moving a directory to a new parent needs write access to it; windows/ is
  # owned by root (the VM container writes it).
  if [ -d "$src" ] && [ ! -w "$src" ]; then
    sudo=(sudo)
  fi
  "${sudo[@]}" mv "$src" "$dest" || die "Could not move $(tilde "$src")."
  printf '  %bmoved%b   %s -> %s\n' "$GREEN" "$NC" "$(tilde "$src")" "$(tilde "$dest")"
}

cmd_migrate() {
  local items ans
  if ! items=$(legacy_items); then
    success "Nothing to migrate; already on the new layout."
    cmd_paths
    return 0
  fi

  # Read the old env for the container user name and so docker compose can
  # interpolate the file while stopping the containers.
  if [ -f "$SCRIPT_DIR/.env" ]; then
    set -a
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/.env"
    set +a
    set_paths
  fi

  echo -e "${BOLD}Move to the new layout${NC}"
  echo ""
  echo "  .env           -> $(tilde "$WORK_ENV")"
  echo "  certificates/  -> $(tilde "$CERT_DIR")"
  echo "  shared/id_*    -> $(tilde "$GUEST_SSH_DIR")   (private keys out of the shared folder)"
  echo "  shared/        -> $(tilde "$WORK_SHARED_DIR")"
  echo "  windows/       -> $(tilde "$WORK_DATA_DIR")/windows   (sudo: owned by root)"
  echo "  linux/         -> $(tilde "$WORK_DATA_DIR")/linux"
  echo "  .work/         -> $(tilde "$WORK_STATE_DIR")"
  echo ""
  echo "Found: ${items//$'\n'/ }"
  warn "This stops all containers, the VPN included."
  read -rp "Continue? [y/N] " ans
  case "$ans" in
    y | Y) ;;
    *) info "Nothing changed."; return 0 ;;
  esac

  info "Stopping containers..."
  docker compose -f "$COMPOSE_FILE" down || die "Could not stop the containers."

  echo ""
  mkdir_private "$WORK_CONFIG_DIR" "$GUEST_SSH_DIR"
  migrate_move "$SCRIPT_DIR/certificates" "$CERT_DIR"
  migrate_move "$SCRIPT_DIR/.work" "$WORK_STATE_DIR"

  if [ -d "$SCRIPT_DIR/shared" ]; then
    local key
    for key in "$SCRIPT_DIR"/shared/id_*; do
      if [ -f "$key" ]; then migrate_move "$key" "$GUEST_SSH_DIR/$(basename "$key")"; fi
    done
    # Generated copies from the old shared-folder certificate import.
    if [ -d "$SCRIPT_DIR/shared/certificates" ] &&
      [ -z "$(find "$SCRIPT_DIR/shared/certificates" -type f ! -name '*.crt' ! -name '*.cer' ! -name '*.pem' ! -name 'import-certs.ps1')" ]; then
      rm -rf "$SCRIPT_DIR/shared/certificates"
      printf '  %bremoved%b shared/certificates (old copies)\n' "$GREEN" "$NC"
    fi
    rm -f "$SCRIPT_DIR/shared/.gitkeep"
    migrate_move "$SCRIPT_DIR/shared" "$WORK_SHARED_DIR"
  fi

  migrate_move "$SCRIPT_DIR/windows" "$WORK_DATA_DIR/windows"
  migrate_move "$SCRIPT_DIR/linux" "$WORK_DATA_DIR/linux"
  # Last, so an interrupted run still finds the old env on the next try.
  migrate_move "$SCRIPT_DIR/.env" "$WORK_ENV"
  if [ -f "$WORK_ENV" ]; then chmod 600 "$WORK_ENV"; fi

  echo ""
  success "Migrated."
  echo ""
  cmd_paths
  echo ""
  info "Next: ./work.sh up, then ./work.sh connect"
}

# --- Preflight ---

# One prerequisite check: check req|opt <label> <hint> <command...>. A failed
# req is counted by the caller and blocks, a failed opt only warns.
check() {
  local kind="$1" label="$2" hint="$3"
  shift 3
  if "$@" >/dev/null 2>&1; then
    printf '  %bok%b      %s\n' "$GREEN" "$NC" "$label"
    return 0
  fi
  if [ "$kind" = req ]; then
    printf '  %bmissing%b %s\n' "$RED" "$NC" "$label"
  else
    printf '  %babsent%b  %s\n' "$YELLOW" "$NC" "$label"
  fi
  printf '          %b%s%b\n' "$DIM" "$hint" "$NC"
  return 1
}

# Probes for check. Each succeeds when the prerequisite is met.
have() { command -v "$1"; }
have_any() { local bin; for bin in "$@"; do command -v "$bin" && return 0; done; return 1; }
have_kvm() { [ -r /dev/kvm ] && [ -w /dev/kvm ]; }
have_ssh() { command -v ssh && command -v ssh-keygen; }
no_legacy_layout() { ! legacy_items; }

cmd_doctor() {
  echo -e "${BOLD}Preflight${NC}"
  echo ""
  local fails=0

  check req "Docker" "Install Docker. See https://docs.docker.com/engine/install/" \
    have docker || fails=$((fails + 1))
  check req "Docker daemon" "Start Docker, or add yourself to the docker group and re-login." \
    docker info || fails=$((fails + 1))
  check req "Docker Compose v2" "Install the docker compose plugin." \
    docker compose version || fails=$((fails + 1))
  check req "KVM (/dev/kvm)" "Enable virtualization in BIOS, add yourself to the kvm group, re-login." \
    have_kvm || fails=$((fails + 1))
  check req "TUN (/dev/net/tun)" "Load the module: sudo modprobe tun." \
    test -e /dev/net/tun || fails=$((fails + 1))
  check req "jq" "Install jq. It parses GitHub's ranges at connect and builds the Windows sync input." \
    have jq || fails=$((fails + 1))

  echo ""
  check opt "FreeRDP" "Only for ./work.sh windows rdp (package: freerdp). ./work.sh windows web works without it." \
    have_any xfreerdp3 xfreerdp || true
  check opt "OpenSSH client" "Only for ./work.sh windows sync (package: openssh)." \
    have_ssh || true

  echo ""
  # Repo integrity. The Linux image build copies this snapshot, so a clone
  # missing it fails the build. Catch it here, not halfway through a build.
  check req "Linux image rootfs" "linux-image/rootfs/ is missing. It must be committed to the repo; ask whoever shared it." \
    test -d "$SCRIPT_DIR/linux-image/rootfs" || fails=$((fails + 1))
  check opt "env file" "Not configured yet. Run ./work.sh setup, or ./work.sh migrate if .env is still in the repo." \
    test -f "$WORK_ENV" || true
  check opt "folder layout" "Old in-repo layout. Run ./work.sh migrate." \
    no_legacy_layout || true

  echo ""
  if [ "$fails" -gt 0 ]; then
    warn "$fails required check(s) failed. Fix the above, then re-run ./work.sh doctor."
    return 1
  fi
  success "All required checks passed."
}

# --- Setup ---

# The env file for the given values, every one single-quoted so load_env can
# source it even when a password holds a space, $, #, quote or backslash.
# Arguments: username vm_password vpn_server vpn_password corporate_dns
#            extra_routes test_host ad_domain sso_sites
render_env() {
  cat <<EOF
# Generated by ./work.sh setup. Edit freely; re-run setup to regenerate.

# --- Local guest accounts (Windows VM + Linux container) ---
# Not domain-joined, so this password does not rotate.
USERNAME=$(env_quote "$1")
VM_PASSWORD=$(env_quote "$2")

# --- Corporate VPN ---
# VPN_PASSWORD rotates on the company schedule (~45d). 2FA is prompted at connect.
VPN_SERVER=$(env_quote "$3")
VPN_PASSWORD=$(env_quote "$4")

# Internal DNS, reachable only through the tunnel. Both guests use it while up.
CORPORATE_DNS=$(env_quote "$5")

# Public ranges to route through the tunnel as well, comma-separated.
# Corporate GitHub is IP-allowlisted, so its ranges belong here or git is blocked.
VPN_EXTRA_ROUTES=$(env_quote "$6")

# Internal-only hostname for ./work.sh test.
VPN_TEST_HOST=$(env_quote "$7")

# --- Windows silent login (pushed by ./work.sh windows sync) ---
# The AD account is AD_USER (default USERNAME@AD_DOMAIN) with AD_PASSWORD
# (default VPN_PASSWORD). SSO_SITES defaults to *.AD_DOMAIN.
AD_DOMAIN=$(env_quote "$8")
SSO_SITES=$(env_quote "$9")
#AD_USER=
#AD_PASSWORD=
EOF
}

cmd_setup() {
  local env_file="$WORK_ENV"
  local example="$SCRIPT_DIR/.env.example"

  [ -f "$example" ] || die ".env.example not found. Run this from the repo root."
  if legacy_items >/dev/null; then die "Found the old in-repo layout. Run ./work.sh migrate instead."; fi

  echo -e "${BOLD}Work environment setup${NC}"
  echo ""
  echo -e "${DIM}Fields marked [IT] come from your IT admin or Check Point client logs.${NC}"
  echo -e "${DIM}Press Enter to accept a default shown in [brackets].${NC}"
  echo ""

  local ans
  if [ -f "$env_file" ]; then
    warn "$(tilde "$env_file") already exists."
    read -rp "Overwrite it (a backup goes to env.bak)? [y/N] " ans
    case "$ans" in
      y | Y) cp "$env_file" "$env_file.bak" ;;
      *)
        info "Keeping the existing env file. Nothing changed."
        return 0
        ;;
    esac
  fi

  local username vm_password vpn_server vpn_password corporate_dns
  local extra_routes test_host ad_domain sso_sites=""

  read -rp "Local guest username (USERNAME) [your.username]: " username
  username="${username:-your.username}"

  read -rsp "Password for the Windows and Linux guests (VM_PASSWORD), Enter to auto-generate: " vm_password
  echo ""
  if [ -z "$vm_password" ]; then
    vm_password=$(gen_password)
    info "Generated a random VM_PASSWORD. It is stored in $(tilde "$env_file"); read it there if you log in to Windows directly."
  fi

  read -rp "VPN gateway IP (VPN_SERVER) [IT]: " vpn_server
  read -rsp "VPN password (VPN_PASSWORD), rotates ~45d, Enter to fill later: " vpn_password
  echo ""
  read -rp "Corporate DNS (CORPORATE_DNS) [IT]: " corporate_dns
  read -rp "Extra ranges through the tunnel (VPN_EXTRA_ROUTES), comma-separated, 'github' = GitHub's live ranges [github]: " extra_routes
  extra_routes="${extra_routes:-github}"
  read -rp "Internal host for ./work.sh test (VPN_TEST_HOST) [optional]: " test_host
  read -rp "AD domain for Windows silent login (AD_DOMAIN), e.g. corp.example.com [optional]: " ad_domain
  if [ -n "$ad_domain" ]; then
    read -rp "Sites that get silent login (SSO_SITES), comma-separated [*.$ad_domain]: " sso_sites
  fi

  # chmod is explicit because umask only applies to a newly created file;
  # overwriting an existing file in place would otherwise keep its old mode.
  umask 077
  mkdir_private "$WORK_CONFIG_DIR"
  mkdir -p "$CERT_DIR" "$GUEST_SSH_DIR"
  render_env "$username" "$vm_password" "$vpn_server" "$vpn_password" "$corporate_dns" \
    "$extra_routes" "$test_host" "$ad_domain" "$sso_sites" >"$env_file"
  chmod 600 "$env_file"

  success "$(tilde "$env_file") written."
  info "Drop internal CA files into $(tilde "$CERT_DIR") and guest SSH keys into $(tilde "$GUEST_SSH_DIR")."
  echo ""
  info "Next:"
  info "  ./work.sh doctor    check prerequisites"
  info "  ./work.sh up        build and start the containers"
  info "  ./work.sh connect   bring up the VPN (prompts for 2FA)"
}

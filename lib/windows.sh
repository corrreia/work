# shellcheck shell=bash
# Windows VM: sync over SSH, one-time bootstrap, RDP. The PowerShell that runs
# inside Windows lives in scripts/windows/; this file only builds its input.

WIN_SSH_PORT=2222                    # published on 127.0.0.1 by the vpn service
WIN_SSH_WAIT=300                     # seconds to wait for Windows to boot
# Windows' ssh shell is cmd.exe. Read the whole script from stdin and run it as
# one block; "powershell -Command -" runs stdin line by line and breaks blocks.
WIN_PS='powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "& ([scriptblock]::Create([Console]::In.ReadToEnd()))"'

# --- Running scripts/windows/*.ps1 ---

# PowerShell that runs scripts/windows/<name> with the JSON read from stdin as
# its single argument. Data and code never mix: the JSON travels as one base64
# literal, and the script file is passed through unchanged.
ps_invocation() {
  local file="$SCRIPT_DIR/scripts/windows/$1" data
  [ -f "$file" ] || die "Missing $file"
  data=$(base64 -w0)
  printf '& {\n%s\n} ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('\''%s'\'')) | ConvertFrom-Json)\n' \
    "$(cat "$file")" "$data"
}

# Comma-separated SSO sites, validated because Windows stores them as browser
# policy and credential targets. Defaults to every host under AD_DOMAIN.
sso_sites() {
  local sites="${SSO_SITES:-*.${AD_DOMAIN:-}}"
  sites="${sites// /}"
  if ! [[ "$sites" =~ ^[A-Za-z0-9.*-]+(,[A-Za-z0-9.*-]+)*$ ]] || [ "$sites" = "*." ]; then
    die "SSO_SITES must be comma-separated host patterns like *.corp.example.com, got: $sites"
  fi
  printf '%s' "$sites"
}

# Input for machine.ps1: { certs: [base64 of each CA file], sites }. The
# certificates reach jq through stdin.
win_machine_json() {
  local sites="$1" file
  shopt -s nullglob
  for file in "$CERT_DIR"/*.crt "$CERT_DIR"/*.cer "$CERT_DIR"/*.pem; do
    base64 -w0 "$file"
    echo
  done | jq -Rn --arg sites "$sites" '{sites: $sites, certs: [inputs | select(length > 0)]}'
  shopt -u nullglob
}

# Input for user.ps1: { sshFiles: [{name, data}], credential }. Secrets reach
# jq through its environment and the key files through stdin, never argv,
# which any local user can read in the process list.
win_user_json() {
  local user="$1" password="$2" sites="$3" vm_password="$4" name
  while read -r name; do
    [ -n "$name" ] && printf '%s\t%s\n' "$name" "$(base64 -w0 "$GUEST_SSH_DIR/$name")"
  done <<<"$(guest_ssh_files)" |
    WORK_USER="$user" WORK_PASSWORD="$password" WORK_SITES="$sites" WORK_VM_PASSWORD="$vm_password" \
      jq -Rn --rawfile cred "$SCRIPT_DIR/scripts/windows/credential.ps1" '{
        sshFiles: [inputs | select(length > 0) | split("\t") | {name: .[0], data: .[1]}],
        credential: (if env.WORK_SITES == "" then null else {
          script: $cred,
          user: env.WORK_USER,
          password: env.WORK_PASSWORD,
          targets: (env.WORK_SITES | split(",")),
          vmPassword: env.WORK_VM_PASSWORD
        } end)
      }'
}

# --- SSH into Windows ---

# Run a command in the Windows VM with the bootstrap key: an elevated session
# as the user. Any SSH login (key or password) is a network logon, so it cannot
# write Credential Manager; user.ps1 works around that with a task.
win_ssh() {
  ssh -p "$WIN_SSH_PORT" -o HostKeyAlias=work-windows \
    -o UserKnownHostsFile="$WIN_KNOWN_HOSTS" -o StrictHostKeyChecking=accept-new \
    -o ConnectTimeout=5 -o LogLevel=ERROR \
    -i "$WIN_SSH_KEY" -o IdentitiesOnly=yes -o BatchMode=yes \
    "$USERNAME@127.0.0.1" "$@"
}

# Run the PowerShell on stdin in the Windows VM.
win_ps() {
  win_ssh "$WIN_PS"
}

win_ssh_ready() {
  win_ssh exit </dev/null >/dev/null 2>&1
}

# Wait until Windows has booted far enough to accept SSH.
win_wait_ssh() {
  local waited=0
  win_ssh_ready && return 0
  info "Waiting for Windows to accept SSH (up to $((WIN_SSH_WAIT / 60)) min)..."
  while [ "$waited" -lt "$WIN_SSH_WAIT" ]; do
    sleep 5
    waited=$((waited + 5))
    win_ssh_ready && return 0
  done
  return 1
}

# --- Commands ---

# Push certificates, browser policy, SSH keys and SSO credentials into the
# Windows VM. Idempotent; runs on every start so a rotated password is picked up.
windows_sync() {
  load_env
  require_env USERNAME VM_PASSWORD
  command -v jq >/dev/null || die "jq not found. Install jq (./work.sh doctor lists what is missing)."
  container_running work-windows || die "Windows is not running. Run: ./work.sh windows start"

  if [ ! -f "$WIN_SSH_KEY" ]; then
    warn "Windows sync is not set up yet. Run once: ./work.sh windows bootstrap"
    return 1
  fi

  # Before the first successful sync, a closed port most likely means the
  # bootstrap has not been run inside Windows. Do not wait minutes for it.
  if [ -f "$WIN_SYNCED" ]; then
    win_wait_ssh || { warn "Windows did not accept SSH within $((WIN_SSH_WAIT / 60)) min. Retry with: ./work.sh windows sync"; return 1; }
  elif ! win_ssh_ready; then
    warn "Windows does not accept the sync key yet. If it is still booting, retry with: ./work.sh windows sync"
    warn "Otherwise finish the one-time setup: ./work.sh windows bootstrap"
    return 1
  fi

  info "Syncing Windows..."
  # Browser policy follows AD_DOMAIN; the credentials also need a password.
  local policy_sites="" sites="" user="" password=""
  if [ -n "${AD_DOMAIN:-}" ]; then
    policy_sites=$(sso_sites) || return 1
  fi
  if [ -z "${AD_DOMAIN:-}" ]; then
    echo -e "  ${DIM}credentials: skipped, AD_DOMAIN is not set in $(tilde "$WORK_ENV")${NC}"
  elif [ -z "${AD_PASSWORD:-${VPN_PASSWORD:-}}" ]; then
    echo -e "  ${DIM}credentials: skipped, neither AD_PASSWORD nor VPN_PASSWORD is set${NC}"
  else
    sites="$policy_sites"
    user="${AD_USER:-$USERNAME@$AD_DOMAIN}"
    password="${AD_PASSWORD:-$VPN_PASSWORD}"
  fi

  win_machine_json "$policy_sites" | ps_invocation machine.ps1 | win_ps ||
    { warn "Machine sync (certificates, browser policy) failed."; return 1; }

  if [ -n "$sites" ] || [ -n "$(guest_ssh_files 2>/dev/null)" ]; then
    win_user_json "$user" "$password" "$sites" "$VM_PASSWORD" | ps_invocation user.ps1 | win_ps ||
      { warn "User sync (SSH keys, credentials) failed."; return 1; }
  fi

  touch "$WIN_SYNCED"
  success "Windows synced."
}

# One-time setup inside Windows: install OpenSSH Server and trust the host's
# sync key. Printed as one command to paste into an elevated PowerShell, so
# nothing goes through the shared folder.
windows_bootstrap() {
  load_env
  require_env USERNAME
  command -v ssh-keygen >/dev/null || die "ssh-keygen not found. Install openssh."
  command -v jq >/dev/null || die "jq not found. Install jq."

  mkdir_private "$WORK_STATE_DIR"
  [ -f "$WIN_SSH_KEY" ] || ssh-keygen -q -t ed25519 -N '' -C "work.sh windows sync" -f "$WIN_SSH_KEY"

  local encoded cmd
  # -EncodedCommand takes base64 of UTF-16LE.
  encoded=$(jq -n --arg key "$(cat "$WIN_SSH_KEY.pub")" '{publicKey: $key}' |
    ps_invocation bootstrap.ps1 | iconv -f UTF-8 -t UTF-16LE | base64 -w0)
  cmd="powershell -NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded"

  echo -e "${BOLD}One-time Windows setup${NC}"
  echo ""
  echo "In Windows, open PowerShell as Administrator and paste this command."
  echo "It installs OpenSSH Server and trusts this host's sync key ($(tilde "$WIN_SSH_KEY").pub)."
  if command -v wl-copy >/dev/null && printf '%s' "$cmd" | wl-copy 2>/dev/null; then
    success "Copied to the clipboard. Paste it into the RDP session."
  else
    echo ""
    echo "$cmd"
  fi
  echo ""
  info "Then run: ./work.sh windows sync"
}

# FreeRDP /scale for the focused Hyprland monitor, or nothing.
hyprland_rdp_scale() {
  local scale pct
  command -v hyprctl >/dev/null && command -v jq >/dev/null || return 0
  scale=$(hyprctl monitors -j 2>/dev/null | jq -r '.[] | select(.focused == true) | .scale' 2>/dev/null) || return 0
  [ -n "$scale" ] || return 0
  pct=$(awk -v s="$scale" 'BEGIN { print int(s * 100) }')
  if ((pct >= 170)); then
    printf '/scale:180'
  elif ((pct >= 130)); then
    printf '/scale:140'
  fi
}

# First FreeRDP 3 binary on PATH. Distros package it as xfreerdp3 or xfreerdp;
# both read the same /args-from: file, so every RDP option below behaves the same.
rdp_client() {
  local bin
  for bin in xfreerdp3 xfreerdp; do
    command -v "$bin" &>/dev/null && { printf '%s' "$bin"; return 0; }
  done
  return 1
}

windows_rdp() {
  local rdp_bin rdp_scale rdp_args rdp_pid
  local rdp_log="/tmp/work-windows-rdp.log"
  load_env
  require_env USERNAME VM_PASSWORD
  rdp_bin=$(rdp_client) || die "No FreeRDP client found. Install the freerdp package (it provides xfreerdp3). ./work.sh windows web needs no client."
  rdp_scale=$(hyprland_rdp_scale)

  info "Opening RDP to Windows VM..."
  # The password goes in a 0600 args file rather than argv.
  rdp_args=$(mktemp /tmp/work-windows-rdp.XXXXXX)
  chmod 600 "$rdp_args"
  {
    printf '%s\n' \
      "/v:127.0.0.1:3390" \
      "/u:localhost\\$USERNAME" \
      "/p:$VM_PASSWORD" \
      "/auth-pkg-list:none,ntlm" \
      "/cert:ignore" \
      "/dynamic-resolution" \
      "/gfx:AVC444" \
      "/floatbar:sticky:off,default:visible,show:fullscreen" \
      "/sound" \
      "/microphone" \
      "/clipboard" \
      "/title:Work Windows" \
      "-grab-keyboard"
    if [ -n "$rdp_scale" ]; then printf '%s\n' "$rdp_scale"; fi
  } >"$rdp_args"

  nohup "$rdp_bin" /args-from:"$rdp_args" >"$rdp_log" 2>&1 </dev/null &
  rdp_pid=$!
  sleep 2
  rm -f "$rdp_args"

  if ! kill -0 "$rdp_pid" 2>/dev/null; then
    warn "RDP exited immediately. Recent log output:"
    echo -e "${DIM}--- $rdp_log ---${NC}"
    tail -n 40 "$rdp_log" 2>/dev/null || true
    echo -e "${DIM}--- end ---${NC}"
    return 1
  fi

  disown "$rdp_pid" 2>/dev/null || true
  success "RDP launched. Logs: $rdp_log"
}

cmd_windows() {
  local action="${1:-help}"
  case "$action" in
    start)
      vm_start windows
      windows_sync || true
      ;;
    stop) vm_stop windows ;;
    restart)
      vm_restart windows
      windows_sync || true
      ;;
    sync | certs) windows_sync ;;
    bootstrap) windows_bootstrap ;;
    logs) docker logs -f work-windows ;;
    rdp) windows_rdp ;;
    web)
      info "Opening Windows web viewer..."
      xdg-open "http://127.0.0.1:8007" >/dev/null 2>&1 &
      ;;
    *)
      echo -e "${BOLD}Windows VM commands:${NC}"
      echo ""
      echo "  ./work.sh windows start      Start the Windows VM"
      echo "  ./work.sh windows stop       Graceful shutdown"
      echo "  ./work.sh windows restart    Stop + start"
      echo "  ./work.sh windows rdp        Open RDP session"
      echo "  ./work.sh windows sync       Push certificates + SSO credentials (runs on start)"
      echo "  ./work.sh windows bootstrap  One-time: enable SSH in Windows for sync"
      echo "  ./work.sh windows web        Open web viewer in browser"
      echo "  ./work.sh windows logs       Tail container logs"
      ;;
  esac
}

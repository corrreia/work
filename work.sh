#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.yml"
VM_SUBNET="172.30.0.0/24"   # dockurr's bridge inside work-vpn
VPN_RUNTIME_CONF="/run/snx-rs-connect.conf"

# Corporate GitHub is IP-allowlisted to company egress, so GitHub routes through
# the tunnel by default: "github" in VPN_EXTRA_ROUTES expands at connect time to
# the live ranges from api.github.com/meta. This fixed list is only the fallback
# when that fetch fails; it misses GitHub's regional Azure addresses.
GITHUB_ROUTES="192.30.252.0/22,185.199.108.0/22,140.82.112.0/20,143.55.64.0/20"
GITHUB_META="https://api.github.com/meta"

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

# Contracted for display: /home/me/.config/work -> ~/.config/work
tilde() {
  printf '%s' "${1/#$HOME/\~}"
}

WIN_SSH_PORT=2222                    # published on 127.0.0.1 by the vpn service
WIN_SSH_WAIT=300                     # seconds to wait for Windows to boot
# Windows' ssh shell is cmd.exe. Read the whole script from stdin and run it as
# one block; "powershell -Command -" runs stdin line by line and breaks blocks.
WIN_PS='powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "& ([scriptblock]::Create([Console]::In.ReadToEnd()))"'

# Runs inside work-vpn with $corporate_dns set. Without the tunnel the
# corporate resolver is unreachable, so a leftover redirect kills Windows DNS.
DNS_TEARDOWN='
for proto in udp tcp; do
  while iptables -t nat -D PREROUTING -i docker -p "$proto" --dport 53 -j DNAT --to-destination "${corporate_dns}:53" 2>/dev/null; do :; done
done'

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

# First FreeRDP 3 binary on PATH. Distros package it as xfreerdp3 or xfreerdp;
# both read the same /args-from: file, so every RDP option below behaves the same.
rdp_client() {
  local bin
  for bin in xfreerdp3 xfreerdp; do
    command -v "$bin" &>/dev/null && { printf '%s' "$bin"; return 0; }
  done
  return 1
}

# Random alphanumeric password for a local guest account. Alphanumeric only, so it
# survives the dockur unattended install and RDP without quoting or escaping issues.
gen_password() {
  LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 20
}

load_env() {
  if [ ! -f "$WORK_ENV" ]; then
    [ -f "$SCRIPT_DIR/.env" ] && die "Found the old layout (.env in the repo). Run: ./work.sh migrate"
    die "$(tilde "$WORK_ENV") not found. Run: ./work.sh setup"
  fi
  set -a
  source "$WORK_ENV"
  set +a
  set_paths
}

# docker compose with the env loaded (it interpolates USERNAME, VM_PASSWORD and
# the paths). Bind-mount sources are created here, since Docker would create
# missing ones owned by root.
compose() {
  load_env
  mkdir -p "$WORK_DATA_DIR/windows" "$WORK_DATA_DIR/linux" "$WORK_SHARED_DIR"
  mkdir -p -m 700 "$WORK_CONFIG_DIR"
  mkdir -p "$CERT_DIR" "$GUEST_SSH_DIR"
  docker compose -f "$COMPOSE_FILE" "$@"
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

# Check if a container is running
container_running() {
  [ "$(docker inspect -f '{{.State.Status}}' "$1" 2>/dev/null)" = "running" ]
}

# Check if VPN tunnel is up
vpn_connected() {
  docker exec work-vpn ip link show snx-tun &>/dev/null 2>&1
}

# GitHub's current IPv4 ranges for web, api and git, comma-separated. GitHub
# keeps adding regional addresses (github.com resolves to one in Azure from
# Europe), and any it misses leaves through the home address and hits the IP
# allow list. The meta arrays hold only strings, so no JSON parser is needed.
github_routes() {
  local routes
  routes=$(curl -fsS --max-time 10 "$GITHUB_META" 2>/dev/null | tr -d ' \n' |
    grep -oE '"(web|api|git)":\[[^]]*\]' | grep -oE '[0-9]+(\.[0-9]+){3}/[0-9]+' |
    sort -u | paste -sd, -) || true
  if [ -z "$routes" ]; then
    warn "Could not fetch GitHub's ranges from $GITHUB_META; using the built-in list, which misses its regional addresses." >&2
    routes="$GITHUB_ROUTES"
  fi
  printf '%s' "$routes"
}

# VPN_EXTRA_ROUTES with "github" expanded. Entries are validated because they
# reach ip route inside work-vpn.
extra_routes() {
  local item out=""
  for item in ${VPN_EXTRA_ROUTES//,/ }; do
    if [ "$item" = github ]; then
      item=$(github_routes)
    elif ! [[ "$item" =~ ^[0-9]+(\.[0-9]+){3}(/[0-9]+)?$ ]]; then
      warn "VPN_EXTRA_ROUTES: '$item' is neither an IPv4 range nor 'github'; skipped." >&2
      continue
    fi
    out="${out:+$out,}$item"
  done
  printf '%s' "$out"
}

# Set up NAT + DNS forwarding inside work-vpn
setup_nat() {
  local routes
  load_env
  require_env CORPORATE_DNS
  routes=$(extra_routes)
  docker exec -i work-vpn sh -s -- "$CORPORATE_DNS" "$VM_SUBNET" "$routes" <<'EOF'
set -e
corporate_dns="$1"
vm_subnet="$2"
extra_routes="$3"
vpn_table="18000"
local_pref="17900"

# snx-rs turns forwarding off on the tunnel unless allow-forwarding is set,
# which silently drops every reply headed for the Windows VM.
if [ "$(cat /proc/sys/net/ipv4/conf/snx-tun/forwarding)" != "1" ]; then
  echo "forwarding is disabled on snx-tun (allow-forwarding missing from snx-rs.conf?)" >&2
  exit 1
fi

# --- Corporate traffic via VPN tunnel ---
iptables -t nat -C POSTROUTING -o snx-tun -j MASQUERADE 2>/dev/null ||
  iptables -t nat -A POSTROUTING -o snx-tun -j MASQUERADE
iptables -C FORWARD -i docker -o snx-tun -j ACCEPT 2>/dev/null ||
  iptables -A FORWARD -i docker -o snx-tun -j ACCEPT
iptables -C FORWARD -i snx-tun -o docker -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null ||
  iptables -A FORWARD -i snx-tun -o docker -m state --state RELATED,ESTABLISHED -j ACCEPT

# dockur forwards every port addressed to this namespace to the VM, the tunnel
# address included. Keep the corporate side from reaching the VM's sshd.
iptables -C FORWARD -i snx-tun -o docker -p tcp --dport 22 -m state --state NEW -j DROP 2>/dev/null ||
  iptables -I FORWARD -i snx-tun -o docker -p tcp --dport 22 -m state --state NEW -j DROP

# snx-rs consults its own table ahead of main, and its 172.16.0.0/12 route
# covers both the Docker network and the VM bridge. Send those back to main by
# rule, so it holds whether or not the VM bridge exists yet.
while ip rule del pref "$local_pref" 2>/dev/null; do :; done
for subnet in $(ip -4 route show dev eth0 proto kernel scope link | awk '{print $1}') "$vm_subnet"; do
  ip rule add to "$subnet" lookup main pref "$local_pref"
done
ip route replace 10.0.0.0/8 dev snx-tun table "$vpn_table"
ip route replace 172.16.0.0/12 dev snx-tun table "$vpn_table"
ip route replace 192.168.0.0/16 dev snx-tun table "$vpn_table"

# --- Internet traffic via eth0 (home connection) ---
iptables -t nat -C POSTROUTING -o eth0 -j MASQUERADE 2>/dev/null ||
  iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
iptables -C FORWARD -i docker -o eth0 -j ACCEPT 2>/dev/null ||
  iptables -A FORWARD -i docker -o eth0 -j ACCEPT
iptables -C FORWARD -i eth0 -o docker -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null ||
  iptables -A FORWARD -i eth0 -o docker -m state --state RELATED,ESTABLISHED -j ACCEPT

# --- DNS to corporate DNS ---
iptables -t nat -C PREROUTING -i docker -p udp --dport 53 -j DNAT --to-destination "${corporate_dns}:53" 2>/dev/null ||
  iptables -t nat -A PREROUTING -i docker -p udp --dport 53 -j DNAT --to-destination "${corporate_dns}:53"
iptables -t nat -C PREROUTING -i docker -p tcp --dport 53 -j DNAT --to-destination "${corporate_dns}:53" 2>/dev/null ||
  iptables -t nat -A PREROUTING -i docker -p tcp --dport 53 -j DNAT --to-destination "${corporate_dns}:53"

# --- Extra public ranges that must go through the tunnel ---
for route in $(echo "$extra_routes" | tr ',' ' '); do
  ip route replace "$route" dev snx-tun
done
ip route flush cache 2>/dev/null || true
EOF
}

teardown_nat() {
  load_env
  require_env CORPORATE_DNS
  docker exec work-vpn sh -c "corporate_dns=\"\$1\"; $DNS_TEARDOWN" sh "$CORPORATE_DNS"
}

configure_linux_dns() {
  container_running work-linux || return 0

  if vpn_connected; then
    load_env
    require_env CORPORATE_DNS
    docker exec work-linux sh -lc "cat > /etc/resolv.conf <<EOF
nameserver ${CORPORATE_DNS}
search .
options edns0 trust-ad ndots:0
EOF"
  else
    docker exec work-linux sh -lc "cat > /etc/resolv.conf <<'EOF'
nameserver 127.0.0.11
search .
options edns0 trust-ad ndots:0
EOF"
  fi
}

# --- Windows sync over SSH ---

# Run a command in the Windows VM with the bootstrap key: an elevated session
# as the user. Any SSH login (key or password) is a network logon, so it cannot
# write Credential Manager; win_user_script works around that with a task.
win_ssh() {
  ssh -p "$WIN_SSH_PORT" -o HostKeyAlias=work-windows \
    -o UserKnownHostsFile="$WIN_KNOWN_HOSTS" -o StrictHostKeyChecking=accept-new \
    -o ConnectTimeout=5 -o LogLevel=ERROR \
    -i "$WIN_SSH_KEY" -o IdentitiesOnly=yes -o BatchMode=yes \
    "$USERNAME@127.0.0.1" "$@"
}

# Run the PowerShell script on stdin in the Windows VM.
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

# Comma-separated SSO sites, validated because they are spliced into
# PowerShell. Defaults to every host under AD_DOMAIN.
sso_sites() {
  local sites="${SSO_SITES:-*.${AD_DOMAIN}}"
  sites="${sites// /}"
  [[ "$sites" =~ ^[A-Za-z0-9.*-]+(,[A-Za-z0-9.*-]+)*$ ]] ||
    die "SSO_SITES must be comma-separated host patterns like *.corp.example.com, got: $sites"
  printf '%s' "$sites"
}

# Machine-wide part, run elevated: trust CERT_DIR (self-signed into Root, the
# rest into Intermediate), let Edge and Chrome answer Negotiate/NTLM for the
# SSO sites, and resync the clock (Kerberos rejects >5 min of skew).
win_machine_script() {
  local file sites=""
  [ -n "${AD_DOMAIN:-}" ] && sites=$(sso_sites)

  echo '$ErrorActionPreference = "Stop"'
  echo '$certs = @('
  shopt -s nullglob
  for file in "$CERT_DIR"/*.crt "$CERT_DIR"/*.cer "$CERT_DIR"/*.pem; do
    printf "  '%s'\n" "$(base64 -w0 "$file")"
  done
  shopt -u nullglob
  echo ')'
  printf "\$sites = '%s'\n" "$sites"
  cat <<'EOF'
foreach ($b64 in $certs) {
  $cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new([Convert]::FromBase64String($b64))
  $storeName = if ($cert.Subject -eq $cert.Issuer) { 'Root' } else { 'CA' }
  $store = [System.Security.Cryptography.X509Certificates.X509Store]::new($storeName, 'LocalMachine')
  $store.Open('ReadWrite')
  try {
    if ($store.Certificates.Find('FindByThumbprint', $cert.Thumbprint, $false).Count -eq 0) {
      $store.Add($cert)
      Write-Output "  certificate added ($storeName): $($cert.Subject)"
    }
  } finally { $store.Close() }
}
Write-Output "  certificates: $($certs.Count) in sync"

if ($sites) {
  foreach ($key in 'HKLM:\SOFTWARE\Policies\Microsoft\Edge', 'HKLM:\SOFTWARE\Policies\Google\Chrome') {
    if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
    Set-ItemProperty -Path $key -Name AuthServerAllowlist -Value $sites -Type String
  }
  Write-Output "  browser policy: Edge + Chrome allow silent login to $sites"
}

try {
  Start-Service w32time
  w32tm /resync /force | Out-Null
} catch { }
EOF
}

# Files directly in GUEST_SSH_DIR (keys, config, known_hosts), one per line,
# for ~/.ssh in both guests. Names are spliced into PowerShell, so validated.
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

# Copy GUEST_SSH_DIR into ~/.ssh in the Linux container. Through docker exec as
# the container user, so ownership is right whatever the host uid is.
linux_sync_ssh() {
  local names tries=0
  load_env
  container_running work-linux || return 0
  names=$(guest_ssh_files)
  [ -n "$names" ] || return 0

  # The entrypoint creates the user; give a just-started container a moment.
  until docker exec work-linux id -u "$USERNAME" >/dev/null 2>&1; do
    tries=$((tries + 1))
    [ "$tries" -lt 10 ] || { warn "Linux user $USERNAME not ready; SSH keys not copied."; return 1; }
    sleep 1
  done

  printf '%s\n' "$names" | tar -C "$GUEST_SSH_DIR" -cf - -T - |
    docker exec -i -u "$USERNAME" work-linux sh -c '
      mkdir -p ~/.ssh && chmod 700 ~/.ssh &&
      tar -C ~/.ssh --no-same-owner -xf - &&
      find ~/.ssh -maxdepth 1 -type f ! -name "*.pub" -exec chmod 600 {} +' ||
    { warn "Could not copy SSH keys into the Linux container."; return 1; }
  echo -e "  ${DIM}linux ssh: $(printf '%s ' $names)${NC}"
}

# Store the AD credential in Credential Manager for each SSO site, so Windows
# answers their login challenge itself. Runs inside the credential task (see
# win_user_script) and reports through a .log next to itself.
win_cred_script() {
  local user="$1" password="$2" sites="$3" site

  echo '$ErrorActionPreference = "Stop"'
  echo '$log = [IO.Path]::ChangeExtension($PSCommandPath, ".log")'
  echo 'try {'
  printf "\$user = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('%s'))\n" "$(printf '%s' "$user" | base64 -w0)"
  printf "\$pass = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('%s'))\n" "$(printf '%s' "$password" | base64 -w0)"
  echo '$targets = @('
  for site in ${sites//,/ }; do
    printf "  '%s'\n" "$site"
  done
  echo ')'
  cat <<'EOF'
Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
public static class WorkCred {
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  struct CREDENTIAL {
    public int Flags; public int Type; public string TargetName; public string Comment;
    public long LastWritten; public int CredentialBlobSize; public IntPtr CredentialBlob;
    public int Persist; public int AttributeCount; public IntPtr Attributes;
    public string TargetAlias; public string UserName;
  }
  [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
  static extern bool CredWrite(ref CREDENTIAL credential, int flags);
  public static void Write(string target, string user, string pass) {
    var c = new CREDENTIAL();
    c.Type = 2;     // CRED_TYPE_DOMAIN_PASSWORD: used by Negotiate, Kerberos, NTLM
    c.Persist = 2;  // CRED_PERSIST_LOCAL_MACHINE
    c.TargetName = target;
    c.UserName = user;
    c.Comment = "Managed by work.sh";
    byte[] blob = System.Text.Encoding.Unicode.GetBytes(pass);
    c.CredentialBlobSize = blob.Length;
    c.CredentialBlob = Marshal.AllocCoTaskMem(blob.Length);
    try {
      Marshal.Copy(blob, 0, c.CredentialBlob, blob.Length);
      if (!CredWrite(ref c, 0)) throw new Win32Exception(Marshal.GetLastWin32Error());
    } finally {
      Marshal.FreeCoTaskMem(c.CredentialBlob);
    }
  }
}
'@
  foreach ($t in $targets) { [WorkCred]::Write($t, $user, $pass) }
  $result = "  credentials: $user stored for $($targets -join ', ')"
} catch {
  $result = "error: $_"
}
# Write then rename, so the waiting side never reads a partial file.
Set-Content -Path "$log.tmp" -Value $result
Move-Item -Path "$log.tmp" -Destination $log -Force
EOF
}

# User part, run over the key session: copy GUEST_SSH_DIR into ~\.ssh, then
# store the SSO credentials. An SSH login is a network logon, which has no
# Credential Manager, so that part runs as a one-shot scheduled task logged on
# with VM_PASSWORD; the task and its script (in the user-only %TEMP%) are
# removed afterwards. Secrets travel base64-encoded inside the script on ssh's
# stdin. Empty sites skip the credential part.
win_user_script() {
  local user="$1" password="$2" sites="$3" vm_password="$4" name

  echo '$ErrorActionPreference = "Stop"'
  echo '$sshFiles = [ordered]@{'
  while read -r name; do
    [ -n "$name" ] && printf "  '%s' = '%s'\n" "$name" "$(base64 -w0 "$GUEST_SSH_DIR/$name")"
  done <<<"$(guest_ssh_files)"
  echo '}'
  cat <<'EOF'
if ($sshFiles.Count) {
  $dir = Join-Path $env:USERPROFILE '.ssh'
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
  foreach ($name in $sshFiles.Keys) {
    [IO.File]::WriteAllBytes((Join-Path $dir $name), [Convert]::FromBase64String($sshFiles[$name]))
  }
  Write-Output "  windows ssh: $($sshFiles.Keys -join ' ')"
}
EOF

  [ -n "$sites" ] || return 0
  printf "\$credScript = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('%s'))\n" \
    "$(win_cred_script "$user" "$password" "$sites" | base64 -w0)"
  printf "\$vmPass = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('%s'))\n" \
    "$(printf '%s' "$vm_password" | base64 -w0)"
  cat <<'EOF'
$task = 'work.sh credentials'
$file = Join-Path $env:TEMP "work-cred-$([guid]::NewGuid()).ps1"
$log = [IO.Path]::ChangeExtension($file, '.log')
try {
  [IO.File]::WriteAllText($file, $credScript)
  $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$file`""
  Register-ScheduledTask -TaskName $task -Action $action -Force `
    -User "$env:COMPUTERNAME\$env:USERNAME" -Password $vmPass | Out-Null
  Start-ScheduledTask -TaskName $task
  $deadline = (Get-Date).AddSeconds(60)
  while (-not (Test-Path $log)) {
    if ((Get-Date) -gt $deadline) { throw 'the credential task did not finish within 60 s' }
    Start-Sleep -Milliseconds 300
  }
  $result = (Get-Content -Path $log -Raw).TrimEnd()
  if ($result -like 'error:*') { throw $result }
  Write-Output $result
} finally {
  Unregister-ScheduledTask -TaskName $task -Confirm:$false -ErrorAction SilentlyContinue
  Remove-Item -Path $file, $log, "$log.tmp" -Force -ErrorAction SilentlyContinue
}
EOF
}

# Push certificates, browser policy, SSH keys and SSO credentials into the
# Windows VM. Idempotent; runs on every start so a rotated password is picked up.
windows_sync() {
  load_env
  require_env USERNAME VM_PASSWORD
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
  win_machine_script | win_ps || { warn "Machine sync (certificates, browser policy) failed."; return 1; }

  local sites="" user="" password=""
  if [ -z "${AD_DOMAIN:-}" ]; then
    echo -e "  ${DIM}credentials: skipped, AD_DOMAIN is not set in $(tilde "$WORK_ENV")${NC}"
  elif [ -z "${AD_PASSWORD:-${VPN_PASSWORD:-}}" ]; then
    echo -e "  ${DIM}credentials: skipped, neither AD_PASSWORD nor VPN_PASSWORD is set${NC}"
  else
    sites=$(sso_sites) || return 1
    user="${AD_USER:-$USERNAME@$AD_DOMAIN}"
    password="${AD_PASSWORD:-$VPN_PASSWORD}"
  fi

  if [ -n "$sites" ] || [ -n "$(guest_ssh_files 2>/dev/null)" ]; then
    win_user_script "$user" "$password" "$sites" "$VM_PASSWORD" |
      win_ps || { warn "User sync (SSH keys, credentials) failed."; return 1; }
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

  mkdir -p -m 700 "$WORK_STATE_DIR"
  [ -f "$WIN_SSH_KEY" ] || ssh-keygen -q -t ed25519 -N '' -C "work.sh windows sync" -f "$WIN_SSH_KEY"

  local pubkey script encoded
  pubkey=$(cat "$WIN_SSH_KEY.pub")
  script=$(cat <<EOF
\$ErrorActionPreference = 'Stop'
\$cap = Get-WindowsCapability -Online | Where-Object Name -like 'OpenSSH.Server*'
if (\$cap.State -ne 'Installed') {
  Write-Host 'Installing OpenSSH Server (takes a minute)...'
  Add-WindowsCapability -Online -Name \$cap.Name | Out-Null
}
Set-Service -Name sshd -StartupType Automatic
Start-Service sshd
if (-not (Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue)) {
  New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH Server (sshd)' -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 | Out-Null
}
# Administrators authenticate against this file, not ~\\.ssh\\authorized_keys.
\$keys = Join-Path \$env:ProgramData 'ssh\\administrators_authorized_keys'
\$pubkey = '$pubkey'
if (-not ((Test-Path \$keys) -and (Select-String -Path \$keys -SimpleMatch \$pubkey -Quiet))) {
  Add-Content -Path \$keys -Value \$pubkey -Encoding ascii
}
icacls.exe \$keys /inheritance:r /grant '*S-1-5-32-544:F' /grant '*S-1-5-18:F' | Out-Null
Write-Host 'Done. On the host, run: ./work.sh windows sync'
EOF
  )
  # -EncodedCommand takes base64 of UTF-16LE.
  encoded=$(printf '%s' "$script" | iconv -f UTF-8 -t UTF-16LE | base64 -w0)
  local cmd="powershell -NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded"

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

# --- Commands ---

cmd_connect() {
  local log_level=info
  [[ "$1" == "--debug" || "$1" == "-debug" ]] && log_level=debug

  load_env
  require_env USERNAME VPN_SERVER VPN_PASSWORD CORPORATE_DNS

  # Check if already connected
  if vpn_connected; then
    warn "VPN is already connected."
    setup_nat || warn "Could not apply NAT/routing inside work-vpn; guests may not reach the VPN."
    cmd_status
    return
  fi

  read -p "2FA code: " otp
  echo ""

  FULL_PASSWORD_B64=$(printf '%s' "${VPN_PASSWORD}${otp}" | base64 -w0)

  # Ensure VPN container is up
  if ! container_running work-vpn; then
    info "Starting VPN container..."
    compose up -d vpn
    sleep 2
  fi

  container_running work-vpn || die "work-vpn failed to start"

  info "Connecting VPN as $USERNAME to $VPN_SERVER..."

  # Hand the credentials over in a root-only file instead of argv, which stays
  # readable in the host process list for the life of the tunnel.
  {
    cat "$SCRIPT_DIR/snx-rs.conf"
    printf '\nserver-name = %s\nuser-name = %s\npassword = %s\n' \
      "$VPN_SERVER" "$USERNAME" "$FULL_PASSWORD_B64"
  } | docker exec -i work-vpn sh -c "umask 077 && cat > $VPN_RUNTIME_CONF"

  # Run snx-rs detached inside the container, logging to /var/log/snx-rs.log.
  # Whenever it exits, for any reason, the guest DNS redirect goes with it.
  docker exec -d work-vpn sh -c "
    snx-rs -m standalone -c \"\$1\" -l \"\$2\" >> /var/log/snx-rs.log 2>&1
    rm -f \"\$1\"
    corporate_dns=\"\$3\"; $DNS_TEARDOWN" \
    sh "$VPN_RUNTIME_CONF" "$log_level" "$CORPORATE_DNS"

  # Wait for tunnel to come up
  local timeout=30 waited
  for waited in $(seq 1 $timeout); do
    sleep 1
    if vpn_connected; then
      docker exec work-vpn rm -f "$VPN_RUNTIME_CONF"
      echo ""
      if setup_nat; then
        success "VPN connected."
      else
        warn "VPN connected, but NAT/routing setup inside work-vpn failed; guests may not reach the VPN."
      fi
      cmd_status
      return
    fi
    # snx-rs already gave up: no point waiting out the clock
    docker exec work-vpn pgrep -x snx-rs >/dev/null 2>&1 || break
  done

  # If we get here, tunnel didn't come up — show logs for diagnosis
  docker exec work-vpn rm -f "$VPN_RUNTIME_CONF" 2>/dev/null || true
  if [ "$waited" -lt "$timeout" ]; then
    warn "snx-rs exited after ${waited}s without bringing the tunnel up."
  else
    warn "VPN tunnel did not come up within ${timeout}s."
  fi
  echo ""
  echo -e "${DIM}--- snx-rs log ---${NC}"
  docker exec work-vpn tail -n 40 /var/log/snx-rs.log 2>/dev/null || echo "(no log output)"
  echo -e "${DIM}--- end ---${NC}"
  return 1
}

cmd_disconnect() {
  if ! container_running work-vpn; then
    warn "VPN container is not running."
    return
  fi

  if ! vpn_connected; then
    warn "VPN tunnel is not up."
    # Still kill any lingering snx-rs process
    docker exec work-vpn killall snx-rs 2>/dev/null || true
    teardown_nat
    configure_linux_dns
    return
  fi

  info "Disconnecting VPN..."
  docker exec work-vpn killall snx-rs 2>/dev/null || true
  sleep 1
  if vpn_connected; then
    warn "Tunnel still up, forcing..."
    docker exec work-vpn killall -9 snx-rs 2>/dev/null || true
    sleep 1
  fi
  vpn_connected && die "Could not stop snx-rs; the tunnel is still up."
  teardown_nat
  configure_linux_dns
  success "VPN disconnected."
}

cmd_reconnect() {
  cmd_disconnect
  sleep 1
  cmd_connect "$@"
}

cmd_status() {
  # The tunnel can drop on its own; keep the Linux resolver in step with it.
  configure_linux_dns

  echo -e "${BOLD}Work Environment Status${NC}"
  echo ""

  # VPN container
  if container_running work-vpn; then
    if vpn_connected; then
      local vpn_ip vpn_dns
      vpn_ip=$(docker exec work-vpn ip -4 addr show snx-tun 2>/dev/null | grep -oP 'inet \K[0-9./]+' || echo "unknown")
      vpn_dns=$(docker exec work-vpn cat /etc/resolv.conf 2>/dev/null | grep -oP 'nameserver \K[0-9.]+' | head -1 || echo "")
      echo -e "  VPN:     ${GREEN}connected${NC}"
      echo -e "           IP: $vpn_ip"
      [ -n "$vpn_dns" ] && echo -e "           DNS: $vpn_dns"
    else
      echo -e "  VPN:     ${YELLOW}container running, tunnel down${NC}"
    fi
  else
    echo -e "  VPN:     ${RED}stopped${NC}"
  fi

  # Windows
  if container_running work-windows; then
    echo -e "  Windows: ${GREEN}running${NC}"
    echo -e "           Web: http://127.0.0.1:8007"
    echo -e "           RDP: 127.0.0.1:3390"
  else
    echo -e "  Windows: ${RED}stopped${NC}"
  fi

  # Linux
  if container_running work-linux; then
    echo -e "  Linux:   ${GREEN}running${NC}"
    echo -e "           Shell: ./work.sh linux shell"
  else
    echo -e "  Linux:   ${RED}stopped${NC}"
  fi

  echo ""
}

# Resolve + connect to an internal-only host along both guest paths. The VPN
# hands out a single address: Linux shares work-vpn's network namespace and
# uses it directly, Windows is masqueraded behind it.
cmd_test() {
  local host failed=0 out addr

  load_env
  host="${1:-${VPN_TEST_HOST:-}}"
  [ -n "$host" ] || die "No host to test. Pass one (./work.sh test <host>) or set VPN_TEST_HOST in $(tilde "$WORK_ENV")."

  container_running work-vpn || die "work-vpn is not running. Run: ./work.sh up"
  vpn_connected || die "VPN tunnel is down. Run: ./work.sh connect"

  echo -e "${BOLD}VPN test: $host${NC}"
  echo ""

  # Linux path: locally originated traffic, resolver pointed at corporate DNS
  if container_running work-linux; then
    addr=$(docker exec work-linux getent ahostsv4 "$host" 2>/dev/null | awk 'NR==1{print $1}')
    if [ -z "$addr" ]; then
      echo -e "  Linux:   ${RED}DNS failed${NC} (resolver: $(docker exec work-linux awk '/^nameserver/{print $2; exit}' /etc/resolv.conf))"
      failed=1
    elif docker exec work-linux timeout 8 bash -c "exec 3<>/dev/tcp/$addr/443" 2>/dev/null; then
      echo -e "  Linux:   ${GREEN}ok${NC} ($host -> $addr, tcp/443 open)"
    else
      echo -e "  Linux:   ${RED}resolved $addr but tcp/443 failed${NC}"
      failed=1
    fi
  else
    echo -e "  Linux:   ${DIM}not running, skipped${NC}"
  fi

  # Windows path: a throwaway namespace plugged into the VM bridge, so the
  # probe is forwarded, DNS-redirected and NATed exactly like the VM's traffic.
  if container_running work-windows; then
    out=$(docker exec -i work-vpn sh -s -- "$host" 2>&1 <<'EOF'
host="$1"
ns="work-probe"
cleanup() {
  ip netns del "$ns" 2>/dev/null
  ip link del probe0 2>/dev/null
  rm -rf "/etc/netns/$ns"
}
trap cleanup EXIT
cleanup

gw=$(ip -4 -o addr show dev docker 2>/dev/null | awk 'NR==1{print $4}')
[ -n "$gw" ] || { echo "VM bridge not up yet"; exit 1; }
probe_ip="${gw%.*}.250/${gw#*/}"

set -e
ip netns add "$ns"
ip link add probe0 type veth peer name probe1 netns "$ns"
ip link set probe0 master docker up
ip -n "$ns" link set lo up
ip -n "$ns" addr add "$probe_ip" dev probe1
ip -n "$ns" link set probe1 up
ip -n "$ns" route add default via "${gw%/*}"
mkdir -p "/etc/netns/$ns"
echo "nameserver ${gw%/*}" > "/etc/netns/$ns/resolv.conf"
set +e

addr=$(ip netns exec "$ns" timeout 12 getent ahostsv4 "$host" | awk 'NR==1{print $1}')
[ -n "$addr" ] || { echo "DNS failed"; exit 1; }
ip netns exec "$ns" timeout 8 bash -c "exec 3<>/dev/tcp/$addr/443" 2>/dev/null ||
  { echo "resolved $addr but tcp/443 failed"; exit 1; }
echo "$host -> $addr, tcp/443 open"
EOF
    ) && echo -e "  Windows: ${GREEN}ok${NC} ($out)" || {
      echo -e "  Windows: ${RED}${out}${NC}"
      failed=1
    }
  else
    echo -e "  Windows: ${DIM}not running, skipped${NC}"
  fi

  echo ""
  return $failed
}

cmd_up() {
  load_env
  require_env USERNAME VM_PASSWORD
  info "Starting all containers..."
  compose up -d --build
  configure_linux_dns
  linux_sync_ssh || true
  success "All containers started."
  windows_sync || true
  echo ""
  cmd_status
}

cmd_down() {
  info "Stopping all containers..."
  compose down
  success "All containers stopped."
}

cmd_logs() {
  local service="${1:-vpn}"
  case "$service" in
    vpn)     docker exec work-vpn tail -f /var/log/snx-rs.log 2>/dev/null || warn "No VPN logs yet. Connect first with: ./work.sh connect" ;;
    windows) docker logs -f work-windows ;;
    linux)   docker logs -f work-linux ;;
    *)       die "Unknown service: $service. Use 'vpn', 'windows', or 'linux'." ;;
  esac
}

# --- VM subcommands ---

vm_start() {
  local vm="$1"
  load_env
  require_env USERNAME VM_PASSWORD

  # Ensure VPN container is up first (VMs depend on it for networking)
  if ! container_running work-vpn; then
    info "Starting VPN container..."
    compose up -d vpn
    sleep 2
  fi

  info "Starting $vm..."
  if [ "$vm" = "linux" ]; then
    compose up -d --build "$vm"
  else
    compose up -d "$vm"
  fi
  success "$vm started."
}



vm_stop() {
  local vm="$1"
  info "Stopping $vm gracefully..."
  compose stop "$vm"
  success "$vm stopped."
}

vm_restart() {
  local vm="$1"
  vm_stop "$vm"
  sleep 2
  vm_start "$vm"
}

vm_logs() {
  local container="$1"
  docker logs -f "$container"
}

cmd_windows() {
  local action="${1:-help}"
  case "$action" in
    start)
      vm_start windows
      windows_sync || true
      ;;
    stop)    vm_stop windows ;;
    restart)
      vm_restart windows
      windows_sync || true
      ;;
    sync|certs) windows_sync ;;
    bootstrap)  windows_bootstrap ;;
    logs)    vm_logs work-windows ;;
    rdp)
      load_env
      require_env USERNAME VM_PASSWORD
      local rdp_bin
      rdp_bin=$(rdp_client) || die "No FreeRDP client found. Install the freerdp package (it provides xfreerdp3). ./work.sh windows web needs no client."

      # Detect Hyprland display scale
      local rdp_scale=""
      local rdp_log="/tmp/work-windows-rdp.log"
      if command -v hyprctl &>/dev/null; then
        local hypr_json hypr_scale
        if hypr_json=$(hyprctl monitors -j 2>/dev/null); then
          hypr_scale=$(printf '%s' "$hypr_json" | jq -r '.[] | select(.focused == true) | .scale' 2>/dev/null || true)
        fi
        if [ -n "${hypr_scale:-}" ]; then
          local scale_pct
          scale_pct=$(echo "$hypr_scale" | awk '{print int($1 * 100)}')
          if (( scale_pct >= 170 )); then
            rdp_scale="/scale:180"
          elif (( scale_pct >= 130 )); then
            rdp_scale="/scale:140"
          fi
        fi
      fi

      info "Opening RDP to Windows VM..."
      local rdp_args rdp_pid
      rdp_args=$(mktemp /tmp/work-windows-rdp.XXXXXX)
      chmod 600 "$rdp_args"
      {
        printf '%s\n' "/v:127.0.0.1:3390"
        printf '%s\n' "/u:localhost\\$USERNAME"
        printf '%s\n' "/p:$VM_PASSWORD"
        printf '%s\n' "/auth-pkg-list:none,ntlm"
        printf '%s\n' "/cert:ignore"
        printf '%s\n' "/dynamic-resolution"
        printf '%s\n' "/gfx:AVC444"
        printf '%s\n' "/floatbar:sticky:off,default:visible,show:fullscreen"
        printf '%s\n' "/sound"
        printf '%s\n' "/microphone"
        printf '%s\n' "/clipboard"
        printf '%s\n' "/title:Work Windows"
        printf '%s\n' "-grab-keyboard"
        [ -n "$rdp_scale" ] && printf '%s\n' "$rdp_scale"
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
      ;;
    web)
      info "Opening Windows web viewer..."
      xdg-open "http://127.0.0.1:8007" 2>/dev/null &
      ;;
    *)
      echo -e "${BOLD}Windows VM commands:${NC}"
      echo ""
      echo "  ./work.sh windows start    Start the Windows VM"
      echo "  ./work.sh windows stop     Graceful shutdown"
      echo "  ./work.sh windows restart  Stop + start"
      echo "  ./work.sh windows rdp      Open RDP session"
      echo "  ./work.sh windows sync     Push certificates + SSO credentials (runs on start)"
      echo "  ./work.sh windows bootstrap  One-time: enable SSH in Windows for sync"
      echo "  ./work.sh windows web      Open web viewer in browser"
      echo "  ./work.sh windows logs     Tail container logs"
      ;;
  esac
}

# --- Future VM stubs ---

cmd_linux() {
  local action="${1:-help}"
  case "$action" in
    start)
      vm_start linux
      configure_linux_dns
      linux_sync_ssh || true
      ;;
    stop)
      vm_stop linux
      ;;
    restart)
      vm_restart linux
      configure_linux_dns
      linux_sync_ssh || true
      ;;
    logs)
      vm_logs work-linux
      ;;
    shell|ssh)
      if ! container_running work-linux; then
        info "Linux container is not running, starting it..."
        vm_start linux
        configure_linux_dns
        linux_sync_ssh || true
      fi
      load_env
      require_env USERNAME
      # docker exec defaults to TERM=xterm; hand over the real terminal so
      # colours, the prompt and nvim behave as they do on the host.
      exec docker exec -it -u "$USERNAME" -w "/home/$USERNAME" \
        -e TERM="${TERM:-xterm-256color}" -e COLORTERM="${COLORTERM:-truecolor}" \
        work-linux bash -l
      ;;
    rebuild)
      info "Snapshotting host Omarchy config..."
      "$SCRIPT_DIR/linux-image/sync-host-config.sh"
      info "Rebuilding the Linux image..."
      compose build linux
      compose up -d --force-recreate linux
      configure_linux_dns
      linux_sync_ssh || true
      success "Linux container rebuilt. Configs already in your home are kept; delete one to get the fresh copy."
      ;;
    *)
      echo -e "${BOLD}Linux commands:${NC}"
      echo ""
      echo "  ./work.sh linux start      Start the Linux container"
      echo "  ./work.sh linux stop       Stop the Linux container"
      echo "  ./work.sh linux restart    Stop + start"
      echo "  ./work.sh linux shell      Open interactive shell (alias: ssh)"
      echo "  ./work.sh linux rebuild    Re-snapshot host Omarchy config and rebuild the image"
      echo "  ./work.sh linux logs       Tail container logs"
      ;;
  esac
}

# --- Help ---

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

cmd_paths() {
  [ -f "$WORK_ENV" ] && load_env
  local row='  %-9s %-34s %s\n'
  echo -e "${BOLD}Folders${NC}"
  echo ""
  printf "$row" "env"     "$(tilde "$WORK_ENV")"            "settings and passwords (mode 0600)"
  printf "$row" "certs"   "$(tilde "$CERT_DIR")"            "CAs trusted by both guests"
  printf "$row" "ssh"     "$(tilde "$GUEST_SSH_DIR")"       "copied into ~/.ssh of both guests"
  printf "$row" "shared"  "$(tilde "$WORK_SHARED_DIR")"     "mounted in both guests (Linux: ~/Shared)"
  printf "$row" "data"    "$(tilde "$WORK_DATA_DIR")"       "windows/ disk, linux/ home, state/"
  printf "$row" "code"    "$(tilde "$SCRIPT_DIR")"          "this repo"
  echo ""
  echo -e "${DIM}Certificates and keys reach the guests on every start, or now with:"
  echo -e "  ./work.sh windows sync   ./work.sh linux restart${NC}"
  if legacy_items >/dev/null; then
    echo ""
    warn "Old in-repo layout found. Run: ./work.sh migrate"
  fi
}

cmd_open() {
  [ -f "$WORK_ENV" ] && load_env
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
  local src="$1" dest="$2" sudo=""
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
    sudo="sudo"
  fi
  $sudo mv "$src" "$dest" || die "Could not move $(tilde "$src")."
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
  echo "Found: $(printf '%s ' $items)"
  warn "This stops all containers, the VPN included."
  read -p "Continue? [y/N] " ans
  case "$ans" in
    y | Y) ;;
    *) info "Nothing changed."; return 0 ;;
  esac

  info "Stopping containers..."
  docker compose -f "$COMPOSE_FILE" down || die "Could not stop the containers."

  echo ""
  mkdir -p -m 700 "$WORK_CONFIG_DIR"
  mkdir -p -m 700 "$GUEST_SSH_DIR"
  migrate_move "$SCRIPT_DIR/certificates" "$CERT_DIR"
  migrate_move "$SCRIPT_DIR/.work" "$WORK_STATE_DIR"

  if [ -d "$SCRIPT_DIR/shared" ]; then
    local key
    for key in "$SCRIPT_DIR"/shared/id_*; do
      [ -f "$key" ] && migrate_move "$key" "$GUEST_SSH_DIR/$(basename "$key")"
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
  [ -f "$WORK_ENV" ] && chmod 600 "$WORK_ENV"

  echo ""
  success "Migrated."
  echo ""
  cmd_paths
  echo ""
  info "Next: ./work.sh up, then ./work.sh connect"
}

# --- Setup / preflight ---

# One prerequisite check. `kind` is req or opt: a failed req is counted by the
# caller and blocks, a failed opt only warns. The probe is a shell snippet.
check() {
  local kind="$1" label="$2" probe="$3" hint="$4"
  if bash -c "$probe" >/dev/null 2>&1; then
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

# Single-quote a value for safe inclusion in the env file, which load_env sources.
# Without this a value with a space, $, #, quote or backslash breaks sourcing:
# each embedded ' becomes '\'' and the whole is wrapped in single quotes.
env_quote() {
  printf "'%s'" "${1//\'/\'\\\'\'}"
}

cmd_doctor() {
  echo -e "${BOLD}Preflight${NC}"
  echo ""
  local fails=0

  check req "Docker"             'command -v docker'                   "Install Docker. See https://docs.docker.com/engine/install/" || fails=$((fails + 1))
  check req "Docker daemon"      'docker info'                         "Start Docker, or add yourself to the docker group and re-login." || fails=$((fails + 1))
  check req "Docker Compose v2"  'docker compose version'              "Install the docker compose plugin." || fails=$((fails + 1))
  check req "KVM (/dev/kvm)"     '[ -r /dev/kvm ] && [ -w /dev/kvm ]'  "Enable virtualization in BIOS, add yourself to the kvm group, re-login." || fails=$((fails + 1))
  check req "TUN (/dev/net/tun)" '[ -e /dev/net/tun ]'                 "Load the module: sudo modprobe tun." || fails=$((fails + 1))

  echo ""
  check opt "FreeRDP"            'command -v xfreerdp3 || command -v xfreerdp'  "Only for ./work.sh windows rdp (package: freerdp). ./work.sh windows web works without it." || true
  check opt "jq"                 'command -v jq'                       "Only for Hyprland RDP scale detection." || true
  check opt "OpenSSH client"     'command -v ssh && command -v ssh-keygen'  "Only for ./work.sh windows sync (package: openssh)." || true

  echo ""
  # Repo integrity. The Linux image build copies this snapshot, so a clone
  # missing it fails the build. Catch it here, not halfway through a build.
  check req "Linux image rootfs" "[ -d '$SCRIPT_DIR/linux-image/rootfs' ]" "linux-image/rootfs/ is missing. It must be committed to the repo; ask whoever shared it." || fails=$((fails + 1))
  check opt "env file"           "[ -f '$WORK_ENV' ]"                  "Not configured yet. Run ./work.sh setup, or ./work.sh migrate if .env is still in the repo." || true
  check opt "folder layout"      "! [ -e '$SCRIPT_DIR/.env' -o -e '$SCRIPT_DIR/windows' -o -e '$SCRIPT_DIR/linux' -o -e '$SCRIPT_DIR/shared' -o -e '$SCRIPT_DIR/certificates' ]" "Old in-repo layout. Run ./work.sh migrate." || true

  echo ""
  if [ "$fails" -gt 0 ]; then
    warn "$fails required check(s) failed. Fix the above, then re-run ./work.sh doctor."
    return 1
  fi
  success "All required checks passed."
}

cmd_setup() {
  local env_file="$WORK_ENV"
  local example="$SCRIPT_DIR/.env.example"

  [ -f "$example" ] || die ".env.example not found. Run this from the repo root."
  legacy_items >/dev/null && die "Found the old in-repo layout. Run ./work.sh migrate instead."

  echo -e "${BOLD}Work environment setup${NC}"
  echo ""
  echo -e "${DIM}Fields marked [IT] come from your IT admin or Check Point client logs.${NC}"
  echo -e "${DIM}Press Enter to accept a default shown in [brackets].${NC}"
  echo ""

  if [ -f "$env_file" ]; then
    warn "$(tilde "$env_file") already exists."
    read -p "Overwrite it (a backup goes to env.bak)? [y/N] " ans
    case "$ans" in
      y | Y) cp "$env_file" "$env_file.bak" ;;
      *)
        info "Keeping the existing env file. Nothing changed."
        return 0
        ;;
    esac
  fi

  local username vm_password vpn_server vpn_password corporate_dns extra_routes test_host ad_domain sso_sites

  read -p "Local guest username (USERNAME) [your.username]: " username
  username="${username:-your.username}"

  read -rsp "Password for the Windows and Linux guests (VM_PASSWORD), Enter to auto-generate: " vm_password
  echo ""
  if [ -z "$vm_password" ]; then
    vm_password=$(gen_password)
    info "Generated a random VM_PASSWORD. It is stored in $(tilde "$env_file"); read it there if you log in to Windows directly."
  fi

  read -p "VPN gateway IP (VPN_SERVER) [IT]: " vpn_server
  read -rsp "VPN password (VPN_PASSWORD), rotates ~45d, Enter to fill later: " vpn_password
  echo ""
  read -p "Corporate DNS (CORPORATE_DNS) [IT]: " corporate_dns
  read -p "Extra ranges through the tunnel (VPN_EXTRA_ROUTES), comma-separated, 'github' = GitHub's live ranges [github]: " extra_routes
  extra_routes="${extra_routes:-github}"
  read -p "Internal host for ./work.sh test (VPN_TEST_HOST) [optional]: " test_host
  read -p "AD domain for Windows silent login (AD_DOMAIN), e.g. corp.example.com [optional]: " ad_domain
  if [ -n "$ad_domain" ]; then
    read -p "Sites that get silent login (SSO_SITES), comma-separated [*.$ad_domain]: " sso_sites
  fi

  # Single-quote every value so load_env can source the file even when a
  # password holds a space, $, #, quote or backslash. chmod is explicit
  # because umask only applies to a newly created file; overwriting an
  # existing file in place would otherwise keep its old, looser mode.
  umask 077
  mkdir -p "$WORK_CONFIG_DIR" "$CERT_DIR" "$GUEST_SSH_DIR"
  chmod 700 "$WORK_CONFIG_DIR"
  cat >"$env_file" <<EOF
# Generated by ./work.sh setup. Edit freely; re-run setup to regenerate.

# --- Local guest accounts (Windows VM + Linux container) ---
# Not domain-joined, so this password does not rotate.
USERNAME=$(env_quote "$username")
VM_PASSWORD=$(env_quote "$vm_password")

# --- Corporate VPN ---
# VPN_PASSWORD rotates on the company schedule (~45d). 2FA is prompted at connect.
VPN_SERVER=$(env_quote "$vpn_server")
VPN_PASSWORD=$(env_quote "$vpn_password")

# Internal DNS, reachable only through the tunnel. Both guests use it while up.
CORPORATE_DNS=$(env_quote "$corporate_dns")

# Public ranges to route through the tunnel as well, comma-separated.
# Corporate GitHub is IP-allowlisted, so its ranges belong here or git is blocked.
VPN_EXTRA_ROUTES=$(env_quote "$extra_routes")

# Internal-only hostname for ./work.sh test.
VPN_TEST_HOST=$(env_quote "$test_host")

# --- Windows silent login (pushed by ./work.sh windows sync) ---
# The AD account is AD_USER (default USERNAME@AD_DOMAIN) with AD_PASSWORD
# (default VPN_PASSWORD). SSO_SITES defaults to *.AD_DOMAIN.
AD_DOMAIN=$(env_quote "$ad_domain")
SSO_SITES=$(env_quote "$sso_sites")
#AD_USER=
#AD_PASSWORD=
EOF
  chmod 600 "$env_file"

  success "$(tilde "$env_file") written."
  info "Drop internal CA files into $(tilde "$CERT_DIR") and guest SSH keys into $(tilde "$GUEST_SSH_DIR")."
  echo ""
  info "Next:"
  info "  ./work.sh doctor    check prerequisites"
  info "  ./work.sh up        build and start the containers"
  info "  ./work.sh connect   bring up the VPN (prompts for 2FA)"
}

# --- Main dispatcher ---

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
  up)       cmd_up ;;
  down)       cmd_down ;;
  logs)       shift; cmd_logs "$@" ;;
  windows)    shift; cmd_windows "$@" ;;
  linux)      shift; cmd_linux "$@" ;;
  help|--help|-h) cmd_help ;;
  *)          die "Unknown command: $1. Run './work.sh help' for usage." ;;
esac

#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COMPOSE="docker compose -f $SCRIPT_DIR/docker-compose.yml"
VM_SUBNET="172.30.0.0/24"   # dockurr's bridge inside work-vpn
VPN_RUNTIME_CONF="/run/snx-rs-connect.conf"

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
  [ -f "$SCRIPT_DIR/.env" ] || die ".env file not found. Copy .env.example to .env and fill in your credentials."
  set -a
  source "$SCRIPT_DIR/.env"
  set +a
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
    die "Missing in .env: ${missing[*]}. See .env.example."
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

# Set up NAT + DNS forwarding inside work-vpn
setup_nat() {
  load_env
  require_env CORPORATE_DNS
  docker exec -i work-vpn sh -s -- "$CORPORATE_DNS" "$VM_SUBNET" "${VPN_EXTRA_ROUTES:-}" <<'EOF'
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

prepare_windows_certs() {
  local src_dir="$SCRIPT_DIR/certificates"
  local dst_dir="$SCRIPT_DIR/shared/certificates"
  local cert_count=0
  local file

  mkdir -p "$src_dir" "$dst_dir"

  rm -f "$dst_dir"/*.crt "$dst_dir"/*.cer "$dst_dir"/*.pem

  shopt -s nullglob
  for file in "$src_dir"/*.crt "$src_dir"/*.cer "$src_dir"/*.pem; do
    [ -f "$file" ] || continue
    cp -f "$file" "$dst_dir/"
    cert_count=$((cert_count + 1))
  done
  shopt -u nullglob

  cat > "$dst_dir/import-certs.ps1" <<'EOF'
$certDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$certFiles = Get-ChildItem -Path $certDir -File | Where-Object { $_.Extension -in '.crt', '.cer', '.pem' }

if (-not $certFiles) {
  Write-Host 'No certificate files found.'
  exit 0
}

foreach ($certFile in $certFiles) {
  Import-Certificate -FilePath $certFile.FullName -CertStoreLocation Cert:\LocalMachine\Root | Out-Null
  Write-Host "Imported $($certFile.Name)"
}
EOF

  printf '%s\n' "$cert_count"
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
    $COMPOSE up -d vpn
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
  [ -n "$host" ] || die "No host to test. Pass one (./work.sh test <host>) or set VPN_TEST_HOST in .env."

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
  $COMPOSE up -d --build
  configure_linux_dns
  success "All containers started."
  echo ""
  cmd_status
}

cmd_down() {
  info "Stopping all containers..."
  $COMPOSE down
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
    $COMPOSE up -d vpn
    sleep 2
  fi

  info "Starting $vm..."
  if [ "$vm" = "linux" ]; then
    $COMPOSE up -d --build "$vm"
  else
    $COMPOSE up -d "$vm"
  fi
  success "$vm started."
}



vm_stop() {
  local vm="$1"
  info "Stopping $vm gracefully..."
  $COMPOSE stop "$vm"
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
      prepare_windows_certs >/dev/null
      vm_start windows
      ;;
    stop)    vm_stop windows ;;
    restart)
      prepare_windows_certs >/dev/null
      vm_restart windows
      ;;
    logs)    vm_logs work-windows ;;
    rdp)
      load_env
      require_env USERNAME VM_PASSWORD
      local rdp_bin
      rdp_bin=$(rdp_client) || die "No FreeRDP client found. Install the freerdp package (it provides xfreerdp3). ./work.sh windows web needs no client."
      prepare_windows_certs >/dev/null

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
    certs)
      local cert_count
      cert_count=$(prepare_windows_certs)
      info "Prepared ${cert_count} certificate(s) for Windows in \\\\172.30.0.1\\Data\\certificates"
      echo ""
      echo "Run this in an elevated PowerShell inside Windows:"
      echo "  PowerShell -ExecutionPolicy Bypass -File \\\\172.30.0.1\\Data\\certificates\\import-certs.ps1"
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
      echo "  ./work.sh windows certs    Prepare internal certs for Windows"
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
      ;;
    stop)
      vm_stop linux
      ;;
    restart)
      vm_restart linux
      configure_linux_dns
      ;;
    logs)
      vm_logs work-linux
      ;;
    shell|ssh)
      if ! container_running work-linux; then
        info "Linux container is not running, starting it..."
        vm_start linux
        configure_linux_dns
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
      $COMPOSE build linux
      $COMPOSE up -d --force-recreate linux
      configure_linux_dns
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
  echo "  ./work.sh setup              Create .env interactively (first run)"
  echo "  ./work.sh doctor             Check prerequisites (Docker, KVM, tun, tools)"
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
  echo "  ./work.sh windows <cmd>      Manage Windows VM (start|stop|restart|rdp|web|logs)"
  echo "  ./work.sh linux <cmd>        Manage Linux container (start|stop|restart|shell|rebuild|logs)"
  echo ""
  echo -e "${BOLD}Examples:${NC}"
  echo "  ./work.sh connect            Connect VPN, type 2FA, done"
  echo "  ./work.sh windows restart    Restart Windows VM"
  echo "  ./work.sh windows rdp        Open RDP session"
  echo "  ./work.sh linux shell        Open shell in Arch container"
  echo "  ./work.sh status             Quick overview of everything"
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

# Single-quote a value for safe inclusion in .env, which load_env later sources.
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

  echo ""
  # Repo integrity. The Linux image build copies this snapshot, so a clone
  # missing it fails the build. Catch it here, not halfway through a build.
  check req "Linux image rootfs" "[ -d '$SCRIPT_DIR/linux-image/rootfs' ]" "linux-image/rootfs/ is missing. It must be committed to the repo; ask whoever shared it." || fails=$((fails + 1))
  check opt ".env"               "[ -f '$SCRIPT_DIR/.env' ]"           "Not configured yet. Run ./work.sh setup." || true

  echo ""
  if [ "$fails" -gt 0 ]; then
    warn "$fails required check(s) failed. Fix the above, then re-run ./work.sh doctor."
    return 1
  fi
  success "All required checks passed."
}

cmd_setup() {
  local env_file="$SCRIPT_DIR/.env"
  local example="$SCRIPT_DIR/.env.example"

  [ -f "$example" ] || die ".env.example not found. Run this from the repo root."

  echo -e "${BOLD}Work environment setup${NC}"
  echo ""
  echo -e "${DIM}Fields marked [IT] come from your IT admin or Check Point client logs.${NC}"
  echo -e "${DIM}Press Enter to accept a default shown in [brackets].${NC}"
  echo ""

  if [ -f "$env_file" ]; then
    warn ".env already exists."
    read -p "Overwrite it (a backup goes to .env.bak)? [y/N] " ans
    case "$ans" in
      y | Y) cp "$env_file" "$env_file.bak" ;;
      *)
        info "Keeping existing .env. Nothing changed."
        return 0
        ;;
    esac
  fi

  local username vm_password vpn_server vpn_password corporate_dns extra_routes test_host

  read -p "Local guest username (USERNAME) [your.username]: " username
  username="${username:-your.username}"

  read -rsp "Password for the Windows and Linux guests (VM_PASSWORD), Enter to auto-generate: " vm_password
  echo ""
  if [ -z "$vm_password" ]; then
    vm_password=$(gen_password)
    info "Generated a random VM_PASSWORD. It is stored in .env; read it there if you log in to Windows directly."
  fi

  read -p "VPN gateway IP (VPN_SERVER) [IT]: " vpn_server
  read -rsp "VPN password (VPN_PASSWORD), rotates ~45d, Enter to fill later: " vpn_password
  echo ""
  read -p "Corporate DNS (CORPORATE_DNS) [IT]: " corporate_dns
  read -p "Extra ranges through the tunnel (VPN_EXTRA_ROUTES), comma-separated, e.g. corporate GitHub ranges [optional]: " extra_routes
  read -p "Internal host for ./work.sh test (VPN_TEST_HOST) [optional]: " test_host

  # Single-quote every value so load_env can source the file even when a
  # password holds a space, $, #, quote or backslash. chmod is explicit
  # because umask only applies to a newly created file; overwriting an
  # existing .env in place would otherwise keep its old, looser mode.
  umask 077
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
EOF
  chmod 600 "$env_file"

  success ".env written."
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

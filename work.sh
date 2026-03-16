#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COMPOSE="docker compose -f $SCRIPT_DIR/docker-compose.yml"
CORPORATE_DNS="10.17.193.169"

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

load_env() {
  [ -f "$SCRIPT_DIR/.env" ] || die ".env file not found. Copy .env.example to .env and fill in your credentials."
  set -a
  source "$SCRIPT_DIR/.env"
  set +a
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
  docker exec work-vpn sh -c "\
    # --- Corporate traffic via VPN tunnel ---
    iptables -t nat -C POSTROUTING -o snx-tun -j MASQUERADE 2>/dev/null || \
    iptables -t nat -A POSTROUTING -o snx-tun -j MASQUERADE; \
    iptables -C FORWARD -i docker -o snx-tun -j ACCEPT 2>/dev/null || \
    iptables -A FORWARD -i docker -o snx-tun -j ACCEPT; \
    iptables -C FORWARD -i snx-tun -o docker -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
    iptables -A FORWARD -i snx-tun -o docker -m state --state RELATED,ESTABLISHED -j ACCEPT; \
    # --- Internet traffic via eth0 (home connection) ---
    iptables -t nat -C POSTROUTING -o eth0 -j MASQUERADE 2>/dev/null || \
    iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE; \
    iptables -C FORWARD -i docker -o eth0 -j ACCEPT 2>/dev/null || \
    iptables -A FORWARD -i docker -o eth0 -j ACCEPT; \
    iptables -C FORWARD -i eth0 -o docker -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
    iptables -A FORWARD -i eth0 -o docker -m state --state RELATED,ESTABLISHED -j ACCEPT; \
    # --- DNS to corporate DNS ---
    iptables -t nat -C PREROUTING -i docker -p udp --dport 53 -j DNAT --to-destination ${CORPORATE_DNS}:53 2>/dev/null || \
    iptables -t nat -A PREROUTING -i docker -p udp --dport 53 -j DNAT --to-destination ${CORPORATE_DNS}:53; \
    iptables -t nat -C PREROUTING -i docker -p tcp --dport 53 -j DNAT --to-destination ${CORPORATE_DNS}:53 2>/dev/null || \
    iptables -t nat -A PREROUTING -i docker -p tcp --dport 53 -j DNAT --to-destination ${CORPORATE_DNS}:53; \
    # --- GitHub routes via VPN tunnel ---
    ip route replace 192.30.252.0/22 dev snx-tun; \
    ip route replace 185.199.108.0/22 dev snx-tun; \
    ip route replace 140.82.112.0/20 dev snx-tun; \
    ip route replace 143.55.64.0/20 dev snx-tun" 2>/dev/null
}

configure_linux_dns() {
  container_running work-linux || return 0

  if vpn_connected; then
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

# --- Commands ---

cmd_connect() {
  local log_level=info
  [[ "$1" == "--debug" || "$1" == "-debug" ]] && log_level=debug

  load_env

  # Check if already connected
  if vpn_connected; then
    warn "VPN is already connected."
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

  [ -n "$VPN_SERVER" ] || die "VPN_SERVER not set in .env"

  info "Connecting VPN as $USERNAME to $VPN_SERVER..."

  # Run snx-rs detached inside the container, logging to /var/log/snx-rs.log
  docker exec -d work-vpn \
    sh -c "snx-rs -m standalone \
      -c /etc/snx-rs/snx-rs.conf \
      -s '$VPN_SERVER' \
      -u '$USERNAME' \
      -p '$FULL_PASSWORD_B64' \
      -l '$log_level' \
      >> /var/log/snx-rs.log 2>&1"

  # Wait for tunnel to come up
  local timeout=30
  for i in $(seq 1 $timeout); do
    if vpn_connected; then
      setup_nat
      configure_linux_dns
      echo ""
      success "VPN connected."
      cmd_status
      return
    fi
    sleep 1
  done

  # If we get here, tunnel didn't come up — show logs for diagnosis
  warn "VPN tunnel did not come up within ${timeout}s."
  echo ""
  echo -e "${DIM}--- snx-rs log ---${NC}"
  docker exec work-vpn cat /var/log/snx-rs.log 2>/dev/null || echo "(no log output)"
  echo -e "${DIM}--- end ---${NC}"
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
    return
  fi

  info "Disconnecting VPN..."
  docker exec work-vpn killall snx-rs 2>/dev/null || true
  sleep 1
  if vpn_connected; then
    warn "Tunnel still up, forcing..."
    docker exec work-vpn killall -9 snx-rs 2>/dev/null || true
  fi
  configure_linux_dns
  success "VPN disconnected."
}

cmd_reconnect() {
  cmd_disconnect
  sleep 1
  cmd_connect "$@"
}

cmd_status() {
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
    echo -e "           SSH: 127.0.0.1:2222"
  else
    echo -e "  Linux:   ${RED}stopped${NC}"
  fi

  echo ""
}

cmd_up() {
  load_env
  info "Starting all containers..."
  $COMPOSE up -d
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

  # Ensure VPN container is up first (VMs depend on it for networking)
  if ! container_running work-vpn; then
    info "Starting VPN container..."
    $COMPOSE up -d vpn
    sleep 2
  fi

  info "Starting $vm..."
  $COMPOSE up -d "$vm"
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
    start)   vm_start windows ;;
    stop)    vm_stop windows ;;
    restart) vm_restart windows ;;
    logs)    vm_logs work-windows ;;
    rdp)
      load_env

      # Detect Hyprland display scale
      local rdp_scale=""
      if command -v hyprctl &>/dev/null; then
        local hypr_scale
        hypr_scale=$(hyprctl monitors -j 2>/dev/null | jq -r '.[] | select(.focused == true) | .scale' 2>/dev/null)
        if [ -n "$hypr_scale" ]; then
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
      xfreerdp3 \
        /v:127.0.0.1:3390 \
        /u:"$USERNAME" \
        /p:"$PASSWORD" \
        /cert:ignore \
        /dynamic-resolution \
        /gfx:AVC444 \
        /floatbar:sticky:off,default:visible,show:fullscreen \
        /sound \
        /microphone \
        /clipboard \
        /title:"Work Windows" \
        -grab-keyboard \
        $rdp_scale &
      disown
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
    ssh)
      if ! container_running work-linux; then
        info "Linux container is not running, starting it..."
        vm_start linux
        configure_linux_dns
      fi
      load_env
      info "Opening SSH to Linux container..."
      ssh \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -p 2222 \
        "$USERNAME@127.0.0.1"
      ;;
    *)
      echo -e "${BOLD}Linux commands:${NC}"
      echo ""
      echo "  ./work.sh linux start      Start the Linux container"
      echo "  ./work.sh linux stop       Stop the Linux container"
      echo "  ./work.sh linux restart    Stop + start"
      echo "  ./work.sh linux ssh        Open SSH session"
      echo "  ./work.sh linux logs       Tail container logs"
      ;;
  esac
}

# --- Help ---

cmd_help() {
  echo -e "${BOLD}work.sh${NC} — Corporate remote environment manager"
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
  echo "  ./work.sh logs [vpn|windows|linux]  Tail container logs"
  echo ""
  echo -e "${BOLD}VMs:${NC}"
  echo "  ./work.sh windows <cmd>      Manage Windows VM (start|stop|restart|rdp|web|logs)"
  echo "  ./work.sh linux <cmd>        Manage Linux container (start|stop|restart|ssh|logs)"
  echo ""
  echo -e "${BOLD}Examples:${NC}"
  echo "  ./work.sh connect            Connect VPN, type 2FA, done"
  echo "  ./work.sh windows restart    Restart Windows VM"
  echo "  ./work.sh windows rdp        Open RDP session"
  echo "  ./work.sh linux ssh          Open SSH session to Arch"
  echo "  ./work.sh status             Quick overview of everything"
}

# --- Main dispatcher ---

case "${1:-help}" in
  connect)    shift; cmd_connect "$@" ;;
  disconnect) cmd_disconnect ;;
  reconnect)  shift; cmd_reconnect "$@" ;;
  status)     cmd_status ;;
  up)         cmd_up ;;
  down)       cmd_down ;;
  logs)       shift; cmd_logs "$@" ;;
  windows)    shift; cmd_windows "$@" ;;
  linux)      shift; cmd_linux "$@" ;;
  help|--help|-h) cmd_help ;;
  *)          die "Unknown command: $1. Run './work.sh help' for usage." ;;
esac

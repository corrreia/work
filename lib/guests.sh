# shellcheck shell=bash
# Containers as a whole (up, down, status, logs) and the Linux container.

vm_start() {
  local vm="$1"
  load_env
  require_env USERNAME VM_PASSWORD

  # The guests share work-vpn's network namespace, so it starts first.
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

  # shellcheck disable=SC2016 # expanded by the container's sh
  printf '%s\n' "$names" | tar -C "$GUEST_SSH_DIR" -cf - -T - |
    docker exec -i -u "$USERNAME" work-linux sh -c '
      mkdir -p ~/.ssh && chmod 700 ~/.ssh &&
      tar -C ~/.ssh --no-same-owner -xf - &&
      find ~/.ssh -maxdepth 1 -type f ! -name "*.pub" -exec chmod 600 {} +' ||
    { warn "Could not copy SSH keys into the Linux container."; return 1; }
  echo -e "  ${DIM}linux ssh: ${names//$'\n'/ }${NC}"
}

# DNS and SSH keys after the Linux container (re)starts.
linux_after_start() {
  configure_linux_dns
  linux_sync_ssh || true
}

cmd_up() {
  load_env
  require_env USERNAME VM_PASSWORD
  info "Starting all containers..."
  compose up -d --build
  linux_after_start
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
    vpn) docker exec work-vpn tail -f /var/log/snx-rs.log 2>/dev/null || warn "No VPN logs yet. Connect first with: ./work.sh connect" ;;
    windows) docker logs -f work-windows ;;
    linux) docker logs -f work-linux ;;
    *) die "Unknown service: $service. Use 'vpn', 'windows', or 'linux'." ;;
  esac
}

cmd_status() {
  # The tunnel can drop on its own; keep the Linux resolver in step with it.
  configure_linux_dns

  echo -e "${BOLD}Work Environment Status${NC}"
  echo ""

  if container_running work-vpn; then
    if vpn_connected; then
      local vpn_ip vpn_dns
      vpn_ip=$(docker exec work-vpn ip -4 addr show snx-tun 2>/dev/null | grep -oP 'inet \K[0-9./]+') || vpn_ip="unknown"
      vpn_dns=$(docker exec work-vpn cat /etc/resolv.conf 2>/dev/null | grep -oP 'nameserver \K[0-9.]+' | head -1) || vpn_dns=""
      echo -e "  VPN:     ${GREEN}connected${NC}"
      echo -e "           IP: $vpn_ip"
      if [ -n "$vpn_dns" ]; then echo -e "           DNS: $vpn_dns"; fi
    else
      echo -e "  VPN:     ${YELLOW}container running, tunnel down${NC}"
    fi
  else
    echo -e "  VPN:     ${RED}stopped${NC}"
  fi

  if container_running work-windows; then
    echo -e "  Windows: ${GREEN}running${NC}"
    echo -e "           Web: http://127.0.0.1:8007"
    echo -e "           RDP: 127.0.0.1:3390"
  else
    echo -e "  Windows: ${RED}stopped${NC}"
  fi

  if container_running work-linux; then
    echo -e "  Linux:   ${GREEN}running${NC}"
    echo -e "           Shell: ./work.sh linux shell"
  else
    echo -e "  Linux:   ${RED}stopped${NC}"
  fi

  echo ""
}

cmd_linux() {
  local action="${1:-help}"
  case "$action" in
    start)
      vm_start linux
      linux_after_start
      ;;
    stop) vm_stop linux ;;
    restart)
      vm_restart linux
      linux_after_start
      ;;
    logs) docker logs -f work-linux ;;
    shell | ssh)
      if ! container_running work-linux; then
        info "Linux container is not running, starting it..."
        vm_start linux
        linux_after_start
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
      linux_after_start
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

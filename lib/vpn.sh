# shellcheck shell=bash
# VPN: tunnel lifecycle, split routing, guest DNS, and the reachability test.
# Everything that runs inside work-vpn lives in scripts/vpn/work-net.sh.

VPN_RUNTIME_CONF="/run/snx-rs-connect.conf"
VPN_HELPER="/usr/local/sbin/work-net"

# Corporate GitHub is IP-allowlisted to company egress, so GitHub routes through
# the tunnel by default: "github" in VPN_EXTRA_ROUTES expands at connect time to
# the live ranges from api.github.com/meta. This fixed list is only the fallback
# when that fetch fails; it misses GitHub's regional Azure addresses.
GITHUB_ROUTES="192.30.252.0/22,185.199.108.0/22,140.82.112.0/20,143.55.64.0/20"
GITHUB_META="https://api.github.com/meta"

# GitHub's current IPv4 ranges for web, api and git, comma-separated, from the
# meta JSON on stdin. Empty when the input is not the meta document.
github_ranges_from_meta() {
  jq -r '[.web[]?, .api[]?, .git[]?]
    | map(select(test("^[0-9]+(\\.[0-9]+){3}/[0-9]+$")))
    | unique | join(",")' 2>/dev/null || true
}

# GitHub's live ranges, or the built-in list when they cannot be fetched.
# GitHub keeps adding regional addresses (github.com resolves to one in Azure
# from Europe), and any it misses leaves through the home address and hits the
# IP allow list.
github_routes() {
  local routes
  routes=$(curl -fsS --max-time 10 "$GITHUB_META" 2>/dev/null | github_ranges_from_meta) || routes=""
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
  local routes="${VPN_EXTRA_ROUTES:-}"
  for item in ${routes//,/ }; do
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

# Copy scripts/vpn/work-net.sh into work-vpn. Installed by rename, so the copy
# already running as the snx-rs supervisor keeps its old file instead of
# reading one that is being rewritten under it.
vpn_install_helper() {
  # shellcheck disable=SC2016 # expanded by the container's sh
  docker exec -i work-vpn sh -c '
    mkdir -p "$(dirname "$1")" && tmp="$1.$$" &&
    cat >"$tmp" && chmod 755 "$tmp" && mv -f "$tmp" "$1"' \
    sh "$VPN_HELPER" <"$SCRIPT_DIR/scripts/vpn/work-net.sh"
}

# Run work-net inside work-vpn: nat | dns-teardown | run | probe.
vpn_net() {
  vpn_install_helper || return 1
  docker exec work-vpn "$VPN_HELPER" "$@"
}

# Set up NAT, split routing and the DNS redirect inside work-vpn.
setup_nat() {
  local routes
  load_env
  require_env CORPORATE_DNS
  routes=$(extra_routes)
  vpn_net nat "$CORPORATE_DNS" "$VM_SUBNET" "$routes"
}

teardown_nat() {
  load_env
  require_env CORPORATE_DNS
  vpn_net dns-teardown "$CORPORATE_DNS"
}

# Point the Linux container at corporate DNS while the tunnel is up, at
# Docker's resolver otherwise.
configure_linux_dns() {
  local nameserver="127.0.0.11"
  container_running work-linux || return 0

  if vpn_connected; then
    load_env
    require_env CORPORATE_DNS
    nameserver="$CORPORATE_DNS"
  fi
  printf 'nameserver %s\nsearch .\noptions edns0 trust-ad ndots:0\n' "$nameserver" |
    docker exec -i work-linux sh -c 'cat > /etc/resolv.conf'
}

cmd_connect() {
  local log_level=info otp
  [[ "${1:-}" == "--debug" || "${1:-}" == "-debug" ]] && log_level=debug

  load_env
  require_env USERNAME VPN_SERVER VPN_PASSWORD CORPORATE_DNS

  if vpn_connected; then
    warn "VPN is already connected."
    setup_nat || warn "Could not apply NAT/routing inside work-vpn; guests may not reach the VPN."
    cmd_status
    return
  fi

  read -rp "2FA code: " otp
  echo ""

  if ! container_running work-vpn; then
    info "Starting VPN container..."
    compose up -d vpn
    sleep 2
  fi
  container_running work-vpn || die "work-vpn failed to start"
  vpn_install_helper || die "Could not install the network helper into work-vpn."

  info "Connecting VPN as $USERNAME to $VPN_SERVER..."

  # Hand the credentials over in a root-only file instead of argv, which stays
  # readable in the host process list for the life of the tunnel.
  {
    cat "$SCRIPT_DIR/snx-rs.conf"
    printf '\nserver-name = %s\nuser-name = %s\npassword = %s\n' \
      "$VPN_SERVER" "$USERNAME" "$(printf '%s' "${VPN_PASSWORD}${otp}" | base64 -w0)"
  } | docker exec -i work-vpn sh -c "umask 077 && cat > $VPN_RUNTIME_CONF"

  # snx-rs runs detached under work-net, logging to /var/log/snx-rs.log.
  # Whenever it exits, for any reason, the guest DNS redirect goes with it.
  docker exec -d work-vpn "$VPN_HELPER" run "$VPN_RUNTIME_CONF" "$log_level" "$CORPORATE_DNS"

  local timeout=30 waited=0
  while [ "$waited" -lt "$timeout" ]; do
    sleep 1
    waited=$((waited + 1))
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

  # The tunnel did not come up; show the log for diagnosis.
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

# Resolve + connect to an internal-only host along both guest paths. The VPN
# hands out a single address: Linux shares work-vpn's network namespace and
# uses it directly, Windows is masqueraded behind it.
cmd_test() {
  local host failed=0 out addr resolver

  load_env
  host="${1:-${VPN_TEST_HOST:-}}"
  [ -n "$host" ] || die "No host to test. Pass one (./work.sh test <host>) or set VPN_TEST_HOST in $(tilde "$WORK_ENV")."

  container_running work-vpn || die "work-vpn is not running. Run: ./work.sh up"
  vpn_connected || die "VPN tunnel is down. Run: ./work.sh connect"

  echo -e "${BOLD}VPN test: $host${NC}"
  echo ""

  # Linux path: locally originated traffic, resolver pointed at corporate DNS
  if container_running work-linux; then
    addr=$(docker exec work-linux getent ahostsv4 "$host" 2>/dev/null | awk 'NR==1{print $1}') || addr=""
    if [ -z "$addr" ]; then
      resolver=$(docker exec work-linux awk '/^nameserver/{print $2; exit}' /etc/resolv.conf) || resolver="?"
      echo -e "  Linux:   ${RED}DNS failed${NC} (resolver: $resolver)"
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

  # Windows path: work-net probes from a namespace on the VM bridge.
  if container_running work-windows; then
    if out=$(vpn_net probe "$host" 2>&1); then
      echo -e "  Windows: ${GREEN}ok${NC} ($out)"
    else
      echo -e "  Windows: ${RED}${out}${NC}"
      failed=1
    fi
  else
    echo -e "  Windows: ${DIM}not running, skipped${NC}"
  fi

  echo ""
  return $failed
}

#!/bin/sh
# Runs inside the work-vpn container, never on the host. work.sh installs it
# as /usr/local/sbin/work-net before each use (see vpn_install_helper), so the
# container always runs the copy from this checkout.
#
#   work-net nat <corporate-dns> <vm-subnet> <extra-routes>
#   work-net dns-teardown <corporate-dns>
#   work-net run <config> <log-level> <corporate-dns>
#   work-net probe <host>
set -eu

# Without the tunnel the corporate resolver is unreachable, so a leftover
# redirect would kill Windows DNS.
dns_teardown() {
  corporate_dns="$1"
  for proto in udp tcp; do
    while iptables -t nat -D PREROUTING -i docker -p "$proto" --dport 53 \
      -j DNAT --to-destination "${corporate_dns}:53" 2>/dev/null; do :; done
  done
}

# Append a rule to <table> unless it is already there.
ipt_ensure() {
  table="$1"
  shift
  iptables -t "$table" -C "$@" 2>/dev/null || iptables -t "$table" -A "$@"
}

# Same, but insert at the top of the chain so it wins over later ACCEPTs.
ipt_ensure_first() {
  table="$1"
  shift
  iptables -t "$table" -C "$@" 2>/dev/null || iptables -t "$table" -I "$@"
}

# NAT, split routing and DNS redirect for both guests. Idempotent.
nat() {
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
  ipt_ensure nat POSTROUTING -o snx-tun -j MASQUERADE
  ipt_ensure filter FORWARD -i docker -o snx-tun -j ACCEPT
  ipt_ensure filter FORWARD -i snx-tun -o docker -m state --state RELATED,ESTABLISHED -j ACCEPT

  # dockur forwards every port addressed to this namespace to the VM, the
  # tunnel address included. Keep the corporate side from reaching the VM's sshd.
  ipt_ensure_first filter FORWARD -i snx-tun -o docker -p tcp --dport 22 -m state --state NEW -j DROP

  # snx-rs consults its own table ahead of main, and its 172.16.0.0/12 route
  # covers both the Docker network and the VM bridge. Send those back to main
  # by rule, so it holds whether or not the VM bridge exists yet.
  while ip rule del pref "$local_pref" 2>/dev/null; do :; done
  for subnet in $(ip -4 route show dev eth0 proto kernel scope link | awk '{print $1}') "$vm_subnet"; do
    ip rule add to "$subnet" lookup main pref "$local_pref"
  done
  ip route replace 10.0.0.0/8 dev snx-tun table "$vpn_table"
  ip route replace 172.16.0.0/12 dev snx-tun table "$vpn_table"
  ip route replace 192.168.0.0/16 dev snx-tun table "$vpn_table"

  # --- Internet traffic via eth0 (home connection) ---
  ipt_ensure nat POSTROUTING -o eth0 -j MASQUERADE
  ipt_ensure filter FORWARD -i docker -o eth0 -j ACCEPT
  ipt_ensure filter FORWARD -i eth0 -o docker -m state --state RELATED,ESTABLISHED -j ACCEPT

  # --- DNS to corporate DNS ---
  for proto in udp tcp; do
    ipt_ensure nat PREROUTING -i docker -p "$proto" --dport 53 \
      -j DNAT --to-destination "${corporate_dns}:53"
  done

  # --- Extra public ranges that must go through the tunnel ---
  for route in $(echo "$extra_routes" | tr ',' ' '); do
    ip route replace "$route" dev snx-tun
  done
  ip route flush cache 2>/dev/null || true
}

# Run snx-rs in the foreground until it exits, for any reason, then remove
# its config (it holds the password) and the guest DNS redirect with it.
run() {
  config="$1"
  log_level="$2"
  corporate_dns="$3"
  snx-rs -m standalone -c "$config" -l "$log_level" >>/var/log/snx-rs.log 2>&1 || true
  rm -f "$config"
  dns_teardown "$corporate_dns"
}

# Resolve and connect to an internal host the way the Windows VM does: from a
# throwaway namespace plugged into the VM bridge, so the probe is forwarded,
# DNS-redirected and NATed exactly like the VM's traffic.
probe() {
  host="$1"
  ns="work-probe"
  cleanup() {
    ip netns del "$ns" 2>/dev/null || true
    ip link del probe0 2>/dev/null || true
    rm -rf "/etc/netns/$ns"
  }
  trap cleanup EXIT
  cleanup

  gw=$(ip -4 -o addr show dev docker 2>/dev/null | awk 'NR==1{print $4}')
  [ -n "$gw" ] || { echo "VM bridge not up yet"; exit 1; }
  probe_ip="${gw%.*}.250/${gw#*/}"

  ip netns add "$ns"
  ip link add probe0 type veth peer name probe1 netns "$ns"
  ip link set probe0 master docker up
  ip -n "$ns" link set lo up
  ip -n "$ns" addr add "$probe_ip" dev probe1
  ip -n "$ns" link set probe1 up
  ip -n "$ns" route add default via "${gw%/*}"
  mkdir -p "/etc/netns/$ns"
  echo "nameserver ${gw%/*}" >"/etc/netns/$ns/resolv.conf"

  addr=$(ip netns exec "$ns" timeout 12 getent ahostsv4 "$host" | awk 'NR==1{print $1}') || true
  [ -n "$addr" ] || { echo "DNS failed"; exit 1; }
  ip netns exec "$ns" timeout 8 bash -c "exec 3<>/dev/tcp/$addr/443" 2>/dev/null ||
    { echo "resolved $addr but tcp/443 failed"; exit 1; }
  echo "$host -> $addr, tcp/443 open"
}

usage() {
  echo "usage: work-net nat|dns-teardown|run|probe ..." >&2
  exit 2
}

[ $# -ge 1 ] || usage
cmd="$1"
shift
case "$cmd" in
  nat)          [ $# -eq 3 ] || usage; nat "$@" ;;
  dns-teardown) [ $# -eq 1 ] || usage; dns_teardown "$@" ;;
  run)          [ $# -eq 3 ] || usage; run "$@" ;;
  probe)        [ $# -eq 1 ] || usage; probe "$@" ;;
  *)            usage ;;
esac

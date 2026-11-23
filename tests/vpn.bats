#!/usr/bin/env bats
# Route handling in lib/vpn.sh. Nothing here talks to Docker or the network.

load helpers

META='{
  "hooks": ["192.30.252.0/22"],
  "web": ["140.82.112.0/20", "2a0a:a440::/29", "20.201.28.151/32"],
  "api": ["140.82.112.0/20", "20.205.243.168/32"],
  "git": ["192.30.252.0/22", "2606:50c0::/32"],
  "packages": ["1.1.1.1/32"]
}'

@test "github_ranges_from_meta keeps IPv4 web/api/git/packages, unique and sorted" {
  result=$(printf '%s' "$META" | github_ranges_from_meta)
  [ "$result" = "1.1.1.1/32,140.82.112.0/20,192.30.252.0/22,20.201.28.151/32,20.205.243.168/32" ]
}

@test "github_ranges_from_meta is empty for junk" {
  [ -z "$(printf 'not json' | github_ranges_from_meta)" ]
  [ -z "$(printf '{"message":"rate limited"}' | github_ranges_from_meta)" ]
}

@test "github_routes falls back to the built-in list when the fetch fails" {
  curl() { return 22; }
  github_host_routes() { :; }
  run github_routes
  [ "$status" -eq 0 ]
  [[ "$output" == *"using the built-in list"* ]]
  [[ "$output" == *"$GITHUB_ROUTES" ]]
}

@test "github_routes uses the live ranges when the fetch works" {
  curl() { printf '%s' "$META"; }
  github_host_routes() { :; }
  [ "$(github_routes 2>/dev/null)" = "1.1.1.1/32,140.82.112.0/20,192.30.252.0/22,20.201.28.151/32,20.205.243.168/32" ]
}

@test "github_routes appends the resolved host addresses, also on fallback" {
  github_host_routes() { printf '20.250.119.71/32'; }
  curl() { printf '%s' "$META"; }
  [[ "$(github_routes 2>/dev/null)" == *",20.205.243.168/32,20.250.119.71/32" ]]
  curl() { return 22; }
  [ "$(github_routes 2>/dev/null)" = "$GITHUB_ROUTES,20.250.119.71/32" ]
}

@test "resolve_in_vpn keeps IPv4 addresses as unique /32s" {
  docker() {
    printf '%s\n' '20.250.119.71   STREAM codeload.github.com' \
      '20.250.119.71   DGRAM' '20.250.119.71   RAW' '185.199.108.133 STREAM' 'junk'
  }
  [ "$(resolve_in_vpn codeload.github.com | paste -sd,)" = "185.199.108.133/32,20.250.119.71/32" ]
}

@test "github_host_routes joins every host and skips the ones that do not resolve" {
  GITHUB_HOSTS="a.example b.example
c.example"
  resolve_in_vpn() {
    case "$1" in
      a.example) printf '1.1.1.1/32\n1.1.1.2/32\n' ;;
      c.example) printf '3.3.3.3/32\n' ;;
    esac
  }
  run github_host_routes
  [[ "$output" == *"Could not resolve b.example"* ]]
  [ "$(github_host_routes 2>/dev/null)" = "1.1.1.1/32,1.1.1.2/32,3.3.3.3/32" ]
}

@test "github_host_routes is empty, not fatal, when docker fails, under strict mode" {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/bin/sh\nexit 1\n' >"$BATS_TEST_TMPDIR/bin/docker"
  chmod +x "$BATS_TEST_TMPDIR/bin/docker"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" run strict github_host_routes
  [ "$status" -eq 0 ]
  [[ "$output" == *"Could not resolve codeload.github.com"* ]]
  [[ "$output" != *"/32"* ]]
}

@test "extra_routes expands github and keeps plain ranges" {
  github_routes() { printf '1.0.0.0/8,2.0.0.0/8'; }
  VPN_EXTRA_ROUTES="10.9.0.0/16, github,8.8.8.8"
  [ "$(extra_routes)" = "10.9.0.0/16,1.0.0.0/8,2.0.0.0/8,8.8.8.8" ]
}

@test "extra_routes skips anything that is not an IPv4 range" {
  VPN_EXTRA_ROUTES="10.0.0.0/8,evil;rm,example.com"
  run extra_routes
  [[ "$output" == *"'evil;rm' is neither"* ]]
  [[ "$output" == *"'example.com' is neither"* ]]
  [ "$(extra_routes 2>/dev/null)" = "10.0.0.0/8" ]
}

@test "extra_routes is empty when VPN_EXTRA_ROUTES is unset, under strict mode" {
  run strict extra_routes
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "work-net rejects unknown subcommands and wrong arity" {
  run sh "$REPO/scripts/vpn/work-net.sh"
  [ "$status" -eq 2 ]
  run sh "$REPO/scripts/vpn/work-net.sh" bogus
  [ "$status" -eq 2 ]
  run sh "$REPO/scripts/vpn/work-net.sh" nat only-one
  [ "$status" -eq 2 ]
}

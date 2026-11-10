#!/usr/bin/env bats
# Pure helpers in lib/common.sh and lib/setup.sh.

load helpers

@test "paths stay inside the isolated home" {
  [[ "$CERT_DIR" == "$TEST_HOME"/* ]]
  [[ "$GUEST_SSH_DIR" == "$TEST_HOME"/* ]]
  [[ "$WORK_STATE_DIR" == "$TEST_HOME"/* ]]
}

@test "tilde contracts the home directory only at the start" {
  [ "$(tilde "$HOME/.config/work")" = "~/.config/work" ]
  [ "$(tilde "/srv$HOME")" = "/srv$HOME" ]
}

@test "env_quote survives sourcing for awkward values" {
  local value
  for value in "plain" "with space" "it's" 'dollar $HOME' 'back\slash' 'hash # x' "'" '"' ""; do
    eval "got=$(env_quote "$value")"
    [ "$got" = "$value" ]
  done
}

@test "render_env round-trips through load_env" {
  mkdir -p "$WORK_CONFIG_DIR"
  render_env 'me' "v'm \$pw" '10.0.0.1' 'vpn"pw#x' '10.0.0.53' 'github,1.2.3.0/24' '' 'corp.example.com' '' >"$WORK_ENV"
  load_env
  [ "$USERNAME" = "me" ]
  [ "$VM_PASSWORD" = "v'm \$pw" ]
  [ "$VPN_PASSWORD" = 'vpn"pw#x' ]
  [ "$VPN_EXTRA_ROUTES" = "github,1.2.3.0/24" ]
  [ "$AD_DOMAIN" = "corp.example.com" ]
  [ -z "$SSO_SITES" ]
}

@test "gen_password gives 20 alphanumerics under strict mode" {
  run strict gen_password
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[A-Za-z0-9]{20}$ ]]
}

@test "require_env names every missing variable" {
  export USERNAME=me
  unset VM_PASSWORD VPN_SERVER
  run require_env USERNAME VM_PASSWORD VPN_SERVER
  [ "$status" -eq 1 ]
  [[ "$output" == *"VM_PASSWORD VPN_SERVER"* ]]
  [[ "$output" != *"USERNAME"* ]]
}

@test "load_env points to setup when there is no env file" {
  run load_env
  [ "$status" -eq 1 ]
  [[ "$output" == *"./work.sh setup"* ]]
}

@test "mkdir_private makes every new directory 0700" {
  mkdir_private "$TEST_HOME/a/b"
  [ "$(stat -c %a "$TEST_HOME/a/b")" = 700 ]
}

@test "guest_ssh_files lists safe names and skips the rest" {
  mkdir -p "$GUEST_SSH_DIR/subdir"
  touch "$GUEST_SSH_DIR/id_ed25519" "$GUEST_SSH_DIR/config" "$GUEST_SSH_DIR/bad name" "$GUEST_SSH_DIR/subdir/nested"
  run guest_ssh_files
  [ "$status" -eq 0 ]
  [[ "$output" == *"Skipping ssh/bad name"* ]]
  [ "$(guest_ssh_files 2>/dev/null)" = $'config\nid_ed25519' ]
}

@test "guest_ssh_files is empty without the folder" {
  [ -z "$(guest_ssh_files)" ]
}

@test "check reports ok and missing with the right status" {
  run check req "Thing" "hint" true
  [ "$status" -eq 0 ]
  [[ "$output" == *ok*Thing* ]]
  run check req "Thing" "install it" false
  [ "$status" -eq 1 ]
  [[ "$output" == *missing*Thing* ]]
  [[ "$output" == *"install it"* ]]
  run check opt "Thing" "hint" false
  [[ "$output" == *absent*Thing* ]]
}

@test "legacy_items finds old in-repo items only" {
  SCRIPT_DIR="$TEST_HOME/repo"
  mkdir -p "$SCRIPT_DIR/scripts/windows"
  run legacy_items
  [ "$status" -eq 1 ]
  touch "$SCRIPT_DIR/.env"
  mkdir "$SCRIPT_DIR/windows"
  run legacy_items
  [ "$status" -eq 0 ]
  [ "$output" = $'.env\nwindows' ]
}

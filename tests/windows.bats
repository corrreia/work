#!/usr/bin/env bats
# Input building for scripts/windows/*.ps1 in lib/windows.sh. Where pwsh is
# installed, the generated PowerShell is also run (with stand-in scripts) to
# prove the data arrives intact.

load helpers

# pwsh when it actually runs (a version-manager shim may exist without one).
pwsh_bin() {
  if pwsh -NoProfile -NonInteractive -Command 'exit 0' >/dev/null 2>&1; then
    command -v pwsh
  fi
}

@test "sso_sites defaults to every host under AD_DOMAIN" {
  AD_DOMAIN=corp.example.com
  [ "$(sso_sites)" = "*.corp.example.com" ]
}

@test "sso_sites strips spaces and keeps the list" {
  SSO_SITES="*.a.example.com, intranet ,b.example.com"
  [ "$(sso_sites)" = "*.a.example.com,intranet,b.example.com" ]
}

@test "sso_sites rejects anything that is not a host pattern" {
  for bad in "a.example.com;calc" "x'y" '$(id)' "a,,b"; do
    SSO_SITES="$bad"
    run sso_sites
    [ "$status" -eq 1 ]
  done
}

@test "sso_sites fails without AD_DOMAIN or SSO_SITES" {
  run strict sso_sites
  [ "$status" -eq 1 ]
}

@test "win_machine_json carries every certificate and the sites" {
  mkdir -p "$CERT_DIR"
  printf 'one' >"$CERT_DIR/a.crt"
  printf 'two' >"$CERT_DIR/b.pem"
  printf 'skip' >"$CERT_DIR/notes.txt"
  json=$(win_machine_json "*.corp.example.com")
  [ "$(jq -r .sites <<<"$json")" = "*.corp.example.com" ]
  [ "$(jq -r '.certs | map(@base64d) | join(",")' <<<"$json")" = "one,two" ]
}

@test "win_machine_json has an empty list without certificates" {
  [ "$(win_machine_json "" | jq -c .)" = '{"sites":"","certs":[]}' ]
}

@test "win_user_json omits the credential part without sites" {
  mkdir -p "$GUEST_SSH_DIR"
  printf 'KEY' >"$GUEST_SSH_DIR/id_test"
  json=$(win_user_json "" "" "" "")
  [ "$(jq -c .credential <<<"$json")" = null ]
  [ "$(jq -r '.sshFiles[0].name' <<<"$json")" = id_test ]
  [ "$(jq -r '.sshFiles[0].data | @base64d' <<<"$json")" = KEY ]
}

@test "win_user_json carries secrets verbatim" {
  json=$(win_user_json 'me@corp' "p'a\"ss \$x \\ y" '*.corp.example.com,intranet' "vm'pw")
  [ "$(jq -r .credential.password <<<"$json")" = "p'a\"ss \$x \\ y" ]
  [ "$(jq -r .credential.vmPassword <<<"$json")" = "vm'pw" ]
  [ "$(jq -c .credential.targets <<<"$json")" = '["*.corp.example.com","intranet"]' ]
  cmp <(jq -j .credential.script <<<"$json") "$REPO/scripts/windows/credential.ps1"
}

@test "ps_invocation wraps the script unchanged and the data as one base64 literal" {
  out=$(printf '{"a":1}' | ps_invocation machine.ps1)
  [ "$(head -n1 <<<"$out")" = "& {" ]
  diff <(sed '1d;$d' <<<"$out") "$REPO/scripts/windows/machine.ps1"
  b64=$(tail -n1 <<<"$out" | grep -oE "FromBase64String\('[A-Za-z0-9+/=]+'\)" | grep -oE "'.*'" | tr -d "'")
  [ "$(base64 -d <<<"$b64")" = '{"a":1}' ]
}

@test "ps_invocation hands hostile data to PowerShell as data" {
  pwsh=$(pwsh_bin)
  [ -n "$pwsh" ] || skip "pwsh not installed"
  SCRIPT_DIR="$TEST_HOME/repo"
  mkdir -p "$SCRIPT_DIR/scripts/windows"
  printf '%s\n' 'param([Parameter(Mandatory)] [psobject] $Work)' 'Write-Output "v=$($Work.v)"' \
    >"$SCRIPT_DIR/scripts/windows/echo.ps1"
  hostile="it's \"\$(whoami)\" }) ; exit 7"
  run "$pwsh" -NoProfile -NonInteractive -Command '& ([scriptblock]::Create([Console]::In.ReadToEnd()))' \
    < <(jq -n --arg v "$hostile" '{v: $v}' | ps_invocation echo.ps1)
  [ "$status" -eq 0 ]
  [ "$output" = "v=$hostile" ]
}

@test "the sync scripts exit non-zero on an error" {
  pwsh=$(pwsh_bin)
  [ -n "$pwsh" ] || skip "pwsh not installed"
  # LocalMachine stores are read-only on Linux, so adding a certificate fails.
  mkdir -p "$CERT_DIR"
  openssl req -x509 -newkey ed25519 -nodes -keyout /dev/null -subj "/CN=work.sh test" \
    -days 1 -out "$CERT_DIR/test.crt" 2>/dev/null || skip "openssl not available"
  run "$pwsh" -NoProfile -NonInteractive -Command '& ([scriptblock]::Create([Console]::In.ReadToEnd()))' \
    < <(win_machine_json "" | ps_invocation machine.ps1)
  [ "$status" -eq 1 ]
}

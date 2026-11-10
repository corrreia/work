#!/bin/bash
# Lint and test everything: shellcheck, the PowerShell parser and
# PSScriptAnalyzer (when pwsh is installed), and the bats suite.
# Usage: tests/run.sh [lint|test]   (default: both)
#
# Tools are used from PATH, else fetched on the fly when possible:
#   - ShellCheck: pacman -S shellcheck (or uvx --from shellcheck-py shellcheck)
#   - bats: pacman -S bash-bats (or npx bats)
#   - pwsh: optional, e.g. mise use -g powershell
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BOLD='\033[1m'
NC='\033[0m'

failed=0
step() { echo -e "\n${BOLD}== $*${NC}"; }
pass() { echo -e "${GREEN}ok${NC} $*"; }
fail() { echo -e "${RED}FAIL${NC} $*"; failed=1; }
skip() { echo -e "${YELLOW}skipped${NC} $*"; }

# run_check <label> <command...>: pass or fail by the command's status.
run_check() {
  local label="$1"
  shift
  if "$@"; then pass "$label"; else fail "$label"; fi
}

# Command line for a tool: on PATH, or through a runner that can fetch it.
tool() {
  local name="$1" fallback_runner="$2"
  shift 2
  if command -v "$name" >/dev/null; then
    echo "$name"
  elif command -v "$fallback_runner" >/dev/null; then
    echo "$fallback_runner $*"
  fi
}

lint() {
  local sc=()
  step "shellcheck"
  read -ra sc <<<"$(tool shellcheck uvx --from shellcheck-py shellcheck)"
  if [ ${#sc[@]} -eq 0 ]; then
    fail "shellcheck not found (pacman -S shellcheck)"
  else
    # work.sh with -x checks it against the libraries' definitions. Each
    # library on its own cannot see the others' variables, so the cross-file
    # "unused / unassigned" codes are left to the work.sh pass.
    run_check "scripts" "${sc[@]}" -x work.sh tests/run.sh scripts/vpn/work-net.sh linux-image/*.sh
    run_check "lib/" "${sc[@]}" -x -e SC2034,SC2153,SC2154 lib/*.sh
    run_check "tests/helpers.bash" "${sc[@]}" -x -s bash -e SC2034,SC2154 tests/helpers.bash
  fi

  step "PowerShell"
  # Run it once: a version-manager shim can exist without a usable pwsh.
  if ! pwsh -NoProfile -NonInteractive -Command 'exit 0' >/dev/null 2>&1; then
    skip "pwsh not available; scripts/windows/*.ps1 not checked"
    return
  fi
  # shellcheck disable=SC2016 # PowerShell, not bash
  run_check "scripts/windows" pwsh -NoProfile -NonInteractive -Command '
    $failed = 0
    foreach ($f in Get-ChildItem scripts/windows/*.ps1) {
      $tokens = $null; $errors = $null
      [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errors)
      foreach ($e in $errors) { "$($f.Name):$($e.Extent.StartLineNumber): $($e.Message)"; $failed = 1 }
    }
    if (Get-Module -ListAvailable PSScriptAnalyzer) {
      $issues = Invoke-ScriptAnalyzer -Path scripts/windows -Severity Warning, Error
      foreach ($i in $issues) { "$($i.ScriptName):$($i.Line): $($i.RuleName): $($i.Message)"; $failed = 1 }
    } else {
      "PSScriptAnalyzer not installed (Install-Module PSScriptAnalyzer); parse check only"
    }
    exit $failed'
}

tests() {
  local bats=()
  step "bats"
  read -ra bats <<<"$(tool bats npx --yes bats)"
  if [ ${#bats[@]} -eq 0 ]; then
    fail "bats not found (pacman -S bash-bats)"
    return
  fi
  run_check "tests/" "${bats[@]}" tests/
}

case "${1:-all}" in
  lint) lint ;;
  test) tests ;;
  all) lint; tests ;;
  *) echo "usage: tests/run.sh [lint|test]" >&2; exit 2 ;;
esac

echo ""
if [ "$failed" -ne 0 ]; then
  echo -e "${RED}${BOLD}Some checks failed.${NC}"
  exit 1
fi
echo -e "${GREEN}${BOLD}All checks passed.${NC}"

#!/bin/bash

set -euo pipefail

source "$(dirname "$0")/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT
stub_bin="$test_tmp/bin"
mkdir -p "$stub_bin"

cat >"$stub_bin/omarchy-cmd-present" <<'STUB'
#!/bin/bash
exit 0
STUB
cat >"$stub_bin/checkupdates" <<'STUB'
#!/bin/bash
printf '%s\n' 'linux 6.17.1-1 -> 6.17.2-1' 'omarchy 4.0.1-1 -> 4.0.2-1'
STUB
cat >"$stub_bin/pacman" <<'STUB'
#!/bin/bash
if [[ $1 == "-Qem" ]]; then
  exit 0
elif [[ $1 == "-Si" ]]; then
  if [[ $3 == "omarchy" ]]; then
    printf 'Repository : omarchy\n'
  else
    printf 'Repository : core\n'
  fi
fi
STUB
cat >"$stub_bin/omarchy-pkg-aur-accessible" <<'STUB'
#!/bin/bash
exit 0
STUB
cat >"$stub_bin/yay" <<'STUB'
#!/bin/bash
printf '%s\n' 'remote-desktop-manager 2026.2.2.2-2 -> 2026.3.0.1-1'
STUB
cat >"$stub_bin/mise" <<'STUB'
#!/bin/bash
if [[ $1 == "outdated" ]]; then
  printf '%s\n' '{"opencode":{"current":"1.18.23","latest":"1.19.0"}}'
elif [[ $1 == "ls" ]]; then
  printf '%s\n' '{"opencode":[{"version":"1.18.23","requested_version":"1.18.23"}],"deno":[{"version":"2.0.0","requested_version":"2.0.0"}]}'
elif [[ $1 == "latest" ]]; then
  printf '%s\n' '9.9.9'
fi
STUB
chmod +x "$stub_bin"/*

pins="$test_tmp/pins.json"
printf '%s\n' '{"remote-desktop-manager":{"version":"2026.2.2.2-2","manager":"aur"}}' >"$pins"

PATH="$stub_bin:$PATH" OMARCHY_UPDATE_PINS_FILE="$pins" \
  bash "$ROOT/bin/omarchy-update-plan" >"$test_tmp/plan.json"

jq -e '.categories[] | select(.id == "arch") | .packages[0].name == "linux"' "$test_tmp/plan.json" >/dev/null ||
  fail "the planner groups Arch repository updates"
jq -e '.categories[] | select(.id == "omarchy") | .packages[0].name == "omarchy"' "$test_tmp/plan.json" >/dev/null ||
  fail "the planner separates Omarchy repository updates"
jq -e '.categories[] | select(.id == "aur") | .packages[0].target == "2026.2.2.2-2"' "$test_tmp/plan.json" >/dev/null ||
  fail "the planner applies persistent exact-version targets"
jq -e '.categories[] | select(.id == "mise") | .packages[] | select(.name == "opencode") | .available == "1.19.0"' "$test_tmp/plan.json" >/dev/null ||
  fail "the planner includes mise updates"
jq -e '.categories[] | select(.id == "mise") | .packages[] | select(.name == "opencode") | .target == "1.18.23"' "$test_tmp/plan.json" >/dev/null ||
  fail "the planner does not surface a mise tool's requested version as its target"
jq -e '.categories[] | select(.id == "mise") | .packages[] | select(.name == "deno") | .target == "2.0.0"' "$test_tmp/plan.json" >/dev/null ||
  fail "a pinned mise tool that owes nothing to its range is missing from the plan"
jq -e '.categories[] | select(.id == "mise") | .packages[] | select(.name == "deno") | .available == "9.9.9"' "$test_tmp/plan.json" >/dev/null ||
  fail "a pinned mise tool does not show the version it is behind"
pass "the planner groups every update source and applies package targets"

cat >"$stub_bin/checkupdates" <<'STUB'
#!/bin/bash
echo "mirror unavailable" >&2
exit 1
STUB
chmod +x "$stub_bin/checkupdates"
if PATH="$stub_bin:$PATH" OMARCHY_UPDATE_PINS_FILE="$pins" bash "$ROOT/bin/omarchy-update-plan" >/dev/null 2>&1; then
  fail "a failed repository query becomes an unrestricted empty plan"
fi
pass "a failed repository query stops planning"

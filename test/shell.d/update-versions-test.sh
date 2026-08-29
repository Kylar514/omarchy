#!/bin/bash

set -euo pipefail

source "$(dirname "$0")/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT
stub_bin="$test_tmp/bin"
cache="$test_tmp/cache"
mkdir -p "$stub_bin" "$cache"
archive="$cache/remote-desktop-manager-2025.3.0.4-1-x86_64.pkg.tar.zst"
touch "$archive"

cat >"$stub_bin/pacman-conf" <<STUB
#!/bin/bash
printf '%s\n' '$cache'
STUB
cat >"$stub_bin/pacman" <<'STUB'
#!/bin/bash
if [[ $1 == "-Qp" ]]; then
  printf 'remote-desktop-manager\t2025.3.0.4-1\n'
fi
STUB
chmod +x "$stub_bin"/*

PATH="$stub_bin:$PATH" OMARCHY_UPDATE_NO_AUR_HISTORY=1 \
  XDG_CACHE_HOME="$test_tmp/no-yay-cache" \
  bash "$ROOT/bin/omarchy-update-versions" aur remote-desktop-manager \
    2026.2.2.2-2 2026.3.0.1-1 AUR >"$test_tmp/versions.json"

jq -e '.[] | select(.version == "latest" and .kind == "latest")' "$test_tmp/versions.json" >/dev/null ||
  fail "the version list has no way to resume latest updates"
jq -e '.[] | select(.version == "2026.2.2.2-2" and .kind == "installed")' "$test_tmp/versions.json" >/dev/null ||
  fail "the installed version is not selectable as an exact target"
jq -e --arg archive "$archive" '.[] | select(.version == "2025.3.0.4-1" and .kind == "cache" and .locator == $archive)' "$test_tmp/versions.json" >/dev/null ||
  fail "a cached historical package is not selectable"
pass "version discovery distinguishes latest, installed, and cached targets"

cp "$ROOT/test/shell.d/fixtures/update-plan.json" "$test_tmp/target-plan.json"
jq --arg archive "$archive" '
  (.categories[] | select(.id == "aur") | .packages[0]) |=
    (.target = "2025.3.0.4-1" | .candidate = {version:"2025.3.0.4-1", kind:"cache", locator:$archive})
' "$test_tmp/target-plan.json" >"$test_tmp/target-plan.tmp"
mv "$test_tmp/target-plan.tmp" "$test_tmp/target-plan.json"

cat >"$stub_bin/sudo" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >>"$TARGET_LOG"
STUB
chmod +x "$stub_bin/sudo"
TARGET_LOG="$test_tmp/target-call" PATH="$stub_bin:$PATH" \
  bash "$ROOT/bin/omarchy-update-targets" "$test_tmp/target-plan.json" aur

grep -qF "pacman -U --noconfirm $archive" "$test_tmp/target-call" ||
  fail "the selected cached historical package is not installed"
pass "a cached exact target is applied through pacman's dependency checks"

jq '
  (.categories[] | select(.id == "aur") | .packages[0]) |=
    (.target = "2025.3.0.4-1" | .candidate = {version:"2025.3.0.4-1", kind:"archive", locator:"https://archive.example/package.pkg.tar.zst"})
' "$ROOT/test/shell.d/fixtures/update-plan.json" >"$test_tmp/archive-plan.json"
cat >"$stub_bin/curl" <<'STUB'
#!/bin/bash
while (($#)); do
  if [[ $1 == "--output" ]]; then
    shift
    touch "$1"
    exit 0
  fi
  shift
done
exit 1
STUB
chmod +x "$stub_bin/curl"
: >"$test_tmp/target-call"
TARGET_LOG="$test_tmp/target-call" PATH="$stub_bin:$PATH" \
  bash "$ROOT/bin/omarchy-update-targets" "$test_tmp/archive-plan.json" aur
grep -qF 'pacman-key --verify' "$test_tmp/target-call" ||
  fail "an archived package is installed without verifying its detached signature"
grep -qF 'pacman -U --noconfirm' "$test_tmp/target-call" ||
  fail "a verified archived package is not installed"
pass "archived packages require detached-signature verification"

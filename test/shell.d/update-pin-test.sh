#!/bin/bash

set -euo pipefail

source "$(dirname "$0")/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT
pins="$test_tmp/config/update-pins.json"

OMARCHY_UPDATE_PINS_FILE="$pins" bash "$ROOT/bin/omarchy-update-pin" \
  set remote-desktop-manager 2026.2.2.2-2 aur
jq -e '.["remote-desktop-manager"] == {"version":"2026.2.2.2-2","manager":"aur","kind":"installed","locator":""}' "$pins" >/dev/null ||
  fail "setting an exact target does not persist its version and manager"
pass "an exact package version can be persisted"

OMARCHY_UPDATE_PINS_FILE="$pins" bash "$ROOT/bin/omarchy-update-pin" latest remote-desktop-manager
jq -e 'has("remote-desktop-manager") | not' "$pins" >/dev/null ||
  fail "returning a package to latest leaves an exact target behind"
pass "latest removes a persistent exact-version target"

if OMARCHY_UPDATE_PINS_FILE="$pins" bash "$ROOT/bin/omarchy-update-pin" set '../bad' 1 aur 2>/dev/null; then
  fail "an unsafe package name is accepted"
fi
pass "unsafe package names are rejected"

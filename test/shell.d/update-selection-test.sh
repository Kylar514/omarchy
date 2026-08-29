#!/bin/bash

set -euo pipefail

source "$(dirname "$0")/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT
stub_bin="$test_tmp/bin"
mkdir -p "$stub_bin"

cat >"$stub_bin/sudo" <<'STUB'
#!/bin/bash
printf 'sudo %s\n' "$*" >>"$CALL_LOG"
exit 0
STUB
cat >"$stub_bin/pacman" <<'STUB'
#!/bin/bash
[[ $1 == "-Qem" ]] && exit 0
exit 0
STUB
cat >"$stub_bin/omarchy-pkg-aur-accessible" <<'STUB'
#!/bin/bash
exit 0
STUB
cat >"$stub_bin/yay" <<'STUB'
#!/bin/bash
printf 'yay %s\n' "$*" >>"$CALL_LOG"
STUB
cat >"$stub_bin/omarchy-cmd-present" <<'STUB'
#!/bin/bash
exit 0
STUB
cat >"$stub_bin/mise" <<'STUB'
#!/bin/bash
printf 'mise %s\n' "$*" >>"$CALL_LOG"
STUB
chmod +x "$stub_bin"/*
call_log="$test_tmp/calls"

CALL_LOG="$call_log" PATH="$stub_bin:$PATH" OMARCHY_UPDATE_IGNORE_REPO=linux,mesa \
  bash "$ROOT/bin/omarchy-update-system-pkgs"
grep -q 'pacman -Syu --noconfirm --ignore linux --ignore mesa' "$call_log" ||
  fail "repository exclusions do not reach pacman as separate safe arguments"
pass "repository exclusions reach pacman"

: >"$call_log"
CALL_LOG="$call_log" PATH="$stub_bin:$PATH" OMARCHY_UPDATE_IGNORE_AUR=remote-desktop-manager \
  bash "$ROOT/bin/omarchy-update-aur-pkgs"
grep -q 'yay -Sua --noconfirm --cleanafter --ignore gcc14 --ignore gcc14-libs --ignore remote-desktop-manager' "$call_log" ||
  fail "AUR exclusions are not merged with Omarchy's existing holds"
pass "AUR exclusions reach yay"

: >"$call_log"
CALL_LOG="$call_log" PATH="$stub_bin:$PATH" OMARCHY_UPDATE_IGNORE_MISE=opencode,codex \
  bash "$ROOT/bin/omarchy-update-mise"
grep -q 'mise up --exclude opencode --exclude codex' "$call_log" ||
  fail "mise exclusions do not reach mise upgrade"
pass "mise exclusions reach mise"

steps="$test_tmp/steps"
for step in \
  omarchy-update-lock omarchy-update-requires-free-space omarchy-update-confirm \
  omarchy-update-pkg-prune omarchy-snapshot omarchy-update-stay-awake \
  omarchy-update-dev omarchy-update-keyring omarchy-update-system-pkgs \
  omarchy-migrate omarchy-hook omarchy-update-aur-pkgs omarchy-update-mise \
  omarchy-update-targets omarchy-update-orphan-pkgs omarchy-update-analyze-logs \
  omarchy-update-status omarchy-update-restart; do
  cat >"$stub_bin/$step" <<'STUB'
#!/bin/bash
printf '%s\n' "${0##*/}" >>"$STEP_LOG"
[[ ${0##*/} != omarchy-update-lock || ${1:-} != held ]] || exit 0
STUB
  chmod +x "$stub_bin/$step"
done
cat >"$stub_bin/omarchy-update-plan" <<STUB
#!/bin/bash
cat "$ROOT/test/shell.d/fixtures/update-plan.json"
STUB
cat >"$stub_bin/omarchy-update-tui" <<'STUB'
#!/bin/bash
tmp=$(mktemp)
jq '(.categories[] | select(.id != "mise") | .selected) = false' "$1" >"$tmp"
mv "$tmp" "$1"
STUB
chmod +x "$stub_bin/omarchy-update-plan" "$stub_bin/omarchy-update-tui"

STEP_LOG="$steps" PATH="$stub_bin:$PATH" OMARCHY_UPDATE_LOGGED=1 OMARCHY_UPDATE_TUI=1 \
  bash "$ROOT/bin/omarchy-update"

grep -q '^omarchy-update-mise$' "$steps" || fail "a mise-only plan does not update mise"
for skipped in omarchy-update-requires-free-space omarchy-snapshot omarchy-update-system-pkgs omarchy-update-aur-pkgs omarchy-migrate omarchy-update-restart; do
  if grep -q "^$skipped$" "$steps"; then
    fail "a mise-only plan still runs $skipped"
  fi
done
pass "a mise-only plan skips privileged package and restart phases"

# An empty plan is the up-to-date early exit: no selector, no privileged steps.
empty_plan() {
  jq "$1" "$ROOT/test/shell.d/fixtures/update-plan.json"
}

cat >"$stub_bin/omarchy-update-plan" <<STUB
#!/bin/bash
empty_plan() { jq "\$1" "$ROOT/test/shell.d/fixtures/update-plan.json"; }
empty_plan '.categories[].packages = [] | .pins = {}'
STUB
chmod +x "$stub_bin/omarchy-update-plan"

: >"$steps"
STEP_LOG="$steps" PATH="$stub_bin:$PATH" OMARCHY_UPDATE_LOGGED=1 OMARCHY_UPDATE_TUI=1 \
  bash "$ROOT/bin/omarchy-update" >"$test_tmp/out"
grep -q 'System is up to date' "$test_tmp/out" ||
  fail "an empty plan does not report the system as up to date"
for not_run in omarchy-update-tui omarchy-update-requires-free-space omarchy-snapshot omarchy-update-system-pkgs; do
  if grep -q "^$not_run$" "$steps"; then
    fail "an up-to-date system still runs $not_run"
  fi
done
pass "an empty plan reports up to date and starts nothing"

# Held versions survive the early exit as visible state with a way back.
cat >"$stub_bin/omarchy-update-plan" <<STUB
#!/bin/bash
empty_plan() { jq "\$1" "$ROOT/test/shell.d/fixtures/update-plan.json"; }
empty_plan '.categories[].packages = [] | .pins = {"remote-desktop-manager": {version: "2026.2.2.2-2", manager: "aur", kind: "installed", locator: ""}}'
STUB
chmod +x "$stub_bin/omarchy-update-plan"
STEP_LOG="$steps" PATH="$stub_bin:$PATH" OMARCHY_UPDATE_LOGGED=1 OMARCHY_UPDATE_TUI=1 \
  bash "$ROOT/bin/omarchy-update" >"$test_tmp/out"
grep -q 'remote-desktop-manager=2026.2.2.2-2' "$test_tmp/out" ||
  fail "a held version is not named when the system is otherwise up to date"
grep -q 'omarchy update pin latest' "$test_tmp/out" ||
  fail "the held-version notice does not say how to resume updates"
if grep -q '^omarchy-update-tui$' "$steps"; then
  fail "the selector opens when there are no rows to manage"
fi
pass "held versions are reported with their unpin path when up to date"

# Quitting the selector is not an update error.
cat >"$stub_bin/omarchy-update-plan" <<STUB
#!/bin/bash
cat "$ROOT/test/shell.d/fixtures/update-plan.json"
STUB
cat >"$stub_bin/omarchy-update-tui" <<'STUB'
#!/bin/bash
exit 130
STUB
chmod +x "$stub_bin/omarchy-update-plan" "$stub_bin/omarchy-update-tui"
STEP_LOG="$steps" PATH="$stub_bin:$PATH" OMARCHY_UPDATE_LOGGED=1 OMARCHY_UPDATE_TUI=1 \
  bash "$ROOT/bin/omarchy-update" >"$test_tmp/out"
grep -q 'Update cancelled' "$test_tmp/out" ||
  fail "a cancelled selection does not report the cancellation"
if grep -q 'Something went wrong' "$test_tmp/out"; then
  fail "cancelling the selector raises the update failure banner"
fi
pass "cancelling the selector stays quiet about failures"

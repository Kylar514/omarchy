#!/bin/bash

set -euo pipefail

source "$(dirname "$0")/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT
stub_bin="$test_tmp/bin"
state_dir="$test_tmp/state"
mkdir -p "$stub_bin" "$state_dir"

cat >"$stub_bin/omarchy-update-versions" <<'STUB'
#!/bin/bash
cat <<'JSON'
[
  {"version":"latest","kind":"latest","locator":""},
  {"version":"2026.2.2.2-2","kind":"installed","locator":""},
  {"version":"2025.3.0.4-1","kind":"cache","locator":"/cache/remote-desktop-manager.pkg.tar.zst"}
]
JSON
STUB
chmod +x "$stub_bin/omarchy-update-versions"
export PATH="$stub_bin:$PATH"

new_plan() {
  cp "$ROOT/test/shell.d/fixtures/update-plan.json" "$state_dir/plan.json"
  export OMARCHY_TUI_PLAN="$state_dir/plan.json"
  export OMARCHY_TUI_STATE="$state_dir"
}

# Drive one key press through the dispatcher the way fzf would.
press() {
  local key=$1 item=$2 state=$3
  printf '%s\n' "$state" >"$state_dir/state"
  FZF_KEY="$key" FZF_CURRENT_ITEM="$item" \
    bash "$ROOT/bin/omarchy-update-tui" --dispatch
}

new_plan
out=$(press space $'aur\t[x]\tAUR packages\t1/1' 'main')
jq -e '.categories[] | select(.id == "aur") | .selected == false' "$state_dir/plan.json" >/dev/null ||
  fail "toggling a category does not update the plan"
[[ $out == *"reload(cat "*$state_dir*"/rows)" ]] ||
  fail "a toggle does not tell fzf to reload its rows"
grep -q '^aur\.\?\|\[ \]' "$state_dir/rows" 2>/dev/null || grep -q '\[ \]' "$state_dir/rows" ||
  fail "the reloaded rows still show the category selected"
pass "a toggle updates the plan and reloads rows in place"

out=$(press l $'aur\t[ ]\tAUR packages\t1/1' 'main')
[[ $(<"$state_dir/state") == $'category\taur' ]] ||
  fail "opening a category does not record the category screen"
[[ $out == *'change-header(AUR packages)'* ]] ||
  fail "opening a category does not retitle the screen"
[[ -s $state_dir/rows ]] || fail "opening a category writes no rows"
pass "entering a category switches rows and header in the same fzf"

out=$(press enter $'remote-desktop-manager\t[x]\tremote-desktop-manager\t2026.2.2.2-2 -> 2026.3.0.1-1\tlatest' $'category\taur')
[[ $(<"$state_dir/state") == $'version\taur\tremote-desktop-manager' ]] ||
  fail "opening a package does not record the version screen"
[[ $out == *'change-with-nth(2..4)'* ]] || fail "the version screen does not narrow the columns"
grep -q 'latest' "$state_dir/rows" || fail "the version screen lists no versions"
pass "opening a package lists its selectable versions"

out=$(press enter $'2025.3.0.4-1\t \t2025.3.0.4-1\tcached binary\t/cache/remote-desktop-manager.pkg.tar.zst' $'version\taur\tremote-desktop-manager')
jq -e '.categories[] | select(.id == "aur") | .packages[0].target == "2025.3.0.4-1"' "$state_dir/plan.json" >/dev/null ||
  fail "choosing a version does not stage the target"
jq -e '.pins["remote-desktop-manager"].version == "2025.3.0.4-1"' "$state_dir/plan.json" >/dev/null ||
  fail "choosing a version does not stage the persistent pin"
[[ $(<"$state_dir/state") == $'category\taur' ]] ||
  fail "choosing a version does not return to the package list"
[[ $out == *'pos('* ]] || fail "returning from a version screen does not restore the cursor"
pass "choosing a version stages target and pin, then returns to the package"

new_plan
out=$(press enter $'run\tUpdate selected packages' 'main')
[[ $out == accept ]] || fail "Enter on the update action does not start the update"
jq -e '.categories[] | select(.id == "aur") | .selected' "$state_dir/plan.json" >/dev/null ||
  fail "an untouched plan was changed before accepting"
pass "Enter on the untouched plan starts immediately"

out=$(press q $'run\tUpdate selected packages' 'main')
[[ $out == abort ]] || fail "q on the main screen does not quit"
out=$(press h $'run\tUpdate selected packages' 'main')
[[ -z $out ]] || fail "h on the main screen emits an action"
pass "q quits and h is inert on the main screen"

new_plan
out=$(press l $'snapper\tSnapshots kept: 5' 'main')
[[ $(<"$state_dir/state") == snapper ]] ||
  fail "opening the retention screen does not record it"
[[ $out == *'change-header(Snapshot retention)'* ]] ||
  fail "the retention screen does not retitle the picker"
grep -q '5 snapshots' "$state_dir/rows" ||
  fail "the retention presets are not listed"

out=$(press enter $'10\t \t10 snapshots' snapper)
jq -e '.snapshots == 10' "$state_dir/plan.json" >/dev/null ||
  fail "choosing a retention preset does not stage it"
[[ $(<"$state_dir/state") == main ]] ||
  fail "choosing a retention preset does not return to the main screen"
[[ $out == *'pos('* ]] ||
  fail "returning from the retention screen does not restore the cursor"
grep -q -- '-> 10' "$state_dir/rows" ||
  fail "the main screen does not show the staged retention change"
pass "snapshot retention stages a preset and returns to the main screen"

# Parent exit-code contract: fzf accept starts, cancel propagates as 130.
cat >"$stub_bin/fzf" <<'STUB'
#!/bin/bash
exit ${TUI_TEST_FZF_STATUS:-0}
STUB
chmod +x "$stub_bin/fzf"
new_plan
TUI_TEST_FZF_STATUS=0 bash "$ROOT/bin/omarchy-update-tui" "$state_dir/plan.json"
TUI_TEST_FZF_STATUS=130 bash "$ROOT/bin/omarchy-update-tui" "$state_dir/plan.json" &&
  fail "a cancelled selection reports success"
pass "the TUI exits 0 to update and 130 to cancel"

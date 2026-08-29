#!/bin/bash

set -euo pipefail

source "$(dirname "$0")/base-test.sh"

migration="$ROOT/migrations/1787933008.sh"
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
home="$test_dir/home"
bin_dir="$home/.local/bin"
mkdir -p "$bin_dir"

cat >"$bin_dir/opencode" <<'EOF'
#!/bin/bash
export MISE_MINIMUM_RELEASE_AGE=0
mise use -g --quiet "opencode" || exit 1
exec mise x "opencode" -- "opencode" "$@"
EOF
chmod +x "$bin_dir/opencode"

HOME="$home" PATH="$ROOT/bin:$PATH" bash -euo pipefail "$migration" >/dev/null

grep -qF 'mise current "opencode" &>/dev/null || mise use -g --quiet "opencode" || exit 1' "$bin_dir/opencode" ||
  fail "the migration does not preserve an already selected exact mise version"
grep -qF 'exec mise exec -- "opencode" "$@"' "$bin_dir/opencode" ||
  fail "the migrated wrapper still overrides the active mise version at execution"
pass "generated mise wrappers honor active exact versions"

before=$(<"$bin_dir/opencode")
HOME="$home" PATH="$ROOT/bin:$PATH" bash -euo pipefail "$migration" >/dev/null
[[ $(<"$bin_dir/opencode") == "$before" ]] || fail "the version-safe wrapper migration is not idempotent"
pass "the version-safe wrapper migration is idempotent"

cat >"$bin_dir/custom" <<'EOF'
#!/bin/bash
export CUSTOM_SETTING=1
mise use -g --quiet "custom" || exit 1
exec mise x "custom" -- "custom" "$@"
EOF
custom_before=$(<"$bin_dir/custom")
HOME="$home" PATH="$ROOT/bin:$PATH" bash -euo pipefail "$migration" >/dev/null
[[ $(<"$bin_dir/custom") == "$custom_before" ]] || fail "the migration rewrites a customized wrapper"
pass "the migration leaves customized wrappers alone"

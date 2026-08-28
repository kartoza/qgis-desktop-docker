#!/usr/bin/env bash
# Lint every script that flake.nix packages with writeShellApplication.
#
# writeShellApplication runs shellcheck at BUILD time and treats even
# info-level findings as fatal. Without this test the first sign of a problem
# is a failed image build several minutes in, with the real message buried in
# "Last 7 log lines" — which has now happened twice, once for a regex that
# looked like a command substitution (SC2016) and once for a function only
# reachable from a trap (SC2329).
#
# The list is READ OUT OF flake.nix rather than restated here, so a script
# added to the image is covered without anyone remembering to add it.
#
# Run:  ./scripts/test-shellcheck.sh
#       nix run .#test-shellcheck

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${QGIS_DESKTOP_PROJECT_ROOT:-$(cd -- "$SCRIPT_DIR/.." && pwd)}"
FLAKE="$PROJECT_ROOT/flake.nix"

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
no() {
  FAIL=$((FAIL + 1))
  printf '  \033[31m✗\033[0m %s\n' "$1"
  [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/      /'
}

echo "shellcheck (build-time lint)"

if ! command -v shellcheck >/dev/null 2>&1; then
  echo "  — skipped: shellcheck not on PATH (run via 'nix run .#test-shellcheck')"
  exit 0
fi

[ -r "$FLAKE" ] || { no "flake.nix is readable"; exit 1; }

# Every `text = builtins.readFile ./path;` is a script that gets packaged.
SCRIPTS="$(grep -oE 'builtins\.readFile \./[a-zA-Z0-9./_-]+' "$FLAKE" |
  sed 's|builtins.readFile \./||' | sort -u)"

count=0
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  path="$PROJECT_ROOT/$rel"
  # readFile is also used for non-shell files; only lint things with a shebang.
  head -1 "$path" 2>/dev/null | grep -q '^#!.*sh' || continue
  count=$((count + 1))
  if OUTPUT="$(shellcheck -s bash "$path" 2>&1)"; then
    ok "$rel"
  else
    no "$rel" "$(printf '%s' "$OUTPUT" | head -6)"
  fi
done <<< "$SCRIPTS"

if [ "$count" -gt 0 ]; then
  ok "found $count packaged script(s) by reading flake.nix"
else
  no "found packaged scripts by reading flake.nix" \
    "none matched — has the 'builtins.readFile ./' idiom changed?"
fi

echo ""
echo "─────────────────────────────────────────"
printf '  %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1

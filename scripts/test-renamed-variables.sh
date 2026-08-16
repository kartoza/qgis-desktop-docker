#!/usr/bin/env bash
# Unit tests for the 2.0.0 rename guard in entrypoint.sh.
#
# Every setting that is this project's own behaviour moved from the KASM_ prefix
# to QGIS_DESKTOP_. The KASM_ prefix now means "a KasmVNC setting" and nothing
# else. A container started with an old name must refuse to boot rather than
# ignore it — an ignored QGIS_DESKTOP_EGRESS_ALLOW or QGIS_DESKTOP_AUTH_MODE
# means a deployment that believes it is locked down running wide open.
#
# The guard is sourced out of entrypoint.sh rather than duplicated here, so the
# list it checks is always the real one.
#
# Run:  ./scripts/test-renamed-variables.sh
#       nix run .#test-renamed-variables

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${QGIS_DESKTOP_PROJECT_ROOT:-$(cd -- "$SCRIPT_DIR/.." && pwd)}"
ENTRYPOINT="$PROJECT_ROOT/entrypoint.sh"

PASS=0
FAIL=0

ok() {
  PASS=$((PASS + 1))
  printf '  \033[32m✓\033[0m %s\n' "$1"
}

no() {
  FAIL=$((FAIL + 1))
  printf '  \033[31m✗\033[0m %s\n' "$1"
  [ -n "${2:-}" ] && printf '      %s\n' "$2"
}

# Pull the guard out of the entrypoint and run it in isolation, with only the
# variables the caller names. Everything before `check_renamed_variables` is
# extracted, so the helper and its rename table come from the real file.
run_guard() {
  local body
  body="$(sed -n '1,/^check_renamed_variables$/p' "$ENTRYPOINT")"
  OUTPUT="$(env -i PATH="$PATH" "$@" bash -c "$body" 2>&1)"
  STATUS=$?
}

assert_contains() {
  case "$1" in
    *"$2"*) ok "$3" ;;
    *) no "$3" "expected to find: $2" ;;
  esac
}

echo "renamed-variable guard"

# --- The happy path ---------------------------------------------------------
run_guard QGIS_DESKTOP_AUTH_MODE=basic QGIS_DESKTOP_EGRESS_ALLOW=db
if [ "$STATUS" -eq 0 ]; then ok "new names boot normally"; else no "new names boot normally" "$OUTPUT"; fi

run_guard
if [ "$STATUS" -eq 0 ]; then ok "no variables at all boots normally"; else no "no variables at all boots normally" "$OUTPUT"; fi

# --- KasmVNC's own settings must be left alone ------------------------------
run_guard KASM_ALLOW_CLIPBOARD_IN=1 KASM_DLP_LOG=info KASM_WATERMARK_TEXT=x \
  KASM_CLIPBOARD_DELAY_MS=500 KASM_ALLOW_PRIMARY_SELECTION=1 \
  KASM_CLIPBOARD_IN_MAX=4096 KASM_CLIPBOARD_OUT_MAX=4096 \
  KASM_CLIPBOARD_MIME_TYPES=text/plain KASM_ALLOW_CLIPBOARD_OUT=1
if [ "$STATUS" -eq 0 ]; then
  ok "KasmVNC's own KASM_* settings still boot — they map onto Xkasmvnc flags"
else
  no "KasmVNC's own KASM_* settings still boot" "$OUTPUT"
fi

# --- Every renamed name is refused ------------------------------------------
# Derived from the entrypoint's own table, so a name added there without a test
# still gets covered.
mapfile -t RENAMED < <(
  sed -n '/local -a renames=(/,/^  )$/p' "$ENTRYPOINT" |
    grep -oE '"KASM_[A-Z_]+=' | tr -d '"=' | sort -u
)

if [ "${#RENAMED[@]}" -lt 20 ]; then
  no "the rename table could be read from entrypoint.sh" "found ${#RENAMED[@]} entries"
else
  ok "read ${#RENAMED[@]} renamed names out of entrypoint.sh"
fi

refused=0
silent=""
for old in "${RENAMED[@]}"; do
  run_guard "${old}=something"
  if [ "$STATUS" -ne 0 ]; then
    refused=$((refused + 1))
  else
    silent="$silent $old"
  fi
done

if [ -z "$silent" ]; then
  ok "all ${refused} legacy names are refused, none silently ignored"
else
  no "all legacy names are refused" "silently accepted:$silent"
fi

# --- The message has to be actionable ---------------------------------------
run_guard KASM_EGRESS_ALLOW=db
assert_contains "$OUTPUT" "KASM_EGRESS_ALLOW" "the error names the variable that was set"
assert_contains "$OUTPUT" "QGIS_DESKTOP_EGRESS_ALLOW" "the error names its replacement"
assert_contains "$OUTPUT" "2.0.0" "the error says which release changed it"
assert_contains "$OUTPUT" "docs/configuration" "the error points at the migration guide"

# Several at once should all be listed, not just the first.
run_guard KASM_AUTH_MODE=greeter KASM_USERS=a:b KASM_OIDC_ISSUER_URL=https://x/y
assert_contains "$OUTPUT" "KASM_AUTH_MODE" "first of several is listed"
assert_contains "$OUTPUT" "KASM_USERS" "second of several is listed"
assert_contains "$OUTPUT" "KASM_OIDC_ISSUER_URL" "third of several is listed"

# The old on/off toggle needs its replacement spelled out — the mapping is not
# a straight rename.
run_guard KASM_AUTH=0
assert_contains "$OUTPUT" "use =none instead of =0" "KASM_AUTH gets its value translated too"

# --- An empty legacy variable is not a setting ------------------------------
run_guard KASM_EGRESS_ALLOW=
if [ "$STATUS" -eq 0 ]; then
  ok "an empty legacy variable is ignored, not fatal"
else
  no "an empty legacy variable is ignored, not fatal" "$OUTPUT"
fi

# --- Documentation must not drift -------------------------------------------
# Every replacement the guard names has to exist in the docs, or the error
# message sends people somewhere useless.
missing=""
for old in "${RENAMED[@]}"; do
  new="$(grep -oE "\"${old}=[^\"]+\"" "$ENTRYPOINT" | head -1 | sed -e 's/.*=//' -e 's/"$//' -e 's/ .*//')"
  [ -n "$new" ] || continue
  grep -rq -- "$new" "$PROJECT_ROOT/docs" "$PROJECT_ROOT/README.md" 2>/dev/null || missing="$missing $new"
done
if [ -z "$missing" ]; then
  ok "every replacement name appears in the docs"
else
  no "every replacement name appears in the docs" "undocumented:$missing"
fi

echo ""
echo "─────────────────────────────────────────"
printf '  %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1

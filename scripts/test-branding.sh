#!/usr/bin/env bash
# Unit tests for config/branding/brand-www.sh.
#
# The script rewrites a copy of KasmVNC's web root. Its most important
# property is not that it themes correctly — it is that it FAILS when the
# upstream markup it keys on moves, rather than silently shipping an image
# that still says "KasmVNC". Most of what follows tests that.
#
# Runs against a synthetic www tree, so it needs neither KasmVNC nor Docker.
#
# Run:  ./scripts/test-branding.sh
#       nix run .#test-branding

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${QGIS_DESKTOP_PROJECT_ROOT:-$(cd -- "$SCRIPT_DIR/.." && pwd)}"
BRAND="$PROJECT_ROOT/config/branding/brand-www.sh"
TOKENS="$PROJECT_ROOT/config/branding/tokens.json"
TEMPLATE="$PROJECT_ROOT/config/branding/disconnected.html.in"
LOGO="$PROJECT_ROOT/resources/brand/geohosting.svg"

PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
no() {
  FAIL=$((FAIL + 1))
  printf '  \033[31m✗\033[0m %s\n' "$1"
  [ -n "${2:-}" ] && printf '      %s\n' "$2"
}

echo "branding"

if ! command -v jq >/dev/null 2>&1; then
  echo "  — skipped: jq not on PATH (run via 'nix run .#test-branding')"
  exit 0
fi

WORK="$(mktemp -d -t qgis-desktop-branding-tests.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

printf 'regular\n' > "$WORK/regular.ttf"
printf 'bold\n' > "$WORK/bold.ttf"

# A miniature stand-in for KasmVNC's web root, carrying exactly the markup the
# script keys on.
make_www() {
  local dir="$1"
  rm -rf "$dir"
  mkdir -p "$dir/assets"
  for page in index.html vnc.html; do
    cat > "$dir/$page" <<'PAGE'
<!DOCTYPE html><html lang="en"><head><title>KasmVNC</title><meta charset="utf-8"><link rel="icon" sizes="16x16" type="image/png" href="./assets/368_kasm_logo_only_16x16-BfyYpHuV.png"><link rel="icon" sizes="32x32" type="image/png" href="./assets/368_kasm_logo_only_32x32-ig-uDAV_.png"><link rel="apple-touch-icon" href="./assets/368_kasm_logo_only_192x192-5ckMOqv_.png"></head><body><div id="app"></div></body></html>
PAGE
  done
  echo '<html><body>Session Disconnected</body></html>' > "$dir/disconnected.html"
  echo 'console.log(1)' > "$dir/assets/ui-D357AMxM.js"
  echo '.a{color:red}' > "$dir/assets/screen-D7_1SmlI.css"
}

run_brand() {
  local src="$1" out="$2"
  shift 2
  OUTPUT="$(
    bash "$BRAND" \
      --source "$src" \
      --tokens "${TOKENS_OVERRIDE:-$TOKENS}" \
      --template "$TEMPLATE" \
      --logo "$LOGO" \
      --font-regular "$WORK/regular.ttf" \
      --font-bold "$WORK/bold.ttf" \
      --out "$out" "$@" 2>&1
  )"
  STATUS=$?
}

# --- The happy path ---------------------------------------------------------
make_www "$WORK/src"
run_brand "$WORK/src" "$WORK/out"

if [ "$STATUS" -eq 0 ]; then ok "brands a well-formed web root"; else no "brands a well-formed web root" "exited $STATUS: $OUTPUT"; fi

BRAND_NAME="$(jq -r .brand.name "$TOKENS")"
for page in index.html vnc.html; do
  if grep -q "<title>${BRAND_NAME}</title>" "$WORK/out/$page" 2>/dev/null; then
    ok "$page carries the brand title"
  else
    no "$page carries the brand title"
  fi
  if grep -q '368_kasm_logo_only' "$WORK/out/$page" 2>/dev/null; then
    no "$page has no stock Kasm favicons left" "a 368_kasm_logo_only reference survived"
  else
    ok "$page has no stock Kasm favicons left"
  fi
  if grep -q 'href="./assets/brand-logo.svg" type="image/svg+xml"' "$WORK/out/$page" 2>/dev/null; then
    ok "$page points at the brand favicon"
  else
    no "$page points at the brand favicon"
  fi
done

for asset in brand-logo.svg brand-body.ttf brand-body-bold.ttf; do
  if [ -f "$WORK/out/assets/$asset" ]; then ok "assets/$asset is installed"; else no "assets/$asset is installed"; fi
done

# The Vite bundle and hashed CSS are exactly what we promised not to touch.
if cmp -s "$WORK/src/assets/ui-D357AMxM.js" "$WORK/out/assets/ui-D357AMxM.js"; then
  ok "the Vite bundle is left byte-identical"
else
  no "the Vite bundle is left byte-identical" "the script modified it"
fi
if cmp -s "$WORK/src/assets/screen-D7_1SmlI.css" "$WORK/out/assets/screen-D7_1SmlI.css"; then
  ok "the hashed stylesheet is left byte-identical"
else
  no "the hashed stylesheet is left byte-identical"
fi

# --- The disconnected page --------------------------------------------------
ACCENT="$(jq -r .color.accent "$TOKENS")"
if grep -q -- "--accent: ${ACCENT};" "$WORK/out/disconnected.html" 2>/dev/null; then
  ok "the accent colour reaches the disconnected page"
else
  no "the accent colour reaches the disconnected page"
fi
if grep -qE '@[A-Z_]+@' "$WORK/out/disconnected.html" 2>/dev/null; then
  no "no placeholder survives substitution" "$(grep -oE '@[A-Z_]+@' "$WORK/out/disconnected.html" | sort -u | tr '\n' ' ')"
else
  ok "no placeholder survives substitution"
fi
# This page is the one surface that CAN clear the SSO cookie, so the link is
# the point of branding it at all.
if grep -q 'href="/oauth2/sign_out"' "$WORK/out/disconnected.html" 2>/dev/null; then
  ok "the disconnected page offers a sign-out link"
else
  no "the disconnected page offers a sign-out link"
fi
if grep -q 'Session Disconnected' "$WORK/out/disconnected.html" 2>/dev/null; then
  no "the stock Kasm disconnected page is replaced" "upstream text survived"
else
  ok "the stock Kasm disconnected page is replaced"
fi

# --- Failing loudly when upstream moves -------------------------------------
# Each of these is a KasmVNC release changing something we key on. A silent
# pass here would mean shipping Kasm's branding while believing otherwise.
make_www "$WORK/src-notitle"
sed -i 's|<title>KasmVNC</title>|<title>Kasm Workspaces</title>|' "$WORK/src-notitle/index.html"
run_brand "$WORK/src-notitle" "$WORK/out-notitle"
if [ "$STATUS" -ne 0 ]; then ok "a renamed <title> fails the build"; else no "a renamed <title> fails the build" "it passed"; fi
case "$OUTPUT" in
  *"changed its markup"*) ok "and says the markup moved" ;;
  *) no "and says the markup moved" "got: $OUTPUT" ;;
esac

make_www "$WORK/src-nofav"
sed -i 's|<link rel="icon"[^>]*>||g; s|<link rel="apple-touch-icon"[^>]*>||g' "$WORK/src-nofav/index.html"
run_brand "$WORK/src-nofav" "$WORK/out-nofav"
if [ "$STATUS" -ne 0 ]; then ok "renamed favicons fail the build"; else no "renamed favicons fail the build" "it passed"; fi

make_www "$WORK/src-nodisc"
rm -f "$WORK/src-nodisc/disconnected.html"
run_brand "$WORK/src-nodisc" "$WORK/out-nodisc"
if [ "$STATUS" -ne 0 ]; then ok "a missing disconnected.html fails the build"; else no "a missing disconnected.html fails the build"; fi

make_www "$WORK/src-nopages"
rm -f "$WORK/src-nopages/index.html" "$WORK/src-nopages/vnc.html"
run_brand "$WORK/src-nopages" "$WORK/out-nopages"
if [ "$STATUS" -ne 0 ]; then ok "no entry page at all fails the build"; else no "no entry page at all fails the build"; fi

# --- Token validation -------------------------------------------------------
make_www "$WORK/src2"

jq '.color.accent = "not-a-colour"' "$TOKENS" > "$WORK/bad-colour.json"
TOKENS_OVERRIDE="$WORK/bad-colour.json" run_brand "$WORK/src2" "$WORK/out-badcolour"
if [ "$STATUS" -ne 0 ]; then ok "a malformed colour is rejected"; else no "a malformed colour is rejected"; fi
case "$OUTPUT" in
  *"hex literal"*) ok "and says it wanted a hex literal" ;;
  *) no "and says it wanted a hex literal" "got: $OUTPUT" ;;
esac

jq 'del(.brand.name)' "$TOKENS" > "$WORK/no-name.json"
TOKENS_OVERRIDE="$WORK/no-name.json" run_brand "$WORK/src2" "$WORK/out-noname"
if [ "$STATUS" -ne 0 ]; then ok "a missing token is rejected"; else no "a missing token is rejected"; fi

# --- Argument handling ------------------------------------------------------
OUTPUT="$(bash "$BRAND" --source "$WORK/src2" --out "$WORK/out3" 2>&1)"; STATUS=$?
if [ "$STATUS" -ne 0 ]; then ok "missing arguments are rejected"; else no "missing arguments are rejected"; fi

OUTPUT="$(bash "$BRAND" --nonsense 2>&1)"; STATUS=$?
if [ "$STATUS" -ne 0 ]; then ok "an unknown argument is rejected"; else no "an unknown argument is rejected"; fi

# --- The shipped tokens file ------------------------------------------------
if jq -e . "$TOKENS" >/dev/null 2>&1; then ok "the shipped tokens file is valid JSON"; else no "the shipped tokens file is valid JSON"; fi
if jq -e '._provenance.assumed | length > 0' "$TOKENS" >/dev/null 2>&1; then
  ok "the tokens file records which values are assumed"
else
  no "the tokens file records which values are assumed" \
    "every derived value needs its provenance stated, or nobody knows what still needs confirming"
fi

echo ""
echo "─────────────────────────────────────────"
printf '  %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1

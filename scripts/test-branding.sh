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
<!DOCTYPE html><html lang="en"><head><title>KasmVNC</title><meta charset="utf-8"><link rel="icon" sizes="16x16" type="image/png" href="./assets/368_kasm_logo_only_16x16-BfyYpHuV.png"><link rel="icon" sizes="32x32" type="image/png" href="./assets/368_kasm_logo_only_32x32-ig-uDAV_.png"><link rel="apple-touch-icon" href="./assets/368_kasm_logo_only_192x192-5ckMOqv_.png"></head><body><div id="noVNC_fallback_error"><div>KasmVNC encountered an error:</div></div><div id="noVNC_control_bar"><h1 class="noVNC_logo"><a href="https://www.kasmweb.com/kasmvnc" target="_blank" alt="KasmVNC Learn More" title="KasmVNC Learn More"><img src="data:image/svg+xml,%3csvg/%3e"></a></h1><label>Enable KasmVNC Keyboard Shortcuts</label><a href="https://www.kasmweb.com/kasmvnc/docs/latest/index.html">Documentation</a></div></body></html>
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


# --- The control bar --------------------------------------------------------
# The panel down the left of the screen is built from this markup, not from the
# Vite bundle — which is the only reason it is safe to touch.
for page in index.html vnc.html; do
  if grep -q "<img src=\"./assets/brand-logo.svg\" alt=\"${BRAND_NAME}\"" "$WORK/out/$page" 2>/dev/null; then
    ok "$page control bar shows the brand logo"
  else
    no "$page control bar shows the brand logo"
  fi
  if grep -q 'kasmweb.com/kasmvnc"' "$WORK/out/$page" 2>/dev/null; then
    no "$page control-bar logo no longer links to kasmweb" "the link survived"
  else
    ok "$page control-bar logo no longer links to kasmweb"
  fi
  if grep -qE '(alt|title)="[^"]*Kasm' "$WORK/out/$page" 2>/dev/null; then
    no "$page has no Kasm left in alt/title attributes"
  else
    ok "$page has no Kasm left in alt/title attributes"
  fi
done

# The error box is what a user sees whenever the connection drops, so it is the
# string most likely to be read by someone already having a bad time.
if grep -q "${BRAND_NAME} encountered an error:" "$WORK/out/index.html" 2>/dev/null; then
  ok "the connection-error message carries the brand"
else
  no "the connection-error message carries the brand"
fi
if grep -q "Enable ${BRAND_NAME} Keyboard Shortcuts" "$WORK/out/index.html" 2>/dev/null; then
  ok "the keyboard-shortcuts toggle carries the brand"
else
  no "the keyboard-shortcuts toggle carries the brand"
fi

# --- The documentation link -------------------------------------------------
# Unset, it stays pointing at upstream: those are real docs for these very
# controls, and a dead link of our own would be worse than an honest outbound.
if grep -q 'kasmweb.com/kasmvnc/docs' "$WORK/out/index.html" 2>/dev/null; then
  ok "the Documentation link is left alone when brand.docsUrl is unset"
else
  no "the Documentation link is left alone when brand.docsUrl is unset"
fi

make_www "$WORK/src-docs"
jq '.brand.docsUrl = "https://example.com/help"' "$TOKENS" > "$WORK/docs.json"
TOKENS_OVERRIDE="$WORK/docs.json" run_brand "$WORK/src-docs" "$WORK/out-docs"
if grep -q 'https://example.com/help' "$WORK/out-docs/index.html" 2>/dev/null; then
  ok "brand.docsUrl redirects the Documentation link"
else
  no "brand.docsUrl redirects the Documentation link"
fi

# --- More ways for upstream to move -----------------------------------------
make_www "$WORK/src-nologo"
sed -i 's|<h1 class="noVNC_logo">|<h1 class="kasm_logo">|' "$WORK/src-nologo/index.html"
run_brand "$WORK/src-nologo" "$WORK/out-nologo"
if [ "$STATUS" -ne 0 ]; then ok "a renamed control-bar header fails the build"; else no "a renamed control-bar header fails the build"; fi

make_www "$WORK/src-noerr"
sed -i 's|KasmVNC encountered an error:|Something went wrong:|' "$WORK/src-noerr/index.html"
run_brand "$WORK/src-noerr" "$WORK/out-noerr"
if [ "$STATUS" -ne 0 ]; then ok "reworded error text fails the build"; else no "reworded error text fails the build"; fi

# --- Brand values are interpolated into sed, so they are validated ----------
make_www "$WORK/src-inject"
jq '.brand.name = "Ac|me & Co"' "$TOKENS" > "$WORK/inject.json"
TOKENS_OVERRIDE="$WORK/inject.json" run_brand "$WORK/src-inject" "$WORK/out-inject"
if [ "$STATUS" -ne 0 ]; then ok "a brand name with sed metacharacters is rejected"; else no "a brand name with sed metacharacters is rejected"; fi

jq '.brand.url = "javascript:alert(1)"' "$TOKENS" > "$WORK/badurl.json"
TOKENS_OVERRIDE="$WORK/badurl.json" run_brand "$WORK/src-inject" "$WORK/out-badurl"
if [ "$STATUS" -ne 0 ]; then ok "a non-http brand url is rejected"; else no "a non-http brand url is rejected"; fi
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



# --- The wallpaper ----------------------------------------------------------
# It is used in three places (XFCE desktop, LightDM greeter background, and the
# X root window during a session restart), so a broken render is visible in all
# of them.
if command -v rsvg-convert >/dev/null 2>&1; then
  WALLPAPER="$PROJECT_ROOT/config/branding/brand-wallpaper.sh"
  WP_TEMPLATE="$PROJECT_ROOT/config/branding/wallpaper.svg.in"

  run_wallpaper() {
    OUTPUT="$(bash "$WALLPAPER" --template "${2:-$WP_TEMPLATE}" --logo "$LOGO" \
      --tokens "${1:-$TOKENS}" --out "$WORK/wp.png" 2>&1)"
    STATUS=$?
  }

  rm -f "$WORK/wp.png"
  run_wallpaper
  if [ "$STATUS" -eq 0 ]; then ok "the wallpaper renders"; else no "the wallpaper renders" "$OUTPUT"; fi
  if [ -s "$WORK/wp.png" ]; then ok "…and the PNG is not empty"; else no "…and the PNG is not empty"; fi
  # A PNG, not an SVG someone renamed.
  if head -c 8 "$WORK/wp.png" 2>/dev/null | grep -q 'PNG'; then
    ok "…and is a real PNG"
  else
    no "…and is a real PNG"
  fi

  run_wallpaper "$WORK/wp-bad.json"
  if [ "$STATUS" -ne 0 ]; then ok "a malformed wallpaper colour is rejected"; else no "a malformed wallpaper colour is rejected"; fi

  # The logo is embedded by reference, so rsvg needs it beside the SVG — a
  # missing one renders a wallpaper with a hole in it rather than failing.
  OUTPUT="$(bash "$WALLPAPER" --template "$WP_TEMPLATE" --tokens "$TOKENS" \
    --logo "$WORK/no-such-logo.svg" --out "$WORK/wp.png" 2>&1)"; STATUS=$?
  if [ "$STATUS" -ne 0 ]; then ok "a missing logo is rejected"; else no "a missing logo is rejected"; fi

  jq 'del(.wallpaper)' "$TOKENS" > "$WORK/wp-none.json"
  run_wallpaper "$WORK/wp-none.json"
  if [ "$STATUS" -ne 0 ]; then ok "a missing wallpaper block is rejected"; else no "a missing wallpaper block is rejected"; fi

  # An unknown placeholder in the template must fail the build, not ship.
  sed 's|@WORDMARK@|@NOT_A_TOKEN@|' "$WP_TEMPLATE" > "$WORK/wp-tmpl.svg"
  run_wallpaper "$TOKENS" "$WORK/wp-tmpl.svg"
  if [ "$STATUS" -ne 0 ]; then ok "an unknown template placeholder fails the render"; else no "an unknown template placeholder fails the render"; fi
else
  echo "  — rsvg-convert not on PATH; skipping the wallpaper checks"
fi
# --- shellcheck -------------------------------------------------------------
# brand-www.sh is packaged with writeShellApplication, which runs shellcheck at
# BUILD time and treats even info-level findings as fatal. Without this test the
# first sign of a problem is a failed `nix build`, which is a slow and confusing
# way to learn that a regex looked like a command substitution.
if command -v shellcheck >/dev/null 2>&1; then
  if SC_OUT="$(shellcheck -s bash "$BRAND" 2>&1)"; then
    ok "brand-www.sh is shellcheck-clean (writeShellApplication requires it)"
  else
    no "brand-www.sh is shellcheck-clean (writeShellApplication requires it)" \
      "$(printf '%s' "$SC_OUT" | head -5)"
  fi
else
  echo "  — shellcheck not on PATH; skipping the build-time lint check"
fi
echo ""
echo "─────────────────────────────────────────"
printf '  %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1

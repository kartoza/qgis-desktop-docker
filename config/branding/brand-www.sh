#!/usr/bin/env bash
# Renders a branded copy of the KasmVNC web root.
#
# Runs at BUILD time, inside a nix derivation — never in a running container.
# It takes the upstream www tree (which lives read-only in the nix store),
# copies it somewhere writable, and replaces the surfaces that are safe to
# replace:
#
#   index.html / vnc.html   <title> and the favicon links
#   disconnected.html       rendered wholesale from a template
#   assets/brand-*          the logo and the body font
#
# It deliberately does NOT touch the Vite bundle (ui-*.js) or the hashed
# stylesheets. Those are rebuilt with new content hashes on every KasmVNC
# release, so patching them would turn every version bump into a debugging
# session.
#
# Every substitution is asserted: if a future KasmVNC stops shipping the
# markup we key on, this fails the build loudly rather than silently producing
# an image that still says "KasmVNC".
#
#   qgis-desktop-brand-www --source DIR --tokens FILE --template FILE \
#                          --logo FILE --font-regular FILE --font-bold FILE \
#                          --out DIR

set -euo pipefail

SOURCE="" TOKENS="" TEMPLATE="" LOGO="" SPLASH="" REDIRECT_JS="" FONT_REGULAR="" FONT_BOLD="" OUT=""

die() { echo "ERROR: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --source) SOURCE="${2:-}"; shift 2 ;;
    --tokens) TOKENS="${2:-}"; shift 2 ;;
    --template) TEMPLATE="${2:-}"; shift 2 ;;
    --logo) LOGO="${2:-}"; shift 2 ;;
    --splash) SPLASH="${2:-}"; shift 2 ;;
    --redirect-js) REDIRECT_JS="${2:-}"; shift 2 ;;
    --font-regular) FONT_REGULAR="${2:-}"; shift 2 ;;
    --font-bold) FONT_BOLD="${2:-}"; shift 2 ;;
    --out) OUT="${2:-}"; shift 2 ;;
    *) die "unknown argument '$1'" ;;
  esac
done

for pair in \
  "SOURCE:--source" "TOKENS:--tokens" "TEMPLATE:--template" \
  "LOGO:--logo" "SPLASH:--splash" "REDIRECT_JS:--redirect-js" "FONT_REGULAR:--font-regular" "FONT_BOLD:--font-bold" "OUT:--out"
do
  var="${pair%%:*}"
  flag="${pair#*:}"
  [ -n "${!var}" ] || die "${flag} is required."
done

[ -d "${SOURCE}" ] || die "--source ${SOURCE} is not a directory."
for f in "${TOKENS}" "${TEMPLATE}" "${LOGO}" "${SPLASH}" "${REDIRECT_JS}" "${FONT_REGULAR}" "${FONT_BOLD}"; do
  [ -r "${f}" ] || die "${f} is not readable."
done

# --- Read the brand -----------------------------------------------------
# One file is the single source of truth for every brand value; correcting it
# re-themes everything this script produces.
tok() {
  local path="$1" value
  value="$(jq -r "${path} // empty" "${TOKENS}")"
  [ -n "${value}" ] || die "${TOKENS} is missing ${path}"
  printf '%s' "${value}"
}

BRAND_NAME="$(tok '.brand.name')"
BRAND_URL="$(tok '.brand.url')"
# Optional — jq prints nothing for a missing key, and unset means "leave
# upstream's link alone", so this one does not go through tok().
BRAND_DOCS_URL="$(jq -r '.brand.docsUrl // empty' "${TOKENS}")"
FONT_FAMILY="$(tok '.font.family')"
COLOR_ACCENT="$(tok '.color.accent')"
COLOR_ACCENT_HOVER="$(tok '.color.accentHover')"
COLOR_SECONDARY="$(tok '.color.secondary')"
COLOR_MUTED="$(tok '.color.muted')"
COLOR_SURFACE="$(tok '.color.surface')"
COLOR_SURFACE_RAISED="$(tok '.color.surfaceRaised')"
COLOR_TEXT="$(tok '.color.text')"
COLOR_TEXT_MUTED="$(tok '.color.textMuted')"

# Every colour must be a hex literal: these values are interpolated straight
# into CSS, and a malformed one would break the stylesheet silently.
for name in ACCENT ACCENT_HOVER SECONDARY MUTED SURFACE SURFACE_RAISED TEXT TEXT_MUTED; do
  var="COLOR_${name}"
  case "${!var}" in
    '#'[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]) : ;;
    *) die "color.${name} = '${!var}' is not a #rrggbb hex literal." ;;
  esac
done

# BRAND_NAME and BRAND_URL are interpolated into sed replacement text below, so
# they must not carry sed's metacharacters. An allowlist rather than escaping:
# a brand name has no business containing & or | or a backslash, and a rule you
# can read is worth more than one you have to trust.
printf '%s' "${BRAND_NAME}" | grep -qE '^[A-Za-z0-9 ._-]+$' ||
  die "brand.name = '${BRAND_NAME}' must be letters, digits, spaces, dot, underscore or hyphen."
printf '%s' "${BRAND_URL}" | grep -qE '^https?://[A-Za-z0-9._~:/?#@%+=-]+$' ||
  die "brand.url = '${BRAND_URL}' must be an http(s) URL with no shell- or sed-significant characters."
echo "Branding the KasmVNC web root as '${BRAND_NAME}'"

# --- Copy the upstream tree ---------------------------------------------
mkdir -p "${OUT}"
cp -r "${SOURCE}/." "${OUT}/"
chmod -R u+w "${OUT}"

# The control-bar link is injected at runtime, long after tokens.json is out of
# reach, so publish the one value that markup needs. Keeps the tokens file the
# single source of truth instead of a second hardcoded copy going stale.
printf '%s\n' "${COLOR_ACCENT}" > "${OUT}/assets/brand-accent.txt"
chmod 0444 "${OUT}/assets/brand-accent.txt"

install -m 0444 "${LOGO}" "${OUT}/assets/brand-logo.svg"
install -m 0444 "${FONT_REGULAR}" "${OUT}/assets/brand-body.ttf"
install -m 0444 "${FONT_BOLD}" "${OUT}/assets/brand-body-bold.ttf"

# --- The entry pages -----------------------------------------------------
# vnc.html is byte-identical to index.html upstream, but both are served, so
# both are patched. A future release that drops one is not an error; a release
# that drops both is.
# The bundle name carries a content hash, so find it by shape and insist on one.
ui_count="$(find "${OUT}/assets" -maxdepth 1 -name 'ui-*.js' | wc -l)"
[ "${ui_count}" -eq 1 ] ||
  die "expected exactly one assets/ui-*.js, found ${ui_count} — KasmVNC changed its asset layout."
UI_BUNDLE="$(basename "$(find "${OUT}/assets" -maxdepth 1 -name 'ui-*.js')")"
install -m 0444 "${REDIRECT_JS}" "${OUT}/assets/brand-disconnect.js"

patched_pages=0
for page in index.html vnc.html; do
  path="${OUT}/${page}"
  [ -f "${path}" ] || continue

  grep -q '<title>KasmVNC</title>' "${path}" ||
    die "${page} no longer contains '<title>KasmVNC</title>' — KasmVNC changed its markup and this script needs updating."
  sed -i "s|<title>KasmVNC</title>|<title>${BRAND_NAME}</title>|" "${path}"

  # Drop the stock Kasm favicons (thirteen <link rel="icon"> tags pointing at
  # content-hashed PNGs) and replace them with one SVG, which every browser we
  # care about supports and which needs no raster pipeline at build time.
  grep -q '368_kasm_logo_only' "${path}" ||
    die "${page} no longer references the stock Kasm favicons — this script needs updating."
  sed -i 's|<link rel="icon"[^>]*368_kasm_logo_only[^>]*>||g; s|<link rel="apple-touch-icon"[^>]*368_kasm_logo_only[^>]*>||g' "${path}"

  if grep -q '368_kasm_logo_only' "${path}"; then
    die "${page} still references a Kasm favicon after substitution."
  fi

  sed -i "s|</title>|</title><link rel=\"icon\" href=\"./assets/brand-logo.svg\" type=\"image/svg+xml\">|" "${path}"

  # KasmVNC only navigates to disconnected.html on an idle timeout; an ordinary
  # disconnect shows a status bar. Without this the session-ended page — and
  # the billing reminder on it — is never seen by anyone who logs out.
  grep -qF 'noVNC_disconnected' "${OUT}/assets/${UI_BUNDLE}" ||
    die "the bundle no longer sets the noVNC_disconnected class — the disconnect redirect needs updating."
  grep -qF 'noVNC_connected' "${OUT}/assets/${UI_BUNDLE}" ||
    die "the bundle no longer sets the noVNC_connected class — the disconnect redirect needs updating."
  sed -i "s|</body>|<script src=\"./assets/brand-disconnect.js\"></script></body>|" "${path}"
  grep -q 'brand-disconnect.js' "${path}" ||
    die "${page} has no </body> to attach the disconnect redirect to."

  # --- The control bar and the strings users actually read ----------------
  # Everything below lives in the entry page's own markup, NOT in the hashed
  # Vite bundle — which is why it is safe to touch. The control bar down the
  # left of the screen is built from this HTML: its header is an <h1> holding
  # Kasm's logo as an inline data: URI, wrapped in a link to kasmweb.com.
  #
  # There is exactly one <h1> in the document, so the bounded replacement below
  # cannot run away across the (single-line) file.
  grep -q '<h1 class="noVNC_logo">' "${path}" ||
    die "${page} no longer has the noVNC_logo header — KasmVNC changed its markup and this script needs updating."
  sed -i "s|<h1 class=\"noVNC_logo\">.*</h1>|<h1 class=\"noVNC_logo\"><a href=\"${BRAND_URL}\" target=\"_blank\" rel=\"noopener\" title=\"${BRAND_NAME}\"><img src=\"./assets/brand-logo.svg\" alt=\"${BRAND_NAME}\" style=\"height:2.5em\"></a></h1>|" "${path}"

  if grep -q 'kasmweb.com/kasmvnc"' "${path}"; then
    die "${page} still links to kasmweb.com from the control-bar logo after substitution."
  fi

  # Two more strings a user reads: the error box that appears whenever the
  # connection drops, and the keyboard-shortcuts toggle in the settings panel.
  # Both said "KasmVNC" in front of our users.
  for pair in \
    "KasmVNC encountered an error::${BRAND_NAME} encountered an error:" \
    "Enable KasmVNC Keyboard Shortcuts:Enable ${BRAND_NAME} Keyboard Shortcuts"
  do
    needle="${pair%%:*}"
    # Rebuild the replacement from the remainder so a ':' inside it survives.
    replacement="${pair#*:}"
    grep -qF "${needle}" "${path}" ||
      die "${page} no longer contains '${needle}' — KasmVNC changed its wording and this script needs updating."
    sed -i "s|${needle}|${replacement}|g" "${path}"
  done

  # Optional: point the Settings > Documentation link at your own help. Left
  # alone when brand.docsUrl is unset, because upstream's link goes to real
  # KasmVNC documentation for these very controls — a dead link of our own
  # would be worse than an honest outbound one.
  if [ -n "${BRAND_DOCS_URL}" ]; then
    sed -i "s|https://www.kasmweb.com/kasmvnc/docs/latest/index.html|${BRAND_DOCS_URL}|g" "${path}"
  fi
  # --- Runtime slot, LAST ---------------------------------------------------
  # This must come after every build-time edit above. The .in copy is what the
  # runtime renders index.html from, so anything patched after the copy is
  # taken would be silently thrown away at boot — which is exactly how the
  # branded control-bar logo disappeared the first time: the template still
  # held Kasm's.
  sed -i "s|</h1>|</h1><!--QGIS_DESKTOP_MANAGE_LINK_BAR-->|" "${path}"

  grep -q 'assets/brand-logo.svg' "${path}" ||
    die "${page} lost the brand logo before the template was captured — the runtime would restore Kasm's."

  # Ship the marked-up page as a template, and a copy with the marker removed
  # so the tree is valid served as-is. qgis-desktop-manage-link renders the
  # second from the first at boot, which is also what makes it idempotent.
  cp "${path}" "${path}.in"
  sed -i 's|<!--QGIS_DESKTOP_MANAGE_LINK_BAR-->||' "${path}"

  grep -q 'assets/brand-logo.svg' "${path}.in" ||
    die "${page}.in has no brand logo; the runtime render would undo the branding."

  patched_pages=$((patched_pages + 1))
  echo "  ${page}: title, favicon, control bar, error text"
done

[ "${patched_pages}" -gt 0 ] ||
  die "neither index.html nor vnc.html was found in ${SOURCE}."

# --- The pre-connection splash ----------------------------------------------
# The background KasmVNC shows before the desktop connects, and after it
# disconnects. It was Kasm's blue geometry, which is the first thing a user
# sees — so it is worth replacing even though it is a hashed asset.
#
# The filename carries a content hash and will change on a KasmVNC bump, so
# find it by shape rather than by name, and insist on exactly one: zero means
# they renamed it, more than one means the assumption is wrong. Either way the
# build should stop rather than quietly leave Kasm's artwork in place.
splash_count="$(find "${OUT}/assets" -maxdepth 1 -name 'splash-*.jpg' | wc -l)"
if [ "${splash_count}" -ne 1 ]; then
  die "expected exactly one assets/splash-*.jpg, found ${splash_count} — KasmVNC changed its asset layout and this script needs updating."
fi
splash_path="$(find "${OUT}/assets" -maxdepth 1 -name 'splash-*.jpg')"
cp "${SPLASH}" "${splash_path}"
chmod 0444 "${splash_path}"
echo "  $(basename "${splash_path}"): replaced with the brand splash"

# --- The disconnected page ----------------------------------------------
[ -f "${OUT}/disconnected.html" ] ||
  die "${SOURCE} has no disconnected.html — KasmVNC changed its layout and this script needs updating."

# Rendered by substitution rather than a heredoc so the template stays a real
# HTML file that can be opened, linted and previewed on its own.
sed \
  -e "s|@BRAND_NAME@|${BRAND_NAME}|g" \
  -e "s|@BRAND_URL@|${BRAND_URL}|g" \
  -e "s|@FONT_FAMILY@|${FONT_FAMILY}|g" \
  -e "s|@COLOR_ACCENT@|${COLOR_ACCENT}|g" \
  -e "s|@COLOR_ACCENT_HOVER@|${COLOR_ACCENT_HOVER}|g" \
  -e "s|@COLOR_SECONDARY@|${COLOR_SECONDARY}|g" \
  -e "s|@COLOR_MUTED@|${COLOR_MUTED}|g" \
  -e "s|@COLOR_SURFACE@|${COLOR_SURFACE}|g" \
  -e "s|@COLOR_SURFACE_RAISED@|${COLOR_SURFACE_RAISED}|g" \
  -e "s|@COLOR_TEXT@|${COLOR_TEXT}|g" \
  -e "s|@COLOR_TEXT_MUTED@|${COLOR_TEXT_MUTED}|g" \
  "${TEMPLATE}" > "${OUT}/disconnected.html"

# An unresolved placeholder means the template grew a token the script does not
# know about — visible as literal "@COLOR_...@" text on the page.
if grep -oE '@[A-Z_]+@' "${OUT}/disconnected.html" | head -1 | grep -q .; then
  die "disconnected.html still has unsubstituted placeholders: $(grep -oE '@[A-Z_]+@' "${OUT}/disconnected.html" | sort -u | tr '\n' ' ')"
fi
# The page carries a marker that only the runtime knows how to fill in (the
# management URL is a property of the deployment, not the image), so ship two
# files: the template with the marker intact, and a rendered page that is valid
# on its own. qgis-desktop-manage-link re-renders the second from the first at
# container start; anything serving this tree directly still gets a working
# page.
cp "${OUT}/disconnected.html" "${OUT}/disconnected.html.in"

DEFAULT_NOTICE='    <div class="notice">
      <p><strong>Your desktop is still running.</strong> Closing this tab does
      not stop it — it keeps running, and keeps costing you, until you shut it
      down from your hosting control panel.</p>
    </div>'
awk -v block="${DEFAULT_NOTICE}" '
  index($0, "<!--QGIS_DESKTOP_MANAGE_LINK-->") { print block; next }
  { print }
' "${OUT}/disconnected.html.in" > "${OUT}/disconnected.html"

grep -q 'Your desktop is still running' "${OUT}/disconnected.html" ||
  die "the cost reminder did not reach disconnected.html — is the marker still in the template?"
grep -qF '<!--QGIS_DESKTOP_MANAGE_LINK-->' "${OUT}/disconnected.html.in" ||
  die "disconnected.html.in lost its marker; the runtime would have nothing to fill in."

echo "  disconnected.html: rendered from template (+ .in for the runtime link)"

echo "Branded web root written to ${OUT}"

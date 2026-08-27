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

SOURCE="" TOKENS="" TEMPLATE="" LOGO="" FONT_REGULAR="" FONT_BOLD="" OUT=""

die() { echo "ERROR: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --source) SOURCE="${2:-}"; shift 2 ;;
    --tokens) TOKENS="${2:-}"; shift 2 ;;
    --template) TEMPLATE="${2:-}"; shift 2 ;;
    --logo) LOGO="${2:-}"; shift 2 ;;
    --font-regular) FONT_REGULAR="${2:-}"; shift 2 ;;
    --font-bold) FONT_BOLD="${2:-}"; shift 2 ;;
    --out) OUT="${2:-}"; shift 2 ;;
    *) die "unknown argument '$1'" ;;
  esac
done

for pair in \
  "SOURCE:--source" "TOKENS:--tokens" "TEMPLATE:--template" \
  "LOGO:--logo" "FONT_REGULAR:--font-regular" "FONT_BOLD:--font-bold" "OUT:--out"
do
  var="${pair%%:*}"
  flag="${pair#*:}"
  [ -n "${!var}" ] || die "${flag} is required."
done

[ -d "${SOURCE}" ] || die "--source ${SOURCE} is not a directory."
for f in "${TOKENS}" "${TEMPLATE}" "${LOGO}" "${FONT_REGULAR}" "${FONT_BOLD}"; do
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

echo "Branding the KasmVNC web root as '${BRAND_NAME}'"

# --- Copy the upstream tree ---------------------------------------------
mkdir -p "${OUT}"
cp -r "${SOURCE}/." "${OUT}/"
chmod -R u+w "${OUT}"

install -m 0444 "${LOGO}" "${OUT}/assets/brand-logo.svg"
install -m 0444 "${FONT_REGULAR}" "${OUT}/assets/brand-body.ttf"
install -m 0444 "${FONT_BOLD}" "${OUT}/assets/brand-body-bold.ttf"

# --- The entry pages -----------------------------------------------------
# vnc.html is byte-identical to index.html upstream, but both are served, so
# both are patched. A future release that drops one is not an error; a release
# that drops both is.
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

  patched_pages=$((patched_pages + 1))
  echo "  ${page}: title + favicon"
done

[ "${patched_pages}" -gt 0 ] ||
  die "neither index.html nor vnc.html was found in ${SOURCE}."

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
echo "  disconnected.html: rendered from template"

echo "Branded web root written to ${OUT}"

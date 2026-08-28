#!/usr/bin/env bash
# Renders the desktop wallpaper from config/branding/wallpaper.svg.in.
#
# Runs at BUILD time inside a nix derivation. The SVG is the source of truth and
# stays editable; the PNG is generated, because that is what xfdesktop, LightDM's
# greeter and feh all want, and because rasterising once at build time beats
# depending on an SVG loader being present at runtime.
#
# The same wallpaper is used in three places, which is why it is worth getting
# right: the XFCE desktop, the LightDM greeter background in greeter mode, and
# the X root window that shows for a few seconds while a session restarts.
#
#   qgis-desktop-brand-wallpaper --template FILE --tokens FILE --out FILE
#                                [--width N] [--height N]

set -euo pipefail

TEMPLATE="" TOKENS="" OUT="" WIDTH=1920 HEIGHT=1080

die() { echo "ERROR: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --template) TEMPLATE="${2:-}"; shift 2 ;;
    --tokens) TOKENS="${2:-}"; shift 2 ;;
    --out) OUT="${2:-}"; shift 2 ;;
    --width) WIDTH="${2:-}"; shift 2 ;;
    --height) HEIGHT="${2:-}"; shift 2 ;;
    *) die "unknown argument '$1'" ;;
  esac
done

[ -n "${TEMPLATE}" ] || die "--template is required."
[ -n "${TOKENS}" ] || die "--tokens is required."
[ -n "${OUT}" ] || die "--out is required."
[ -r "${TEMPLATE}" ] || die "${TEMPLATE} is not readable."
[ -r "${TOKENS}" ] || die "${TOKENS} is not readable."

case "${WIDTH}${HEIGHT}" in
  *[!0-9]*) die "--width and --height must be whole numbers." ;;
esac

tok() {
  local path="$1" value
  value="$(jq -r "${path} // empty" "${TOKENS}")"
  [ -n "${value}" ] || die "${TOKENS} is missing ${path}"
  printf '%s' "${value}"
}

BRAND_NAME="$(tok '.brand.name')"
TAGLINE="$(jq -r '.brand.tagline // ""' "${TOKENS}")"
FONT_FAMILY="$(tok '.font.family')"
ACCENT="$(tok '.color.accent')"
SECONDARY="$(tok '.color.secondary')"
MUTED="$(tok '.color.muted')"
BG_TOP="$(tok '.wallpaper.bgTop')"
BG_BOTTOM="$(tok '.wallpaper.bgBottom')"
GLOW="$(tok '.wallpaper.glow')"
WORDMARK="$(tok '.wallpaper.wordmark')"

# Colours go straight into SVG fill attributes; a malformed one would be
# silently ignored by the renderer and produce a black shape.
for name in ACCENT SECONDARY MUTED BG_TOP BG_BOTTOM GLOW WORDMARK; do
  case "${!name}" in
    '#'[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]) : ;;
    *) die "${name} = '${!name}' is not a #rrggbb hex literal." ;;
  esac
done

# Text lands inside an XML text node, so the five predefined entities have to be
# escaped or the SVG will not parse.
xml_escape() {
  printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' \
    -e "s/'/\&apos;/g" -e 's/"/\&quot;/g'
}

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
SVG="${WORK}/wallpaper.svg"

sed \
  -e "s|@BRAND_NAME@|$(xml_escape "${BRAND_NAME}")|g" \
  -e "s|@TAGLINE@|$(xml_escape "${TAGLINE}")|g" \
  -e "s|@FONT_FAMILY@|$(xml_escape "${FONT_FAMILY}")|g" \
  -e "s|@ACCENT@|${ACCENT}|g" \
  -e "s|@SECONDARY@|${SECONDARY}|g" \
  -e "s|@MUTED@|${MUTED}|g" \
  -e "s|@BG_TOP@|${BG_TOP}|g" \
  -e "s|@BG_BOTTOM@|${BG_BOTTOM}|g" \
  -e "s|@GLOW@|${GLOW}|g" \
  -e "s|@WORDMARK@|${WORDMARK}|g" \
  "${TEMPLATE}" > "${SVG}"

if grep -oE '@[A-Z_]+@' "${SVG}" | head -1 | grep -q .; then
  die "unsubstituted placeholders remain: $(grep -oE '@[A-Z_]+@' "${SVG}" | sort -u | tr '\n' ' ')"
fi

rsvg-convert --width "${WIDTH}" --height "${HEIGHT}" \
  --format png --output "${OUT}" "${SVG}" ||
  die "rsvg-convert failed to render ${SVG}"

[ -s "${OUT}" ] || die "${OUT} was written but is empty."
echo "Wallpaper rendered: ${OUT} (${WIDTH}x${HEIGHT}, ${BRAND_NAME})"

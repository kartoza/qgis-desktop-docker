#!/usr/bin/env bash
# Renders the "your desktop is still running" notice into the session-ended
# page, at container start.
#
# Runs as ROOT from entrypoint.sh, before privileges are dropped, because the
# branded web root lives under /usr/share.
#
# Why this cannot happen at build time: the management URL is a property of the
# deployment, not of the image. One image serves many customers, and each needs
# a link back to their own control panel. So the build ships a template with a
# marker in it, and this fills the marker in from the environment.
#
# The reminder itself is shown whether or not a URL is configured. A
# disconnected session is exactly the moment someone assumes they are finished
# and walks away from a machine that is still costing them money; saying so is
# worth more than the link is.
#
#   QGIS_DESKTOP_MANAGE_URL    Where "Manage my desktops" points. Unset means
#                              the reminder is shown with no button.
#   QGIS_DESKTOP_MANAGE_LABEL  Button text. Defaults to "Manage my desktops".
#   QGIS_DESKTOP_BRANDED_WWW   Web root to patch.

set -uo pipefail

WWW="${QGIS_DESKTOP_BRANDED_WWW:-/usr/share/qgis-desktop/www}"
URL="${QGIS_DESKTOP_MANAGE_URL:-}"
LABEL="${QGIS_DESKTOP_MANAGE_LABEL:-Manage my desktops}"
URL_REJECTED=0
MARKER='<!--QGIS_DESKTOP_MANAGE_LINK-->'

log() { printf '[manage-link] %s\n' "$*"; }
warn() { printf '[manage-link] WARN: %s\n' "$*" >&2; }

TEMPLATE="${WWW}/disconnected.html.in"
TARGET="${WWW}/disconnected.html"

# No branded web root (branding turned off, or a bind-mounted tree of someone
# else's making) is not an error — there is simply nothing of ours to patch.
if [ ! -r "${TEMPLATE}" ]; then
  log "no ${TEMPLATE}; nothing to do"
  exit 0
fi

# Render from the pristine template every boot rather than editing in place, so
# this is idempotent and a restart cannot double-insert the notice.
if [ ! -w "${WWW}" ]; then
  warn "${WWW} is not writable; leaving the session-ended page as built."
  exit 0
fi

# HTML-escape anything that lands in markup or an attribute.
html_escape() {
  printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'
}

if [ -n "${URL}" ]; then
  case "${URL}" in
    http://* | https://*) : ;;
    *)
      warn "QGIS_DESKTOP_MANAGE_URL='${URL}' must start with http:// or https://."
      warn "Showing the reminder without a button rather than emitting a broken link."
      URL=""
      URL_REJECTED=1
      ;;
  esac
fi

SAFE_URL="$(html_escape "${URL}")"
SAFE_LABEL="$(html_escape "${LABEL}")"

if [ -n "${URL}" ]; then
  BLOCK="$(cat <<HTML
    <div class="notice">
      <p><strong>Your desktop is still running.</strong> Closing this tab does
      not stop it — it keeps running, and keeps costing you, until you shut it
      down.</p>
      <a class="btn btn-primary" href="${SAFE_URL}">${SAFE_LABEL}</a>
    </div>
HTML
  )"
  log "manage link: ${URL}"
else
  BLOCK="$(cat <<HTML
    <div class="notice">
      <p><strong>Your desktop is still running.</strong> Closing this tab does
      not stop it — it keeps running, and keeps costing you, until you shut it
      down from your hosting control panel.</p>
    </div>
HTML
  )"
  if [ "${URL_REJECTED}" = "1" ]; then
    log "the configured URL was rejected; showing the reminder without a button"
  else
    log "no QGIS_DESKTOP_MANAGE_URL set; showing the reminder without a button"
  fi
fi

TMP="$(mktemp)"
# awk rather than sed: the replacement is multi-line HTML, which sed makes
# needlessly painful to escape.
awk -v marker="${MARKER}" -v block="${BLOCK}" '
  index($0, marker) { print block; next }
  { print }
' "${TEMPLATE}" > "${TMP}" || { warn "could not render ${TARGET}"; rm -f "${TMP}"; exit 0; }

if grep -qF "${MARKER}" "${TMP}"; then
  warn "the marker survived substitution; leaving the page as built."
  rm -f "${TMP}"
  exit 0
fi

chmod 0444 "${TMP}"
mv -f "${TMP}" "${TARGET}" || { warn "could not write ${TARGET}"; exit 0; }
log "session-ended page updated"

# --- The control bar --------------------------------------------------------
# Same link, in the panel down the left of the screen, so it is reachable while
# the user is still working rather than only once they have disconnected.
# Styled inline rather than with a Kasm class: the class names live in a bundle
# whose contents change between releases, and inline styling cannot go stale.
BAR_MARKER='<!--QGIS_DESKTOP_MANAGE_LINK_BAR-->'
if [ -n "${URL}" ]; then
  BAR_BLOCK="<a href=\"${SAFE_URL}\" target=\"_blank\" rel=\"noopener\" title=\"${SAFE_LABEL}\" style=\"display:block;margin:6px 8px 10px;padding:7px 10px;border-radius:6px;background:#ECB44B;color:#2B2B2B;font:700 12px/1.2 sans-serif;text-align:center;text-decoration:none\">${SAFE_LABEL}</a>"
else
  BAR_BLOCK=""
fi

for page in index.html vnc.html; do
  src="${WWW}/${page}.in"
  [ -r "${src}" ] || continue
  tmp="$(mktemp)"
  awk -v marker="${BAR_MARKER}" -v block="${BAR_BLOCK}" '
    { gsub(marker, block); print }
  ' "${src}" > "${tmp}" || { warn "could not render ${page}"; rm -f "${tmp}"; continue; }
  if grep -qF "${BAR_MARKER}" "${tmp}"; then
    warn "${page}: the control-bar marker survived substitution; leaving it as built."
    rm -f "${tmp}"
    continue
  fi
  chmod 0444 "${tmp}"
  mv -f "${tmp}" "${WWW}/${page}" || warn "could not write ${page}"
done

if [ -n "${URL}" ]; then
  log "control bar link added to the entry pages"
fi

#!/usr/bin/env bash
# Launch QGIS automatically when the desktop session starts.
#
# Runs as the DESKTOP USER, from whichever path brought the session up:
# start-desktop.sh in basic/none mode, or LightDM's Xsession in greeter mode.
# Both end in a full XFCE session, and XFCE honours the XDG autostart spec — so
# writing one .desktop file covers every mode without touching the session
# scripts themselves.
#
# Idempotent in both directions: with the flag off it removes the file it
# previously wrote, so turning the feature off actually turns it off, including
# on a home directory restored from object storage with the file still in it.
#
# It deliberately does NOT write a file it did not author. A user who creates
# their own autostart entry for QGIS keeps it.

set -uo pipefail

ENABLED="${QGIS_DESKTOP_AUTOSTART_QGIS:-0}"
EXTRA_ARGS="${QGIS_DESKTOP_AUTOSTART_QGIS_ARGS:-}"
AUTOSTART_DIR="${QGIS_DESKTOP_AUTOSTART_DIR:-${HOME}/.config/autostart}"
ENTRY="${AUTOSTART_DIR}/qgis-desktop-autostart.desktop"

# Stamped into the file so we can tell our own entry from a user's.
MARKER="X-QGIS-Desktop-Generated=true"

log() { printf '[autostart] %s\n' "$*"; }

to_bool() {
  case "${1,,}" in
    1 | yes | true | on | enabled) echo 1 ;;
    *) echo 0 ;;
  esac
}

if [ "$(to_bool "${ENABLED}")" != "1" ]; then
  # Only remove what we wrote.
  if [ -f "${ENTRY}" ] && grep -q "^${MARKER}$" "${ENTRY}" 2>/dev/null; then
    rm -f "${ENTRY}"
    log "QGIS autostart disabled — removed ${ENTRY}"
  fi
  exit 0
fi

if ! command -v qgis >/dev/null 2>&1; then
  echo "[autostart] WARN: QGIS_DESKTOP_AUTOSTART_QGIS is on but qgis is not on PATH." >&2
  exit 0
fi

mkdir -p "${AUTOSTART_DIR}" || {
  echo "[autostart] WARN: could not create ${AUTOSTART_DIR}" >&2
  exit 0
}

# Exec= is a single line, so a newline in the arguments would silently truncate
# the command — and anything after it would be parsed as a new key.
EXEC_ARGS="${EXTRA_ARGS//$'\n'/ }"

cat > "${ENTRY}" <<ENTRY_EOF
[Desktop Entry]
Type=Application
Version=1.0
Name=QGIS
Comment=Started automatically by QGIS_DESKTOP_AUTOSTART_QGIS
Exec=qgis ${EXEC_ARGS}
Terminal=false
X-GNOME-Autostart-enabled=true
${MARKER}
ENTRY_EOF

chmod 0644 "${ENTRY}"

if [ -n "${EXEC_ARGS}" ]; then
  log "QGIS will start with the session: qgis ${EXEC_ARGS}"
else
  log "QGIS will start with the session"
fi

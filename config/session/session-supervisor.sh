#!/usr/bin/env bash
# Session supervisor for the KasmVNC desktop paths (basic / none, and the
# inner mode of oidc).
#
# Runs as the DESKTOP USER, wrapping the XFCE session so that an exit is not
# the end of the container's usefulness. Before this existed, start-desktop.sh
# launched the session once and then waited on the X server: when the user
# picked "Log Out" from the XFCE menu, the session died and Xkasmvnc stayed
# up, leaving the browser looking at a bare X root window with no panel, no
# menu and no way back. Only a container restart recovered it. An XFCE crash
# had exactly the same effect.
#
# LightDM does this job itself in greeter mode, which is why that path does
# not use this script.
#
#   qgis-desktop-session <command> [args...]
#
# Environment:
#   QGIS_DESKTOP_SESSION_RESTART         1 (default) to relaunch on exit, 0 for
#                                        the old run-once behaviour.
#   QGIS_DESKTOP_SESSION_RESTART_MAX     Restarts tolerated inside the window
#                                        before giving up (default 5).
#   QGIS_DESKTOP_SESSION_RESTART_WINDOW  Width of that window, in seconds
#                                        (default 60).
#   QGIS_DESKTOP_SESSION_RESTART_DELAY   Seconds to pause between restarts
#                                        (default 1).
#   QGIS_DESKTOP_SESSION_RESET_STATE     1 (default) to drop the saved-session
#                                        cache between runs, 0 to keep it.
#   QGIS_DESKTOP_SESSION_GUARD_PID       Optional pid — usually the X server's.
#                                        The loop stops once it is gone, so a
#                                        dying X server does not leave us
#                                        respawning sessions into nothing.
#
# Exits with the status of the last session run.

set -uo pipefail

RESTART="${QGIS_DESKTOP_SESSION_RESTART:-1}"
RESTART_MAX="${QGIS_DESKTOP_SESSION_RESTART_MAX:-5}"
RESTART_WINDOW="${QGIS_DESKTOP_SESSION_RESTART_WINDOW:-60}"
RESTART_DELAY="${QGIS_DESKTOP_SESSION_RESTART_DELAY:-1}"
RESET_STATE="${QGIS_DESKTOP_SESSION_RESET_STATE:-1}"
GUARD_PID="${QGIS_DESKTOP_SESSION_GUARD_PID:-}"

log() { printf '[session] %s\n' "$*"; }
warn() { printf '[session] WARN: %s\n' "$*" >&2; }

to_bool() {
  case "${1,,}" in
    1 | yes | true | on | enabled) echo 1 ;;
    *) echo 0 ;;
  esac
}

# A non-numeric limit would make the arithmetic below silently misbehave, and
# the failure mode (no crash-loop guard at all) is the one worth catching.
to_uint() {
  local value="$1" fallback="$2" name="$3"
  case "${value}" in
    '' | *[!0-9]*)
      warn "${name}='${value}' is not a whole number; using ${fallback}."
      echo "${fallback}"
      ;;
    *) echo "${value}" ;;
  esac
}

if [ "$#" -eq 0 ]; then
  echo "usage: qgis-desktop-session <command> [args...]" >&2
  exit 2
fi

RESTART="$(to_bool "${RESTART}")"
RESET_STATE="$(to_bool "${RESET_STATE}")"
RESTART_MAX="$(to_uint "${RESTART_MAX}" 5 QGIS_DESKTOP_SESSION_RESTART_MAX)"
RESTART_WINDOW="$(to_uint "${RESTART_WINDOW}" 60 QGIS_DESKTOP_SESSION_RESTART_WINDOW)"
RESTART_DELAY="$(to_uint "${RESTART_DELAY}" 1 QGIS_DESKTOP_SESSION_RESTART_DELAY)"

# Forward a shutdown to the running session rather than orphaning it — the
# container is being stopped and XFCE should get the chance to exit cleanly.
SESSION_PID=""
# shellcheck disable=SC2329  # invoked from the traps below, which shellcheck
# does not trace. writeShellApplication treats even info-level findings as
# fatal, so this directive is load-bearing: without it the image does not build.
forward_signal() {
  RESTART=0
  [ -n "${SESSION_PID}" ] && kill "-$1" "${SESSION_PID}" 2>/dev/null
  return 0
}
trap 'forward_signal TERM' TERM
trap 'forward_signal INT' INT
trap 'forward_signal HUP' HUP

# XFCE writes the "restore my windows next time" cache here. Wiping it between
# runs is what makes a log-out mean a *clean* desktop: without it the next
# person to reach this container — which under SSO may genuinely be a
# different person on the same shared URL — is handed back the previous
# session's open windows. It is a cache directory, so removing it costs
# nothing but the restore.
reset_session_state() {
  [ "${RESET_STATE}" = "1" ] || return 0
  local cache="${HOME:-}/.cache/sessions"
  [ -n "${HOME:-}" ] && [ -d "${cache}" ] || return 0
  rm -rf -- "${cache}" 2>/dev/null ||
    warn "could not clear ${cache}; the next session may restore old windows."
  return 0
}

guard_alive() {
  [ -z "${GUARD_PID}" ] && return 0
  kill -0 "${GUARD_PID}" 2>/dev/null
}

restarts=0
window_start="$(date +%s)"
status=0

while :; do
  "$@" &
  SESSION_PID=$!
  wait "${SESSION_PID}"
  status=$?
  SESSION_PID=""

  [ "${RESTART}" = "1" ] || break

  if ! guard_alive; then
    log "X server (pid ${GUARD_PID}) is gone — not restarting the session."
    break
  fi

  now="$(date +%s)"
  if [ "$((now - window_start))" -gt "${RESTART_WINDOW}" ]; then
    restarts=0
    window_start="${now}"
  fi
  restarts=$((restarts + 1))

  if [ "${restarts}" -gt "${RESTART_MAX}" ]; then
    warn "the session exited ${restarts} times in under ${RESTART_WINDOW}s — giving up."
    warn "Something is wrong with the desktop session itself; restarting it again"
    warn "would only spin. Check the log above, then restart the container."
    break
  fi

  log "session exited (status ${status}) — restarting (${restarts}/${RESTART_MAX} in this ${RESTART_WINDOW}s window)."
  reset_session_state
  [ "${RESTART_DELAY}" -gt 0 ] && sleep "${RESTART_DELAY}"
done

exit "${status}"

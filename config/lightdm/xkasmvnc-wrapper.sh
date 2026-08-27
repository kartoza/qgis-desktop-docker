#!/usr/bin/env bash
# LightDM xserver-command wrapper for QGIS_DESKTOP_AUTH_MODE=greeter.
#
# LightDM invokes its xserver-command with args like:
#   :1 -auth /var/run/lightdm/root/:1 -nolisten tcp -novtswitch
#
# We must run Xkasmvnc (which IS the X server) with our web/DLP/clipboard
# flags, while accepting LightDM's :DISPLAY and -auth flags and dropping the
# ones that conflict with Xkasmvnc's networking model (-nolisten tcp,
# -novtswitch).
#
# Because LightDM is the parent, HTTP BasicAuth on the web endpoint is
# always disabled here — the greeter is the auth boundary.

set -euo pipefail

# LightDM redirects our stderr to /var/log/lightdm/x-0.log which is
# invisible to `docker logs` when the container is --rm'd on failure.
# Also send diagnostics to PID 1's stderr so they reach the docker log.
wlog() {
  echo "xkasmvnc-wrapper: $*" >&2
  echo "xkasmvnc-wrapper: $*" > /proc/1/fd/2 2>/dev/null || true
}

# Extract the display arg (":1") and any "-auth <file>" pair from LightDM's
# invocation. LightDM typically calls us as:
#   xkasmvnc-wrapper :1 -config /path -auth /path -nolisten tcp -novtswitch -background none
# Xkasmvnc takes its own equivalents so we drop everything except the display
# and the auth file.
ORIG_ARGS="$*"
DISPLAY_ARG=""
AUTH_FILE=""

while [ $# -gt 0 ]; do
  case "$1" in
    :*)
      DISPLAY_ARG="$1"
      shift
      ;;
    -auth)
      AUTH_FILE="${2:-}"
      shift 2
      ;;
    -config|-nolisten|-background|-verbose)
      # Value-bearing flags LightDM passes that Xkasmvnc doesn't understand.
      shift 2 2>/dev/null || shift
      ;;
    -novtswitch|-noreset|-terminate)
      # Flag-only args to drop.
      shift
      ;;
    *)
      shift
      ;;
  esac
done

DISPLAY_ARG="${DISPLAY_ARG:-${DISPLAY:-:1}}"

# Kasm permission controls (same env-var contract as start-desktop.sh —
# secure-by-default: clipboard off in both directions).
VNC_PORT="${VNC_PORT:-8443}"
VNC_RESOLUTION="${VNC_RESOLUTION:-1280x720}"
VNC_COL_DEPTH="${VNC_COL_DEPTH:-24}"
QGIS_DESKTOP_BIND_INTERFACE="${QGIS_DESKTOP_BIND_INTERFACE:-0.0.0.0}"

# LightDM spawns the X server with a scrubbed environment, so the entrypoint's
# exports never reach us. In QGIS_DESKTOP_AUTH_MODE=oidc it also writes the listener
# override to a file, which is the only channel that survives — without this,
# Xkasmvnc would try to bind the public port that the OIDC proxy already owns.
# Parsed key by key rather than sourced: root writes it, we are not root, and
# sourcing would turn it into an arbitrary-code channel.
QGIS_DESKTOP_LISTEN_ENV="${QGIS_DESKTOP_LISTEN_ENV:-/run/qgis-desktop/listen.env}"
if [ -r "${QGIS_DESKTOP_LISTEN_ENV}" ]; then
  while IFS='=' read -r _key _value; do
    case "${_key}" in
      VNC_PORT) VNC_PORT="${_value}" ;;
      QGIS_DESKTOP_BIND_INTERFACE) QGIS_DESKTOP_BIND_INTERFACE="${_value}" ;;
      *) : ;;
    esac
  done < "${QGIS_DESKTOP_LISTEN_ENV}"
fi

KASM_ALLOW_CLIPBOARD_IN="${KASM_ALLOW_CLIPBOARD_IN:-0}"
KASM_ALLOW_CLIPBOARD_OUT="${KASM_ALLOW_CLIPBOARD_OUT:-0}"
KASM_ALLOW_PRIMARY_SELECTION="${KASM_ALLOW_PRIMARY_SELECTION:-0}"
KASM_CLIPBOARD_IN_MAX="${KASM_CLIPBOARD_IN_MAX:-0}"
KASM_CLIPBOARD_OUT_MAX="${KASM_CLIPBOARD_OUT_MAX:-0}"
KASM_CLIPBOARD_DELAY_MS="${KASM_CLIPBOARD_DELAY_MS:-0}"
KASM_CLIPBOARD_MIME_TYPES="${KASM_CLIPBOARD_MIME_TYPES:-}"
KASM_WATERMARK_TEXT="${KASM_WATERMARK_TEXT:-}"
KASM_DLP_LOG="${KASM_DLP_LOG:-off}"

to_bool() {
  case "${1,,}" in
    1|yes|true|on|enabled) echo 1 ;;
    *) echo 0 ;;
  esac
}

CLIP_IN=$(to_bool "${KASM_ALLOW_CLIPBOARD_IN}")
CLIP_OUT=$(to_bool "${KASM_ALLOW_CLIPBOARD_OUT}")
CLIP_PRIMARY=$(to_bool "${KASM_ALLOW_PRIMARY_SELECTION}")

case "${KASM_DLP_LOG,,}" in
  off|info|verbose) DLP_LOG="${KASM_DLP_LOG,,}" ;;
  *) DLP_LOG="off" ;;
esac

DLP_ARGS=(
  -SendCutText       "${CLIP_OUT}"
  -AcceptCutText     "${CLIP_IN}"
  -SendPrimary       "${CLIP_PRIMARY}"
  -DLP_ClipSendMax   "${KASM_CLIPBOARD_OUT_MAX}"
  -DLP_ClipAcceptMax "${KASM_CLIPBOARD_IN_MAX}"
  -DLP_ClipDelay     "${KASM_CLIPBOARD_DELAY_MS}"
  -DLP_Log           "${DLP_LOG}"
)
if [ -n "${KASM_CLIPBOARD_MIME_TYPES}" ]; then
  DLP_ARGS+=(-DLP_ClipTypes "${KASM_CLIPBOARD_MIME_TYPES}")
fi
if [ -n "${KASM_WATERMARK_TEXT}" ]; then
  # In greeter mode the watermark's $USER placeholder is expanded to the
  # first materialised account (populated by entrypoint.sh); if none was
  # picked up, fall back to "user".
  WATERMARK_USER="${QGIS_DESKTOP_GREETER_FIRST_USER:-user}"
  KASM_WATERMARK_TEXT="${KASM_WATERMARK_TEXT//\$\{USER\}/${WATERMARK_USER}}"
  KASM_WATERMARK_TEXT="${KASM_WATERMARK_TEXT//\$USER/${WATERMARK_USER}}"
  DLP_ARGS+=(-DLP_WatermarkText "${KASM_WATERMARK_TEXT}")
fi

wlog "invoked with args: $ORIG_ARGS"
XKASMVNC_BIN="$(command -v Xkasmvnc || true)"
if [ -z "${XKASMVNC_BIN}" ]; then
  wlog "ERROR: Xkasmvnc not on PATH (PATH=${PATH})"
  exit 1
fi
WWW_DIR="$(dirname "${XKASMVNC_BIN}")/../share/kasmvnc/www"
if [ ! -d "${WWW_DIR}" ]; then
  wlog "ERROR: WWW_DIR ${WWW_DIR} does not exist"
  exit 1
fi

# Same branded web root as start-desktop.sh. LightDM scrubs the environment
# before spawning us, so QGIS_DESKTOP_BRANDING never survives to here — the
# fixed path is the only channel, which is exactly why the image copies the
# files in rather than symlinking them into the nix store.
QGIS_DESKTOP_BRANDED_WWW="${QGIS_DESKTOP_BRANDED_WWW:-/usr/share/qgis-desktop/www}"
if [ "$(to_bool "${QGIS_DESKTOP_BRANDING:-1}")" = "1" ] &&
   [ -f "${QGIS_DESKTOP_BRANDED_WWW}/index.html" ]; then
  WWW_DIR="${QGIS_DESKTOP_BRANDED_WWW}"
fi

# Lightdm strips most env vars when spawning children, so XKB_BASE_DIR
# (set as an image env var) doesn't survive. Fall back to a fixed path
# symlinked into the image via fakeRootCommands.
XKB_DIR="${XKB_BASE_DIR:-/usr/share/X11/xkb}"

wlog "display=${DISPLAY_ARG} auth=${AUTH_FILE:-<none>} bin=${XKASMVNC_BIN} www=${WWW_DIR} xkb=${XKB_DIR}"
wlog "listening on ${QGIS_DESKTOP_BIND_INTERFACE}:${VNC_PORT}"

# Route Xkasmvnc's stderr through PID 1 so its own failure messages reach
# docker logs, not just /var/log/lightdm/x-0.log (which vanishes with --rm).
if [ -w /proc/1/fd/2 ]; then
  exec 2>/proc/1/fd/2
fi

# Xvnc/Xkasmvnc doesn't send SIGUSR1 to its parent when ready — lightdm
# waits forever. We synthesise it ourselves. Critical detail: lightdm's
# Process class only accepts the signal if the sender PID matches the
# tracked xserver PID, which is our shell's PID ($$). So we CAN'T exec
# into Xkasmvnc (that'd swap our identity too late); instead we
# background it, watch for the display socket, then send the signal from
# our own PID.
LIGHTDM_PID="$PPID"
DISPLAY_NUM="${DISPLAY_ARG#:}"

XKASMVNC_PID=""
forward_signal() {
  [ -n "${XKASMVNC_PID}" ] && kill "$1" "${XKASMVNC_PID}" 2>/dev/null || true
}
trap 'forward_signal TERM; exit 0' TERM
trap 'forward_signal INT;  exit 0' INT
trap 'forward_signal HUP;  exit 0' HUP

# Ensure clean slate for the X display socket / lock (LightDM may have left
# stale files if the previous X server crashed).
DISPLAY_NUM="${DISPLAY_ARG#:}"
rm -f "/tmp/.X${DISPLAY_NUM}-lock" "/tmp/.X11-unix/X${DISPLAY_NUM}"

"${XKASMVNC_BIN}" "${DISPLAY_ARG}" \
  -geometry "${VNC_RESOLUTION}" \
  -depth "${VNC_COL_DEPTH}" \
  -websocketPort "${VNC_PORT}" \
  -interface "${QGIS_DESKTOP_BIND_INTERFACE}" \
  -SecurityTypes None \
  -DisableBasicAuth \
  -RawKeyboard \
  -AlwaysShared \
  -httpd "${WWW_DIR}" \
  ${AUTH_FILE:+-auth "${AUTH_FILE}"} \
  -nopn \
  -publicIP 127.0.0.1 \
  -xkbdir "${XKB_DIR}" \
  "${DLP_ARGS[@]}" \
  +extension GLX \
  +extension RANDR \
  +extension RENDER &
XKASMVNC_PID=$!

# Poll for the display socket, then signal lightdm from our PID (which
# is the one lightdm tracks as the xserver PID — signals from any other
# PID are dropped).
for _ in $(seq 1 200); do
  if [ -S "/tmp/.X11-unix/X${DISPLAY_NUM}" ]; then
    wlog "X socket ready, signalling lightdm PID=${LIGHTDM_PID} from PID=$$"
    kill -USR1 "${LIGHTDM_PID}" 2>/dev/null || true
    break
  fi
  sleep 0.1
done

# Stay resident so lightdm's tracked PID is alive; forward its exit code.
wait "${XKASMVNC_PID}"
exit $?

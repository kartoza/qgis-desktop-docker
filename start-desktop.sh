#!/usr/bin/env bash
# Startup script for KasmVNC + XFCE desktop
# Drives Xkasmvnc directly instead of the kasmvncserver perl wrapper

set -euo pipefail

VNC_PORT="${VNC_PORT:-8443}"
VNC_RESOLUTION="${VNC_RESOLUTION:-1280x720}"
VNC_COL_DEPTH="${VNC_COL_DEPTH:-24}"
DISPLAY="${DISPLAY:-:1}"
VNC_USER="${VNC_USER:-user}"
VNC_PW="${VNC_PW:-password}"
DISPLAY_NUM="${DISPLAY#:}"

# Kasm permission controls (secure-by-default).
# See README.md ("Kasm permission controls") for the full matrix.
# Clipboard is OFF in both directions unless explicitly enabled.
KASM_ALLOW_CLIPBOARD_IN="${KASM_ALLOW_CLIPBOARD_IN:-0}"    # paste local → container
KASM_ALLOW_CLIPBOARD_OUT="${KASM_ALLOW_CLIPBOARD_OUT:-0}"  # copy container → local
KASM_ALLOW_PRIMARY_SELECTION="${KASM_ALLOW_PRIMARY_SELECTION:-0}"  # X middle-click paste
KASM_CLIPBOARD_IN_MAX="${KASM_CLIPBOARD_IN_MAX:-0}"        # bytes; 0 = unlimited
KASM_CLIPBOARD_OUT_MAX="${KASM_CLIPBOARD_OUT_MAX:-0}"      # bytes; 0 = unlimited
KASM_CLIPBOARD_DELAY_MS="${KASM_CLIPBOARD_DELAY_MS:-0}"    # anti-spam delay; 0 = none
KASM_CLIPBOARD_MIME_TYPES="${KASM_CLIPBOARD_MIME_TYPES:-}" # comma-sep MIME allowlist
KASM_WATERMARK_TEXT="${KASM_WATERMARK_TEXT:-}"             # empty = no watermark
KASM_DLP_LOG="${KASM_DLP_LOG:-off}"                        # off | info | verbose

# Authentication controls (tri-state as of 1.4.0; legacy KASM_AUTH still honoured).
#   KASM_AUTH_MODE=basic (default) — HTTP BasicAuth on the web endpoint + VncAuth on RFB.
#   KASM_AUTH_MODE=none            — no auth (dev only; never expose to the network).
#   KASM_AUTH_MODE=greeter         — handled by the root entrypoint; start-desktop
#                                     is not invoked in that mode.
# Credentials come from (in order): KASM_USERS_FILE if readable, else KASM_USERS
# env var, else legacy single-user VNC_USER / VNC_PW.
#   KASM_USERS_FILE — path to a file with one 'user:password' per line, '#' comments.
#   KASM_USERS      — inline 'user1:pw1,user2:pw2' (comma or newline separated).
KASM_AUTH_MODE="${KASM_AUTH_MODE:-}"
case "${KASM_AUTH_MODE,,}" in
  none)    KASM_AUTH="0" ;;
  basic)   KASM_AUTH="1" ;;
  greeter)
    echo "ERROR: start-desktop invoked with KASM_AUTH_MODE=greeter — the root" >&2
    echo "       entrypoint should have execed lightdm instead." >&2
    exit 1
    ;;
  "")      : ;;  # No mode override — fall back to legacy KASM_AUTH.
  *)
    echo "ERROR: KASM_AUTH_MODE='${KASM_AUTH_MODE}' is not one of none|basic|greeter." >&2
    exit 1
    ;;
esac
KASM_AUTH="${KASM_AUTH:-1}"
KASM_USERS_FILE="${KASM_USERS_FILE:-/etc/kasmvnc/users}"
KASM_USERS="${KASM_USERS:-}"

export DISPLAY

# Normalise 1/yes/true/on to "1", anything else to "0".
kasm_bool() {
  case "${1,,}" in
    1|yes|true|on|enabled) echo 1 ;;
    *) echo 0 ;;
  esac
}

CLIP_IN=$(kasm_bool "${KASM_ALLOW_CLIPBOARD_IN}")
CLIP_OUT=$(kasm_bool "${KASM_ALLOW_CLIPBOARD_OUT}")
CLIP_PRIMARY=$(kasm_bool "${KASM_ALLOW_PRIMARY_SELECTION}")

case "${KASM_DLP_LOG,,}" in
  off|info|verbose) DLP_LOG="${KASM_DLP_LOG,,}" ;;
  *)
    echo "WARN: KASM_DLP_LOG='${KASM_DLP_LOG}' is not one of off|info|verbose; defaulting to 'off'."
    DLP_LOG="off"
    ;;
esac

echo "=== Starting XFCE Desktop with KasmVNC ==="
echo "Display:    ${DISPLAY}"
echo "Resolution: ${VNC_RESOLUTION}"
echo "Web port:   ${VNC_PORT}"
echo "Clipboard:  in=${CLIP_IN} out=${CLIP_OUT} primary=${CLIP_PRIMARY} delay=${KASM_CLIPBOARD_DELAY_MS}ms"
echo "DLP:        log=${DLP_LOG} watermark=$([ -n "${KASM_WATERMARK_TEXT}" ] && echo on || echo off)"

# Create runtime directories
mkdir -p /tmp/runtime-user
mkdir -p /tmp/.X11-unix
mkdir -p "$HOME/.vnc"
mkdir -p "$HOME/.config/xfce4"
export XDG_RUNTIME_DIR=/tmp/runtime-user

# Wipe any stale X server lock or socket left over from a previous crashed run.
# Without this the container thrashes: docker restarts it, but /tmp survives
# and Xkasmvnc refuses to start with "Server is already active for display N".
rm -f "/tmp/.X${DISPLAY_NUM}-lock" "/tmp/.X11-unix/X${DISPLAY_NUM}"

AUTH_ENABLED=$(kasm_bool "${KASM_AUTH}")
KASM_AUTH_ARGS=()

if [ "${AUTH_ENABLED}" = "1" ]; then
  # Resolve credentials source: file wins, then env, then legacy single-user.
  if [ -r "${KASM_USERS_FILE}" ]; then
    USER_LINES="$(grep -vE '^\s*(#|$)' "${KASM_USERS_FILE}" || true)"
    CRED_SOURCE="file ${KASM_USERS_FILE}"
  elif [ -n "${KASM_USERS}" ]; then
    USER_LINES="$(printf '%s\n' "${KASM_USERS}" | tr ',' '\n' | sed '/^\s*$/d')"
    CRED_SOURCE="KASM_USERS env"
  else
    USER_LINES="${VNC_USER}:${VNC_PW}"
    CRED_SOURCE="legacy VNC_USER/VNC_PW"
  fi

  # Wipe any stale password file so removed users can't sign in.
  rm -f "$HOME/.kasmpasswd"

  user_count=0
  while IFS= read -r line; do
    [ -z "${line}" ] && continue
    if [[ "${line}" != *:* ]]; then
      echo "WARN: skipping malformed auth line (no ':'): '${line}'"
      continue
    fi
    u="${line%%:*}"
    p="${line#*:}"
    if [ -z "${u}" ] || [ -z "${p}" ]; then
      echo "WARN: skipping auth line with empty user or password"
      continue
    fi
    printf '%s\n%s\n' "${p}" "${p}" | kasmvncpasswd -u "${u}" -w -r >/dev/null
    user_count=$((user_count + 1))
  done <<< "${USER_LINES}"

  if [ "${user_count}" -eq 0 ]; then
    echo "ERROR: KASM_AUTH=1 but no valid users could be loaded from ${CRED_SOURCE}."
    echo "Set KASM_AUTH=0 (dev only) or supply KASM_USERS / KASM_USERS_FILE / VNC_USER+VNC_PW."
    exit 1
  fi
  echo "Auth:       ENABLED — ${user_count} user(s) loaded from ${CRED_SOURCE}"
else
  # No BasicAuth on HTTP, no VncAuth on RFB. Do not expose this on the network.
  KASM_AUTH_ARGS=(-DisableBasicAuth)
  echo "Auth:       DISABLED (KASM_AUTH=${KASM_AUTH}) — do not expose this port to untrusted networks."
fi

# Generate Xauthority
XAUTH_FILE="$HOME/.Xauthority"
export XAUTHORITY="$XAUTH_FILE"
touch "$XAUTH_FILE"

# Write xstartup - use dbus-run-session to handle dbus lifecycle
DBUS_RUN_SESSION_PATH="$(command -v dbus-run-session)"
cat > "$HOME/.vnc/xstartup" <<XSTARTUP
#!/usr/bin/env bash
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS

# Write wallpaper config before xfconfd starts
mkdir -p "\$HOME/.config/xfce4/xfconf/xfce-perchannel-xml"
cat > "\$HOME/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-desktop.xml" <<'DESKTOPXML'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfce4-desktop" version="1.0">
  <property name="backdrop" type="empty">
    <property name="screen0" type="empty">
      <property name="monitorscreen" type="empty">
        <property name="workspace0" type="empty">
          <property name="color-style" type="int" value="0"/>
          <property name="image-style" type="int" value="5"/>
          <property name="last-image" type="string" value="/usr/share/wallpaper.png"/>
        </property>
      </property>
      <property name="monitor0" type="empty">
        <property name="workspace0" type="empty">
          <property name="color-style" type="int" value="0"/>
          <property name="image-style" type="int" value="5"/>
          <property name="last-image" type="string" value="/usr/share/wallpaper.png"/>
        </property>
      </property>
    </property>
  </property>
</channel>
DESKTOPXML

# Start XFCE, then set wallpaper via xfconf-query after desktop is up
${DBUS_RUN_SESSION_PATH} bash -c '
  startxfce4 &
  sleep 3
  # Force set wallpaper on all possible monitor property paths
  for monitor in monitorscreen monitor0 monitorVNC-0; do
    xfconf-query -c xfce4-desktop -p /backdrop/screen0/\$monitor/workspace0/last-image -s /usr/share/wallpaper.png --create -t string 2>/dev/null || true
    xfconf-query -c xfce4-desktop -p /backdrop/screen0/\$monitor/workspace0/image-style -s 5 --create -t int 2>/dev/null || true
  done
  wait
'
XSTARTUP
chmod +x "$HOME/.vnc/xstartup"

# Find the KasmVNC web directory
KASMVNC_DIR="$(dirname "$(command -v Xkasmvnc)")/.."
WWW_DIR="${KASMVNC_DIR}/share/kasmvnc/www"

# Assemble Kasm DLP flag list. These map directly to KasmVNC's yaml keys
# under data_loss_prevention.* (see kasmvncserver perl wrapper source).
KASM_DLP_ARGS=(
  -SendCutText   "${CLIP_OUT}"
  -AcceptCutText "${CLIP_IN}"
  -SendPrimary   "${CLIP_PRIMARY}"
  -DLP_ClipSendMax   "${KASM_CLIPBOARD_OUT_MAX}"
  -DLP_ClipAcceptMax "${KASM_CLIPBOARD_IN_MAX}"
  -DLP_ClipDelay     "${KASM_CLIPBOARD_DELAY_MS}"
  -DLP_Log           "${DLP_LOG}"
)
if [ -n "${KASM_CLIPBOARD_MIME_TYPES}" ]; then
  KASM_DLP_ARGS+=(-DLP_ClipTypes "${KASM_CLIPBOARD_MIME_TYPES}")
fi
if [ -n "${KASM_WATERMARK_TEXT}" ]; then
  # Xkasmvnc's watermark renderer only does strftime — it does NOT expand
  # shell-style ${USER} references (that's the perl kasmvncserver wrapper's
  # job, and we bypass it). Do the substitution ourselves. Preference order:
  # first user in KASM_USERS → VNC_USER → OS $USER.
  if [ -n "${KASM_USERS}" ]; then
    WATERMARK_USER="$(printf '%s' "${KASM_USERS}" | cut -d, -f1 | cut -d: -f1)"
  elif [ -n "${VNC_USER:-}" ]; then
    WATERMARK_USER="${VNC_USER}"
  else
    WATERMARK_USER="${USER:-user}"
  fi
  KASM_WATERMARK_TEXT="${KASM_WATERMARK_TEXT//\$\{USER\}/${WATERMARK_USER}}"
  KASM_WATERMARK_TEXT="${KASM_WATERMARK_TEXT//\$USER/${WATERMARK_USER}}"
  KASM_DLP_ARGS+=(-DLP_WatermarkText "${KASM_WATERMARK_TEXT}")
fi

# RFB-layer SecurityTypes is always "None" — HTTP BasicAuth (via
# ~/.kasmpasswd) is the sole authentication gate. Setting VncAuth here would
# require a legacy ~/.vnc/passwd file in DES-encoded TigerVNC format, which
# kasmvncpasswd does not produce; the browser would then hit
#   "no password configured for VNC auth"
# after the BasicAuth prompt succeeded. When KASM_AUTH=0, BasicAuth is
# disabled via -DisableBasicAuth in KASM_AUTH_ARGS so the container is fully
# open (dev only).
SECURITY_TYPES="None"

# Launch Xkasmvnc directly (bypasses the perl kasmvncserver wrapper)
echo "Starting Xkasmvnc..."
Xkasmvnc "${DISPLAY}" \
  -geometry "${VNC_RESOLUTION}" \
  -depth "${VNC_COL_DEPTH}" \
  -websocketPort "${VNC_PORT}" \
  -interface 0.0.0.0 \
  -SecurityTypes "${SECURITY_TYPES}" \
  -RawKeyboard \
  -AlwaysShared \
  -httpd "${WWW_DIR}" \
  -auth "$XAUTH_FILE" \
  -nopn \
  -publicIP 127.0.0.1 \
  -xkbdir "${XKB_BASE_DIR:-/dev/null}" \
  "${KASM_AUTH_ARGS[@]}" \
  "${KASM_DLP_ARGS[@]}" \
  +extension GLX \
  +extension RANDR \
  +extension RENDER &

XKASMVNC_PID=$!

# Wait for the X server to be ready
echo "Waiting for X server..."
for _i in $(seq 1 30); do
  if [ -e "/tmp/.X11-unix/X${DISPLAY_NUM}" ]; then
    echo "X server is ready."
    break
  fi
  sleep 0.5
done

if [ ! -e "/tmp/.X11-unix/X${DISPLAY_NUM}" ]; then
  echo "ERROR: X server failed to start"
  exit 1
fi

# Start the desktop session
echo "Starting XFCE desktop..."
"$HOME/.vnc/xstartup" &
DE_PID=$!
export DE_PID

echo ""
echo "============================================"
echo "  Desktop is ready!"
echo "  Open: http://localhost:${VNC_PORT}"
echo "============================================"
echo ""

# Wait for Xkasmvnc to exit
wait $XKASMVNC_PID

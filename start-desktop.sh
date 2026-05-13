#!/usr/bin/env bash
# Startup script for KasmVNC + XFCE desktop
# Drives Xkasmvnc directly instead of the kasmvncserver perl wrapper

set -euo pipefail

VNC_PORT="${VNC_PORT:-8443}"
VNC_RESOLUTION="${VNC_RESOLUTION:-1280x720}"
VNC_COL_DEPTH="${VNC_COL_DEPTH:-24}"
DISPLAY="${DISPLAY:-:1}"
VNC_PW="${VNC_PW:-password}"
DISPLAY_NUM="${DISPLAY#:}"

export DISPLAY

echo "=== Starting XFCE Desktop with KasmVNC ==="
echo "Display:    ${DISPLAY}"
echo "Resolution: ${VNC_RESOLUTION}"
echo "Web port:   ${VNC_PORT}"

# Create runtime directories
mkdir -p /tmp/runtime-user
mkdir -p /tmp/.X11-unix
mkdir -p "$HOME/.vnc"
mkdir -p "$HOME/.config/xfce4"
export XDG_RUNTIME_DIR=/tmp/runtime-user

# Set KasmVNC password
echo -e "${VNC_PW}\n${VNC_PW}\n" | kasmvncpasswd -u user -w -r

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

# Launch Xkasmvnc directly (bypasses the perl kasmvncserver wrapper)
echo "Starting Xkasmvnc..."
Xkasmvnc "${DISPLAY}" \
  -geometry "${VNC_RESOLUTION}" \
  -depth "${VNC_COL_DEPTH}" \
  -websocketPort "${VNC_PORT}" \
  -interface 0.0.0.0 \
  -disableBasicAuth \
  -SecurityTypes None \
  -RawKeyboard \
  -AlwaysShared \
  -httpd "${WWW_DIR}" \
  -auth "$XAUTH_FILE" \
  -nopn \
  -xkbdir "${XKB_BASE_DIR:-/dev/null}" \
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

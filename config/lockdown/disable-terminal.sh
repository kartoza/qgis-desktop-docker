#!/usr/bin/env bash
# Terminal lockdown for KASM_ALLOW_TERMINAL=0.
#
# Runs as ROOT from entrypoint.sh, before privileges are dropped, and closes
# every route from the XFCE session to a shell prompt:
#
#   1. Deletes the terminal emulators themselves — both the /bin symlink and the
#      binary it points at. This is the control that actually holds: Thunar's
#      "Open Terminal Here", the applications menu, the panel launcher and
#      Ctrl-Alt-T all end up exec()ing one of these names, and none of them can
#      succeed once the executable is gone.
#   2. Deletes the run-a-command launchers (xfce4-appfinder / xfrun4, exo-open),
#      which would otherwise let a user type an arbitrary command into a dialog.
#   3. Hides the menu entries and removes the panel launcher, so the desktop
#      does not offer an affordance that is going to fail.
#
# Steps 1 and 2 are the security control. Step 3 is presentation: if it silently
# does nothing (because someone reformatted the shipped panel XML), the worst
# case is a dead icon, not a shell.
#
# IMPORTANT: this is not a sandbox. QGIS ships a Python console, and anything
# that can run Python can run a subprocess. Removing the terminal raises the bar
# for a casual user; the boundaries that actually contain a determined one are
# the unprivileged UID, the egress filter and the container itself.
#
# Everything here is idempotent, and re-runnable in either direction: with
# KASM_ALLOW_TERMINAL=1 the entrypoint calls this script with `restore`, which
# removes the menu overrides it previously wrote. Deleted executables are NOT
# restored — the container's filesystem layer is thrown away on restart, so a
# plain `docker restart` brings them back anyway.

set -euo pipefail

MODE="${1:-disable}"

# Overridable so the test suite can drive this against a temporary tree.
BIN_DIR="${KASM_LOCKDOWN_BIN_DIR:-/bin}"
HOME_ROOT="${KASM_LOCKDOWN_HOME_ROOT:-/home}"

# Emulators to remove. Only xfce4-terminal ships in this image today; the rest
# are here so that adding a package to the image cannot quietly reopen the door.
TERMINAL_BINARIES=(
  xfce4-terminal
  xfce4-terminal.wrapper
  xterm
  uxterm
  koi8rxterm
  lxterm
  x-terminal-emulator
  gnome-terminal
  mate-terminal
  lxterminal
  konsole
  terminator
  tilix
  urxvt
  rxvt
  alacritty
  kitty
  foot
  sakura
  st
)

# Dialogs that run an arbitrary command line. exo-open is included because its
# "preferred application" fallback prompts the user for a command when the
# helper it was asked for is missing — which is exactly the state we just
# created.
LAUNCHER_BINARIES=(
  xfce4-appfinder
  xfrun4
  exo-open
  exo-helper-2
)

# Desktop entries to hide from the applications menu.
TERMINAL_DESKTOP_IDS=(
  xfce4-terminal.desktop
  xfce4-terminal-settings.desktop
  xterm.desktop
  debian-xterm.desktop
  xfce4-appfinder.desktop
  xfce4-run.desktop
)

# Markers in config/xfce4/panel/default.xml that bracket the terminal launcher.
# Editing XML with sed is only safe because we author the file — the markers are
# there to make that explicit, and to fail loudly if it is ever restructured.
PANEL_BEGIN_MARKER="KASM_TERMINAL_LAUNCHER_BEGIN"
PANEL_END_MARKER="KASM_TERMINAL_LAUNCHER_END"
PANEL_ID_MARKER="KASM_TERMINAL_LAUNCHER_ID"

removed_count=0

# Delete an executable and whatever it points at. Both live in the container's
# own filesystem layer, so this affects this container only — the image and the
# nix store on the host are untouched.
remove_executable() {
  local name="$1"
  local link="${BIN_DIR}/${name}"
  local target=""

  [ -e "${link}" ] || [ -L "${link}" ] || return 0

  if [ -L "${link}" ]; then
    target="$(readlink -f "${link}" 2>/dev/null || true)"
  fi

  rm -f "${link}"
  if [ -n "${target}" ] && [ -e "${target}" ]; then
    rm -f "${target}"
  fi

  removed_count=$((removed_count + 1))
  echo "  removed ${name}${target:+ (${target})}"
}

# Write a Hidden=true override into a user's own data dir. XDG_DATA_HOME beats
# every entry in XDG_DATA_DIRS, so this hides the entry wherever it came from.
hide_desktop_entries() {
  local home="$1" owner="$2" apps="$1/.local/share/applications"

  mkdir -p "${apps}"
  local id
  for id in "${TERMINAL_DESKTOP_IDS[@]}"; do
    cat > "${apps}/${id}" <<DESKTOP
[Desktop Entry]
Type=Application
Name=Disabled
NoDisplay=true
Hidden=true
Exec=/bin/false
DESKTOP
  done
  chown -R "${owner}" "${apps}" 2>/dev/null || true
}

unhide_desktop_entries() {
  local apps="$1/.local/share/applications"
  [ -d "${apps}" ] || return 0

  local id
  for id in "${TERMINAL_DESKTOP_IDS[@]}"; do
    # Only remove overrides that we wrote — never a user's own launcher.
    if [ -f "${apps}/${id}" ] && grep -q '^Name=Disabled$' "${apps}/${id}" 2>/dev/null; then
      rm -f "${apps}/${id}"
    fi
  done
}

# Drop the terminal launcher from a panel config, using the markers the shipped
# XML carries.
strip_panel_launcher() {
  local xml="$1"
  [ -f "${xml}" ] || return 0

  if ! grep -q "${PANEL_BEGIN_MARKER}" "${xml}"; then
    # Either already stripped, or a config we did not write. Both are fine.
    return 0
  fi

  sed -i \
    -e "/${PANEL_BEGIN_MARKER}/,/${PANEL_END_MARKER}/d" \
    -e "/${PANEL_ID_MARKER}/d" \
    "${xml}"
  echo "  removed the terminal launcher from ${xml}"
}

# Every home directory we can see, plus the skeleton one the image ships.
for_each_home() {
  local action="$1" home owner
  for home in "${HOME_ROOT}"/*; do
    [ -d "${home}" ] || continue
    owner="$(stat -c '%u:%g' "${home}" 2>/dev/null || echo "0:0")"
    "${action}" "${home}" "${owner}"
  done
}

case "${MODE}" in
  disable)
    echo "=== Terminal lockdown ==="
    echo "KASM_ALLOW_TERMINAL=0 — removing terminal access from the desktop"

    for name in "${TERMINAL_BINARIES[@]}" "${LAUNCHER_BINARIES[@]}"; do
      remove_executable "${name}"
    done

    for_each_home hide_desktop_entries

    for home in "${HOME_ROOT}"/*; do
      [ -d "${home}" ] || continue
      strip_panel_launcher "${home}/.config/xfce4/panel/default.xml"
    done

    if [ "${removed_count}" -eq 0 ]; then
      echo "  no terminal emulators were present"
    fi
    echo "  note: QGIS's Python console can still run subprocesses — see"
    echo "        docs/configuration/kasm-permissions.md#terminal-access"
    echo "========================"
    ;;

  restore)
    # Only the presentation layer is restorable in place; the executables come
    # back with a fresh container, which is how the image is meant to be used.
    for home in "${HOME_ROOT}"/*; do
      [ -d "${home}" ] || continue
      unhide_desktop_entries "${home}"
    done
    ;;

  *)
    echo "usage: $(basename "$0") [disable|restore]" >&2
    exit 2
    ;;
esac

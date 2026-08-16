#!/usr/bin/env bash
# Unit tests for config/lockdown/disable-terminal.sh (QGIS_DESKTOP_ALLOW_TERMINAL=0).
#
# Builds a throwaway tree that mimics the container's /bin and /home, runs the
# lockdown against it, and asserts that every route to a shell is gone. Needs no
# Docker and no root — the script's paths are overridable for exactly this.
#
# Run:  ./scripts/test-terminal-lockdown.sh
#       nix run .#test-terminal-lockdown

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${QGIS_DESKTOP_PROJECT_ROOT:-$(cd -- "$SCRIPT_DIR/.." && pwd)}"
LOCKDOWN="$PROJECT_ROOT/config/lockdown/disable-terminal.sh"
PANEL_TEMPLATE="$PROJECT_ROOT/config/xfce4/panel/default.xml"

WORK="$(mktemp -d -t qgis-desktop-terminal-tests.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0

ok() {
  PASS=$((PASS + 1))
  printf '  \033[32m✓\033[0m %s\n' "$1"
}

no() {
  FAIL=$((FAIL + 1))
  printf '  \033[31m✗\033[0m %s\n' "$1"
  [ -n "${2:-}" ] && printf '      %s\n' "$2"
}

assert_absent() {
  if [ -e "$1" ] || [ -L "$1" ]; then no "$2" "still present: $1"; else ok "$2"; fi
}

assert_present() {
  if [ -e "$1" ]; then ok "$2"; else no "$2" "missing: $1"; fi
}

assert_file_contains() {
  if grep -q -- "$2" "$1" 2>/dev/null; then ok "$3"; else no "$3" "not found in $1: $2"; fi
}

assert_file_lacks() {
  if grep -q -- "$2" "$1" 2>/dev/null; then no "$3" "still in $1: $2"; else ok "$3"; fi
}

# A tree shaped like the container: /bin holding symlinks into a "store", and a
# home directory carrying the shipped panel config.
build_tree() {
  rm -rf "$WORK/tree"
  mkdir -p "$WORK/tree/bin" "$WORK/tree/store/bin" "$WORK/tree/home/user/.config/xfce4/panel"

  local name
  for name in xfce4-terminal xterm exo-open xfce4-appfinder; do
    printf '#!/bin/sh\necho shell\n' > "$WORK/tree/store/bin/$name"
    chmod +x "$WORK/tree/store/bin/$name"
    ln -sfn "$WORK/tree/store/bin/$name" "$WORK/tree/bin/$name"
  done

  # An unrelated binary, to prove the lockdown is targeted.
  printf '#!/bin/sh\n' > "$WORK/tree/store/bin/thunar"
  chmod +x "$WORK/tree/store/bin/thunar"
  ln -sfn "$WORK/tree/store/bin/thunar" "$WORK/tree/bin/thunar"

  cp "$PANEL_TEMPLATE" "$WORK/tree/home/user/.config/xfce4/panel/default.xml"
}

run_lockdown() {
  QGIS_DESKTOP_LOCKDOWN_BIN_DIR="$WORK/tree/bin" \
    QGIS_DESKTOP_LOCKDOWN_HOME_ROOT="$WORK/tree/home" \
    bash "$LOCKDOWN" "$@" > "$WORK/out" 2>&1
  STATUS=$?
  OUTPUT="$(cat "$WORK/out")"
}

echo "qgis-desktop-disable-terminal"

build_tree
run_lockdown disable

if [ "$STATUS" -eq 0 ]; then ok "lockdown runs cleanly"; else no "lockdown runs cleanly" "$OUTPUT"; fi

# --- The control that actually holds ----------------------------------------
assert_absent "$WORK/tree/bin/xfce4-terminal" "terminal symlink removed"
assert_absent "$WORK/tree/store/bin/xfce4-terminal" "terminal binary removed, not just the symlink"
assert_absent "$WORK/tree/bin/xterm" "second terminal removed"
assert_absent "$WORK/tree/store/bin/xterm" "second terminal binary removed"
assert_absent "$WORK/tree/bin/exo-open" "exo-open removed (arbitrary-command dialog)"
assert_absent "$WORK/tree/bin/xfce4-appfinder" "appfinder removed (arbitrary-command dialog)"
assert_present "$WORK/tree/bin/thunar" "unrelated applications are left alone"
assert_present "$WORK/tree/store/bin/thunar" "unrelated binaries are left alone"

# --- Presentation ------------------------------------------------------------
APPS="$WORK/tree/home/user/.local/share/applications"
assert_present "$APPS/xfce4-terminal.desktop" "menu override written"
assert_file_contains "$APPS/xfce4-terminal.desktop" "Hidden=true" "menu override hides the entry"
assert_file_contains "$APPS/xfce4-appfinder.desktop" "NoDisplay=true" "appfinder entry hidden too"

PANEL="$WORK/tree/home/user/.config/xfce4/panel/default.xml"
assert_file_lacks "$PANEL" "xfce4-terminal.desktop" "panel launcher removed"
assert_file_lacks "$PANEL" "QGIS_DESKTOP_TERMINAL_LAUNCHER_ID" "panel launcher id removed"
assert_file_contains "$PANEL" "thunar.desktop" "other panel launchers survive"
assert_file_contains "$PANEL" "org.qgis.qgis.desktop" "the QGIS launcher survives"

# The shipped panel config must still carry the markers, or the strip above
# silently does nothing in production.
assert_file_contains "$PANEL_TEMPLATE" "QGIS_DESKTOP_TERMINAL_LAUNCHER_BEGIN" \
  "shipped panel config still carries the begin marker"
assert_file_contains "$PANEL_TEMPLATE" "QGIS_DESKTOP_TERMINAL_LAUNCHER_END" \
  "shipped panel config still carries the end marker"
assert_file_contains "$PANEL_TEMPLATE" "QGIS_DESKTOP_TERMINAL_LAUNCHER_ID" \
  "shipped panel config still carries the id marker"

# --- Honest about what it does not close ------------------------------------
case "$OUTPUT" in
  *"Python console"*) ok "warns that QGIS's Python console remains a code path" ;;
  *) no "warns that QGIS's Python console remains a code path" ;;
esac

# --- Idempotence -------------------------------------------------------------
run_lockdown disable
if [ "$STATUS" -eq 0 ]; then ok "running it twice is harmless"; else no "running it twice is harmless" "$OUTPUT"; fi
assert_file_lacks "$PANEL" "xfce4-terminal.desktop" "panel stays stripped on a second run"

# --- Restore -----------------------------------------------------------------
run_lockdown restore
if [ "$STATUS" -eq 0 ]; then ok "restore runs cleanly"; else no "restore runs cleanly" "$OUTPUT"; fi
assert_absent "$APPS/xfce4-terminal.desktop" "restore removes the menu override"

# A launcher the user wrote themselves must survive `restore`.
build_tree
mkdir -p "$APPS"
printf '[Desktop Entry]\nType=Application\nName=My Own Thing\nExec=qgis\n' \
  > "$APPS/xfce4-terminal.desktop"
run_lockdown restore
assert_file_contains "$APPS/xfce4-terminal.desktop" "My Own Thing" \
  "restore leaves a user's own desktop entry alone"

# --- A tree with no terminals at all ----------------------------------------
rm -rf "$WORK/tree"
mkdir -p "$WORK/tree/bin" "$WORK/tree/home/user"
run_lockdown disable
if [ "$STATUS" -eq 0 ]; then ok "clean tree with nothing to remove still succeeds"; else no "clean tree with nothing to remove still succeeds" "$OUTPUT"; fi
case "$OUTPUT" in
  *"no terminal emulators were present"*) ok "says so when there was nothing to remove" ;;
  *) no "says so when there was nothing to remove" "$OUTPUT" ;;
esac

echo ""
echo "─────────────────────────────────────────"
printf '  %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1

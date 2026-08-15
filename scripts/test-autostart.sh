#!/usr/bin/env bash
# Unit tests for QGIS_DESKTOP_AUTOSTART_QGIS.
#
# The script writes an XDG autostart entry into the desktop user's home, which
# XFCE reads when the session starts. Everything here runs against a temporary
# HOME — no container, no X server.
#
# Run:  ./scripts/test-autostart.sh
#       nix run .#test-autostart

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${QGIS_DESKTOP_PROJECT_ROOT:-$(cd -- "$SCRIPT_DIR/.." && pwd)}"
AUTOSTART="$PROJECT_ROOT/config/autostart/autostart.sh"

WORK="$(mktemp -d -t qgis-desktop-autostart-tests.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

# A stub qgis on PATH: the script refuses to write an entry for a binary that
# is not there, which is right in production and inconvenient here.
STUB_BIN="$WORK/bin"
mkdir -p "$STUB_BIN"
printf '#!/bin/sh\nexit 0\n' > "$STUB_BIN/qgis"
chmod +x "$STUB_BIN/qgis"

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

ENTRY_REL=".config/autostart/qgis-desktop-autostart.desktop"

run_autostart() {
  local home="$WORK/home"
  OUTPUT="$(
    env -i PATH="$STUB_BIN:$PATH" HOME="$home" "$@" bash "$AUTOSTART" 2>&1
  )"
  STATUS=$?
  ENTRY="$home/$ENTRY_REL"
}

reset_home() {
  rm -rf "${WORK:?}/home"
  mkdir -p "$WORK/home"
}

assert_file() {
  if [ -f "$1" ]; then ok "$2"; else no "$2" "missing: $1"; fi
}

assert_no_file() {
  if [ -f "$1" ]; then no "$2" "unexpectedly present: $1"; else ok "$2"; fi
}

assert_contains() {
  case "$1" in
    *"$2"*) ok "$3" ;;
    *) no "$3" "expected to find: $2" ;;
  esac
}

assert_ok() {
  if [ "$STATUS" -eq 0 ]; then ok "$1"; else no "$1" "exited $STATUS: $OUTPUT"; fi
}

echo "qgis autostart"

# --- Off by default ---------------------------------------------------------
reset_home
run_autostart
assert_ok "runs cleanly with nothing set"
assert_no_file "$ENTRY" "no autostart entry unless asked for"

# --- On ---------------------------------------------------------------------
reset_home
run_autostart QGIS_DESKTOP_AUTOSTART_QGIS=1
assert_ok "runs cleanly when enabled"
assert_file "$ENTRY" "the autostart entry is written"
assert_contains "$(cat "$ENTRY")" "Exec=qgis" "it launches qgis"
assert_contains "$(cat "$ENTRY")" "Type=Application" "it is a valid desktop entry"
assert_contains "$(cat "$ENTRY")" "X-QGIS-Desktop-Generated=true" "it is stamped as ours"
assert_contains "$OUTPUT" "QGIS will start with the session" "and says so"

# The boolean accepts the same words as every other flag in this project.
for value in yes true on enabled; do
  reset_home
  run_autostart "QGIS_DESKTOP_AUTOSTART_QGIS=$value"
  if [ -f "$ENTRY" ]; then ok "'$value' turns it on"; else no "'$value' turns it on"; fi
done

# --- Arguments --------------------------------------------------------------
reset_home
run_autostart QGIS_DESKTOP_AUTOSTART_QGIS=1 \
  QGIS_DESKTOP_AUTOSTART_QGIS_ARGS="--project /home/user/projects/city.qgs"
assert_contains "$(cat "$ENTRY")" "Exec=qgis --project /home/user/projects/city.qgs" \
  "arguments are passed through"

# Exec= is a single line. A newline in the arguments would truncate the command
# and turn the remainder into another key.
reset_home
run_autostart QGIS_DESKTOP_AUTOSTART_QGIS=1 \
  QGIS_DESKTOP_AUTOSTART_QGIS_ARGS="--project a.qgs
Name=Injected"
EXEC_LINES="$(grep -c '^Exec=' "$ENTRY" 2>/dev/null || echo 0)"
NAME_LINES="$(grep -c '^Name=' "$ENTRY" 2>/dev/null || echo 0)"
if [ "$EXEC_LINES" = "1" ] && [ "$NAME_LINES" = "1" ]; then
  ok "a newline in the arguments cannot inject another key"
else
  no "a newline in the arguments cannot inject another key" \
    "Exec lines=$EXEC_LINES Name lines=$NAME_LINES"
fi

# --- Turning it back off ----------------------------------------------------
reset_home
run_autostart QGIS_DESKTOP_AUTOSTART_QGIS=1
assert_file "$ENTRY" "entry written while enabled"
run_autostart QGIS_DESKTOP_AUTOSTART_QGIS=0
assert_no_file "$ENTRY" "turning it off removes the entry"

# This is the case that matters with persistence: the home directory comes back
# from the bucket with the entry still in it, and the flag is now off.
reset_home
mkdir -p "$WORK/home/.config/autostart"
printf '[Desktop Entry]\nType=Application\nName=QGIS\nExec=qgis\nX-QGIS-Desktop-Generated=true\n' \
  > "$WORK/home/$ENTRY_REL"
run_autostart QGIS_DESKTOP_AUTOSTART_QGIS=0
assert_no_file "$ENTRY" "a restored entry is removed when the flag is off"

# --- Never touch a user's own entry -----------------------------------------
reset_home
mkdir -p "$WORK/home/.config/autostart"
printf '[Desktop Entry]\nType=Application\nName=My own QGIS\nExec=qgis --my-flags\n' \
  > "$WORK/home/$ENTRY_REL"
run_autostart QGIS_DESKTOP_AUTOSTART_QGIS=0
assert_contains "$(cat "$ENTRY" 2>&1)" "My own QGIS" \
  "an entry we did not write is left alone"

# --- No QGIS on PATH --------------------------------------------------------
# A session that cannot find QGIS should log and carry on, not fail to come up.
# The PATH here holds exactly what the script needs and nothing else — the
# developer's own PATH may well have a real qgis on it.
MINIMAL_BIN="$WORK/minimal-bin"
mkdir -p "$MINIMAL_BIN"
for tool in bash mkdir cat chmod rm grep; do
  tool_path="$(command -v "$tool" 2>/dev/null)" || continue
  ln -sf "$tool_path" "$MINIMAL_BIN/$tool"
done

reset_home
OUTPUT="$(env -i PATH="$MINIMAL_BIN" HOME="$WORK/home" \
  QGIS_DESKTOP_AUTOSTART_QGIS=1 bash "$AUTOSTART" 2>&1)"
STATUS=$?
assert_ok "a missing qgis is a warning, not a failed boot"
assert_contains "$OUTPUT" "not on PATH" "and says why"
assert_no_file "$WORK/home/$ENTRY_REL" "and no entry is written"

echo ""
echo "─────────────────────────────────────────"
printf '  %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1

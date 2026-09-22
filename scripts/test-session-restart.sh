#!/usr/bin/env bash
# Unit tests for config/session/session-supervisor.sh.
#
# The supervisor is what makes XFCE's "Log Out" survivable: it relaunches the
# session instead of leaving the browser on a bare X root window. Everything
# here runs against stub session commands in a temporary HOME — no container,
# no X server, no XFCE.
#
# Run:  ./scripts/test-session-restart.sh
#       nix run .#test-session-restart

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${QGIS_DESKTOP_PROJECT_ROOT:-$(cd -- "$SCRIPT_DIR/.." && pwd)}"
SUPERVISOR="$PROJECT_ROOT/config/session/session-supervisor.sh"

WORK="$(mktemp -d -t qgis-desktop-session-tests.XXXXXX)"
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

assert_equals() {
  local actual="$1" expected="$2" label="$3"
  if [ "$actual" = "$expected" ]; then
    ok "$label"
  else
    no "$label" "expected '$expected', got '$actual'"
  fi
}

assert_contains() {
  case "$1" in
    *"$2"*) ok "$3" ;;
    *) no "$3" "expected to find: $2" ;;
  esac
}

assert_not_contains() {
  case "$1" in
    *"$2"*) no "$3" "did not expect: $2" ;;
    *) ok "$3" ;;
  esac
}

# A stub session: appends a line to $WORK/runs on every launch, then exits with
# the status baked into it. Stands in for ~/.vnc/xstartup.
make_session() {
  local exit_status="${1:-0}"
  cat > "$WORK/session" <<STUB
#!/usr/bin/env bash
echo run >> "$WORK/runs"
exit ${exit_status}
STUB
  chmod +x "$WORK/session"
}

run_count() {
  [ -f "$WORK/runs" ] && wc -l < "$WORK/runs" | tr -d ' ' || echo 0
}

# Run the supervisor with only the QGIS_DESKTOP_SESSION_* vars given as
# NAME=VALUE arguments. HOME points at a scratch directory so the saved-session
# reset has somewhere safe to work.
run_supervisor() {
  rm -f "$WORK/runs"
  rm -rf "$WORK/home"
  mkdir -p "$WORK/home"
  OUTPUT="$(
    env -i PATH="$PATH" HOME="$WORK/home" "$@" \
      bash "$SUPERVISOR" "$WORK/session" 2>&1
  )"
  STATUS=$?
  RUNS="$(run_count)"
}

echo "session supervisor"

# --- Restart is on by default ----------------------------------------------
# The crash-loop guard is what stops the test: one initial run plus MAX
# restarts, then the supervisor gives up rather than spinning.
make_session 0
run_supervisor QGIS_DESKTOP_SESSION_RESTART_MAX=2 QGIS_DESKTOP_SESSION_RESTART_DELAY=0
assert_equals "$RUNS" "3" "restarts the session by default (1 run + 2 restarts)"
assert_contains "$OUTPUT" "giving up" "gives up once the restart cap is reached"
assert_contains "$OUTPUT" "restarting (1/2" "counts restarts against the cap"

# --- Opting out -------------------------------------------------------------
make_session 0
run_supervisor QGIS_DESKTOP_SESSION_RESTART=0
assert_equals "$RUNS" "1" "QGIS_DESKTOP_SESSION_RESTART=0 runs the session once"
assert_equals "$STATUS" "0" "and exits with the session's status"
assert_not_contains "$OUTPUT" "restarting" "and says nothing about restarting"

# --- Exit status is the last session's --------------------------------------
make_session 3
run_supervisor QGIS_DESKTOP_SESSION_RESTART=0
assert_equals "$STATUS" "3" "propagates a non-zero session exit status"

make_session 3
run_supervisor QGIS_DESKTOP_SESSION_RESTART_MAX=1 QGIS_DESKTOP_SESSION_RESTART_DELAY=0
assert_equals "$STATUS" "3" "propagates the last status after giving up"

# --- The X server guard -----------------------------------------------------
# A dead guard pid means the X server has gone; respawning sessions into
# nothing would just burn CPU until the container is killed.
make_session 1  # a crash, not a log out: the guard is about crash-restarts
DEAD_PID="$(bash -c 'echo $$')" # a pid that has already exited
run_supervisor QGIS_DESKTOP_SESSION_GUARD_PID="$DEAD_PID" QGIS_DESKTOP_SESSION_RESTART_DELAY=0
assert_equals "$RUNS" "1" "stops when the guard pid is gone"
assert_contains "$OUTPUT" "is gone" "and says why"

make_session 1  # a crash, not a log out: the guard is about crash-restarts
sleep 30 &
LIVE_PID=$!
run_supervisor QGIS_DESKTOP_SESSION_GUARD_PID="$LIVE_PID" \
  QGIS_DESKTOP_SESSION_RESTART_MAX=2 QGIS_DESKTOP_SESSION_RESTART_DELAY=0
kill "$LIVE_PID" 2>/dev/null
wait "$LIVE_PID" 2>/dev/null
assert_equals "$RUNS" "3" "keeps restarting while the guard pid is alive"


# --- Logging out is not the same as crashing --------------------------------
# A crash should be papered over by restarting under the same X server. A log
# out must be visible: restarting silently means the browser never disconnects,
# so the user never sees the session-ended page and never gets the chance to
# sign out or to be reminded the machine is still billing.
make_session 0
sleep 30 &
LIVE_PID=$!
rm -f "$WORK/logout-flag"
run_supervisor QGIS_DESKTOP_SESSION_GUARD_PID="$LIVE_PID" \
  QGIS_DESKTOP_LOGOUT_FLAG="$WORK/logout-flag" \
  QGIS_DESKTOP_SESSION_RESTART_DELAY=0
assert_equals "$RUNS" "1" "a clean log out does not silently restart the session"
assert_contains "$OUTPUT" "clean log out" "and says what it is doing"
if [ -e "$WORK/logout-flag" ]; then
  ok "…and leaves the flag start-desktop reads to come back up"
else
  no "…and leaves the flag start-desktop reads to come back up"
fi
if kill -0 "$LIVE_PID" 2>/dev/null; then
  no "…and signals the display server to end" "the guard pid is still alive"
else
  ok "…and signals the display server to end"
fi
kill "$LIVE_PID" 2>/dev/null; wait "$LIVE_PID" 2>/dev/null

# A crash under a live guard must still restart in place — no disconnect.
make_session 1
sleep 30 &
LIVE_PID=$!
rm -f "$WORK/logout-flag"
run_supervisor QGIS_DESKTOP_SESSION_GUARD_PID="$LIVE_PID" \
  QGIS_DESKTOP_LOGOUT_FLAG="$WORK/logout-flag" \
  QGIS_DESKTOP_SESSION_RESTART_MAX=2 QGIS_DESKTOP_SESSION_RESTART_DELAY=0
assert_equals "$RUNS" "3" "a crash still restarts in place"
if [ -e "$WORK/logout-flag" ]; then
  no "a crash does not raise the log-out flag" "the browser would be disconnected for a crash"
else
  ok "a crash does not raise the log-out flag"
fi
kill "$LIVE_PID" 2>/dev/null; wait "$LIVE_PID" 2>/dev/null

# The old behaviour is still reachable for anyone who preferred it.
make_session 0
sleep 30 &
LIVE_PID=$!
run_supervisor QGIS_DESKTOP_SESSION_GUARD_PID="$LIVE_PID" \
  QGIS_DESKTOP_LOGOUT_DISCONNECT=0 \
  QGIS_DESKTOP_SESSION_RESTART_MAX=2 QGIS_DESKTOP_SESSION_RESTART_DELAY=0
assert_equals "$RUNS" "3" "QGIS_DESKTOP_LOGOUT_DISCONNECT=0 restarts in place instead"
kill "$LIVE_PID" 2>/dev/null; wait "$LIVE_PID" 2>/dev/null
# --- Saved-session reset ----------------------------------------------------
# Log out must not hand the next person the previous session's windows.
make_session 0
rm -f "$WORK/runs"
rm -rf "$WORK/home"
mkdir -p "$WORK/home/.cache/sessions"
echo stale > "$WORK/home/.cache/sessions/xfce4-session-stale"
OUTPUT="$(
  env -i PATH="$PATH" HOME="$WORK/home" \
    QGIS_DESKTOP_SESSION_RESTART_MAX=1 QGIS_DESKTOP_SESSION_RESTART_DELAY=0 \
    bash "$SUPERVISOR" "$WORK/session" 2>&1
)"
if [ -e "$WORK/home/.cache/sessions/xfce4-session-stale" ]; then
  no "clears the saved-session cache between runs" "the stale file survived"
else
  ok "clears the saved-session cache between runs"
fi

make_session 0
rm -f "$WORK/runs"
rm -rf "$WORK/home"
mkdir -p "$WORK/home/.cache/sessions"
echo stale > "$WORK/home/.cache/sessions/xfce4-session-stale"
OUTPUT="$(
  env -i PATH="$PATH" HOME="$WORK/home" \
    QGIS_DESKTOP_SESSION_RESET_STATE=0 \
    QGIS_DESKTOP_SESSION_RESTART_MAX=1 QGIS_DESKTOP_SESSION_RESTART_DELAY=0 \
    bash "$SUPERVISOR" "$WORK/session" 2>&1
)"
if [ -e "$WORK/home/.cache/sessions/xfce4-session-stale" ]; then
  ok "QGIS_DESKTOP_SESSION_RESET_STATE=0 keeps the saved-session cache"
else
  no "QGIS_DESKTOP_SESSION_RESET_STATE=0 keeps the saved-session cache" "it was removed anyway"
fi

# --- The window resets the counter ------------------------------------------
# A session that survives longer than the window is not a crash loop, so the
# tally must not carry over. With a zero-width window every run resets it,
# which would otherwise stop at MAX+1 runs.
cat > "$WORK/session" <<STUB
#!/usr/bin/env bash
echo run >> "$WORK/runs"
sleep 1
exit 0
STUB
chmod +x "$WORK/session"
rm -f "$WORK/runs"
rm -rf "$WORK/home"
mkdir -p "$WORK/home"
env -i PATH="$PATH" HOME="$WORK/home" \
  QGIS_DESKTOP_SESSION_RESTART_WINDOW=0 \
  QGIS_DESKTOP_SESSION_RESTART_MAX=1 \
  QGIS_DESKTOP_SESSION_RESTART_DELAY=0 \
  timeout 5 bash "$SUPERVISOR" "$WORK/session" >/dev/null 2>&1
WINDOW_RUNS="$(run_count)"
if [ "$WINDOW_RUNS" -gt 2 ]; then
  ok "a session outliving the window resets the restart tally ($WINDOW_RUNS runs)"
else
  no "a session outliving the window resets the restart tally" \
    "expected more than 2 runs, got $WINDOW_RUNS"
fi

# --- Input validation -------------------------------------------------------
make_session 0
run_supervisor QGIS_DESKTOP_SESSION_RESTART_MAX=lots QGIS_DESKTOP_SESSION_RESTART_DELAY=0
assert_contains "$OUTPUT" "is not a whole number" "warns about a non-numeric restart cap"
assert_equals "$RUNS" "6" "and falls back to the default cap of 5"

OUTPUT="$(env -i PATH="$PATH" HOME="$WORK/home" bash "$SUPERVISOR" 2>&1)"
STATUS=$?
assert_equals "$STATUS" "2" "exits 2 when given no command"
assert_contains "$OUTPUT" "usage:" "and prints a usage line"

echo ""
echo "─────────────────────────────────────────"
printf '  %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1

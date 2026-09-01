#!/usr/bin/env bash
# Unit tests for home-directory persistence (QGIS_DESKTOP_PERSIST=1).
#
# Drives the real config/persist/persist.sh against a *local* rclone remote — a
# directory standing in for the bucket — so the whole restore/save/guard cycle
# is exercised without S3, credentials or a network. The code path is identical
# apart from the rclone backend.
#
# The guards are the point of this suite. Every one of them exists to stop the
# same class of accident: a container that comes up wrong, or dies at the wrong
# moment, replacing a good home directory in the bucket with a bad one.
#
# Run:  ./scripts/test-persist.sh
#       nix run .#test-persist

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${QGIS_DESKTOP_PROJECT_ROOT:-$(cd -- "$SCRIPT_DIR/.." && pwd)}"
PERSIST="$PROJECT_ROOT/config/persist/persist.sh"

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

if ! command -v rclone >/dev/null 2>&1; then
  echo "persistence"
  echo "  — skipped: rclone not on PATH (run via 'nix run .#test-persist')"
  exit 0
fi

WORK="$(mktemp -d -t qgis-desktop-persist-tests.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

# One test fixture: a home directory, a "bucket" directory, and private state.
# Returns with $HOME_DIR / $BUCKET / $STATE set.
fixture() {
  local name="$1"
  HOME_DIR="$WORK/$name/home"
  BUCKET="$WORK/$name/bucket"
  STATE="$WORK/$name/state"
  STAGE="$WORK/$name/stage"
  rm -rf "${WORK:?}/$name"
  mkdir -p "$HOME_DIR" "$BUCKET" "$STATE" "$STAGE"
}

# Run the persist script with the fixture's paths. Extra env as NAME=VALUE args
# before the command, e.g. run_persist QGIS_DESKTOP_PERSIST_QUOTA=1K push
run_persist() {
  local -a env_args=()
  while [[ "${1:-}" == *=* ]]; do
    env_args+=("$1")
    shift
  done
  OUTPUT="$(
    env \
      QGIS_DESKTOP_PERSIST=1 \
      QGIS_DESKTOP_PERSIST_TYPE=local \
      QGIS_DESKTOP_PERSIST_BUCKET="$BUCKET" \
      QGIS_DESKTOP_PERSIST_PREFIX="alice-0f8b" \
      QGIS_DESKTOP_PERSIST_HOME="$HOME_DIR" \
      QGIS_DESKTOP_PERSIST_STATE_DIR="$STATE" \
      QGIS_DESKTOP_PERSIST_STAGE_DIR="$STAGE" \
      QGIS_DESKTOP_PERSIST_UID="$(id -u)" \
      QGIS_DESKTOP_PERSIST_GID="$(id -g)" \
      QGIS_DESKTOP_PERSIST_INTERVAL=1 \
      "${env_args[@]}" \
      bash "$PERSIST" "$@" 2>&1
  )"
  STATUS=$?
}

remote_home() { printf '%s/alice-0f8b/home' "$BUCKET"; }

assert_ok() {
  if [ "$STATUS" -eq 0 ]; then ok "$1"; else no "$1" "exited $STATUS: $OUTPUT"; fi
}

assert_fails() {
  if [ "$STATUS" -ne 0 ]; then ok "$1"; else no "$1" "expected a non-zero exit"; fi
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

assert_equals() {
  if [ "$1" = "$2" ]; then
    ok "$3"
  else
    no "$3" "expected '$2', got '$1'"
  fi
}

# assert_exists <path> <label>  /  assert_absent <path> <label>
assert_exists() {
  if [ -e "$1" ]; then ok "$2"; else no "$2" "missing: $1"; fi
}

assert_absent() {
  if [ -e "$1" ]; then no "$2" "unexpectedly present: $1"; else ok "$2"; fi
}

echo "persistence — round trip"

fixture roundtrip
mkdir -p "$HOME_DIR/.local/share/QGIS/QGIS3/profiles/default"
echo "my project" > "$HOME_DIR/project.qgs"
echo "settings" > "$HOME_DIR/.local/share/QGIS/QGIS3/profiles/default/QGIS.ini"

run_persist restore
assert_ok "first restore with an empty bucket succeeds"
assert_contains "$OUTPUT" "Nothing in the bucket yet" "first run is reported as a first run"
assert_file "$STATE/restored" "restore sentinel written"

run_persist push
assert_ok "first save succeeds"
assert_file "$(remote_home)/project.qgs" "the project reached the bucket"
assert_file "$(remote_home)/.local/share/QGIS/QGIS3/profiles/default/QGIS.ini" "the QGIS profile reached the bucket"

# The container is deleted and recreated with nothing kept but the bucket —
# the Kubernetes case. The lease left behind by the previous boot belongs to the
# same owner, so it must be reclaimed rather than block the restart.
fixture recreate
cp -r "$WORK/roundtrip/bucket/." "$BUCKET/"
run_persist restore
assert_ok "restore into a recreated container succeeds"
assert_contains "$OUTPUT" "Reclaiming our own lease" "the previous boot's lease is reclaimed, not waited out"
assert_file "$HOME_DIR/project.qgs" "the project came back"
assert_file "$HOME_DIR/.local/share/QGIS/QGIS3/profiles/default/QGIS.ini" "the QGIS profile came back"

echo ""
echo "persistence — what must never be uploaded"

fixture secrets
run_persist restore
: > "$HOME_DIR/.kasmpasswd"
echo "hash" > "$HOME_DIR/.kasmpasswd"
mkdir -p "$HOME_DIR/.cache/qgis" "$HOME_DIR/.vnc"
echo "junk" > "$HOME_DIR/.cache/qgis/tiles.db"
echo "xstartup" > "$HOME_DIR/.vnc/xstartup"
echo "keep me" > "$HOME_DIR/data.gpkg"
run_persist push
assert_ok "save with excluded files succeeds"
assert_file "$(remote_home)/data.gpkg" "real data is saved"
assert_no_file "$(remote_home)/.kasmpasswd" "the password file is never uploaded"
assert_no_file "$(remote_home)/.cache/qgis/tiles.db" "caches are not uploaded"
assert_no_file "$(remote_home)/.vnc/xstartup" "the generated VNC config is not uploaded"

echo ""
echo "persistence — guards against catastrophe"

# Guard: no restore this boot means no save. This is the one that stops a
# container which failed to restore from replacing good data with nothing.
fixture nosentinel
echo "precious" > "$HOME_DIR/keep.qgs"
run_persist push
assert_fails "a save without a successful restore is refused"
assert_contains "$OUTPUT" "No successful restore" "and says why"

# Guard: a home that has collapsed is not mirrored.
fixture shrink
run_persist restore
for i in $(seq 1 40); do echo "$i" > "$HOME_DIR/file-$i.txt"; done
run_persist push
assert_ok "a save of 40 files succeeds"
rm -f "$HOME_DIR"/file-*.txt
echo "one" > "$HOME_DIR/lonely.txt"
run_persist push
assert_fails "a sudden collapse in file count is refused"
assert_contains "$OUTPUT" "shrank from" "and says what it saw"
FILES_STILL_THERE=$(find "$(remote_home)" -name 'file-*.txt' | wc -l)
assert_equals "$FILES_STILL_THERE" "40" "the bucket still holds all 40 files"

run_persist QGIS_DESKTOP_PERSIST_SHRINK_GUARD=0 push
assert_ok "the shrink guard can be turned off deliberately"

# Guard: quota.
fixture quota
run_persist restore
head -c 200000 /dev/urandom > "$HOME_DIR/big.tif"
run_persist QGIS_DESKTOP_PERSIST_QUOTA=100K push
assert_fails "a save over quota is refused"
assert_contains "$OUTPUT" "Over quota" "and says so"
assert_file "$HOME_DIR/PERSISTENCE-WARNING.txt" "the user is told, in a file they can see"
assert_contains "$(cat "$HOME_DIR/PERSISTENCE-WARNING.txt")" "NOTHING IS BEING SAVED" "the warning is unambiguous"
assert_no_file "$(remote_home)/big.tif" "the oversized file did not reach the bucket"

run_persist QGIS_DESKTOP_PERSIST_QUOTA=10M push
assert_ok "a save under quota succeeds"
assert_no_file "$HOME_DIR/PERSISTENCE-WARNING.txt" "the warning is cleared once resolved"

# Guard: deletions are recoverable without provider-side versioning.
fixture trash
run_persist restore
echo "v1" > "$HOME_DIR/report.qgs"
run_persist push
echo "v2" > "$HOME_DIR/report.qgs"
rm -f "$HOME_DIR/never-mind.txt"
run_persist push
assert_ok "a second save succeeds"
assert_contains "$(cat "$(remote_home)/report.qgs")" "v2" "the bucket has the new version"
TRASHED=$(find "$BUCKET/alice-0f8b/.persist-trash" -name 'report.qgs' 2>/dev/null | wc -l)
if [ "$TRASHED" -ge 1 ]; then
  ok "the replaced version was kept in the trash prefix"
else
  no "the replaced version was kept in the trash prefix" "found none"
fi

echo ""
echo "persistence — the baseline data to the user"

# baseline/ is baseline material: applied on every start, never uploaded,
# never removed from the bucket, and it never overwrites the user's own file.
fixture baseline
mkdir -p "$BUCKET/alice-0f8b/baseline/Desktop" "$BUCKET/alice-0f8b/baseline/templates"
echo "corporate style" > "$BUCKET/alice-0f8b/baseline/templates/house-style.qml"
echo "welcome" > "$BUCKET/alice-0f8b/baseline/Desktop/README.txt"
run_persist restore
assert_ok "restore with baseline/ succeeds"
assert_file "$HOME_DIR/templates/house-style.qml" "baseline file lands in the home"
assert_file "$HOME_DIR/Desktop/README.txt" "baseline file keeps its subdirectory"
assert_contains "$OUTPUT" "Baseline: applying 2 file(s)" "the the baseline is reported"

# The staged copy is read by the desktop user, not root. This caught a real
# bug: the umask set while writing the credentials file leaked into the rest of
# the process, so the staging directory came out 0700 root-owned and the
# unprivileged copy could not read it. It only showed up in a container,
# because the tests run as one user throughout.
mkdir -p "$BUCKET/alice-0f8b/deploy"
echo "check the mode" > "$BUCKET/alice-0f8b/deploy/mode-probe.txt"
run_persist deliver
STAGE_MODE="$(stat -c '%a' "$STAGE" 2>/dev/null || echo '?')"
# Anything ending in 5 (or 7) for "other" is traversable; 0700 is the bug.
case "$STAGE_MODE" in
  ??[157]) ok "the staging directory stays traversable by the desktop user" ;;
  *) no "the staging directory stays traversable by the desktop user" "mode=$STAGE_MODE" ;;
esac
assert_equals "$(stat -c '%a' "$STATE/rclone.conf" 2>/dev/null)" "400" \
  "…while the credentials file stays 0400"

run_persist push
assert_ok "save after the baseline succeeds"
assert_exists "$BUCKET/alice-0f8b/baseline/templates/house-style.qml" \
  "baseline/ is left in the bucket, not consumed"
assert_file "$(remote_home)/templates/house-style.qml" \
  "the baseline file is now part of the user's saved home"

# A user's own edit must survive the next container start: it is saved, then
# restored, and the baseline must not put the pristine copy back over it.
echo "my own version" > "$HOME_DIR/templates/house-style.qml"
run_persist push
assert_ok "saving the user's edit succeeds"
rm -rf "${HOME_DIR:?}/templates"   # a fresh container has nothing local
run_persist restore
assert_contains "$(cat "$HOME_DIR/templates/house-style.qml" 2>&1)" "my own version" \
  "the baseline never overwrites the user's own copy"

# deploy/ is a one-time handover: delivered, then cleared from the bucket.
fixture deploy
run_persist restore
mkdir -p "$BUCKET/alice-0f8b/deploy"
echo "a picture" > "$BUCKET/alice-0f8b/deploy/photo.jpg"
run_persist deliver
assert_ok "delivering deploy/ succeeds"
assert_file "$HOME_DIR/Desktop/photo.jpg" "the deployed file lands on the desktop"
assert_absent "$BUCKET/alice-0f8b/deploy/photo.jpg" "deploy/ is cleared once delivered"
assert_contains "$OUTPUT" "delivered and cleared" "and says so"

# Delivered once means delivered once: deleting it does not bring it back.
rm -f "$HOME_DIR/Desktop/photo.jpg"
run_persist deliver
assert_absent "$HOME_DIR/Desktop/photo.jpg" "a delivered file does not come back"

# A different destination.
mkdir -p "$BUCKET/alice-0f8b/deploy"
echo "data" > "$BUCKET/alice-0f8b/deploy/layer.gpkg"
run_persist QGIS_DESKTOP_PERSIST_DEPLOY_DEST=incoming deliver
assert_file "$HOME_DIR/incoming/layer.gpkg" "the deploy destination is configurable"

# deploy/ is created at restore, so an operator opening the bucket can see where
# to put a file instead of having to know the name and hand-create the path. On
# S3 this is a zero-byte directory marker; on a local remote, a real directory.
fixture prefixes
run_persist restore
assert_ok "restore succeeds on an empty bucket"
assert_exists "$BUCKET/alice-0f8b/deploy" "deploy/ is created at restore"
# baseline/ is set up once by whoever designs the deployment, not by someone
# reacting to a request, so an empty one on every home would be clutter.
assert_absent "$BUCKET/alice-0f8b/baseline" "baseline/ is NOT created — nothing to react to"

# An empty deploy/ is not something to deliver: no phantom file, no noise.
run_persist deliver
assert_ok "delivering an empty deploy/ succeeds"
if grep -q "Deploy: delivering" <<< "$OUTPUT"; then
  no "an empty deploy/ must not report a delivery" "$(grep -i deploy <<< "$OUTPUT" | head -2)"
else
  ok "an empty deploy/ reports nothing to deliver"
fi
assert_absent "$HOME_DIR/Desktop/deploy" "no marker is delivered as a file"

# Delivery must not remove the prefix — otherwise it is there once, disappears
# after the first hand-off, and the operator is back to creating it by hand.
echo "one off" > "$BUCKET/alice-0f8b/deploy/handover.txt"
run_persist deliver
assert_file "$HOME_DIR/Desktop/handover.txt" "the delivery still works"
assert_exists "$BUCKET/alice-0f8b/deploy" "deploy/ survives a delivery that empties it"

# Opt out, for a credential scoped so tightly it cannot create them.
fixture noprefixes
run_persist QGIS_DESKTOP_PERSIST_CREATE_DEPLOY=0 restore
assert_ok "restore succeeds with deploy/ creation off"
assert_absent "$BUCKET/alice-0f8b/deploy" "deploy/ creation can be turned off"

# Both can be turned off.
fixture nodeliver
mkdir -p "$BUCKET/alice-0f8b/baseline" "$BUCKET/alice-0f8b/deploy"
echo x > "$BUCKET/alice-0f8b/baseline/p.txt"
echo y > "$BUCKET/alice-0f8b/deploy/i.txt"
run_persist QGIS_DESKTOP_PERSIST_BASELINE=0 QGIS_DESKTOP_PERSIST_DEPLOY=0 restore
assert_absent "$HOME_DIR/p.txt" "the baseline can be turned off"
assert_absent "$HOME_DIR/Desktop/i.txt" "deploy/ can be turned off"
assert_exists "$BUCKET/alice-0f8b/deploy/i.txt" "and deploy/ is left untouched"

# The behaviour that sends people to deploy/ in the first place: home/ is a
# mirror, so a file dropped there is treated as one the user deleted. Pinned
# here so nobody "fixes" it into a two-way sync by accident.
fixture mirror
run_persist restore
echo "keep" > "$HOME_DIR/mine.txt"
run_persist push
mkdir -p "$(remote_home)"
echo "dropped straight into home/" > "$(remote_home)/uploaded-by-hand.jpg"
run_persist push
assert_ok "the save after a hand-uploaded file succeeds"
assert_absent "$(remote_home)/uploaded-by-hand.jpg" \
  "a file dropped into home/ is reverted — home/ mirrors the container"
RECOVERED=$(find "$BUCKET/alice-0f8b/.persist-trash" -name 'uploaded-by-hand.jpg' 2>/dev/null | wc -l)
if [ "$RECOVERED" -ge 1 ]; then
  ok "…but it is recoverable from the trash, not destroyed"
else
  no "…but it is recoverable from the trash, not destroyed" "not found in the trash"
fi

echo ""
echo "persistence — the single-writer lease"

fixture lease
run_persist restore
assert_ok "restore takes the lease"
assert_exists "$BUCKET/alice-0f8b/.persist-lease" "the lease object exists"

# A DIFFERENT container — another owner — against the same prefix, while the
# first still holds a fresh lease. This is the case that must be refused: two
# writers means whichever saves last wins and the other's work is gone.
SECOND_STATE="$WORK/lease/state2"
SECOND_STAGE="$WORK/lease/stage2"
mkdir -p "$SECOND_STATE" "$SECOND_STAGE"
run_second_container() {
  OUTPUT="$(
    env QGIS_DESKTOP_PERSIST=1 QGIS_DESKTOP_PERSIST_TYPE=local \
      QGIS_DESKTOP_PERSIST_BUCKET="$BUCKET" QGIS_DESKTOP_PERSIST_PREFIX="alice-0f8b" \
      QGIS_DESKTOP_PERSIST_HOME="$WORK/lease/home2" \
      QGIS_DESKTOP_PERSIST_STATE_DIR="$SECOND_STATE" \
      QGIS_DESKTOP_PERSIST_STAGE_DIR="$SECOND_STAGE" \
      QGIS_DESKTOP_PERSIST_OWNER="qgis-desktop-1" \
      "$@" \
      bash "$PERSIST" restore 2>&1
  )"
  STATUS=$?
}

run_second_container
assert_fails "a second container is refused while the lease is live"
assert_contains "$OUTPUT" "Another container holds the lease" "and explains the risk"
assert_contains "$OUTPUT" "release --force" "and says how to override"

# Same container again once the lease has aged out.
run_second_container QGIS_DESKTOP_PERSIST_LEASE_TTL=0
assert_ok "an expired lease is taken over"
assert_contains "$OUTPUT" "expired lease" "and says it did so"

fixture leaseoff
run_persist QGIS_DESKTOP_PERSIST_LEASE=0 restore
assert_ok "the lease can be turned off"
assert_absent "$BUCKET/alice-0f8b/.persist-lease" "no lease object is written when disabled"

echo ""
echo "persistence — configuration"

fixture config
OUTPUT="$(env QGIS_DESKTOP_PERSIST=1 QGIS_DESKTOP_PERSIST_TYPE=local \
  QGIS_DESKTOP_PERSIST_PREFIX=x bash "$PERSIST" restore 2>&1)"
STATUS=$?
assert_fails "a missing bucket is fatal"

OUTPUT="$(env QGIS_DESKTOP_PERSIST=1 QGIS_DESKTOP_PERSIST_TYPE=local \
  QGIS_DESKTOP_PERSIST_BUCKET="$BUCKET" QGIS_DESKTOP_PERSIST_PREFIX="../escape" \
  bash "$PERSIST" restore 2>&1)"
STATUS=$?
assert_fails "a prefix containing .. is refused"
assert_contains "$OUTPUT" "relative path without" "and says why"

OUTPUT="$(env QGIS_DESKTOP_PERSIST=1 QGIS_DESKTOP_PERSIST_TYPE=local \
  QGIS_DESKTOP_PERSIST_BUCKET="$BUCKET" QGIS_DESKTOP_PERSIST_PREFIX="/absolute" \
  bash "$PERSIST" restore 2>&1)"
STATUS=$?
assert_fails "an absolute prefix is refused"

OUTPUT="$(env QGIS_DESKTOP_PERSIST=0 bash "$PERSIST" status 2>&1)"
STATUS=$?
assert_ok "status works when persistence is off"
assert_contains "$OUTPUT" "disabled" "and says it is disabled"

fixture status
run_persist restore
run_persist status
assert_ok "status works when persistence is on"
assert_contains "$OUTPUT" "remote:" "status names the remote"
assert_contains "$OUTPUT" "usage:" "status reports usage"

# The credentials must never appear in output a user could see.
fixture secretleak
OUTPUT="$(env QGIS_DESKTOP_PERSIST=1 QGIS_DESKTOP_PERSIST_TYPE=s3 \
  QGIS_DESKTOP_PERSIST_BUCKET=b QGIS_DESKTOP_PERSIST_PREFIX=p \
  QGIS_DESKTOP_PERSIST_ENDPOINT=https://example.invalid \
  QGIS_DESKTOP_PERSIST_ACCESS_KEY=AKIAEXAMPLE \
  QGIS_DESKTOP_PERSIST_SECRET_KEY=sup3rs3cr3t \
  QGIS_DESKTOP_PERSIST_STATE_DIR="$STATE" \
  bash "$PERSIST" status 2>&1)"
case "$OUTPUT" in
  *sup3rs3cr3t*) no "the secret key never appears in status output" ;;
  *) ok "the secret key never appears in status output" ;;
esac
MODE="$(stat -c '%a' "$STATE/rclone.conf" 2>/dev/null || echo '?')"
assert_equals "$MODE" "400" "the rclone config is 0400"

echo ""
echo "─────────────────────────────────────────"
printf '  %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1

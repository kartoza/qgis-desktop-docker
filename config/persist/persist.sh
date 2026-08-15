#!/usr/bin/env bash
# Home-directory persistence for one user, one container.
#
# The home directory is an ordinary local filesystem — POSIX semantics, real
# locking, SQLite that does not corrupt — and object storage is the durable
# copy behind it. This script moves data between the two:
#
#   restore   remote -> local, once, BEFORE the desktop starts
#   push      local  -> remote, guarded, repeatedly
#   loop      deliver + push on an interval until killed
#   flush     a final push, on the way down
#   deliver   apply provision/ and drain inbox/ now
#   status    what is configured and how full it is
#   release   drop the single-writer lease
#
# It runs as ROOT throughout, for two reasons: the restore has to write into a
# home directory owned by uid 1000, and the object-store credentials must stay
# unreadable by the desktop user. The rclone config file is written 0400
# root-owned, so the user in the session — who has a Python console in QGIS and
# can run anything as uid 1000 — cannot read the credentials out of it, and
# cannot reach the bucket with them.
#
# Direction matters for safety. The restore is the only moment root writes into
# the home directory, and it happens before any user process exists, so a
# planted symlink cannot redirect a root write. Every later transfer reads
# locally and writes remotely.
#
# WHAT THIS IS NOT: a live mount. Work done since the last push is lost if the
# container dies without warning. That window is QGIS_DESKTOP_PERSIST_INTERVAL
# wide, and the safeguards below decide what happens at the edges.

set -uo pipefail

COMMAND="${1:-status}"

# --- Configuration ----------------------------------------------------------

PERSIST_ENABLED="${QGIS_DESKTOP_PERSIST:-0}"
HOME_DIR="${QGIS_DESKTOP_PERSIST_HOME:-/home/user}"
HOME_UID="${QGIS_DESKTOP_PERSIST_UID:-1000}"
HOME_GID="${QGIS_DESKTOP_PERSIST_GID:-1000}"

# s3 covers MinIO, DigitalOcean Spaces and Hetzner. `local` targets a directory
# instead — a mounted PVC or NFS export, and what the test suite drives.
REMOTE_TYPE="${QGIS_DESKTOP_PERSIST_TYPE:-s3}"
BUCKET="${QGIS_DESKTOP_PERSIST_BUCKET:-}"
PREFIX="${QGIS_DESKTOP_PERSIST_PREFIX:-}"
ENDPOINT="${QGIS_DESKTOP_PERSIST_ENDPOINT:-}"
REGION="${QGIS_DESKTOP_PERSIST_REGION:-us-east-1}"
PROVIDER="${QGIS_DESKTOP_PERSIST_PROVIDER:-Other}"

INTERVAL="${QGIS_DESKTOP_PERSIST_INTERVAL:-300}"
QUOTA="${QGIS_DESKTOP_PERSIST_QUOTA:-}"
EXTRA_EXCLUDE="${QGIS_DESKTOP_PERSIST_EXCLUDE:-}"
KEEP_TRASH="${QGIS_DESKTOP_PERSIST_TRASH:-1}"
USE_LEASE="${QGIS_DESKTOP_PERSIST_LEASE:-1}"
LEASE_TTL="${QGIS_DESKTOP_PERSIST_LEASE_TTL:-900}"
SHRINK_GUARD="${QGIS_DESKTOP_PERSIST_SHRINK_GUARD:-50}"
EXTRA_RCLONE_ARGS="${QGIS_DESKTOP_PERSIST_RCLONE_ARGS:-}"

# Handing data to the user. Both are no-ops until the corresponding directory
# exists in the bucket.
USE_PROVISION="${QGIS_DESKTOP_PERSIST_PROVISION:-1}"
USE_INBOX="${QGIS_DESKTOP_PERSIST_INBOX:-1}"
INBOX_DEST="${QGIS_DESKTOP_PERSIST_INBOX_DEST:-Desktop}"

# Create provision/ and inbox/ in the bucket at startup so an operator can see
# where to put things. S3 has no directories — a prefix exists only while an
# object is under it — so without this the two delivery paths are invisible in
# a bucket browser, and whoever wants to send a user a file has to know the
# names and hand-create the path. Both are written as zero-byte directory
# markers, which rclone skips when listing, so an empty inbox/ is still worth
# nothing to deliver.
CREATE_PREFIXES="${QGIS_DESKTOP_PERSIST_CREATE_PREFIXES:-1}"

# Runtime state, root-only.
STATE_DIR="${QGIS_DESKTOP_PERSIST_STATE_DIR:-/run/qgis-desktop/persist}"
# Where provisioned and inbox files land before being copied into the home as
# the desktop user. Root-owned but readable — it never holds a credential.
STAGE_DIR="${QGIS_DESKTOP_PERSIST_STAGE_DIR:-/run/qgis-desktop/staging}"
RCLONE_CONF="${STATE_DIR}/rclone.conf"
SENTINEL="${STATE_DIR}/restored"
COUNT_FILE="${STATE_DIR}/last-file-count"
ID_FILE="${STATE_DIR}/instance-id"

# Visible to the user, unlike the log.
WARNING_FILE="${HOME_DIR}/PERSISTENCE-WARNING.txt"

LEASE_OBJECT=".persist-lease"
TRASH_PREFIX=".persist-trash"

log() { printf '[persist] %s\n' "$*"; }
err() { printf '[persist] %s\n' "$*" >&2; }

die() {
  err "ERROR: $*"
  exit 1
}

# --- Credential handling ----------------------------------------------------

# Read a secret from <NAME>_FILE if given, else <NAME>. The file form keeps the
# value out of the environment, where `docker inspect` can read it.
read_secret() {
  local name="$1"
  local file_var="${name}_FILE"
  local file value
  file="${!file_var:-}"
  if [ -n "${file}" ]; then
    [ -r "${file}" ] || die "${file_var}=${file} is not readable."
    value="$(cat "${file}")"
  else
    value="${!name:-}"
  fi
  value="${value%$'\r'}"
  printf '%s' "${value}"
}

# The rclone config file is the only place the credentials land. 0400 root, in
# a tmpfs-ish runtime dir that never reaches the image or a volume.
write_rclone_config() {
  mkdir -p "${STATE_DIR}"
  chmod 0700 "${STATE_DIR}"

  local access secret token config

  case "${REMOTE_TYPE}" in
    local)
      config="[persist]
type = local"
      ;;
    s3)
      access="$(read_secret QGIS_DESKTOP_PERSIST_ACCESS_KEY)"
      secret="$(read_secret QGIS_DESKTOP_PERSIST_SECRET_KEY)"
      token="$(read_secret QGIS_DESKTOP_PERSIST_SESSION_TOKEN)"
      [ -n "${access}" ] || die "QGIS_DESKTOP_PERSIST_ACCESS_KEY (or _FILE) is required."
      [ -n "${secret}" ] || die "QGIS_DESKTOP_PERSIST_SECRET_KEY (or _FILE) is required."

      config="[persist]
type = s3
provider = ${PROVIDER}
access_key_id = ${access}
secret_access_key = ${secret}"
      [ -n "${token}" ] && config="${config}
session_token = ${token}"
      [ -n "${ENDPOINT}" ] && config="${config}
endpoint = ${ENDPOINT}"
      # Object storage has no atomic rename; without no_check_bucket rclone
      # tries one.
      config="${config}
region = ${REGION}
no_check_bucket = true"
      ;;
    *)
      die "QGIS_DESKTOP_PERSIST_TYPE='${REMOTE_TYPE}' is not one of s3|local."
      ;;
  esac

  # The umask is scoped to the write, in a subshell, so it cannot leak. It used
  # to be set for the rest of the process, which made the staging directory
  # 0700 root-owned — and the unprivileged copy that delivers provisioned files
  # could not read it. The file must never be group- or world-readable even for
  # the instant between creating and chmod'ing it.
  (
    umask 077
    printf '%s\n' "${config}" > "${RCLONE_CONF}"
  )

  chmod 0400 "${RCLONE_CONF}"
  chown 0:0 "${RCLONE_CONF}" 2>/dev/null || true
}

# --- Remote paths -----------------------------------------------------------

remote_root() {
  case "${REMOTE_TYPE}" in
    local) printf 'persist:%s/%s' "${BUCKET%/}" "${PREFIX%/}" ;;
    *) printf 'persist:%s/%s' "${BUCKET%/}" "${PREFIX%/}" ;;
  esac
}

remote_data() { printf '%s/home' "$(remote_root)"; }
remote_trash() { printf '%s/%s' "$(remote_root)" "${TRASH_PREFIX}"; }
remote_lease() { printf '%s/%s' "$(remote_root)" "${LEASE_OBJECT}"; }

# Two ways to hand data TO a user, both outside home/ so the mirror never
# touches them:
#
#   provision/  copied in every time a container starts, never uploaded, never
#               removed from the bucket. Baseline material — templates, base
#               layers, a corporate style file. Existing files are left alone,
#               so it cannot overwrite the user's own work.
#   inbox/      delivered into the running desktop and then removed from the
#               bucket. A one-time handover: drop a file in, it appears, it
#               does not come back next restart.
#
# Anything dropped into home/ instead is treated as a file the user deleted —
# home/ is a mirror of the container, and the next save makes it match again.
remote_provision() { printf '%s/provision' "$(remote_root)"; }
remote_inbox() { printf '%s/inbox' "$(remote_root)"; }

# Make both delivery prefixes visible in the bucket before anyone needs them.
# Idempotent, and cheap enough to run at every boot.
ensure_prefixes() {
  [ "$(to_bool "${CREATE_PREFIXES}")" = "1" ] || return 0

  local -a args=()
  # On S3 a directory has to be faked with a zero-byte object whose key ends in
  # '/'. rclone only writes those when asked, and ignores them when listing, so
  # the marker never looks like a file to deliver. A local remote makes real
  # directories and needs no such flag.
  [ "${REMOTE_TYPE}" = "s3" ] && args+=(--s3-directory-markers)

  local p
  for p in "$(remote_provision)" "$(remote_inbox)"; do
    # Never fatal: a credential scoped to home/ can legitimately refuse this,
    # and a missing prefix only costs the operator a click later.
    rc mkdir "${args[@]}" "${p}" >/dev/null 2>&1 || true
  done
}

rc() {
  rclone --config "${RCLONE_CONF}" "$@"
}

# Filters. Everything here is either recreated at boot, a cache, or a secret
# that must never be uploaded.
filter_args() {
  local -a f=(
    --exclude ".cache/**"
    --exclude ".local/share/Trash/**"
    --exclude ".local/share/xorg/**"
    --exclude ".dbus/**"
    --exclude ".vnc/**"
    --exclude ".Xauthority"
    --exclude ".ICEauthority"
    # Written from the credential source on every boot, and it holds password
    # hashes. It has no business in the bucket.
    --exclude ".kasmpasswd"
    --exclude "${TRASH_PREFIX}/**"
    --exclude "PERSISTENCE-WARNING.txt"
  )
  local item
  if [ -n "${EXTRA_EXCLUDE}" ]; then
    while IFS= read -r item; do
      item="${item#"${item%%[![:space:]]*}"}"
      item="${item%"${item##*[![:space:]]}"}"
      [ -n "${item}" ] || continue
      f+=(--exclude "${item}")
    done < <(printf '%s\n' "${EXTRA_EXCLUDE}" | tr ',' '\n')
  fi
  printf '%s\n' "${f[@]}"
}

mapfile_filters() {
  mapfile -t FILTERS < <(filter_args)
}

# --- Instance identity and the single-writer lease --------------------------

# Who owns the home directory, not who is running right now. It has to survive a
# restart, or a container that is killed and recreated would be locked out of
# its own data until the lease expired — which is precisely the Kubernetes case
# this is meant to survive.
#
# The hostname is the right default: a StatefulSet pod keeps its name across
# restarts, so it reclaims its own lease immediately, while a *different* pod
# writing the same prefix is still refused. Deployments hand out a new name each
# time, so set QGIS_DESKTOP_PERSIST_OWNER to something stable there.
instance_id() {
  printf '%s' "${QGIS_DESKTOP_PERSIST_OWNER:-$(hostname 2>/dev/null || echo container)}"
}

# Distinguishes one boot of that owner from the next, for the log only.
boot_id() {
  if [ -s "${ID_FILE}" ]; then
    cat "${ID_FILE}"
    return
  fi
  mkdir -p "${STATE_DIR}"
  { cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "$$-${RANDOM}"; } > "${ID_FILE}"
  cat "${ID_FILE}"
}

# Advisory, with a TTL. Object stores give us no atomic compare-and-set through
# rclone, so this cannot be a real mutex — it is here to stop the realistic
# case: Kubernetes starting the replacement pod while the old one is still
# writing. Two writers means last-writer-wins over a whole home directory.
lease_check() {
  [ "$(to_bool "${USE_LEASE}")" = "1" ] || return 0

  local raw holder acquired now age
  raw="$(rc cat "$(remote_lease)" 2>/dev/null || true)"
  [ -n "${raw}" ] || return 0

  holder="$(printf '%s' "${raw}" | sed -n 's/^holder=//p' | head -1)"
  acquired="$(printf '%s' "${raw}" | sed -n 's/^acquired=//p' | head -1)"
  [ -n "${acquired}" ] || return 0

  now="$(date +%s)"
  age=$((now - acquired))

  # Our own lease from a previous boot: reclaim it without waiting.
  if [ "${holder}" = "$(instance_id)" ]; then
    log "Reclaiming our own lease (owner ${holder}, ${age}s old)."
    return 0
  fi

  if [ "${age}" -lt "${LEASE_TTL}" ]; then
    err "Another container holds the lease on this home directory:"
    err "  holder:  ${holder}"
    err "  age:     ${age}s (expires after ${LEASE_TTL}s)"
    err ""
    err "Two containers writing one prefix means whichever syncs last wins, and"
    err "the other one's work is gone. Refusing to start."
    err ""
    err "If that container is definitely dead, either wait for the lease to"
    err "expire or clear it with:"
    err "  qgis-desktop-persist release --force"
    return 1
  fi

  log "Found an expired lease from ${holder} (${age}s old) — taking over."
  return 0
}

lease_write() {
  [ "$(to_bool "${USE_LEASE}")" = "1" ] || return 0
  printf 'holder=%s\nboot=%s\nacquired=%s\nttl=%s\n' \
    "$(instance_id)" "$(boot_id)" "$(date +%s)" "${LEASE_TTL}" |
    rc rcat "$(remote_lease)" 2>/dev/null || true
}

lease_release() {
  [ "$(to_bool "${USE_LEASE}")" = "1" ] || return 0
  rc deletefile "$(remote_lease)" 2>/dev/null || true
}

to_bool() {
  case "${1,,}" in
    1 | yes | true | on | enabled) echo 1 ;;
    *) echo 0 ;;
  esac
}

# --- Delivering data into the home ------------------------------------------

# The delivery below runs as the desktop user, so the staging area has to be
# traversable and readable by them. Set explicitly rather than inherited from
# whatever umask happens to be in force — that assumption is what broke this
# the first time.
stage_readable() {
  chmod -R a+rX "$1" 2>/dev/null || true
}

# Copy a staged directory into the home AS THE DESKTOP USER, not as root.
#
# The user's session is running by the time the inbox is drained, and they can
# create symlinks in their own home. A root-owned copy would follow one and
# write wherever it pointed; the same copy running as uid 1000 can only reach
# what that uid could already reach. The staging directory is root-owned and
# world-readable — it holds the user's own data, never a credential.
deliver_as_user() {
  local staged="$1" dest="$2" clobber="$3"
  local -a cp_args=(-r)

  [ -d "${staged}" ] || return 0
  # Nothing staged is not a failure.
  [ -n "$(ls -A "${staged}" 2>/dev/null)" ] || return 0

  [ "${clobber}" = "no-clobber" ] && cp_args+=(-n)

  # Already running as the target user — in the test suite, or in a container
  # that never had root. Nothing to drop.
  if [ "$(id -u)" != "0" ] || [ "${HOME_UID}" = "0" ]; then
    mkdir -p "${dest}" && cp "${cp_args[@]}" "${staged}/." "${dest}/"
    return
  fi

  # Both of these are packaging faults rather than runtime conditions, and both
  # would otherwise show up only as "could not deliver".
  command -v setpriv >/dev/null 2>&1 || {
    err "setpriv is not on PATH — cannot deliver files as uid ${HOME_UID}."
    return 1
  }
  command -v sh >/dev/null 2>&1 || {
    err "no shell on PATH — cannot deliver files as uid ${HOME_UID}."
    return 1
  }

  # $1 is the destination for mkdir, then shifted away so the rest is the cp
  # command line. Single quotes are deliberate: these expand in the inner shell,
  # which is the one running unprivileged.
  # shellcheck disable=SC2016
  setpriv --reuid="${HOME_UID}" --regid="${HOME_GID}" --init-groups \
    --inh-caps=-all --ambient-caps=-all \
    -- sh -c 'mkdir -p "$1" && shift && exec cp "$@"' _ \
    "${dest}" "${cp_args[@]}" "${staged}/." "${dest}/"
}

# Baseline material, applied on every start. --ignore-existing on the download
# and -n on the copy: a provisioned file never overwrites what the user has.
# Changing a provisioned file therefore does not reach users who already have
# it — use the inbox for that.
apply_provision() {
  [ "$(to_bool "${USE_PROVISION}")" = "1" ] || return 0

  local staged="${STAGE_DIR}/provision"
  rm -rf "${staged}"
  mkdir -p "${staged}"

  local count
  count="$(rc size "$(remote_provision)" --json 2>/dev/null |
    sed -n 's/.*"count":\([0-9]*\).*/\1/p' | head -1)"
  count="${count:-0}"
  [ "${count}" -gt 0 ] || return 0

  log "Provisioning ${count} file(s) from provision/"
  if ! rc copy "$(remote_provision)" "${staged}" --transfers 8 --stats-one-line --stats 30s; then
    err "Could not fetch provision/ — continuing without it."
    rm -rf "${staged}"
    return 0
  fi

  stage_readable "${staged}"

  deliver_as_user "${staged}" "${HOME_DIR}" no-clobber ||
    err "Could not deliver provision/ into the home directory."
  rm -rf "${staged}"
}

# One-time delivery into a running session. Copy, deliver, and only then remove
# from the bucket: if the delivery fails, the files stay in the inbox and are
# retried next cycle rather than disappearing.
drain_inbox() {
  [ "$(to_bool "${USE_INBOX}")" = "1" ] || return 0

  local staged="${STAGE_DIR}/inbox"
  local count
  count="$(rc size "$(remote_inbox)" --json 2>/dev/null |
    sed -n 's/.*"count":\([0-9]*\).*/\1/p' | head -1)"
  count="${count:-0}"
  [ "${count}" -gt 0 ] || return 0

  rm -rf "${staged}"
  mkdir -p "${staged}"

  log "Inbox: delivering ${count} file(s) to ${INBOX_DEST}"
  if ! rc copy "$(remote_inbox)" "${staged}" --transfers 8 --stats-one-line --stats 30s; then
    err "Could not fetch inbox/ — leaving it in place for the next cycle."
    rm -rf "${staged}"
    return 0
  fi

  stage_readable "${staged}"

  if ! deliver_as_user "${staged}" "${HOME_DIR}/${INBOX_DEST}" clobber; then
    err "Could not deliver the inbox — leaving it in the bucket to retry."
    rm -rf "${staged}"
    return 0
  fi

  # Delivered. Now it can leave the bucket.
  rc delete "$(remote_inbox)" --rmdirs 2>/dev/null ||
    err "Delivered the inbox but could not clear it; the next cycle will deliver again."
  rm -rf "${staged}"
  log "Inbox: delivered and cleared"
}

# --- Quota ------------------------------------------------------------------

local_bytes() {
  rc size "${HOME_DIR}" --json 2>/dev/null |
    sed -n 's/.*"bytes":\([0-9]*\).*/\1/p' | head -1
}

local_files() {
  rc size "${HOME_DIR}" --json 2>/dev/null |
    sed -n 's/.*"count":\([0-9]*\).*/\1/p' | head -1
}

quota_bytes() {
  [ -n "${QUOTA}" ] || return 0
  numfmt --from=iec "${QUOTA}" 2>/dev/null
}

# Client-side, and honest about it: the desktop's `df` reports the container
# filesystem, not this. Size the volume behind $HOME_DIR to match if you want
# the number in `df` to mean something.
quota_exceeded() {
  local limit used
  limit="$(quota_bytes)"
  [ -n "${limit}" ] || return 1
  used="$(local_bytes)"
  [ -n "${used}" ] || return 1
  [ "${used}" -gt "${limit}" ]
}

warn_user() {
  local message="$1"
  {
    echo "QGIS Desktop — persistence warning"
    echo "=================================="
    echo ""
    echo "${message}"
    echo ""
    echo "Generated $(date -u '+%Y-%m-%d %H:%M:%S UTC') by the persistence"
    echo "service. This file is not itself backed up."
  } > "${WARNING_FILE}" 2>/dev/null || true
  chown "${HOME_UID}:${HOME_GID}" "${WARNING_FILE}" 2>/dev/null || true
}

clear_warning() {
  rm -f "${WARNING_FILE}" 2>/dev/null || true
}

# --- Commands ---------------------------------------------------------------

require_config() {
  [ "$(to_bool "${PERSIST_ENABLED}")" = "1" ] || die "QGIS_DESKTOP_PERSIST is not enabled."
  [ -n "${BUCKET}" ] || die "QGIS_DESKTOP_PERSIST_BUCKET is required."
  [ -n "${PREFIX}" ] || die "QGIS_DESKTOP_PERSIST_PREFIX is required."
  case "${PREFIX}" in
    /* | *..*)
      die "QGIS_DESKTOP_PERSIST_PREFIX='${PREFIX}' must be a relative path without '..'."
      ;;
  esac
  command -v rclone >/dev/null 2>&1 || die "rclone is not on PATH."
}

cmd_restore() {
  require_config
  write_rclone_config
  mapfile_filters

  log "=== Home persistence ==="
  log "remote:   $(remote_data)"
  log "local:    ${HOME_DIR}"

  lease_check || exit 1

  mkdir -p "${HOME_DIR}"

  # An empty or missing prefix is a first run, not a failure.
  local remote_files
  remote_files="$(rc size "$(remote_data)" --json 2>/dev/null |
    sed -n 's/.*"count":\([0-9]*\).*/\1/p' | head -1)"
  remote_files="${remote_files:-0}"

  if [ "${remote_files}" -eq 0 ]; then
    log "Nothing in the bucket yet — starting from the image's home directory."
  else
    log "Restoring ${remote_files} file(s)…"
    # copy, not sync: whatever the image ships (panel config, wallpaper seed)
    # stays unless the bucket has its own version.
    if ! rc copy "$(remote_data)" "${HOME_DIR}" \
      "${FILTERS[@]}" --transfers 8 --checkers 16 --stats-one-line --stats 30s; then
      # Do NOT write the sentinel. Without it `push` refuses to run, so a failed
      # restore can never propagate an empty home over good data in the bucket.
      die "Restore failed. Not starting the sync loop — the bucket is untouched."
    fi
  fi

  chown -R "${HOME_UID}:${HOME_GID}" "${HOME_DIR}" 2>/dev/null || true

  # Anything the operator has staged for this user. After the restore, so the
  # user's own copy of a file always wins.
  mkdir -p "${STAGE_DIR}"
  chmod 0755 "${STAGE_DIR}"
  ensure_prefixes
  apply_provision
  drain_inbox

  mkdir -p "${STATE_DIR}"
  date -u '+%Y-%m-%dT%H:%M:%SZ' > "${SENTINEL}"
  local_files > "${COUNT_FILE}" 2>/dev/null || echo 0 > "${COUNT_FILE}"
  lease_write

  log "Restore complete. Files: $(cat "${COUNT_FILE}" 2>/dev/null || echo '?')"
  clear_warning
  log "========================"
}

cmd_push() {
  require_config
  [ -f "${RCLONE_CONF}" ] || write_rclone_config
  mapfile_filters

  local final="${1:-}"

  # Guard 1: never push without a restore this boot. A container that came up,
  # failed to restore, and then pushed would replace a good home with an empty
  # one — the exact catastrophe this feature exists to prevent.
  if [ ! -f "${SENTINEL}" ]; then
    err "No successful restore this boot — refusing to push."
    return 1
  fi

  # Guard 2: quota. Stop growing the bucket, and tell the user in a file they
  # will actually see, since they have no terminal to read logs in.
  if quota_exceeded; then
    local used limit
    used="$(local_bytes)"
    limit="$(quota_bytes)"
    err "Over quota: $(numfmt --to=iec "${used}") used of $(numfmt --to=iec "${limit}") — skipping push."
    warn_user "Your home directory is $(numfmt --to=iec "${used}"), over the $(numfmt --to=iec "${limit}") limit.

NOTHING IS BEING SAVED until you free up space. Delete files you do not
need — anything under ~/.cache is never saved anyway — and the next
save will happen automatically within ${INTERVAL} seconds."
    return 1
  fi

  # Guard 3: a sudden collapse in file count is more likely a broken mount or a
  # wiped home than a real deletion. Skip the push and let a human look.
  local now_files last_files threshold
  now_files="$(local_files)"
  now_files="${now_files:-0}"
  last_files="$(cat "${COUNT_FILE}" 2>/dev/null || echo 0)"
  if [ "${last_files}" -gt 20 ] && [ "${SHRINK_GUARD}" -gt 0 ]; then
    threshold=$((last_files * SHRINK_GUARD / 100))
    if [ "${now_files}" -lt "${threshold}" ]; then
      err "Home directory shrank from ${last_files} to ${now_files} files — refusing to push."
      err "Set QGIS_DESKTOP_PERSIST_SHRINK_GUARD=0 to override, or push manually."
      warn_user "A large number of files disappeared from your home directory
(${last_files} -> ${now_files}), so saving has been paused to avoid
deleting them from the backup too.

If you deleted them deliberately, tell your administrator — they can
resume saving. If you did not, your files may still be in the backup."
      return 1
    fi
  fi

  local -a args=(
    sync "${HOME_DIR}" "$(remote_data)"
    "${FILTERS[@]}"
    --transfers 8 --checkers 16
    --stats-one-line --stats 60s
    # Symlinks are skipped rather than followed: the local side is written by
    # an unprivileged user, and following links would let them decide what gets
    # copied into the bucket.
    --skip-links
  )

  # Guard 4: replaced and deleted objects move aside instead of vanishing, so a
  # bad sync is recoverable without provider-side versioning.
  if [ "$(to_bool "${KEEP_TRASH}")" = "1" ]; then
    args+=(--backup-dir "$(remote_trash)/$(date -u '+%Y%m%dT%H%M%SZ')")
  fi

  if [ -n "${EXTRA_RCLONE_ARGS}" ]; then
    read -r -a extra <<< "${EXTRA_RCLONE_ARGS}"
    args+=("${extra[@]}")
  fi

  if [ -n "${final}" ]; then
    log "Final save before shutdown…"
  fi

  if rc "${args[@]}"; then
    printf '%s' "${now_files}" > "${COUNT_FILE}"
    lease_write
    clear_warning
    log "Saved ${now_files} file(s), $(numfmt --to=iec "$(local_bytes)" 2>/dev/null || echo '?')."
    return 0
  fi

  err "Save failed. Will retry in ${INTERVAL}s."
  return 1
}

cmd_loop() {
  require_config
  log "Sync loop started — saving every ${INTERVAL}s."
  while :; do
    sleep "${INTERVAL}"
    # Deliver before saving: a file dropped into the inbox reaches the desktop
    # this cycle, and is part of the home directory the save then mirrors.
    drain_inbox || true
    cmd_push || true
  done
}

cmd_flush() {
  cmd_push final
  local rc_status=$?
  lease_release
  return "${rc_status}"
}

cmd_release() {
  require_config
  write_rclone_config
  if [ "${2:-}" = "--force" ] || [ "${1:-}" = "--force" ]; then
    log "Force-releasing the lease."
    rc deletefile "$(remote_lease)" 2>/dev/null || true
    return 0
  fi
  lease_release
}

cmd_status() {
  if [ "$(to_bool "${PERSIST_ENABLED}")" != "1" ]; then
    echo "Persistence: disabled (QGIS_DESKTOP_PERSIST=0)"
    return 0
  fi
  require_config
  [ -f "${RCLONE_CONF}" ] || write_rclone_config

  echo "Persistence: enabled"
  echo "  type:      ${REMOTE_TYPE}"
  echo "  remote:    $(remote_data)"
  [ -n "${ENDPOINT}" ] && echo "  endpoint:  ${ENDPOINT}"
  echo "  local:     ${HOME_DIR}"
  echo "  interval:  ${INTERVAL}s"
  echo "  quota:     ${QUOTA:-none}"
  echo "  trash:     $([ "$(to_bool "${KEEP_TRASH}")" = 1 ] && echo on || echo off)"
  echo "  lease:     $([ "$(to_bool "${USE_LEASE}")" = 1 ] && echo "on (${LEASE_TTL}s)" || echo off)"
  echo "  restored:  $(cat "${SENTINEL}" 2>/dev/null || echo 'not this boot')"
  echo "  usage:     $(numfmt --to=iec "$(local_bytes)" 2>/dev/null || echo '?') in $(local_files 2>/dev/null || echo '?') file(s)"
}

cmd_deliver() {
  require_config
  [ -f "${RCLONE_CONF}" ] || write_rclone_config
  mkdir -p "${STAGE_DIR}"
  chmod 0755 "${STAGE_DIR}"
  ensure_prefixes
  apply_provision
  drain_inbox
}

case "${COMMAND}" in
  restore) cmd_restore ;;
  push) cmd_push ;;
  loop) cmd_loop ;;
  flush) cmd_flush ;;
  deliver) cmd_deliver ;;
  release) shift; cmd_release "$@" ;;
  status) cmd_status ;;
  *)
    err "usage: $(basename "$0") [restore|push|loop|flush|deliver|release|status]"
    exit 2
    ;;
esac

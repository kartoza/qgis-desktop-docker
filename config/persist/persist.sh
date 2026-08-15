#!/usr/bin/env bash
# Home-directory persistence for one user, one container.
#
# The home directory is an ordinary local filesystem — POSIX semantics, real
# locking, SQLite that does not corrupt — and object storage is the durable
# copy behind it. This script moves data between the two:
#
#   restore   remote -> local, once, BEFORE the desktop starts
#   push      local  -> remote, guarded, repeatedly
#   loop      push on an interval until killed
#   flush     a final push, on the way down
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

# Runtime state, root-only.
STATE_DIR="${QGIS_DESKTOP_PERSIST_STATE_DIR:-/run/qgis-desktop/persist}"
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

  local access secret token
  umask 077

  case "${REMOTE_TYPE}" in
    local)
      cat > "${RCLONE_CONF}" <<'CFG'
[persist]
type = local
CFG
      ;;
    s3)
      access="$(read_secret QGIS_DESKTOP_PERSIST_ACCESS_KEY)"
      secret="$(read_secret QGIS_DESKTOP_PERSIST_SECRET_KEY)"
      token="$(read_secret QGIS_DESKTOP_PERSIST_SESSION_TOKEN)"
      [ -n "${access}" ] || die "QGIS_DESKTOP_PERSIST_ACCESS_KEY (or _FILE) is required."
      [ -n "${secret}" ] || die "QGIS_DESKTOP_PERSIST_SECRET_KEY (or _FILE) is required."

      {
        echo "[persist]"
        echo "type = s3"
        echo "provider = ${PROVIDER}"
        echo "access_key_id = ${access}"
        echo "secret_access_key = ${secret}"
        [ -n "${token}" ] && echo "session_token = ${token}"
        [ -n "${ENDPOINT}" ] && echo "endpoint = ${ENDPOINT}"
        echo "region = ${REGION}"
        # Object storage has no atomic rename; without this rclone tries one.
        echo "no_check_bucket = true"
      } > "${RCLONE_CONF}"
      ;;
    *)
      die "QGIS_DESKTOP_PERSIST_TYPE='${REMOTE_TYPE}' is not one of s3|local."
      ;;
  esac

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

case "${COMMAND}" in
  restore) cmd_restore ;;
  push) cmd_push ;;
  loop) cmd_loop ;;
  flush) cmd_flush ;;
  release) shift; cmd_release "$@" ;;
  status) cmd_status ;;
  *)
    err "usage: $(basename "$0") [restore|push|loop|flush|release|status]"
    exit 2
    ;;
esac

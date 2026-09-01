#!/usr/bin/env bash
# Root entrypoint for the QGIS Desktop container.
#
# Responsibilities (in order):
#   1. Read QGIS_DESKTOP_* env vars and resolve the authentication mode.
#   2. If lockdown is enabled, resolve allowlist hostnames and install nftables
#      rules that drop all egress traffic except to the allowlist + DNS.
#   3. In QGIS_DESKTOP_AUTH_MODE=oidc, start oauth2-proxy as the public listener with
#      the desktop moved behind it on loopback.
#   4. Drop capabilities and switch to the unprivileged `user` account.
#   5. Exec start-desktop (KasmVNC + XFCE + QGIS), or lightdm in greeter mode.
#
# Requires --cap-add=NET_ADMIN on `docker run` when lockdown is enabled.

set -euo pipefail

QGIS_DESKTOP_EGRESS_LOCKDOWN="${QGIS_DESKTOP_EGRESS_LOCKDOWN:-1}"
QGIS_DESKTOP_EGRESS_ALLOW="${QGIS_DESKTOP_EGRESS_ALLOW:-}"

to_bool() {
  case "${1,,}" in
    1|yes|true|on|enabled) echo 1 ;;
    *) echo 0 ;;
  esac
}

LOCKDOWN=$(to_bool "${QGIS_DESKTOP_EGRESS_LOCKDOWN}")

# --- Renamed variables ------------------------------------------------------
# Everything that is this project's own behaviour moved from the KASM_ prefix
# to QGIS_DESKTOP_ in 2.0.0. Only the knobs that map straight onto a KasmVNC
# flag — the clipboard, watermark and DLP controls — kept theirs.
#
# A container started with the old names must not come up: silently ignoring
# QGIS_DESKTOP_EGRESS_ALLOW or QGIS_DESKTOP_AUTH_MODE would mean a deployment
# that thinks it is locked down running wide open on a default password. So we
# refuse to boot and name the replacement for each one.
check_renamed_variables() {
  local -a renames=(
    "KASM_AUTH_MODE=QGIS_DESKTOP_AUTH_MODE"
    "KASM_AUTH=QGIS_DESKTOP_AUTH_MODE (use =none instead of =0)"
    "KASM_USERS=QGIS_DESKTOP_USERS"
    "KASM_USERS_FILE=QGIS_DESKTOP_USERS_FILE"
    "KASM_EGRESS_LOCKDOWN=QGIS_DESKTOP_EGRESS_LOCKDOWN"
    "KASM_EGRESS_ALLOW=QGIS_DESKTOP_EGRESS_ALLOW"
    "KASM_ALLOW_TERMINAL=QGIS_DESKTOP_ALLOW_TERMINAL"
    "KASM_BIND_INTERFACE=QGIS_DESKTOP_BIND_INTERFACE"
    "KASM_OIDC_ISSUER_URL=QGIS_DESKTOP_OIDC_ISSUER_URL"
    "KASM_OIDC_CLIENT_ID=QGIS_DESKTOP_OIDC_CLIENT_ID"
    "KASM_OIDC_CLIENT_SECRET=QGIS_DESKTOP_OIDC_CLIENT_SECRET"
    "KASM_OIDC_CLIENT_SECRET_FILE=QGIS_DESKTOP_OIDC_CLIENT_SECRET_FILE"
    "KASM_OIDC_REDIRECT_URL=QGIS_DESKTOP_OIDC_REDIRECT_URL"
    "KASM_OIDC_COOKIE_SECRET=QGIS_DESKTOP_OIDC_COOKIE_SECRET"
    "KASM_OIDC_COOKIE_SECRET_FILE=QGIS_DESKTOP_OIDC_COOKIE_SECRET_FILE"
    "KASM_OIDC_PROVIDER=QGIS_DESKTOP_OIDC_PROVIDER"
    "KASM_OIDC_SCOPE=QGIS_DESKTOP_OIDC_SCOPE"
    "KASM_OIDC_EMAIL_DOMAINS=QGIS_DESKTOP_OIDC_EMAIL_DOMAINS"
    "KASM_OIDC_EMAIL_CLAIM=QGIS_DESKTOP_OIDC_EMAIL_CLAIM"
    "KASM_OIDC_ALLOWED_GROUPS=QGIS_DESKTOP_OIDC_ALLOWED_GROUPS"
    "KASM_OIDC_ALLOWED_ROLES=QGIS_DESKTOP_OIDC_ALLOWED_ROLES"
    "KASM_OIDC_INNER_MODE=QGIS_DESKTOP_OIDC_INNER_MODE"
    "KASM_OIDC_UPSTREAM_PORT=QGIS_DESKTOP_OIDC_UPSTREAM_PORT"
    "KASM_OIDC_LISTEN_PORT=QGIS_DESKTOP_OIDC_LISTEN_PORT"
    "KASM_OIDC_COOKIE_SECURE=QGIS_DESKTOP_OIDC_COOKIE_SECURE"
    "KASM_OIDC_COOKIE_EXPIRE=QGIS_DESKTOP_OIDC_COOKIE_EXPIRE"
    "KASM_OIDC_TLS_CERT_FILE=QGIS_DESKTOP_OIDC_TLS_CERT_FILE"
    "KASM_OIDC_TLS_KEY_FILE=QGIS_DESKTOP_OIDC_TLS_KEY_FILE"
    "KASM_OIDC_REVERSE_PROXY=QGIS_DESKTOP_OIDC_REVERSE_PROXY"
    "KASM_OIDC_INSECURE_SKIP_VERIFY=QGIS_DESKTOP_OIDC_INSECURE_SKIP_VERIFY"
    "KASM_OIDC_EXTRA_ARGS=QGIS_DESKTOP_OIDC_EXTRA_ARGS"
  )

  local -a found=()
  local entry old new
  for entry in "${renames[@]}"; do
    old="${entry%%=*}"
    new="${entry#*=}"
    if [ -n "${!old:-}" ]; then
      found+=("  ${old}  ->  ${new}")
    fi
  done

  if [ "${#found[@]}" -gt 0 ]; then
    {
      echo "ERROR: these environment variables were renamed in 2.0.0 and are no longer read:"
      echo ""
      printf '%s\n' "${found[@]}"
      echo ""
      echo "       The KASM_ prefix now means 'a KasmVNC setting' and nothing else —"
      echo "       the clipboard, watermark and DLP controls keep it because they map"
      echo "       directly onto Xkasmvnc flags. Everything above is this project's own"
      echo "       behaviour and moved to QGIS_DESKTOP_."
      echo ""
      echo "       Refusing to start rather than ignoring them: a container that was"
      echo "       locked down under the old names would otherwise come up with no"
      echo "       allowlist and a default password."
      echo ""
      echo "       See docs/configuration/index.md#migrating-from-1x"
    } >&2
    exit 1
  fi
}

check_renamed_variables

# The default credentials file moved with the variables: /etc/kasmvnc/users was
# never a KasmVNC path, only one that looked like one. A file still mounted at
# the old location would be silently ignored and the container would fall back
# to the default VNC_USER/VNC_PW — so treat it like a renamed variable.
if [ -z "${QGIS_DESKTOP_USERS_FILE:-}" ] &&
  [ -r /etc/kasmvnc/users ] && [ ! -r /etc/qgis-desktop/users ]; then
  {
    echo "ERROR: found a credentials file at the old path /etc/kasmvnc/users."
    echo ""
    echo "       The default moved to /etc/qgis-desktop/users in 2.0.0. Mount it"
    echo "       there instead, or set QGIS_DESKTOP_USERS_FILE=/etc/kasmvnc/users"
    echo "       explicitly to keep the old location."
    echo ""
    echo "       Refusing to start rather than ignoring it: the fallback would be"
    echo "       the default single user and password."
  } >&2
  exit 1
fi

# Take every secret out of the environment.
#
# The desktop is started from this process, so it inherits this environment —
# and a user with QGIS's Python console can read their own /proc/self/environ.
# Anything left here is readable by the person we are trying to keep it from.
# Each of these has already been consumed by the time this runs: written into a
# root-owned config file, or hashed into ~/.kasmpasswd.
#
# The _FILE variants are deliberately kept: a path is not a secret, and the
# services re-read them as root. Mount those files so uid 1000 cannot read
# them — root-owned 0400 is the intent.
# NOT scrubbed: QGIS_DESKTOP_USERS and VNC_PW. start-desktop.sh reads them
# after the privilege drop, to build ~/.kasmpasswd — removing them here would
# break `basic` auth. With one user per container that leaks a user their own
# password, which is no leak at all. Put several accounts in
# QGIS_DESKTOP_USERS and each can read the others', so use `greeter` (LightDM
# scrubs the environment before spawning a session) or `oidc` for that.
scrub_secrets() {
  unset \
    QGIS_DESKTOP_PERSIST_ACCESS_KEY \
    QGIS_DESKTOP_PERSIST_SECRET_KEY \
    QGIS_DESKTOP_PERSIST_SESSION_TOKEN \
    QGIS_DESKTOP_OIDC_CLIENT_SECRET \
    QGIS_DESKTOP_OIDC_COOKIE_SECRET
}

# Return 0 if the given token looks like an IPv4 address or CIDR (very loose).
is_ipv4_or_cidr() {
  [[ "$1" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}(/[0-9]{1,2})?$ ]]
}

# Resolve a hostname to one or more IPv4 addresses via getent.
# Prints one IP per line; prints nothing (and returns 1) on failure.
resolve_host() {
  local host="$1"
  local ips
  ips="$(getent ahostsv4 "$host" 2>/dev/null | awk '{print $1}' | sort -u || true)"
  if [ -z "$ips" ]; then
    return 1
  fi
  printf '%s\n' "$ips"
}

setup_egress_lockdown() {
  echo "=== Egress lockdown ==="
  echo "Configured allowlist: ${QGIS_DESKTOP_EGRESS_ALLOW:-<empty>}"

  # Confirm we actually have permission to touch nftables.
  if ! nft list ruleset >/dev/null 2>&1; then
    cat >&2 <<'MISSING_CAP'
ERROR: QGIS_DESKTOP_EGRESS_LOCKDOWN=1 but the container cannot manage nftables rules.
       This almost always means the container was started without NET_ADMIN.

       Fix by adding --cap-add=NET_ADMIN to `docker run`:

         docker run --cap-add=NET_ADMIN ...

       Or in docker-compose:

         cap_add:
           - NET_ADMIN

       If you REALLY want unrestricted network access (dev only), set
       QGIS_DESKTOP_EGRESS_LOCKDOWN=0 explicitly. The default is on for safety.
MISSING_CAP
    exit 1
  fi

  # Hostname entries are useless without a resolver. Say so loudly rather than
  # letting every name quietly fall off the allowlist — the filter still fails
  # closed, but an operator who allowlisted `db` deserves to know why nothing
  # can reach it.
  if ! command -v getent >/dev/null 2>&1; then
    echo "ERROR: getent is not on PATH — hostname entries in QGIS_DESKTOP_EGRESS_ALLOW" >&2
    echo "       cannot be resolved and will be dropped. IP and CIDR entries still" >&2
    echo "       work. This is a packaging fault; please report it." >&2
  fi

  # Build the resolved allow list. Accept IPs/CIDRs verbatim; resolve hostnames.
  local -a allow_ips=()
  local raw resolved
  while IFS= read -r raw; do
    raw="${raw//[[:space:]]/}"
    [ -z "$raw" ] && continue
    if is_ipv4_or_cidr "$raw"; then
      allow_ips+=("$raw")
      echo "  allow ${raw} (literal)"
      continue
    fi
    if resolved="$(resolve_host "$raw")"; then
      while IFS= read -r ip; do
        [ -z "$ip" ] && continue
        allow_ips+=("$ip")
        echo "  allow ${raw} -> ${ip}"
      done <<< "$resolved"
    else
      echo "WARN: could not resolve '${raw}' at startup; skipping" >&2
    fi
  done < <(printf '%s\n' "${QGIS_DESKTOP_EGRESS_ALLOW}" | tr ',' '\n')

  # Replace only OUR table, never the whole ruleset.
  #
  # `nft flush ruleset` would take Docker's `ip nat` table with it — the table
  # holding the DNAT rules that make the embedded resolver at 127.0.0.11:53
  # answer at all. nftables even labels it "managed by iptables-nft, do not
  # touch". Flushing it leaves the container unable to resolve any hostname for
  # the rest of its life on any user-defined or compose network, which looks
  # like a broken allowlist but is really a broken resolver.
  nft delete table inet qgis_desktop_egress 2>/dev/null || true

  nft -f - <<'NFTABLES'
table inet qgis_desktop_egress {
    chain input {
        # Ingress is not filtered — the published port has to stay reachable.
        type filter hook input priority filter; policy accept;
    }
    chain forward {
        type filter hook forward priority filter; policy drop;
    }
    chain output {
        type filter hook output priority filter; policy drop;

        # Always: loopback traffic. This also covers DNS to Docker's embedded
        # resolver, which by then has been DNAT'ed to a high port on 127.0.0.11.
        oif "lo" accept

        # Always: return traffic for connections we initiated.
        ct state established,related accept
    }
}
NFTABLES

  # DNS: Docker's embedded resolver is always at 127.0.0.11 on user-defined
  # bridge networks. Allow it plus anything currently in /etc/resolv.conf.
  nft add rule inet qgis_desktop_egress output ip daddr 127.0.0.11 udp dport 53 accept
  nft add rule inet qgis_desktop_egress output ip daddr 127.0.0.11 tcp dport 53 accept
  if [ -r /etc/resolv.conf ]; then
    local ns
    while IFS= read -r ns; do
      [ -z "$ns" ] && continue
      [ "$ns" = "127.0.0.11" ] && continue
      nft add rule inet qgis_desktop_egress output ip daddr "$ns" udp dport 53 accept
      nft add rule inet qgis_desktop_egress output ip daddr "$ns" tcp dport 53 accept
    done < <(awk '/^nameserver /{print $2}' /etc/resolv.conf)
  fi

  # The user-supplied allowlist.
  local target
  for target in "${allow_ips[@]}"; do
    if [[ "$target" == *"/"* ]]; then
      nft add rule inet qgis_desktop_egress output ip daddr "$target" accept
    else
      nft add rule inet qgis_desktop_egress output ip daddr "$target" accept
    fi
  done

  echo "Egress lockdown: ACTIVE (${#allow_ips[@]} allowlist entries)"
  echo "======================="
}

# Authentication mode selection. Resolved BEFORE the egress filter is installed
# because oidc mode has to add the identity provider to the allowlist — without
# that, oauth2-proxy could never reach the IdP's discovery endpoint.
#
#   QGIS_DESKTOP_AUTH_MODE=basic    (default) — HTTP BasicAuth on the web endpoint,
#                                        credentials from QGIS_DESKTOP_USERS_FILE /
#                                        QGIS_DESKTOP_USERS / legacy VNC_USER+VNC_PW.
#                                        start-desktop.sh drops to uid 1000.
#   QGIS_DESKTOP_AUTH_MODE=none               — no auth (dev only).
#   QGIS_DESKTOP_AUTH_MODE=greeter            — LightDM greeter inside the X session.
#                                        Users materialised as real Linux
#                                        accounts, lightdm run as root so it
#                                        can spawn each session as its user.
#   QGIS_DESKTOP_AUTH_MODE=oidc               — oauth2-proxy owns the published port and
#                                        authenticates against an OIDC provider
#                                        (Keycloak by default); KasmVNC is moved
#                                        to a loopback-only port behind it.
#                                        Added in 2.0.0.
QGIS_DESKTOP_AUTH_MODE="${QGIS_DESKTOP_AUTH_MODE:-basic}"

case "${QGIS_DESKTOP_AUTH_MODE,,}" in
  none | basic | greeter) QGIS_DESKTOP_AUTH_MODE="${QGIS_DESKTOP_AUTH_MODE,,}" ;;
  oidc | keycloak) QGIS_DESKTOP_AUTH_MODE="oidc" ;;
  *)
    echo "ERROR: QGIS_DESKTOP_AUTH_MODE='${QGIS_DESKTOP_AUTH_MODE}' is not one of none|basic|greeter|oidc." >&2
    exit 1
    ;;
esac
export QGIS_DESKTOP_AUTH_MODE

echo "=== Auth mode ==="
echo "QGIS_DESKTOP_AUTH_MODE=${QGIS_DESKTOP_AUTH_MODE}"

# The mode the desktop itself boots in. Identical to QGIS_DESKTOP_AUTH_MODE except
# under oidc, where the proxy is the auth boundary and the desktop runs in
# whichever inner mode was requested.
EFFECTIVE_AUTH_MODE="${QGIS_DESKTOP_AUTH_MODE}"
QGIS_DESKTOP_OIDC_UPSTREAM_PORT="${QGIS_DESKTOP_OIDC_UPSTREAM_PORT:-6901}"

# Host part of a URL: strip scheme, userinfo, path and port. IPv6 literals are
# not handled — the nftables rules are IPv4-only anyway.
url_host() {
  local url="${1#*://}"
  url="${url%%/*}"
  url="${url##*@}"
  url="${url%%:*}"
  printf '%s' "${url}"
}

if [ "${QGIS_DESKTOP_AUTH_MODE}" = "oidc" ]; then
  QGIS_DESKTOP_OIDC_INNER_MODE="${QGIS_DESKTOP_OIDC_INNER_MODE:-none}"
  case "${QGIS_DESKTOP_OIDC_INNER_MODE,,}" in
    none | greeter) EFFECTIVE_AUTH_MODE="${QGIS_DESKTOP_OIDC_INNER_MODE,,}" ;;
    *)
      echo "ERROR: QGIS_DESKTOP_OIDC_INNER_MODE='${QGIS_DESKTOP_OIDC_INNER_MODE}' is not one of none|greeter." >&2
      echo "       ('basic' is deliberately unsupported: a second password prompt behind" >&2
      echo "       single sign-on adds nothing.)" >&2
      exit 1
      ;;
  esac
  echo "QGIS_DESKTOP_OIDC_INNER_MODE=${EFFECTIVE_AUTH_MODE} (how the desktop behind the proxy authenticates)"

  # oauth2-proxy runs OIDC discovery and the token exchange server-side, so the
  # identity provider has to stay reachable with the egress filter on. Append
  # rather than replace, so an operator-supplied allowlist survives.
  if [ -n "${QGIS_DESKTOP_OIDC_ISSUER_URL:-}" ]; then
    OIDC_ISSUER_HOST="$(url_host "${QGIS_DESKTOP_OIDC_ISSUER_URL}")"
    if [ -n "${OIDC_ISSUER_HOST}" ]; then
      QGIS_DESKTOP_EGRESS_ALLOW="${QGIS_DESKTOP_EGRESS_ALLOW:+${QGIS_DESKTOP_EGRESS_ALLOW},}${OIDC_ISSUER_HOST}"
      echo "Egress: adding identity provider '${OIDC_ISSUER_HOST}' to the allowlist"
    fi
  fi
fi

# Home persistence needs the object store reachable through the egress filter,
# for the same reason: the transfer is server-side, not in the user's browser.
QGIS_DESKTOP_PERSIST="${QGIS_DESKTOP_PERSIST:-0}"
PERSIST_ACTIVE=0
if [ "$(to_bool "${QGIS_DESKTOP_PERSIST}")" = "1" ] &&
  [ -n "${QGIS_DESKTOP_PERSIST_ENDPOINT:-}" ]; then
  PERSIST_HOST="$(url_host "${QGIS_DESKTOP_PERSIST_ENDPOINT}")"
  if [ -n "${PERSIST_HOST}" ]; then
    QGIS_DESKTOP_EGRESS_ALLOW="${QGIS_DESKTOP_EGRESS_ALLOW:+${QGIS_DESKTOP_EGRESS_ALLOW},}${PERSIST_HOST}"
    echo "Egress: adding object store '${PERSIST_HOST}' to the allowlist"
  fi
fi

if [ "${LOCKDOWN}" = "1" ]; then
  setup_egress_lockdown
else
  echo "WARN: Egress lockdown DISABLED (QGIS_DESKTOP_EGRESS_LOCKDOWN=${QGIS_DESKTOP_EGRESS_LOCKDOWN})."
  echo "      Container has unrestricted network access."
fi

# Whether this process actually has a root phase to spend. A Kubernetes pod
# with securityContext.runAsUser set (or any launcher that skips straight to
# an unprivileged UID) never gets one — the container starts as UID 1000
# directly, and everything below that assumes "we are root right now" would
# otherwise abort the whole entrypoint under `set -e` on the first chown.
RUNNING_AS_ROOT=0
[ "$(id -u)" = "0" ] && RUNNING_AS_ROOT=1

# Prepare /tmp/.X11-unix with the ownership/mode the X server expects.
# When start-desktop runs as uid 1000 and creates this dir itself, Xkasmvnc
# logs "_XSERVTransmkdir: Owner of /tmp/.X11-unix should be set to root"
# and can misbehave. Doing it here (as root) with mode 1777 keeps X happy
# while still letting the uid 1000 process create per-display sockets under it.
#
# Without a root phase (RUNNING_AS_ROOT=0) we cannot chown to root at all —
# skip it and settle for uid-1000-owned + mode 1777, which is what
# start-desktop.sh would have produced anyway had it created the dir itself.
mkdir -p /tmp/.X11-unix
if [ "${RUNNING_AS_ROOT}" = "1" ]; then
  chown root:root /tmp/.X11-unix
else
  echo "WARN: not running as root (uid $(id -u)) — leaving /tmp/.X11-unix owned by the" >&2
  echo "      current user instead of root. Xkasmvnc may log _XSERVTransmkdir about" >&2
  echo "      this; it is not fatal. See docs/configuration/permissions.md." >&2
fi
chmod 1777 /tmp/.X11-unix

# /tmp/.ICE-unix is the socket dir for the X Session Management Protocol
# (XSMP). xfce4-session uses XSMP to spawn xfce4-panel, xfdesktop, xfwm4
# etc. If the dir doesn't exist, non-root sessions can't create it
# (_IceTransmkdir errors on euid != 0) and xfce4-session comes up but its
# children never launch — the user sees an empty desktop.
mkdir -p /tmp/.ICE-unix
[ "${RUNNING_AS_ROOT}" = "1" ] && chown root:root /tmp/.ICE-unix
chmod 1777 /tmp/.ICE-unix

# XDG runtime dir, owned by the target user. When we are not root, uid 1000
# already created it above via mkdir -p, so this chown is a same-owner no-op —
# but skip it outright rather than rely on that when RUNNING_AS_ROOT=0, since
# a non-default runAsUser would make it a real (failing) ownership change.
mkdir -p /tmp/runtime-user
[ "${RUNNING_AS_ROOT}" = "1" ] && chown 1000:1000 /tmp/runtime-user
chmod 700 /tmp/runtime-user

# PostgreSQL service file (pg_service.conf). QGIS/libpq use this to resolve
# named connections (`service=foo` in a DB URI) without embedding host/user/
# password in project files. If PG_SERVICE_CONF is set, its contents are
# written to the target user's ~/.pg_service.conf, creating or overwriting
# it. Mode 0600 since the file commonly holds credentials.
write_pg_service_conf() {
  local home="$1" uid="$2" gid="$3"
  [ -z "${PG_SERVICE_CONF:-}" ] && return 0
  mkdir -p "${home}"
  # Accept literal backslash-n as a line separator too, not just real
  # newlines. docker-compose `environment:` lists, `.env` files and a plain
  # `-e KEY=value` flag often can't carry an embedded newline, so `\n` is
  # the escape people reach for — without this, libpq's ini parser sees the
  # whole file as one line and silently fails to find host/port/dbname. A
  # value that already has real newlines is untouched.
  local content="${PG_SERVICE_CONF//\\n/$'\n'}"
  printf '%s\n' "${content}" > "${home}/.pg_service.conf"
  [ "${RUNNING_AS_ROOT}" = "1" ] && chown "${uid}:${gid}" "${home}/.pg_service.conf"
  chmod 0600 "${home}/.pg_service.conf"
  echo "pg_service.conf: written to ${home}/.pg_service.conf"
}

# --- Home persistence -------------------------------------------------------
# The home directory is a local filesystem; object storage holds the durable
# copy. Restore it BEFORE the desktop starts — this is the only moment root
# writes into the home directory, and no user process exists yet to plant a
# symlink in the way.
if [ "$(to_bool "${QGIS_DESKTOP_PERSIST}")" = "1" ]; then
  if qgis-desktop-persist restore; then
    PERSIST_ACTIVE=1
  elif [ "$(to_bool "${QGIS_DESKTOP_PERSIST_REQUIRED:-1}")" = "1" ]; then
    echo "FATAL: home persistence is enabled but the restore failed." >&2
    echo "       Refusing to start a desktop with an empty home directory that the" >&2
    echo "       user would take for their own. Nothing has been written to the" >&2
    echo "       bucket. Set QGIS_DESKTOP_PERSIST_REQUIRED=0 to start anyway." >&2
    exit 1
  else
    echo "WARN: restore failed and QGIS_DESKTOP_PERSIST_REQUIRED=0 — continuing" >&2
    echo "      with a local-only home. Nothing will be saved." >&2
  fi
fi

# Written after any restore above, so an operator-supplied PG_SERVICE_CONF
# always wins over whatever a previous session happened to push to the bucket.
write_pg_service_conf /home/user 1000 1000

# Hands the container over to the desktop.
#
# Without persistence we exec, so the desktop becomes PID 1 and nothing sits in
# the way. With persistence we have to stay PID 1: SIGTERM is delivered to PID 1
# only, and that signal is the last chance to save before Kubernetes (or
# `docker stop`) follows up with SIGKILL. Exec'ing would throw that chance away.
run_desktop() {
  # Last line of defence: whatever path we took to get here, no unprivileged
  # process inherits a secret.
  scrub_secrets

  if [ "${PERSIST_ACTIVE}" != "1" ]; then
    exec "$@"
  fi

  qgis-desktop-persist loop &
  PERSIST_LOOP_PID=$!

  "$@" &
  DESKTOP_PID=$!

  # Bounded, because the grace period is finite: Kubernetes sends SIGKILL after
  # terminationGracePeriodSeconds (30s by default) whatever we are doing, and a
  # save still running at that point is a save that did not happen.
  # shellcheck disable=SC2329  # invoked from the trap below
  final_save() {
    echo "Shutting down — stopping the desktop and saving the home directory."
    kill -TERM "${PERSIST_LOOP_PID}" 2>/dev/null || true
    kill -TERM "${DESKTOP_PID}" 2>/dev/null || true
    wait "${DESKTOP_PID}" 2>/dev/null || true
    if ! timeout "${QGIS_DESKTOP_PERSIST_FLUSH_TIMEOUT:-25}" qgis-desktop-persist flush; then
      echo "WARN: the final save did not finish. Work since the last periodic save" >&2
      echo "      may be lost; the bucket still holds that last save." >&2
    fi
  }

  trap 'final_save; exit 0' TERM INT

  wait "${DESKTOP_PID}"
  DESKTOP_STATUS=$?

  # The desktop exited by itself — the user logged out, or X died. Same drill.
  kill -TERM "${PERSIST_LOOP_PID}" 2>/dev/null || true
  timeout "${QGIS_DESKTOP_PERSIST_FLUSH_TIMEOUT:-25}" qgis-desktop-persist flush ||
    echo "WARN: the final save did not finish." >&2
  exit "${DESKTOP_STATUS}"
}

# Terminal access. Secure deployments hand users a mapping application, not a
# shell: QGIS_DESKTOP_ALLOW_TERMINAL=0 removes the terminal emulators (and the dialogs
# that would run an arbitrary command) from the container before the desktop
# starts. Must happen while we are still root, and before any user session
# exists. See config/lockdown/disable-terminal.sh for what it closes and what
# it deliberately does not claim to close.
QGIS_DESKTOP_ALLOW_TERMINAL="${QGIS_DESKTOP_ALLOW_TERMINAL:-1}"
if [ "$(to_bool "${QGIS_DESKTOP_ALLOW_TERMINAL}")" = "1" ]; then
  # Clear any stale menu overrides from a previous locked-down run against the
  # same mounted home, so re-enabling actually re-enables.
  qgis-desktop-disable-terminal restore || true
else
  qgis-desktop-disable-terminal disable
fi

if [ "${QGIS_DESKTOP_AUTH_MODE}" = "oidc" ]; then
  echo "=== OIDC single sign-on ==="

  # Validates the configuration and materialises the secrets into a config file
  # only the proxy's UID can read. A non-zero exit is fatal on purpose: failing
  # to boot beats serving a desktop with nothing in front of it.
  qgis-desktop-oidc-config
  # From here the secret lives in that file, so take it out of the environment
  # before anything unprivileged inherits it.
  scrub_secrets

  # Move the desktop's own web endpoint to loopback so the proxy becomes the
  # only way in. Both launchers also read this file, because LightDM scrubs the
  # environment before spawning the X server and env vars would not reach the
  # xkasmvnc wrapper.
  mkdir -p /run/qgis-desktop
  cat > /run/qgis-desktop/listen.env <<LISTEN
VNC_PORT=${QGIS_DESKTOP_OIDC_UPSTREAM_PORT}
QGIS_DESKTOP_BIND_INTERFACE=127.0.0.1
LISTEN
  chmod 0644 /run/qgis-desktop/listen.env

  export QGIS_DESKTOP_OIDC_LISTEN_PORT="${VNC_PORT:-8443}"
  export QGIS_DESKTOP_OIDC_UPSTREAM_PORT
  export VNC_PORT="${QGIS_DESKTOP_OIDC_UPSTREAM_PORT}"
  export QGIS_DESKTOP_BIND_INTERFACE="127.0.0.1"

  # The proxy needs no privileges: its port is unprivileged and its config file
  # is owned by uid 1000. Same capability-clearing shape as the desktop below.
  setpriv \
    --reuid=1000 --regid=1000 --init-groups \
    --inh-caps=-all --ambient-caps=-all \
    -- qgis-desktop-oidc-proxy &
  OIDC_PROXY_PID=$!

  # If the proxy dies, the container must die with it — otherwise the desktop
  # would keep serving with nothing enforcing authentication. This shell is
  # about to exec into the desktop (so it becomes PID 1); the watchdog brings
  # the whole container down by signalling PID 1.
  (
    # A dead-but-unreaped child still answers `kill -0`, so check /proc for the
    # zombie state rather than trusting the signal alone.
    while [ -d "/proc/${OIDC_PROXY_PID}" ] &&
      ! grep -qE '^State:[[:space:]]+Z' "/proc/${OIDC_PROXY_PID}/status" 2>/dev/null; do
      sleep 5
    done
    echo "FATAL: the OIDC proxy exited — stopping the container." >&2
    kill -TERM 1 2>/dev/null || true
  ) &

  echo "OIDC proxy running as pid ${OIDC_PROXY_PID}; desktop bound to 127.0.0.1:${QGIS_DESKTOP_OIDC_UPSTREAM_PORT}"
fi

# Fill the deployment's management URL into the branded pages. Root, because the
# web root lives under /usr/share; before the privilege drop for the same
# reason. A no-op when branding is off or no URL is configured — it still leaves
# the "your desktop is still running" reminder in place, which is the part that
# matters for someone's bill.
if command -v qgis-desktop-manage-link >/dev/null 2>&1; then
  qgis-desktop-manage-link || echo "WARN: could not update the management link" >&2
fi
if [ "${EFFECTIVE_AUTH_MODE}" = "greeter" ]; then
  # Materialise users from the same credential sources basic mode uses, so
  # QGIS_DESKTOP_USERS / QGIS_DESKTOP_USERS_FILE / VNC_USER+VNC_PW all work identically.
  # PAM will authenticate against the resulting /etc/shadow entries. LightDM
  # then runs as root and spawns each successful login as its target user.
  QGIS_DESKTOP_USERS_FILE="${QGIS_DESKTOP_USERS_FILE:-/etc/qgis-desktop/users}"
  QGIS_DESKTOP_USERS="${QGIS_DESKTOP_USERS:-}"
  VNC_USER="${VNC_USER:-user}"
  VNC_PW="${VNC_PW:-password}"

  if [ -r "${QGIS_DESKTOP_USERS_FILE}" ]; then
    USER_LINES="$(grep -vE '^\s*(#|$)' "${QGIS_DESKTOP_USERS_FILE}" || true)"
    CRED_SOURCE="file ${QGIS_DESKTOP_USERS_FILE}"
  elif [ -n "${QGIS_DESKTOP_USERS}" ]; then
    USER_LINES="$(printf '%s\n' "${QGIS_DESKTOP_USERS}" | tr ',' '\n' | sed '/^\s*$/d')"
    CRED_SOURCE="QGIS_DESKTOP_USERS env"
  else
    USER_LINES="${VNC_USER}:${VNC_PW}"
    CRED_SOURCE="legacy VNC_USER/VNC_PW"
  fi

  echo "Greeter credentials: ${CRED_SOURCE}"

  # dockerTools may ship /etc/{passwd,group,shadow} as read-only nix-store
  # symlinks in some layer. Materialise real writable copies before we edit.
  # Failing to do this makes chpasswd/pam_chauthtok error with
  # "Permission denied" — /etc/shadow is unwritable, even for root.
  for f in /etc/passwd /etc/group /etc/shadow; do
    if [ -L "$f" ]; then
      cp --dereference "$f" "${f}.tmp"
      rm -f "$f"
      mv "${f}.tmp" "$f"
    fi
  done
  chmod 0644 /etc/passwd /etc/group
  # /etc/shadow is world-readable so pam_unix can read it after lightdm's
  # session child setuid's to the target user. Nixpkgs' unix_chkpwd
  # SUID helper isn't wired up in the container, so the non-root fallback
  # path pam_unix uses at 0640 fails with PAM_AUTHINFO_UNAVAIL.
  # Passwords are sha512crypt hashes and the container is otherwise
  # isolated; the exposure is limited to what a co-located process
  # already sees.
  chmod 0644 /etc/shadow
  chown root:root /etc/passwd /etc/group /etc/shadow

  next_uid=1001
  first_user=""
  user_count=0
  while IFS= read -r line; do
    [ -z "${line}" ] && continue
    if [[ "${line}" != *:* ]]; then
      echo "WARN: skipping malformed auth line (no ':'): '${line}'" >&2
      continue
    fi
    u="${line%%:*}"
    p="${line#*:}"
    if [ -z "${u}" ] || [ -z "${p}" ]; then
      echo "WARN: skipping auth line with empty user or password" >&2
      continue
    fi

    # If the user isn't in /etc/passwd yet, add them with a fresh UID and
    # a home directory. The baked image ships 'user' at UID 1000; the
    # QGIS_DESKTOP_USERS list may reuse that name or add new ones from 1001.
    if ! getent passwd "${u}" >/dev/null 2>&1; then
      while getent passwd "${next_uid}" >/dev/null 2>&1; do
        next_uid=$((next_uid + 1))
      done
      echo "${u}:x:${next_uid}:${next_uid}:${u}:/home/${u}:/bin/bash" >> /etc/passwd
      echo "${u}:x:${next_uid}:" >> /etc/group
      mkdir -p "/home/${u}"
      chown "${next_uid}:${next_uid}" "/home/${u}"
      chmod 700 "/home/${u}"
      next_uid=$((next_uid + 1))
    fi

    # Set / overwrite the password by editing /etc/shadow directly. We
    # bypass chpasswd (and its PAM stack) because pam_chauthtok wants
    # write access via PAM's own path, which fails inside nixpkgs docker
    # images. openssl passwd -6 emits a $6$…$… sha512crypt hash that
    # pam_unix.so happily accepts at login time.
    hash="$(openssl passwd -6 "${p}")"
    sed -i "/^${u}:/d" /etc/shadow
    printf '%s:%s:1::::::\n' "${u}" "${hash}" >> /etc/shadow

    u_uid="$(getent passwd "${u}" | cut -d: -f3)"
    u_gid="$(getent passwd "${u}" | cut -d: -f4)"
    u_home="$(getent passwd "${u}" | cut -d: -f6)"
    write_pg_service_conf "${u_home}" "${u_uid}" "${u_gid}"

    user_count=$((user_count + 1))
    [ -z "${first_user}" ] && first_user="${u}"
  done <<< "${USER_LINES}"

  if [ "${user_count}" -eq 0 ]; then
    echo "ERROR: QGIS_DESKTOP_AUTH_MODE=greeter but no valid users could be loaded from ${CRED_SOURCE}." >&2
    echo "Set QGIS_DESKTOP_USERS / QGIS_DESKTOP_USERS_FILE / VNC_USER+VNC_PW, or switch to QGIS_DESKTOP_AUTH_MODE=none for dev." >&2
    exit 1
  fi

  echo "Greeter users loaded: ${user_count} (first: ${first_user})"

  # Make the first username available to the wrapper (for $USER watermark
  # expansion) and to the greeter-branding steps.
  export QGIS_DESKTOP_GREETER_FIRST_USER="${first_user}"

  # LightDM runs as root inside the container so it can transition each
  # session to its target user via PAM + setuid. The greeter itself drops
  # to the 'lightdm' account (UID 996, baked into the image), which owns
  # these state dirs.
  mkdir -p /var/run/lightdm /var/log/lightdm /var/cache/lightdm /var/lib/lightdm
  chown -R 996:996 /var/run/lightdm /var/log/lightdm /var/cache/lightdm /var/lib/lightdm
  chmod 0755 /var/run/lightdm /var/log/lightdm /var/cache/lightdm /var/lib/lightdm

  # Start a system dbus bus so lightdm can register org.freedesktop.DisplayManager
  # and lightdm-gtk-greeter can talk back to it.
  mkdir -p /var/run/dbus
  rm -f /var/run/dbus/system_bus_socket /var/run/dbus/pid
  if ! pgrep -x dbus-daemon >/dev/null 2>&1; then
    if ! dbus-daemon --system --fork; then
      echo "WARN: dbus-daemon --system failed to start; lightdm greeter may not authenticate." >&2
    fi
    # Give the bus a moment to open its socket.
    for _i in 1 2 3 4 5; do
      [ -S /var/run/dbus/system_bus_socket ] && break
      sleep 0.2
    done
    if [ -S /var/run/dbus/system_bus_socket ]; then
      echo "dbus system bus: /var/run/dbus/system_bus_socket ready"
    else
      echo "WARN: dbus system_bus_socket not present after 1s" >&2
    fi
  fi

  # nixpkgs' dbus is often compiled with a different default socket path
  # than the "unix:path=/var/run/dbus/system_bus_socket" our system.conf
  # uses. Force the address so lightdm connects to the socket we started.
  export DBUS_SYSTEM_BUS_ADDRESS="unix:path=/var/run/dbus/system_bus_socket"

  # Extend PATH so lightdm can find our /usr/bin/Xephyr shim (which is
  # actually /etc/lightdm/xkasmvnc-wrapper). Without this lightdm's
  # g_spawn_async for the X server fails with "not found in path".
  export PATH="/usr/bin:${PATH}"

  # The terminal lockdown ran before these accounts existed, so their home
  # directories missed the menu overrides. The executables are already gone —
  # this is the cosmetic half — and the call is idempotent.
  if [ "$(to_bool "${QGIS_DESKTOP_ALLOW_TERMINAL}")" = "0" ]; then
    qgis-desktop-disable-terminal disable
  fi

  echo "Starting LightDM..."
  run_desktop lightdm --debug
fi
# basic / none: existing behaviour. Drop root and any inheritable capabilities
# before running the desktop. Clears NET_ADMIN so the desktop process cannot
# alter the firewall.
#
# start-desktop.sh only knows the desktop-level modes, so hand it the effective
# one — under oidc that is the inner mode, with the proxy already listening.
export QGIS_DESKTOP_AUTH_MODE="${EFFECTIVE_AUTH_MODE}"
if [ "${RUNNING_AS_ROOT}" = "1" ]; then
  run_desktop setpriv \
    --reuid=1000 --regid=1000 --init-groups \
    --inh-caps=-all --ambient-caps=-all \
    -- start-desktop
else
  # No root phase to drop out of — a pod-level runAsUser already put us at an
  # unprivileged UID before this script ever ran. setpriv's --init-groups
  # calls setgroups(2), which needs CAP_SETGID; without it this would fail
  # exactly like the chown calls above. There is nothing left to drop.
  run_desktop start-desktop
fi

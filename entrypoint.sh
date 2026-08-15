#!/usr/bin/env bash
# Root entrypoint for the QGIS Desktop container.
#
# Responsibilities (in order):
#   1. Read KASM_EGRESS_* env vars and resolve the authentication mode.
#   2. If lockdown is enabled, resolve allowlist hostnames and install nftables
#      rules that drop all egress traffic except to the allowlist + DNS.
#   3. In KASM_AUTH_MODE=oidc, start oauth2-proxy as the public listener with
#      the desktop moved behind it on loopback.
#   4. Drop capabilities and switch to the unprivileged `user` account.
#   5. Exec start-desktop (KasmVNC + XFCE + QGIS), or lightdm in greeter mode.
#
# Requires --cap-add=NET_ADMIN on `docker run` when lockdown is enabled.

set -euo pipefail

KASM_EGRESS_LOCKDOWN="${KASM_EGRESS_LOCKDOWN:-1}"
KASM_EGRESS_ALLOW="${KASM_EGRESS_ALLOW:-}"

kasm_bool() {
  case "${1,,}" in
    1|yes|true|on|enabled) echo 1 ;;
    *) echo 0 ;;
  esac
}

LOCKDOWN=$(kasm_bool "${KASM_EGRESS_LOCKDOWN}")

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
  echo "Configured allowlist: ${KASM_EGRESS_ALLOW:-<empty>}"

  # Confirm we actually have permission to touch nftables.
  if ! nft list ruleset >/dev/null 2>&1; then
    cat >&2 <<'MISSING_CAP'
ERROR: KASM_EGRESS_LOCKDOWN=1 but the container cannot manage nftables rules.
       This almost always means the container was started without NET_ADMIN.

       Fix by adding --cap-add=NET_ADMIN to `docker run`:

         docker run --cap-add=NET_ADMIN ...

       Or in docker-compose:

         cap_add:
           - NET_ADMIN

       If you REALLY want unrestricted network access (dev only), set
       KASM_EGRESS_LOCKDOWN=0 explicitly. The default is on for safety.
MISSING_CAP
    exit 1
  fi

  # Hostname entries are useless without a resolver. Say so loudly rather than
  # letting every name quietly fall off the allowlist — the filter still fails
  # closed, but an operator who allowlisted `db` deserves to know why nothing
  # can reach it.
  if ! command -v getent >/dev/null 2>&1; then
    echo "ERROR: getent is not on PATH — hostname entries in KASM_EGRESS_ALLOW" >&2
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
  done < <(printf '%s\n' "${KASM_EGRESS_ALLOW}" | tr ',' '\n')

  # Replace only OUR table, never the whole ruleset.
  #
  # `nft flush ruleset` would take Docker's `ip nat` table with it — the table
  # holding the DNAT rules that make the embedded resolver at 127.0.0.11:53
  # answer at all. nftables even labels it "managed by iptables-nft, do not
  # touch". Flushing it leaves the container unable to resolve any hostname for
  # the rest of its life on any user-defined or compose network, which looks
  # like a broken allowlist but is really a broken resolver.
  nft delete table inet kasm_egress 2>/dev/null || true

  nft -f - <<'NFTABLES'
table inet kasm_egress {
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
  nft add rule inet kasm_egress output ip daddr 127.0.0.11 udp dport 53 accept
  nft add rule inet kasm_egress output ip daddr 127.0.0.11 tcp dport 53 accept
  if [ -r /etc/resolv.conf ]; then
    local ns
    while IFS= read -r ns; do
      [ -z "$ns" ] && continue
      [ "$ns" = "127.0.0.11" ] && continue
      nft add rule inet kasm_egress output ip daddr "$ns" udp dport 53 accept
      nft add rule inet kasm_egress output ip daddr "$ns" tcp dport 53 accept
    done < <(awk '/^nameserver /{print $2}' /etc/resolv.conf)
  fi

  # The user-supplied allowlist.
  local target
  for target in "${allow_ips[@]}"; do
    if [[ "$target" == *"/"* ]]; then
      nft add rule inet kasm_egress output ip daddr "$target" accept
    else
      nft add rule inet kasm_egress output ip daddr "$target" accept
    fi
  done

  echo "Egress lockdown: ACTIVE (${#allow_ips[@]} allowlist entries)"
  echo "======================="
}

# Authentication mode selection. Resolved BEFORE the egress filter is installed
# because oidc mode has to add the identity provider to the allowlist — without
# that, oauth2-proxy could never reach the IdP's discovery endpoint.
#
#   KASM_AUTH_MODE=basic    (default) — HTTP BasicAuth on the web endpoint,
#                                        credentials from KASM_USERS_FILE /
#                                        KASM_USERS / legacy VNC_USER+VNC_PW.
#                                        start-desktop.sh drops to uid 1000.
#   KASM_AUTH_MODE=none               — no auth (dev only).
#   KASM_AUTH_MODE=greeter            — LightDM greeter inside the X session.
#                                        Users materialised as real Linux
#                                        accounts, lightdm run as root so it
#                                        can spawn each session as its user.
#   KASM_AUTH_MODE=oidc               — oauth2-proxy owns the published port and
#                                        authenticates against an OIDC provider
#                                        (Keycloak by default); KasmVNC is moved
#                                        to a loopback-only port behind it.
#                                        Added in 1.5.0.
#
# Back-compat: legacy KASM_AUTH=0 forces mode=none.
KASM_AUTH_MODE="${KASM_AUTH_MODE:-basic}"
KASM_AUTH="${KASM_AUTH:-}"
if [ "$(kasm_bool "${KASM_AUTH:-1}")" = "0" ] && [ -n "${KASM_AUTH}" ]; then
  # Legacy KASM_AUTH=0 wins.
  KASM_AUTH_MODE="none"
fi

case "${KASM_AUTH_MODE,,}" in
  none | basic | greeter) KASM_AUTH_MODE="${KASM_AUTH_MODE,,}" ;;
  oidc | keycloak) KASM_AUTH_MODE="oidc" ;;
  *)
    echo "ERROR: KASM_AUTH_MODE='${KASM_AUTH_MODE}' is not one of none|basic|greeter|oidc." >&2
    exit 1
    ;;
esac
export KASM_AUTH_MODE

echo "=== Auth mode ==="
echo "KASM_AUTH_MODE=${KASM_AUTH_MODE}"

# The mode the desktop itself boots in. Identical to KASM_AUTH_MODE except
# under oidc, where the proxy is the auth boundary and the desktop runs in
# whichever inner mode was requested.
EFFECTIVE_AUTH_MODE="${KASM_AUTH_MODE}"
KASM_OIDC_UPSTREAM_PORT="${KASM_OIDC_UPSTREAM_PORT:-6901}"

# Host part of a URL: strip scheme, userinfo, path and port. IPv6 literals are
# not handled — the nftables rules are IPv4-only anyway.
url_host() {
  local url="${1#*://}"
  url="${url%%/*}"
  url="${url##*@}"
  url="${url%%:*}"
  printf '%s' "${url}"
}

if [ "${KASM_AUTH_MODE}" = "oidc" ]; then
  KASM_OIDC_INNER_MODE="${KASM_OIDC_INNER_MODE:-none}"
  case "${KASM_OIDC_INNER_MODE,,}" in
    none | greeter) EFFECTIVE_AUTH_MODE="${KASM_OIDC_INNER_MODE,,}" ;;
    *)
      echo "ERROR: KASM_OIDC_INNER_MODE='${KASM_OIDC_INNER_MODE}' is not one of none|greeter." >&2
      echo "       ('basic' is deliberately unsupported: a second password prompt behind" >&2
      echo "       single sign-on adds nothing.)" >&2
      exit 1
      ;;
  esac
  echo "KASM_OIDC_INNER_MODE=${EFFECTIVE_AUTH_MODE} (how the desktop behind the proxy authenticates)"

  # oauth2-proxy runs OIDC discovery and the token exchange server-side, so the
  # identity provider has to stay reachable with the egress filter on. Append
  # rather than replace, so an operator-supplied allowlist survives.
  if [ -n "${KASM_OIDC_ISSUER_URL:-}" ]; then
    OIDC_ISSUER_HOST="$(url_host "${KASM_OIDC_ISSUER_URL}")"
    if [ -n "${OIDC_ISSUER_HOST}" ]; then
      KASM_EGRESS_ALLOW="${KASM_EGRESS_ALLOW:+${KASM_EGRESS_ALLOW},}${OIDC_ISSUER_HOST}"
      echo "Egress: adding identity provider '${OIDC_ISSUER_HOST}' to the allowlist"
    fi
  fi
fi

if [ "${LOCKDOWN}" = "1" ]; then
  setup_egress_lockdown
else
  echo "WARN: Egress lockdown DISABLED (KASM_EGRESS_LOCKDOWN=${KASM_EGRESS_LOCKDOWN})."
  echo "      Container has unrestricted network access."
fi

# Prepare /tmp/.X11-unix with the ownership/mode the X server expects.
# When start-desktop runs as uid 1000 and creates this dir itself, Xkasmvnc
# logs "_XSERVTransmkdir: Owner of /tmp/.X11-unix should be set to root"
# and can misbehave. Doing it here (as root) with mode 1777 keeps X happy
# while still letting the uid 1000 process create per-display sockets under it.
mkdir -p /tmp/.X11-unix
chown root:root /tmp/.X11-unix
chmod 1777 /tmp/.X11-unix

# /tmp/.ICE-unix is the socket dir for the X Session Management Protocol
# (XSMP). xfce4-session uses XSMP to spawn xfce4-panel, xfdesktop, xfwm4
# etc. If the dir doesn't exist, non-root sessions can't create it
# (_IceTransmkdir errors on euid != 0) and xfce4-session comes up but its
# children never launch — the user sees an empty desktop.
mkdir -p /tmp/.ICE-unix
chown root:root /tmp/.ICE-unix
chmod 1777 /tmp/.ICE-unix

# XDG runtime dir, owned by the target user.
mkdir -p /tmp/runtime-user
chown 1000:1000 /tmp/runtime-user
chmod 700 /tmp/runtime-user

# Terminal access. Secure deployments hand users a mapping application, not a
# shell: KASM_ALLOW_TERMINAL=0 removes the terminal emulators (and the dialogs
# that would run an arbitrary command) from the container before the desktop
# starts. Must happen while we are still root, and before any user session
# exists. See config/lockdown/disable-terminal.sh for what it closes and what
# it deliberately does not claim to close.
KASM_ALLOW_TERMINAL="${KASM_ALLOW_TERMINAL:-1}"
if [ "$(kasm_bool "${KASM_ALLOW_TERMINAL}")" = "1" ]; then
  # Clear any stale menu overrides from a previous locked-down run against the
  # same mounted home, so re-enabling actually re-enables.
  kasm-disable-terminal restore || true
else
  kasm-disable-terminal disable
fi

if [ "${KASM_AUTH_MODE}" = "oidc" ]; then
  echo "=== OIDC single sign-on ==="

  # Validates the configuration and materialises the secrets into a config file
  # only the proxy's UID can read. A non-zero exit is fatal on purpose: failing
  # to boot beats serving a desktop with nothing in front of it.
  kasm-oidc-config

  # Move the desktop's own web endpoint to loopback so the proxy becomes the
  # only way in. Both launchers also read this file, because LightDM scrubs the
  # environment before spawning the X server and env vars would not reach the
  # xkasmvnc wrapper.
  mkdir -p /run/kasm
  cat > /run/kasm/listen.env <<LISTEN
VNC_PORT=${KASM_OIDC_UPSTREAM_PORT}
KASM_BIND_INTERFACE=127.0.0.1
LISTEN
  chmod 0644 /run/kasm/listen.env

  export KASM_OIDC_LISTEN_PORT="${VNC_PORT:-8443}"
  export KASM_OIDC_UPSTREAM_PORT
  export VNC_PORT="${KASM_OIDC_UPSTREAM_PORT}"
  export KASM_BIND_INTERFACE="127.0.0.1"

  # The proxy needs no privileges: its port is unprivileged and its config file
  # is owned by uid 1000. Same capability-clearing shape as the desktop below.
  setpriv \
    --reuid=1000 --regid=1000 --init-groups \
    --inh-caps=-all --ambient-caps=-all \
    -- kasm-oidc-proxy &
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

  echo "OIDC proxy running as pid ${OIDC_PROXY_PID}; desktop bound to 127.0.0.1:${KASM_OIDC_UPSTREAM_PORT}"
fi

if [ "${EFFECTIVE_AUTH_MODE}" = "greeter" ]; then
  # Materialise users from the same credential sources basic mode uses, so
  # KASM_USERS / KASM_USERS_FILE / VNC_USER+VNC_PW all work identically.
  # PAM will authenticate against the resulting /etc/shadow entries. LightDM
  # then runs as root and spawns each successful login as its target user.
  KASM_USERS_FILE="${KASM_USERS_FILE:-/etc/kasmvnc/users}"
  KASM_USERS="${KASM_USERS:-}"
  VNC_USER="${VNC_USER:-user}"
  VNC_PW="${VNC_PW:-password}"

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
    # KASM_USERS list may reuse that name or add new ones from 1001.
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

    user_count=$((user_count + 1))
    [ -z "${first_user}" ] && first_user="${u}"
  done <<< "${USER_LINES}"

  if [ "${user_count}" -eq 0 ]; then
    echo "ERROR: KASM_AUTH_MODE=greeter but no valid users could be loaded from ${CRED_SOURCE}." >&2
    echo "Set KASM_USERS / KASM_USERS_FILE / VNC_USER+VNC_PW, or switch to KASM_AUTH_MODE=none for dev." >&2
    exit 1
  fi

  echo "Greeter users loaded: ${user_count} (first: ${first_user})"

  # Make the first username available to the wrapper (for $USER watermark
  # expansion) and to the greeter-branding steps.
  export KASM_GREETER_FIRST_USER="${first_user}"

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
  if [ "$(kasm_bool "${KASM_ALLOW_TERMINAL}")" = "0" ]; then
    kasm-disable-terminal disable
  fi

  echo "Starting LightDM..."
  exec lightdm --debug
fi

# basic / none: existing behaviour. Drop root and any inheritable capabilities
# before running the desktop. Clears NET_ADMIN so the desktop process cannot
# alter the firewall.
#
# start-desktop.sh only knows the desktop-level modes, so hand it the effective
# one — under oidc that is the inner mode, with the proxy already listening.
export KASM_AUTH_MODE="${EFFECTIVE_AUTH_MODE}"
exec setpriv \
  --reuid=1000 --regid=1000 --init-groups \
  --inh-caps=-all --ambient-caps=-all \
  -- start-desktop

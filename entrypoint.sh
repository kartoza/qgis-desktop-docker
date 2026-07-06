#!/usr/bin/env bash
# Root entrypoint for the QGIS Desktop container.
#
# Responsibilities (in order):
#   1. Read KASM_EGRESS_* env vars.
#   2. If lockdown is enabled, resolve allowlist hostnames and install nftables
#      rules that drop all egress traffic except to the allowlist + DNS.
#   3. Drop capabilities and switch to the unprivileged `user` account.
#   4. Exec start-desktop (KasmVNC + XFCE + QGIS).
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

  # Install the ruleset atomically.
  nft flush ruleset

  nft -f - <<'NFTABLES'
table inet filter {
    chain input {
        type filter hook input priority filter; policy accept;
    }
    chain forward {
        type filter hook forward priority filter; policy drop;
    }
    chain output {
        type filter hook output priority filter; policy drop;

        # Always: loopback traffic.
        oif "lo" accept

        # Always: return traffic for connections we initiated.
        ct state established,related accept
    }
}
NFTABLES

  # DNS: Docker's embedded resolver is always at 127.0.0.11 on user-defined
  # bridge networks. Allow it plus anything currently in /etc/resolv.conf.
  nft add rule inet filter output ip daddr 127.0.0.11 udp dport 53 accept
  nft add rule inet filter output ip daddr 127.0.0.11 tcp dport 53 accept
  if [ -r /etc/resolv.conf ]; then
    local ns
    while IFS= read -r ns; do
      [ -z "$ns" ] && continue
      [ "$ns" = "127.0.0.11" ] && continue
      nft add rule inet filter output ip daddr "$ns" udp dport 53 accept
      nft add rule inet filter output ip daddr "$ns" tcp dport 53 accept
    done < <(awk '/^nameserver /{print $2}' /etc/resolv.conf)
  fi

  # The user-supplied allowlist.
  local target
  for target in "${allow_ips[@]}"; do
    if [[ "$target" == *"/"* ]]; then
      nft add rule inet filter output ip daddr "$target" accept
    else
      nft add rule inet filter output ip daddr "$target" accept
    fi
  done

  echo "Egress lockdown: ACTIVE (${#allow_ips[@]} allowlist entries)"
  echo "======================="
}

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

# XDG runtime dir, owned by the target user.
mkdir -p /tmp/runtime-user
chown 1000:1000 /tmp/runtime-user
chmod 700 /tmp/runtime-user

# Drop root and any inheritable capabilities before running the desktop.
# Clears NET_ADMIN so the desktop process cannot alter the firewall.
exec setpriv \
  --reuid=1000 --regid=1000 --init-groups \
  --inh-caps=-all --ambient-caps=-all \
  -- start-desktop

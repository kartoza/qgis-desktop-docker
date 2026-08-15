#!/usr/bin/env bash
# oauth2-proxy launcher for QGIS_DESKTOP_AUTH_MODE=oidc.
#
# Runs UNPRIVILEGED (uid 1000 by default, dropped by the entrypoint via
# setpriv). It builds the flag list from the QGIS_DESKTOP_OIDC_* environment and execs
# oauth2-proxy, which becomes the only listener on the published port:
#
#   browser ──▶ oauth2-proxy :8443 ──▶ Xkasmvnc 127.0.0.1:6901
#                    │
#                    └── OIDC authorization code flow against the IdP
#
# Secrets are NOT passed here — qgis-desktop-oidc-config wrote them to a 0400 config
# file that only this UID can read, and oauth2-proxy merges the two sources.
#
# The provider defaults to `keycloak-oidc`, which is Keycloak-aware (it can
# filter on realm/client roles) but speaks plain OIDC discovery, so any
# standards-compliant IdP works by pointing QGIS_DESKTOP_OIDC_ISSUER_URL at it. Set
# QGIS_DESKTOP_OIDC_PROVIDER=oidc for a strictly generic provider.

set -euo pipefail

RUNTIME_DIR="${QGIS_DESKTOP_OIDC_RUNTIME_DIR:-/run/qgis-desktop/oidc}"
SECRETS_FILE="${RUNTIME_DIR}/secrets.cfg"

die() {
  echo "ERROR: $*" >&2
  exit 1
}

to_bool() {
  case "${1,,}" in
    1 | yes | true | on | enabled) echo true ;;
    *) echo false ;;
  esac
}

# Trim leading/trailing whitespace only — Keycloak group paths and role names
# may legitimately contain spaces ("/GIS Analysts"), so inner whitespace stays.
trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "${value}"
}

[ -r "${SECRETS_FILE}" ] || die \
  "${SECRETS_FILE} is missing or unreadable — qgis-desktop-oidc-config should have written it as root."

# The listening port is the container's public one; the desktop has been moved
# to a loopback-only port by the entrypoint.
LISTEN_PORT="${QGIS_DESKTOP_OIDC_LISTEN_PORT:-${VNC_PORT:-8443}}"
UPSTREAM_PORT="${QGIS_DESKTOP_OIDC_UPSTREAM_PORT:-6901}"

PROVIDER="${QGIS_DESKTOP_OIDC_PROVIDER:-keycloak-oidc}"
SCOPE="${QGIS_DESKTOP_OIDC_SCOPE:-openid email profile}"
EMAIL_DOMAINS="${QGIS_DESKTOP_OIDC_EMAIL_DOMAINS:-*}"
EMAIL_CLAIM="${QGIS_DESKTOP_OIDC_EMAIL_CLAIM:-email}"
COOKIE_EXPIRE="${QGIS_DESKTOP_OIDC_COOKIE_EXPIRE:-8h}"
REVERSE_PROXY="$(to_bool "${QGIS_DESKTOP_OIDC_REVERSE_PROXY:-0}")"
SKIP_TLS_VERIFY="$(to_bool "${QGIS_DESKTOP_OIDC_INSECURE_SKIP_VERIFY:-0}")"

# Session cookies must be marked Secure whenever the browser reaches us over
# HTTPS, and must NOT be when it reaches us over plain HTTP (the browser would
# drop the cookie and the login would loop forever). Default from the scheme of
# the redirect URL, which is by definition the browser-facing one.
case "${QGIS_DESKTOP_OIDC_REDIRECT_URL:-}" in
  https://*) COOKIE_SECURE_DEFAULT=1 ;;
  *) COOKIE_SECURE_DEFAULT=0 ;;
esac
COOKIE_SECURE="$(to_bool "${QGIS_DESKTOP_OIDC_COOKIE_SECURE:-${COOKIE_SECURE_DEFAULT}}")"

if [ "${COOKIE_SECURE}" = "false" ]; then
  echo "WARN: session cookies are not marked Secure because the browser reaches this" >&2
  echo "      container over plain HTTP. Terminate TLS in front of it before using" >&2
  echo "      OIDC on anything but localhost." >&2
fi

ARGS=(
  --config="${SECRETS_FILE}"
  --provider="${PROVIDER}"
  --provider-display-name="Single sign-on"
  --oidc-issuer-url="${QGIS_DESKTOP_OIDC_ISSUER_URL}"
  --client-id="${QGIS_DESKTOP_OIDC_CLIENT_ID}"
  --redirect-url="${QGIS_DESKTOP_OIDC_REDIRECT_URL}"
  --scope="${SCOPE}"
  --oidc-email-claim="${EMAIL_CLAIM}"
  --upstream="http://127.0.0.1:${UPSTREAM_PORT}/"
  --proxy-websockets=true
  --skip-provider-button=true
  --cookie-secure="${COOKIE_SECURE}"
  --cookie-httponly=true
  --cookie-samesite=lax
  --cookie-expire="${COOKIE_EXPIRE}"
  --reverse-proxy="${REVERSE_PROXY}"
  --ssl-insecure-skip-verify="${SKIP_TLS_VERIFY}"
  # KasmVNC authenticates nobody itself in this mode, so there is nothing to
  # forward an identity to. Sending headers or tokens upstream would only widen
  # what a compromised desktop process can see.
  --pass-basic-auth=false
  --pass-access-token=false
  --pass-authorization-header=false
  --pass-user-headers=false
  --set-xauthrequest=false
  # Keep the health endpoint under /oauth2/ so it cannot shadow a KasmVNC route.
  --ping-path=/oauth2/healthz
  --silence-ping-logging=true
)

# --- Who is allowed in ------------------------------------------------------
# oauth2-proxy rejects everyone unless at least one email domain is allowed;
# "*" means "any account the IdP will issue a token for", which is the usual
# expectation when the client is registered in a dedicated realm.
while IFS= read -r domain; do
  domain="${domain//[[:space:]]/}"
  [ -n "${domain}" ] || continue
  ARGS+=(--email-domain="${domain}")
done < <(printf '%s\n' "${EMAIL_DOMAINS}" | tr ',' '\n')

while IFS= read -r group; do
  group="$(trim "${group}")"
  [ -n "${group}" ] || continue
  ARGS+=(--allowed-group="${group}")
done < <(printf '%s\n' "${QGIS_DESKTOP_OIDC_ALLOWED_GROUPS:-}" | tr ',' '\n')

# Realm/client roles are a Keycloak concept; the flag only exists on the
# keycloak-oidc provider.
if [ -n "${QGIS_DESKTOP_OIDC_ALLOWED_ROLES:-}" ]; then
  if [ "${PROVIDER}" != "keycloak-oidc" ]; then
    die "QGIS_DESKTOP_OIDC_ALLOWED_ROLES needs QGIS_DESKTOP_OIDC_PROVIDER=keycloak-oidc (got '${PROVIDER}')."
  fi
  while IFS= read -r role; do
    role="$(trim "${role}")"
    [ -n "${role}" ] || continue
    ARGS+=(--allowed-role="${role}")
  done < <(printf '%s\n' "${QGIS_DESKTOP_OIDC_ALLOWED_ROLES}" | tr ',' '\n')
fi

# --- Listener ---------------------------------------------------------------
if [ -n "${QGIS_DESKTOP_OIDC_TLS_CERT_FILE:-}" ] || [ -n "${QGIS_DESKTOP_OIDC_TLS_KEY_FILE:-}" ]; then
  [ -r "${QGIS_DESKTOP_OIDC_TLS_CERT_FILE:-}" ] || die "QGIS_DESKTOP_OIDC_TLS_CERT_FILE is unset or unreadable."
  [ -r "${QGIS_DESKTOP_OIDC_TLS_KEY_FILE:-}" ] || die "QGIS_DESKTOP_OIDC_TLS_KEY_FILE is unset or unreadable."
  ARGS+=(
    --https-address="0.0.0.0:${LISTEN_PORT}"
    --tls-cert-file="${QGIS_DESKTOP_OIDC_TLS_CERT_FILE}"
    --tls-key-file="${QGIS_DESKTOP_OIDC_TLS_KEY_FILE}"
    # oauth2-proxy always opens its HTTP listener; port 0 on loopback parks it
    # on an ephemeral port nothing outside the container can reach, which is
    # the portable way to say "TLS only".
    --http-address="127.0.0.1:0"
  )
  echo "OIDC proxy: https://0.0.0.0:${LISTEN_PORT} → http://127.0.0.1:${UPSTREAM_PORT}"
else
  ARGS+=(--http-address="0.0.0.0:${LISTEN_PORT}")
  echo "OIDC proxy: http://0.0.0.0:${LISTEN_PORT} → http://127.0.0.1:${UPSTREAM_PORT}"
fi

# Escape hatch for anything this wrapper does not model. Deliberately word-split.
if [ -n "${QGIS_DESKTOP_OIDC_EXTRA_ARGS:-}" ]; then
  read -r -a EXTRA_ARGS <<< "${QGIS_DESKTOP_OIDC_EXTRA_ARGS}"
  ARGS+=("${EXTRA_ARGS[@]}")
fi

echo "OIDC proxy: provider=${PROVIDER} issuer=${QGIS_DESKTOP_OIDC_ISSUER_URL}"
exec oauth2-proxy "${ARGS[@]}"

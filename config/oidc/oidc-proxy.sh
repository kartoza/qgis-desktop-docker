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
SIGN_OUT_REDIRECT="${QGIS_DESKTOP_OIDC_SIGN_OUT_REDIRECT:-}"
BACKEND_LOGOUT_URL="${QGIS_DESKTOP_OIDC_BACKEND_LOGOUT_URL:-}"
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

# --- Signing out ------------------------------------------------------------
# oauth2-proxy serves /oauth2/sign_out, which drops its own session cookie. On
# its own that is only half a logout: the identity provider still has a live
# SSO session, so the next visit sails back through the authorization-code flow
# without ever showing a login form. The two knobs below close that gap.
#
# Nothing inside the container can trigger this — the session is a cookie in
# the user's browser, and the desktop is pixels inside that page. Signing out
# is always a browser navigation to /oauth2/sign_out.

# Host[:port] of a URL, for --whitelist-domain. Strips scheme, any userinfo,
# and everything from the first '/', '?' or '#'.
url_host() {
  local url="$1"
  url="${url#*://}"
  url="${url##*@}"
  url="${url%%/*}"
  url="${url%%\?*}"
  printf '%s' "${url%%#*}"
}

# Where the browser lands after signing out. Left unset, oauth2-proxy sends it
# to "/", which — with --skip-provider-button — restarts the OIDC flow and puts
# the identity provider's login page straight back on screen. That is the
# behaviour most deployments want, so this exists for the case where you would
# rather drop users on a portal page than re-prompt them immediately.
#
# oauth2-proxy refuses to honour ?rd= for a host it was not told to trust, so
# setting this also adds that host to the redirect allowlist. Without that the
# redirect is silently dropped and the user lands on "/" anyway.
if [ -n "${SIGN_OUT_REDIRECT}" ]; then
  case "${SIGN_OUT_REDIRECT}" in
    http://* | https://*) : ;;
    *) die "QGIS_DESKTOP_OIDC_SIGN_OUT_REDIRECT must start with http:// or https:// (got '${SIGN_OUT_REDIRECT}')." ;;
  esac
  SIGN_OUT_HOST="$(url_host "${SIGN_OUT_REDIRECT}")"
  [ -n "${SIGN_OUT_HOST}" ] || die \
    "QGIS_DESKTOP_OIDC_SIGN_OUT_REDIRECT='${SIGN_OUT_REDIRECT}' has no host component."
  ARGS+=(--whitelist-domain="${SIGN_OUT_HOST}")
  echo "OIDC proxy: sign-out redirects to ${SIGN_OUT_REDIRECT}"
  echo "            (use /oauth2/sign_out?rd=${SIGN_OUT_REDIRECT})"
fi

# Ending the session at the identity provider too. oauth2-proxy calls this URL
# server-side when it processes a sign-out, substituting the user's id_token
# for the {id_token} placeholder — so the browser never has to be bounced
# through the provider, and no post-logout redirect URI has to be registered on
# the client.
#
# 'auto' builds Keycloak's RP-initiated logout endpoint from the issuer. Every
# provider spells this differently and the real answer lives in the discovery
# document's end_session_endpoint, so anything else has to be given in full.
if [ "${BACKEND_LOGOUT_URL}" = "auto" ]; then
  if [ "${PROVIDER}" != "keycloak-oidc" ]; then
    die "QGIS_DESKTOP_OIDC_BACKEND_LOGOUT_URL=auto only knows Keycloak's logout endpoint
       (provider is '${PROVIDER}'). Set it to the end_session_endpoint from
       ${QGIS_DESKTOP_OIDC_ISSUER_URL}/.well-known/openid-configuration instead,
       with '{id_token}' as the id_token_hint value."
  fi
  BACKEND_LOGOUT_URL="${QGIS_DESKTOP_OIDC_ISSUER_URL%/}/protocol/openid-connect/logout?id_token_hint={id_token}"
fi

if [ -n "${BACKEND_LOGOUT_URL}" ]; then
  case "${BACKEND_LOGOUT_URL}" in
    http://* | https://*) : ;;
    *) die "QGIS_DESKTOP_OIDC_BACKEND_LOGOUT_URL must be 'auto' or start with http:// or https:// (got '${BACKEND_LOGOUT_URL}')." ;;
  esac
  case "${BACKEND_LOGOUT_URL}" in
    *'{id_token}'*) : ;;
    *)
      echo "WARN: QGIS_DESKTOP_OIDC_BACKEND_LOGOUT_URL has no '{id_token}' placeholder." >&2
      echo "      Most providers reject an RP-initiated logout with no id_token_hint," >&2
      echo "      which would leave the provider session alive after sign-out." >&2
      ;;
  esac
  ARGS+=(--backend-logout-url="${BACKEND_LOGOUT_URL}")
  echo "OIDC proxy: sign-out also ends the session at the identity provider"
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

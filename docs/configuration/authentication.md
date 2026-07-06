# Authentication

HTTP BasicAuth is **enabled by default** on the web endpoint. When a
browser connects to `:8443`, Xkasmvnc replies `401 WWW-Authenticate: Basic`
and the browser shows its native user/password prompt. Credentials are
reused transparently for the VNC RFB handshake, so users only see one
prompt.

## Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `KASM_AUTH` | `1` | `0` disables auth entirely (`-DisableBasicAuth`, `-SecurityTypes None`). Dev only. |
| `KASM_USERS_FILE` | `/etc/kasmvnc/users` | Bind-mount target for a `user:password` file. |
| `KASM_USERS` | *(none)* | Inline `user1:pw1,user2:pw2` list. Comma or newline separated. |

## Credential resolution

Credentials are resolved in this order, first wins:

1. **`KASM_USERS_FILE`** — path to a file containing `user:password` per
   line. Default `/etc/kasmvnc/users`. Lines starting with `#` and blank
   lines are ignored. Passwords may contain colons; only the first `:` on
   the line is treated as the separator. Mount the file into the container,
   ideally with mode `0600`.
2. **`KASM_USERS`** — inline list. Same semantics as the file, just on
   one env var.
3. **Legacy `VNC_USER` / `VNC_PW`** — single user, kept for backwards
   compatibility. Defaults to `user` / `password`.

At boot, `start-desktop.sh` wipes any stale `~/.kasmpasswd` and re-populates
it from the resolved source, so removing a user from the file or env var
and restarting takes effect immediately.

!!! note "RFB SecurityTypes is always None"
    The RFB-layer `SecurityTypes` is always `None` — HTTP BasicAuth is the
    sole authentication gate. Setting VncAuth would require a legacy
    `~/.vnc/passwd` file in DES-encoded TigerVNC format, which
    `kasmvncpasswd` does not produce. When `KASM_AUTH=0`, BasicAuth is
    also disabled and the container is fully open.

## Examples

**Multi-user via file:**

```bash
cat > users <<'EOF'
# QGIS desktop users — file mode should be 0600
alice:hunter2
bob:correct-horse-battery-staple
EOF
chmod 600 users
docker run --rm -p 8443:8443 --cap-add=NET_ADMIN \
  -v "$PWD/users:/etc/kasmvnc/users:ro" \
  ghcr.io/kartoza/qgis-desktop-docker:latest
```

**Multi-user via env:**

```bash
docker run --rm -p 8443:8443 --cap-add=NET_ADMIN \
  -e KASM_USERS='alice:pw1,bob:pw2' \
  ghcr.io/kartoza/qgis-desktop-docker:latest
```

**Disable auth (local dev only):**

```bash
docker run --rm -p 8443:8443 --cap-add=NET_ADMIN \
  -e KASM_AUTH=0 \
  ghcr.io/kartoza/qgis-desktop-docker:latest
```

## Branded login page

The browser's HTTP BasicAuth prompt is unstyled — a native OS dialog. If
you need a branded login page, front the container with a reverse proxy
(nginx + OAuth2 Proxy, Traefik + BasicAuth, Caddy + `basic_auth`, etc.)
and disable Kasm auth with `KASM_AUTH=0`.

!!! tip
    The container itself runs as non-root (`user`, UID 1000) after the
    root entrypoint drops privileges.

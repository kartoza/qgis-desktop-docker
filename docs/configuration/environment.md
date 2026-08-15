# Environment

The basic session-level variables: where the desktop listens, at what size,
and on which X display.

| Variable | Default | Description |
|----------|---------|-------------|
| `VNC_PORT` | `8443` | Port for the KasmVNC web interface. |
| `VNC_RESOLUTION` | `1280x720` | Initial desktop resolution. Resizable in the browser. |
| `VNC_COL_DEPTH` | `24` | Colour depth (`16`, `24`, or `32`). |
| `VNC_PW` | `password` | Legacy single-user VNC password. Only used if `QGIS_DESKTOP_USERS_FILE` and `QGIS_DESKTOP_USERS` are both unset. |
| `DISPLAY` | `:1` | X display number the server binds to (basic/none mode). In `greeter` mode LightDM manages the display and pins it to `:0`. |

Authentication lives on its own page — see
[Authentication](authentication.md) for `QGIS_DESKTOP_AUTH_MODE`, `QGIS_DESKTOP_USERS_FILE`,
`QGIS_DESKTOP_USERS`, the `QGIS_DESKTOP_OIDC_*` single sign-on settings, and the
credential-resolution order.

!!! note "`VNC_PORT` in `oidc` mode"
    With `QGIS_DESKTOP_AUTH_MODE=oidc`, `VNC_PORT` stays the *published* port — it is
    the OIDC proxy that listens on it. KasmVNC itself is moved to
    `127.0.0.1:$QGIS_DESKTOP_OIDC_UPSTREAM_PORT` (default `6901`) so that nothing can
    reach the desktop except through the proxy.

## Examples

Change the resolution:

```bash
docker run --rm -p 8443:8443 --cap-add=NET_ADMIN \
  -e VNC_RESOLUTION=1920x1080 \
  ghcr.io/kartoza/qgis-desktop-docker:latest
```

Change the port (remember to update the port mapping too):

```bash
docker run --rm -p 3000:3000 --cap-add=NET_ADMIN \
  -e VNC_PORT=3000 \
  ghcr.io/kartoza/qgis-desktop-docker:latest
```

!!! tip
    The resolution set at startup is only the *initial* size. KasmVNC
    supports dynamic resizing — resize the browser window and the desktop
    follows.

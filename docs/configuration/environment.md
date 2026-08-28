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
| `QGIS_DESKTOP_AUTOSTART_QGIS` | `0` | `1` starts QGIS with the desktop session. See [Starting QGIS automatically](#starting-qgis-automatically). |
| `QGIS_DESKTOP_AUTOSTART_QGIS_ARGS` | *(none)* | Arguments for that launch, e.g. `--project /home/user/projects/site.qgs`. |
| `QGIS_DESKTOP_SESSION_RESTART` | `1` | Relaunch the desktop session when it exits, so XFCE's **Log Out** resets the desktop instead of leaving a bare X display. See [Logging out](authentication.md#logging-out-new-in-310) for the full set of `QGIS_DESKTOP_SESSION_*` knobs. |
| `QGIS_DESKTOP_MANAGE_URL` | *(none)* | Link back to your hosting control panel, shown on the session-ended page and in the control bar. See [Branding](branding.md#reminding-people-to-shut-down). |

Authentication lives on its own page — see
[Authentication](authentication.md) for `QGIS_DESKTOP_AUTH_MODE`, `QGIS_DESKTOP_USERS_FILE`,
`QGIS_DESKTOP_USERS`, the `QGIS_DESKTOP_OIDC_*` single sign-on settings, and the
credential-resolution order.

!!! note "`VNC_PORT` in `oidc` mode"
    With `QGIS_DESKTOP_AUTH_MODE=oidc`, `VNC_PORT` stays the *published* port — it is
    the OIDC proxy that listens on it. KasmVNC itself is moved to
    `127.0.0.1:$QGIS_DESKTOP_OIDC_UPSTREAM_PORT` (default `6901`) so that nothing can
    reach the desktop except through the proxy.

## Starting QGIS automatically

By default the session comes up as an XFCE desktop and the user launches QGIS
themselves. For a single-purpose deployment, start it with the session:

```bash
docker run --rm -p 8443:8443 --cap-add=NET_ADMIN \
  -e QGIS_DESKTOP_AUTOSTART_QGIS=1 \
  ghcr.io/kartoza/qgis-desktop-docker:ltr
```

QGIS opens a few seconds after the desktop appears — it is a normal application
in a normal session, so the panel, the file manager and the rest are still
there.

Open a specific project with it:

```bash
  -e QGIS_DESKTOP_AUTOSTART_QGIS=1 \
  -e QGIS_DESKTOP_AUTOSTART_QGIS_ARGS='--project /home/user/projects/site.qgs'
```

That pairs with [home persistence](persistence.md): put the project in the
user's `baseline/` prefix and it is on disk before the session starts, so the
first thing they see is their own map.

!!! note "How it works"
    The flag writes an XDG autostart entry into the user's
    `~/.config/autostart/`, which XFCE reads when the session starts — so it
    behaves identically in `basic`, `greeter` and `oidc` modes. Turning the
    flag off removes the entry again, including from a home directory restored
    from object storage with the entry still in it. An autostart entry you
    wrote yourself is never touched.

!!! tip "Not a kiosk"
    This starts QGIS *alongside* the desktop; the user can still close it and
    reach everything else. For a genuine kiosk, combine it with
    `QGIS_DESKTOP_ALLOW_TERMINAL=0` and the
    [permission controls](permissions.md) — though a user with QGIS's Python
    console can always start something else.

## Examples

Change the resolution:

```bash
docker run --rm -p 8443:8443 --cap-add=NET_ADMIN \
  -e VNC_RESOLUTION=1920x1080 \
  ghcr.io/kartoza/qgis-desktop-docker:ltr
```

Change the port (remember to update the port mapping too):

```bash
docker run --rm -p 3000:3000 --cap-add=NET_ADMIN \
  -e VNC_PORT=3000 \
  ghcr.io/kartoza/qgis-desktop-docker:ltr
```

!!! tip
    The resolution set at startup is only the *initial* size. KasmVNC
    supports dynamic resizing — resize the browser window and the desktop
    follows.

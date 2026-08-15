# Kasm permissions

KasmVNC's data-loss-prevention knobs are wired to environment variables.
Defaults are **restrictive** — clipboard sharing is disabled in both
directions until you explicitly enable it.

Boolean values accept `1`, `yes`, `true`, `on`, or `enabled`; anything
else counts as off.

## Variables

| Variable | Default | Xkasmvnc flag | Effect |
|----------|---------|---------------|--------|
| `KASM_ALLOW_CLIPBOARD_IN` | `0` | `-AcceptCutText` | Allow pasting from local machine into the container. |
| `KASM_ALLOW_CLIPBOARD_OUT` | `0` | `-SendCutText` | Allow copying from the container out to the local machine. |
| `KASM_ALLOW_PRIMARY_SELECTION` | `0` | `-SendPrimary` | Share X primary selection (middle-click paste). |
| `KASM_CLIPBOARD_IN_MAX` | `0` | `-DLP_ClipAcceptMax` | Max bytes accepted per paste; `0` = unlimited. |
| `KASM_CLIPBOARD_OUT_MAX` | `0` | `-DLP_ClipSendMax` | Max bytes sent per copy; `0` = unlimited. |
| `KASM_CLIPBOARD_DELAY_MS` | `0` | `-DLP_ClipDelay` | Minimum ms between clipboard operations (anti-spam). |
| `KASM_CLIPBOARD_MIME_TYPES` | *(kasm default)* | `-DLP_ClipTypes` | Comma-separated MIME allowlist, e.g. `text/plain,text/html`. |
| `KASM_WATERMARK_TEXT` | *(none)* | `-DLP_WatermarkText` | Overlay text on the desktop as a screenshot deterrent. |
| `KASM_DLP_LOG` | `off` | `-DLP_Log` | `off`, `info`, or `verbose`. |
| `KASM_ALLOW_TERMINAL` | `1` | *(not a Kasm flag)* | `0` removes the terminal emulators from the container. See [Terminal access](#terminal-access). |

!!! danger "verbose DLP log captures keystrokes"
    `KASM_DLP_LOG=verbose` writes **KEYSTROKES AND CLIPBOARD CONTENT** to
    the server log. That means typed passwords and any pasted content end
    up on disk. Only use it with legal review in place.

## Watermark expansion

`KASM_WATERMARK_TEXT` supports two kinds of substitution:

- `${USER}` and `$USER` are expanded by `start-desktop.sh` before Xkasmvnc
  sees them, using the first `KASM_USERS` entry, else `VNC_USER`, else the
  OS `$USER`. So `RESTRICTED - ${USER}` becomes `RESTRICTED - bob` when
  `KASM_USERS=bob:...` is set.
- strftime tokens (`%H:%M`, `%Y-%m-%d`, etc.) are expanded by KasmVNC at
  render time.

!!! warning "ASCII only"
    The default watermark font ships without glyphs like em dash (U+2014).
    Stick to ASCII in the watermark text or you will see fallback
    rectangles.

## Examples

Block copy/paste both directions, watermark the desktop:

```bash
docker run --rm -p 8443:8443 --cap-add=NET_ADMIN \
  -e KASM_WATERMARK_TEXT='${USER} %H:%M' \
  ghcr.io/kartoza/qgis-desktop-docker:latest
```

Allow paste in but block copy out, with a 4 KB cap and plain-text only:

```bash
docker run --rm -p 8443:8443 --cap-add=NET_ADMIN \
  -e KASM_ALLOW_CLIPBOARD_IN=1 \
  -e KASM_CLIPBOARD_IN_MAX=4096 \
  -e KASM_CLIPBOARD_MIME_TYPES=text/plain \
  ghcr.io/kartoza/qgis-desktop-docker:latest
```

Fully permissive (matches the KasmVNC upstream default posture):

```bash
docker run --rm -p 8443:8443 --cap-add=NET_ADMIN \
  -e KASM_ALLOW_CLIPBOARD_IN=1 \
  -e KASM_ALLOW_CLIPBOARD_OUT=1 \
  -e KASM_ALLOW_PRIMARY_SELECTION=1 \
  ghcr.io/kartoza/qgis-desktop-docker:latest
```

## Terminal access

By default the desktop ships XFCE's terminal emulator, and a user can reach a
shell from the panel launcher, the applications menu, Ctrl-Alt-T, or Thunar's
right-click **Open Terminal Here**. For a deployment where people are meant to
use a mapping application and nothing else:

```bash
docker run --rm -p 8443:8443 --cap-add=NET_ADMIN \
  -e KASM_ALLOW_TERMINAL=0 \
  ghcr.io/kartoza/qgis-desktop-docker:latest
```

At boot, while it is still root, the entrypoint:

1. **Deletes the terminal emulators** — the `/bin` symlink *and* the binary it
   points at, inside this container's own filesystem layer. This is the control
   that holds: every route above ends in `exec()`ing one of those names, and
   none of them can succeed once the executable is gone.
2. **Deletes the command-runner dialogs** (`xfce4-appfinder`, `xfrun4`,
   `exo-open`), which would otherwise let a user type an arbitrary command into
   a "choose an application" prompt.
3. **Hides the menu entries and removes the panel launcher**, so the desktop
   does not offer an affordance that is only going to fail.

Step 3 is cosmetic; steps 1 and 2 are the control. Nothing is written to the
image — a fresh container starts from the image again, so the setting is per
container and reversible by restarting without it.

!!! warning "This is not a sandbox"
    QGIS ships a Python console, and anything that can run Python can start a
    subprocess. Removing the terminal raises the bar for a casual user and
    removes the obvious affordance; it does not contain a determined one. The
    boundaries that do that are the unprivileged UID the desktop runs as, the
    [egress lockdown](egress-lockdown.md), and the container itself. If you
    need to stop code execution outright, do not hand out a desktop with a
    scripting console in it.

!!! tip "Combine it"
    `KASM_ALLOW_TERMINAL=0` composes with everything else — it is what the
    [analyst locked-down scenario](../scenarios/analyst-locked-down.md) uses on
    top of clipboard blocking, the watermark and the egress allowlist.

## File transfer

KasmVNC 1.4.0 **standalone** does not expose a runtime toggle for the file
upload/download feature — that lives in the commercial Kasm Workspaces
platform. If you need to block file transfer, put the container behind a
reverse proxy and drop the upload/download endpoints there, or drop the
container's outbound network with `--network none`.

# Multi-user greeter session

A shared workstation that hosts several distinct users, each with their
own home directory, each able to log out and hand the tab off to the
next person without closing the browser. Uses `QGIS_DESKTOP_AUTH_MODE=greeter`.

## Why this scenario

The default `basic` mode uses HTTP Basic Auth. Two limits become painful
when more than one person shares the same browser tab:

- The browser caches the successful credentials for the site's origin
  until the tab (or the whole browser) is closed. There's no clean way
  to force a re-prompt from inside the desktop.
- There's no "log out and let the next person sign in" affordance.

`greeter` mode fixes both. The X session presents a LightDM login form
(the same one you'd see on a laptop) as the first thing on the display.
Failure re-prompts *in place*; XFCE's log-out sends the session back to
the greeter for the next user.

## Users

Materialised at container start from `QGIS_DESKTOP_USERS`
(or `QGIS_DESKTOP_USERS_FILE`). Each entry becomes a real Linux account with its
own UID and `/home/<user>` directory. XFCE settings, QGIS projects, and
downloads are stored per user under their home.

```text
alice   → UID 1001, /home/alice
bob     → UID 1002, /home/bob
```

## Run

```bash
docker run --rm -p 8443:8443 --cap-add=NET_ADMIN \
  -e QGIS_DESKTOP_AUTH_MODE=greeter \
  -e QGIS_DESKTOP_USERS='alice:hunter2,bob:correct-horse-battery-staple' \
  ghcr.io/kartoza/qgis-desktop-docker:latest
```

Or from a source checkout:

```bash
nix run .#run-greeter-multi
```

Open [http://localhost:8443](http://localhost:8443). Pick `alice`,
type `hunter2`. When alice is done, XFCE → **Log out** returns you to
the LightDM greeter so bob can sign in on the same tab.

## Verify

- **Login form appears** on the browser (not a native browser auth
  dialog).
- **Wrong password re-prompts in place** — the greeter shows an inline
  error, tab stays open.
- **Log out returns to the greeter** — Applications → Log Out from the
  XFCE panel, then confirm; you should land on the LightDM screen again.
- **Home directories are per user**:

    ```bash
    docker exec qgis-desktop ls -la /home
    docker exec qgis-desktop id alice
    docker exec qgis-desktop id bob
    ```

- **Egress lockdown still enforced** — from a terminal inside the XFCE
  session, `curl 8.8.8.8` should hang. Add `QGIS_DESKTOP_EGRESS_ALLOW` to open
  specific hosts.
- **Clipboard controls apply as usual** — `KASM_ALLOW_CLIPBOARD_IN=1`
  etc. work with greeter mode, same as with basic.

## Trade-offs against `basic` mode

- **Image size**: LightDM + `lightdm-gtk-greeter` + PAM add ~40 MB
  uncompressed to the closure.
- **Root inside the container**: LightDM stays root so it can spawn each
  authenticated session under its target user's UID. XFCE itself still
  runs unprivileged. The nftables egress lockdown is installed before
  LightDM starts and cannot be modified from the desktop session.
- **PAM shape**: auth goes through `pam_exec` calling a small script
  that re-hashes the submitted password with `openssl passwd -6` and
  compares to `/etc/shadow`. `pam_unix` is deliberately bypassed — see
  [Architecture](../developer-guide/architecture.md#why-cant-we-just-use-pam_unix)
  for why.

## Single-user greeter

Same mode, no `QGIS_DESKTOP_USERS`:

```bash
nix run .#run-greeter
```

Boots with the default `user` / `password` credentials. Useful for
verifying the greeter loop end-to-end without editing credentials.

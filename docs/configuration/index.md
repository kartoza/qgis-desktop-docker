# Configuration

Every knob is an environment variable, grouped by concern.

| Group | What it controls | Page |
|-------|------------------|------|
| Session | Port, resolution, colour depth, X display number. | [Environment](environment.md) |
| Permissions | Clipboard direction, size caps, MIME allowlist, watermark, DLP audit log, terminal access. | [Permissions](permissions.md) |
| Authentication | Four modes: `none`, `basic` HTTP BasicAuth (default), `greeter` LightDM login, or `oidc` single sign-on. Multi-user via file, env or your identity provider. | [Authentication](authentication.md) |
| Egress lockdown | nftables allowlist, fail-closed behaviour, capability requirement. | [Egress lockdown](egress-lockdown.md) |
| Giswater | EPA solvers (EPANET/SWMM), the Python packages the plugin imports, and the `epa` wiring command. | [Giswater](giswater.md) |
| Home persistence | Restoring and saving the home directory against object storage, quotas, and the guards that stop a bad save. | [Home persistence](persistence.md) |

Defaults are chosen so that a stock `docker run --cap-add=NET_ADMIN`
produces a container that is safe to expose on a local network: auth on,
clipboard off, egress dropped. Every relaxation is opt-in.

!!! note "Booleans"
    Boolean variables (`QGIS_DESKTOP_ALLOW_TERMINAL`,
    `KASM_ALLOW_CLIPBOARD_IN`, etc.) accept `1`, `yes`, `true`, `on`, or
    `enabled` for true. Anything else counts as false.

## Two prefixes, and what they mean

| Prefix | Meaning |
|--------|---------|
| `QGIS_DESKTOP_` | This project's own behaviour: which authentication pathway runs, who may sign in, what the container may talk to, whether there is a terminal. |
| `KASM_` | A setting that maps straight onto a KasmVNC flag — the clipboard, watermark and DLP controls. Reading the [KasmVNC docs](https://kasmweb.com) tells you what it does. |
| `VNC_` | The session itself: port, resolution, colour depth, and the legacy single-user credentials. |

Before 2.0.0 everything wore the `KASM_` prefix, which implied KasmVNC provided
features it has nothing to do with — the nftables egress filter, the LightDM
greeter, single sign-on, the terminal lockdown. Now the prefix tells you which
project's documentation to read.

## Migrating from 1.x

The container **refuses to start** if it sees an old name, and prints the
replacement for each one. Nothing is silently ignored: a deployment that was
locked down under the old names would otherwise come up with no allowlist and a
default password.

| Old (≤ 1.4.0) | New (2.0.0) |
|---------------|-------------|
| `KASM_AUTH_MODE` | `QGIS_DESKTOP_AUTH_MODE` |
| `KASM_AUTH=0` | `QGIS_DESKTOP_AUTH_MODE=none` |
| `KASM_USERS` | `QGIS_DESKTOP_USERS` |
| `KASM_USERS_FILE` | `QGIS_DESKTOP_USERS_FILE` |
| `KASM_EGRESS_LOCKDOWN` | `QGIS_DESKTOP_EGRESS_LOCKDOWN` |
| `KASM_EGRESS_ALLOW` | `QGIS_DESKTOP_EGRESS_ALLOW` |
| `KASM_BIND_INTERFACE` | `QGIS_DESKTOP_BIND_INTERFACE` |
| `KASM_OIDC_*` | `QGIS_DESKTOP_OIDC_*` |
| `KASM_ALLOW_TERMINAL` | `QGIS_DESKTOP_ALLOW_TERMINAL` |
| *(mount)* `/etc/kasmvnc/users` | `/etc/qgis-desktop/users` |

Unchanged: every `KASM_ALLOW_CLIPBOARD_*`, `KASM_CLIPBOARD_*`,
`KASM_WATERMARK_TEXT`, `KASM_DLP_LOG`, and all the `VNC_*` variables.

A `sed` over your compose files does the whole job:

```bash
sed -i -E 's/\bKASM_(AUTH_MODE|USERS|USERS_FILE|EGRESS_[A-Z]+|OIDC_[A-Z_]+|ALLOW_TERMINAL|BIND_INTERFACE)\b/QGIS_DESKTOP_\1/g' docker-compose.yml
```

`KASM_AUTH=0` needs the hand edit to `QGIS_DESKTOP_AUTH_MODE=none`, since the
value changes shape as well as the name.

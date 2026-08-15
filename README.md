# QGIS Desktop Docker

A fully reproducible, Nix-built Docker image that runs [QGIS](https://qgis.org) inside a minimal XFCE desktop, accessible from any web browser via [KasmVNC](https://kasmweb.com). No VNC client needed -- just open a URL.

![QGIS LTR](https://img.shields.io/badge/QGIS-3.44%20LTR%20%7C%204.0-green?logo=qgis)
![KasmVNC 1.4](https://img.shields.io/badge/KasmVNC-1.4-blue)
![Built with Nix](https://img.shields.io/badge/Built%20with-Nix-5277C3?logo=nixos)
![License](https://img.shields.io/badge/License-GPL--2.0-orange)

## Features

- **Browser-based access** -- connect to a full QGIS desktop from any device with a web browser
- **Multi-monitor support** -- KasmVNC supports dynamic resolution resizing and multiple monitors
- **Fully reproducible** -- the entire image is defined declaratively in a Nix flake
- **Persistent workspaces** -- mount a volume to keep your QGIS projects, plugins, and settings across restarts
- **Minimal footprint** -- only the packages needed to run QGIS and the desktop environment
- **LTR or latest QGIS** -- the long-term release by default, the current release as a second image so you can test against the next LTR before it lands
- **Four ways to log in** -- no auth, HTTP Basic Auth, an in-desktop LightDM greeter, or Keycloak/OIDC single sign-on
- **Giswater-ready** -- the EPANET and SWMM solvers, the Python packages the plugin imports, and the wiring that makes Giswater find them on Linux
- **SBOM & CVE scanning** -- every build produces a Software Bill of Materials and vulnerability scan

## Quick Start

### Pull from GHCR

> **Note:** If the package is private, authenticate first: `echo $GITHUB_TOKEN | docker login ghcr.io -u USERNAME --password-stdin`

```bash
docker pull ghcr.io/kartoza/qgis-desktop-docker:latest
docker run --rm -p 8443:8443 ghcr.io/kartoza/qgis-desktop-docker:latest
```

Open [http://localhost:8443](http://localhost:8443) in your browser.

### Using Docker Compose

```bash
curl -O https://raw.githubusercontent.com/kartoza/qgis-desktop-docker/main/docker-compose.yml
docker compose up -d
```

## Usage Examples

### Basic (ephemeral)

```bash
docker run --rm -p 8443:8443 ghcr.io/kartoza/qgis-desktop-docker:latest
```

### Persistent home directory (named volume)

```bash
docker run --rm -p 8443:8443 \
  -v qgis-home:/home/user \
  ghcr.io/kartoza/qgis-desktop-docker:latest
```

QGIS settings, plugins, and projects in `/home/user` survive container restarts.

### Bind mount a local directory

```bash
docker run --rm -p 8443:8443 \
  -v "$HOME/qgis-data:/home/user/data" \
  ghcr.io/kartoza/qgis-desktop-docker:latest
```

### Persistent home + local data

```bash
docker run --rm -p 8443:8443 \
  -v qgis-home:/home/user \
  -v "$HOME/gis-projects:/home/user/projects" \
  ghcr.io/kartoza/qgis-desktop-docker:latest
```

### Custom resolution

```bash
docker run --rm -p 8443:8443 \
  -e VNC_RESOLUTION=1920x1080 \
  ghcr.io/kartoza/qgis-desktop-docker:latest
```

### Custom port

```bash
docker run --rm -p 3000:3000 \
  -e VNC_PORT=3000 \
  ghcr.io/kartoza/qgis-desktop-docker:latest
```

## Docker Compose

```yaml
services:
  qgis-desktop:
    image: ghcr.io/kartoza/qgis-desktop-docker:latest
    ports:
      - "8443:8443"
    environment:
      - VNC_RESOLUTION=1920x1080
    volumes:
      - qgis-home:/home/user
      # Optional: mount a local data directory
      # - ./data:/home/user/data
    restart: unless-stopped

volumes:
  qgis-home:
```

## QGIS version

Two images are built from the same source. The only difference is which QGIS
is inside.

| Tag | QGIS | Use it for |
|-----|------|------------|
| `:latest`, `:ltr` | **3.44.9 LTR** *(default)* | Production. The LTR line only takes bug fixes, so a project that opens today opens the same way next month. |
| `:qgis-latest` | **4.0.1** (current release) | Testing your projects, plugins and data against what becomes the next LTR — before it becomes the next LTR. |

```bash
# The default
docker run --rm -p 8443:8443 --cap-add=NET_ADMIN ghcr.io/kartoza/qgis-desktop-docker:latest

# Same container, current QGIS
docker run --rm -p 8443:8443 --cap-add=NET_ADMIN ghcr.io/kartoza/qgis-desktop-docker:qgis-latest
```

Building either from source:

```bash
nix run .#build-docker               # QGIS LTR   -> nix-xfce-kasm:ltr (+ :latest)
nix run .#build-docker-qgis-latest   # QGIS latest -> nix-xfce-kasm:qgis-latest
```

Every other feature — auth modes, egress lockdown, terminal lockdown, Giswater
wiring — is identical across both, so a project that works on one and not the
other is a QGIS change worth reporting upstream while it can still be fixed.

The running container tells you which it is: the boot log opens with a `QGIS:`
line, and `QGIS_DESKTOP_QGIS_CHANNEL` / `QGIS_DESKTOP_QGIS_VERSION` are set
inside. Without starting it:

```bash
docker image inspect ghcr.io/kartoza/qgis-desktop-docker:latest \
  --format '{{index .Config.Labels "com.kartoza.qgis.version"}}'
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `VNC_PORT` | `8443` | Port for the KasmVNC web interface |
| `QGIS_DESKTOP_QGIS_CHANNEL` | *(baked in)* | `ltr` or `latest` — which image you are running. Read-only; pick the image tag instead. |
| `QGIS_DESKTOP_QGIS_VERSION` | *(baked in)* | The QGIS version inside the image. Read-only. |
| `VNC_RESOLUTION` | `1280x720` | Initial desktop resolution (resizable in browser) |
| `VNC_COL_DEPTH` | `24` | Color depth (16, 24, or 32) |
| `VNC_PW` | `password` | VNC password (basic auth is disabled by default) |
| `DISPLAY` | `:1` | X display number |

### What the prefixes mean

| Prefix | Meaning |
|--------|---------|
| `QGIS_DESKTOP_` | This project's own behaviour — which authentication pathway runs, who may sign in, what the container may talk to, whether there is a terminal. |
| `KASM_` | A setting that maps straight onto a KasmVNC flag: the clipboard, watermark and DLP controls. |
| `VNC_` | The session itself — port, resolution, colour depth, legacy single-user credentials. |

Before 2.0.0 everything wore the `KASM_` prefix, which implied KasmVNC provided
features it has nothing to do with. **The old names are no longer read**: the
container refuses to start and names the replacement for each one. See
[Migrating from 1.x](docs/configuration/index.md#migrating-from-1x).

## Permission controls

The container ships with KasmVNC's data-loss-prevention knobs wired to environment
variables. Defaults are **restrictive** — clipboard sharing is disabled in both
directions until you explicitly enable it. Boolean values accept
`1`, `yes`, `true`, `on`, or `enabled`; anything else counts as off.

| Variable | Default | Xkasmvnc flag | Effect |
|----------|---------|---------------|--------|
| `KASM_ALLOW_CLIPBOARD_IN` | `0` | `-AcceptCutText` | Allow pasting from local machine into the container |
| `KASM_ALLOW_CLIPBOARD_OUT` | `0` | `-SendCutText` | Allow copying from the container out to the local machine |
| `KASM_ALLOW_PRIMARY_SELECTION` | `0` | `-SendPrimary` | Share X primary selection (middle-click paste) |
| `KASM_CLIPBOARD_IN_MAX` | `0` | `-DLP_ClipAcceptMax` | Max bytes accepted per paste; `0` = unlimited |
| `KASM_CLIPBOARD_OUT_MAX` | `0` | `-DLP_ClipSendMax` | Max bytes sent per copy; `0` = unlimited |
| `KASM_CLIPBOARD_DELAY_MS` | `0` | `-DLP_ClipDelay` | Minimum ms between clipboard operations (anti-spam) |
| `KASM_CLIPBOARD_MIME_TYPES` | *(kasm default)* | `-DLP_ClipTypes` | Comma-separated MIME allowlist, e.g. `text/plain,text/html` |
| `KASM_WATERMARK_TEXT` | *(none)* | `-DLP_WatermarkText` | Overlay text on the desktop as a screenshot deterrent. `${USER}` / `$USER` is expanded by `start-desktop.sh` to the first `QGIS_DESKTOP_USERS` entry (or `VNC_USER`). strftime tokens (`%H:%M` etc.) are expanded by KasmVNC at render time. Stick to ASCII — the default watermark font lacks glyphs like em dash (U+2014). |
| `KASM_DLP_LOG` | `off` | `-DLP_Log` | `off`, `info`, or `verbose`. **`verbose` logs KEYSTROKES AND CLIPBOARD CONTENT to the server log** |
| `QGIS_DESKTOP_ALLOW_TERMINAL` | `1` | *(not a Kasm flag)* | `0` deletes the terminal emulators and the command-runner dialogs from the container at boot, and strips the launcher and menu entries. Closes the panel launcher, the applications menu, Ctrl-Alt-T and Thunar's "Open Terminal Here". **Not a sandbox** — QGIS's Python console can still start subprocesses; see [docs](docs/configuration/permissions.md#terminal-access). |

### Examples

Block copy/paste both directions, watermark the desktop:

```bash
docker run --rm -p 8443:8443 \
  -e KASM_WATERMARK_TEXT='${USER} %H:%M' \
  ghcr.io/kartoza/qgis-desktop-docker:latest
```

Allow paste in but block copy out (a common data-exfil control), with a 4 KB cap:

```bash
docker run --rm -p 8443:8443 \
  -e KASM_ALLOW_CLIPBOARD_IN=1 \
  -e KASM_CLIPBOARD_IN_MAX=4096 \
  -e KASM_CLIPBOARD_MIME_TYPES=text/plain \
  ghcr.io/kartoza/qgis-desktop-docker:latest
```

Fully permissive (matches the KasmVNC upstream default posture):

```bash
docker run --rm -p 8443:8443 \
  -e KASM_ALLOW_CLIPBOARD_IN=1 \
  -e KASM_ALLOW_CLIPBOARD_OUT=1 \
  -e KASM_ALLOW_PRIMARY_SELECTION=1 \
  ghcr.io/kartoza/qgis-desktop-docker:latest
```

### File transfer

KasmVNC 1.4.0 **standalone** does not expose a runtime toggle for the file
upload/download feature — that lives in the (commercial) Kasm Workspaces
platform. If you need to block file transfer, put the container behind a
reverse proxy and drop the upload/download endpoints there, or drop the
container's outbound network with `--network none`.

## Egress network lockdown

The container ships with an **egress firewall enabled by default**. On startup
a root entrypoint installs nftables rules that allow only:

- loopback traffic,
- return traffic for connections the container initiated (`ct state established,related`),
- DNS to Docker's embedded resolver (`127.0.0.11`) and any nameserver in `/etc/resolv.conf`,
- the hosts you name in `QGIS_DESKTOP_EGRESS_ALLOW`.

Everything else outbound is dropped. Once the rules are installed, the
entrypoint drops all inheritable/ambient capabilities and switches to UID
1000, so the desktop process can neither modify nor observe the firewall.

| Variable | Default | Description |
|----------|---------|-------------|
| `QGIS_DESKTOP_EGRESS_LOCKDOWN` | `1` | `0` disables the filter entirely (**dev only**) |
| `QGIS_DESKTOP_EGRESS_ALLOW` | *(empty)* | Comma-separated allowlist: IPv4 addresses, CIDRs, and/or hostnames (resolved once at startup) |

### Required capability

The container needs `NET_ADMIN` so the entrypoint can call `nft`. Add it on
`docker run` or in compose:

```bash
docker run --cap-add=NET_ADMIN -p 8443:8443 ...
```

```yaml
services:
  qgis-desktop:
    cap_add:
      - NET_ADMIN
```

If `NET_ADMIN` is missing and `QGIS_DESKTOP_EGRESS_LOCKDOWN=1` (the default) the
container **fails closed** — it prints a diagnostic and exits. Set
`QGIS_DESKTOP_EGRESS_LOCKDOWN=0` to opt out.

### Example: only the postgres database reachable

```bash
docker run --rm -p 8443:8443 --cap-add=NET_ADMIN \
  -e QGIS_DESKTOP_EGRESS_ALLOW='db.internal,10.0.0.0/24' \
  ghcr.io/kartoza/qgis-desktop-docker:latest
```

Inside the desktop, `psql -h db.internal ...` works; `curl https://example.com`
hangs and times out.

### Caveats

- Hostnames are resolved **once** at container start. If the target's IP
  changes (typical for cloud-managed databases), restart the container.
- Only IPv4 is filtered by default. If you use IPv6, add rules to
  `entrypoint.sh` or block IPv6 with `--sysctl net.ipv6.conf.all.disable_ipv6=1`.
- The filter runs inside the container's network namespace, so it does not
  restrict traffic between multiple containers on a shared Docker network
  unless each container has its own filter.

## Giswater

QGIS in this image is equipped for the
[Giswater](https://www.giswater.org/) plugin: the Python packages it imports
(`jsonschema`, `psutil`, `pyproj`, `matplotlib`, `debugpy`) are inside QGIS's
own interpreter, and both EPA hydraulic solvers are built from source and on
`PATH`:

| Solver | Commands | Giswater project type |
|--------|----------|-----------------------|
| EPANET 2.2 | `runepanet`, `epanet`, `epanet2` | `ws` — water supply |
| SWMM 5.2.4 | `runswmm`, `swmm5` | `ud` — urban drainage |

Giswater does not search `PATH` — it executes Windows binaries shipped inside
its own plugin folder, which exist on Linux but cannot run. The `epa` command
replaces them with symlinks to the native solvers and runs automatically on
every desktop (and greeter session) start:

```bash
epa status      # solver paths and per-plugin wiring
epa install     # point the Giswater plugin(s) at the native solvers
epa test        # run a real model through both solvers
```

Install the plugin itself from the QGIS plugin manager — remember to allow
`plugins.qgis.org` and your PostGIS host through the egress lockdown. Full
details in [docs/configuration/giswater.md](docs/configuration/giswater.md).

## Endpoints

| URL | Description |
|-----|-------------|
| `http://localhost:8443` | KasmVNC web client (full desktop) — or the OIDC proxy in `oidc` mode |

## Scenarios

Worked-example deployments combining several of the knobs above:

- **[Analyst locked-down session](docs/scenarios/analyst-locked-down.md)** —
  single user `bob`, clipboard blocked in both directions, egress restricted
  to a co-located `kartoza/postgis` container. Includes UML diagrams and a
  ready-to-run `docker-compose.yml`. Try it with `nix run .#run-analyst-scenario`.

- **[Keycloak single sign-on](docs/scenarios/keycloak-sso.md)** — no user
  accounts in the container at all: an OIDC proxy authenticates against your
  identity provider and admits only users holding the right role. Ships with a
  throwaway Keycloak realm. Try it with `nix run .#run-keycloak-demo`.

## Architecture

```mermaid
graph LR
    Browser["Web Browser"] -->|HTTP :8443| KasmVNC["KasmVNC<br/>(Xkasmvnc)"]
    KasmVNC -->|X11 :1| XFCE["XFCE Desktop"]
    XFCE --> QGIS["QGIS<br/>LTR or latest"]
    XFCE --> Thunar["Thunar<br/>File Manager"]
    XFCE --> Terminal["XFCE Terminal"]

    subgraph Docker Container
        KasmVNC
        XFCE
        QGIS
        Thunar
        Terminal
    end
```

The container runs a single process tree:

1. **`start-desktop.sh`** -- entrypoint that orchestrates startup
2. **`Xkasmvnc`** -- X server + VNC + embedded web server (KasmVNC)
3. **`dbus-run-session`** -- manages the D-Bus session bus
4. **`startxfce4`** -- launches XFCE window manager, panel, desktop
5. **QGIS** -- available in the applications menu and panel launcher

KasmVNC is driven directly (the `Xkasmvnc` binary) rather than through the `kasmvncserver` Perl wrapper, eliminating a large Perl dependency tree.

## Building from Source

### Prerequisites

- [Nix](https://nixos.org/download) with flakes enabled
- Docker

### Using Nix

```bash
git clone https://github.com/kartoza/qgis-desktop-docker.git
cd qgis-desktop-docker

# Build and load the Docker image
nix run .#build-docker

# Or step by step
nix build .#docker
nix store cat $(nix build .#docker --print-out-paths) | docker load

# Run
docker run --rm -p 8443:8443 nix-xfce-kasm:latest
```

### Using Make

```bash
make build-docker    # Build the image
make run             # Run in foreground
make run-detached    # Run in background
make run-persistent  # Run with persistent home volume
make stop            # Stop the container
make test            # Run the test suite (no Docker required)
make summary         # Generate build summary
make compose-up      # Start with docker-compose
make compose-down    # Stop docker-compose
```

### Available `nix run` commands

```bash
nix run .#build-docker      # Build the Docker image
nix run .#run               # Run the container
nix run .#run-greeter       # LightDM greeter login
nix run .#run-oidc          # Keycloak/OIDC SSO (reads QGIS_DESKTOP_OIDC_* from your env)
nix run .#run-keycloak-demo # Throwaway Keycloak + SSO desktop
nix run .#test              # Run the test suite (no Docker needed)
nix run .#summary           # Generate build summary
nix run                     # Show help
```

### Development shell

```bash
nix develop
```

Provides docker, python3, syft, grype, jq, and other tools.

## Project Structure

```
flake.nix                    # Main flake: packages, Docker image, apps, dev shell
kasmvnc.nix                  # KasmVNC package (v1.4.0 from Debian Bookworm deb)
libcrypt-compat.nix          # libcrypt.so.1 compat lib from Debian
entrypoint.sh                # Root entrypoint: egress filter, auth mode, privilege drop
start-desktop.sh             # Launches Xkasmvnc + XFCE as the desktop user
config/
  xfce4/                     # XFCE panel and desktop configuration
  lightdm/                   # Greeter mode: config, PAM verifier, X server wrapper
  oidc/                      # OIDC mode: secret materialisation + oauth2-proxy launcher
nix/
  epanet.nix, swmm.nix       # EPA hydraulic solvers for Giswater (built from source)
docker-compose.yml           # Docker Compose example
examples/
  analyst-locked-down/       # Locked-down analyst scenario
  keycloak-oidc/             # Keycloak single sign-on demo
Makefile                     # Make targets for build/run/summary
build-summary.sh             # Build summary generator
scripts/
  epa.sh                     # Points the Giswater plugin at the native solvers
  test-oidc-config.sh        # Unit tests for the OIDC plumbing
  sbom_table.py              # SBOM JSON to markdown table
  cve_table.py               # Grype CVE JSON to markdown table
.github/workflows/
  docker.yml                 # Unified PR + Release workflow
```

## CI/CD

A single GitHub Actions workflow (`.github/workflows/docker.yml`) handles both PRs and releases.

### On every Pull Request

1. Builds the Docker image with Nix
2. Generates an SBOM (SPDX JSON via anchore/sbom-action)
3. Scans for CVEs (Grype via anchore/scan-action)
4. Generates a build report with image stats, SBOM table, and CVE table
5. Uploads image tarball, SBOM, and CVE scan as **7-day artifacts**
6. Posts/updates a **PR comment** with the full build report

### On every Release

1. Builds the Docker image with Nix
2. Generates SBOM and CVE scan
3. Pushes to **GitHub Container Registry** (`ghcr.io/kartoza/qgis-desktop-docker`)
4. Tags with both version and `latest`
5. Appends build report to release notes
6. Attaches image tarball, `sbom.spdx.json`, and `cve-scan.json` as release assets

## Security & Transparency

Every build generates:

- **[SBOM](https://github.com/kartoza/qgis-desktop-docker/releases/latest)** (`sbom.spdx.json`) -- complete Software Bill of Materials in SPDX JSON format listing every package in the image
- **[CVE Scan](https://github.com/kartoza/qgis-desktop-docker/releases/latest)** (`cve-scan.json`) -- Grype vulnerability scan results with severity ratings

Both are attached to every release and available as artifacts on every PR build.

### Authentication

The container offers four auth pathways selected by `QGIS_DESKTOP_AUTH_MODE`
(default: `basic`):

| Mode | What the user sees | When to use |
|------|--------------------|-------------|
| `basic` | Browser's HTTP Basic Auth dialog | Fast to set up. Fine for a single trusted user. |
| `greeter` | In-desktop LightDM login form | Multi-user, or wherever users may need to log out / re-authenticate without closing the browser tab. |
| `oidc` | Your identity provider's login page | Single sign-on against Keycloak (or any OIDC provider): central accounts, MFA, role-based access. |
| `none` | No prompt — desktop appears immediately | Local dev only. Never expose to any untrusted network. |

The `KASM_*` names these settings used before 2.0.0 are no longer read — the
container refuses to start and names the replacement. See
[Migrating from 1.x](docs/configuration/index.md#migrating-from-1x).

`basic`, `greeter` and `none` read credentials from the same sources (first
wins); `oidc` gets its accounts from the identity provider instead:

1. `QGIS_DESKTOP_USERS_FILE` — path to a file containing `user:password` per line;
   default `/etc/qgis-desktop/users`. `#` comments and blank lines ignored.
   Mount with mode `0600`.
2. `QGIS_DESKTOP_USERS` — inline `alice:pw1,bob:pw2` list.
3. Legacy `VNC_USER` / `VNC_PW` — single user, defaults to `user` / `password`.

| Variable | Default | Description |
|----------|---------|-------------|
| `QGIS_DESKTOP_AUTH_MODE` | `basic` | `none` \| `basic` \| `greeter` \| `oidc` |
| `QGIS_DESKTOP_USERS_FILE` | `/etc/qgis-desktop/users` | Bind-mount target for a `user:password` file |
| `QGIS_DESKTOP_USERS` | *(none)* | Inline `user1:pw1,user2:pw2` list |
| `QGIS_DESKTOP_OIDC_ISSUER_URL` | *(none)* | Required in `oidc` mode: the realm/issuer URL |
| `QGIS_DESKTOP_OIDC_CLIENT_ID` | *(none)* | Required in `oidc` mode |
| `QGIS_DESKTOP_OIDC_CLIENT_SECRET_FILE` | *(none)* | Required in `oidc` mode (or `QGIS_DESKTOP_OIDC_CLIENT_SECRET`) |
| `QGIS_DESKTOP_OIDC_REDIRECT_URL` | *(none)* | Required in `oidc` mode: public URL + `/oauth2/callback` |

The full `QGIS_DESKTOP_OIDC_*` table is in
[docs/configuration/authentication.md](docs/configuration/authentication.md).

**Basic (default), multi-user via file:**

```bash
cat > users <<'EOF'
alice:hunter2
bob:correct-horse-battery-staple
EOF
chmod 600 users
docker run --rm -p 8443:8443 --cap-add=NET_ADMIN \
  -v "$PWD/users:/etc/qgis-desktop/users:ro" \
  ghcr.io/kartoza/qgis-desktop-docker:latest
```

**Greeter mode (in-desktop LightDM login form):**

```bash
docker run --rm -p 8443:8443 --cap-add=NET_ADMIN \
  -e QGIS_DESKTOP_AUTH_MODE=greeter \
  ghcr.io/kartoza/qgis-desktop-docker:latest
# Log in as user / password. Wrong password re-prompts in place —
# no browser tab to close, no cache to clear.
```

**Single sign-on against Keycloak (or any OIDC provider):**

```bash
docker run --rm -p 8443:8443 --cap-add=NET_ADMIN \
  -e QGIS_DESKTOP_AUTH_MODE=oidc \
  -e QGIS_DESKTOP_OIDC_ISSUER_URL=https://sso.example.com/realms/gis \
  -e QGIS_DESKTOP_OIDC_CLIENT_ID=qgis-desktop \
  -e QGIS_DESKTOP_OIDC_CLIENT_SECRET_FILE=/run/secrets/oidc \
  -e QGIS_DESKTOP_OIDC_REDIRECT_URL=https://gis.example.com/oauth2/callback \
  -e QGIS_DESKTOP_OIDC_ALLOWED_ROLES=qgis-user \
  -v /path/to/secret:/run/secrets/oidc:ro \
  ghcr.io/kartoza/qgis-desktop-docker:latest
```

`oauth2-proxy` takes over the published port and KasmVNC moves to
`127.0.0.1:6901` behind it, so an unauthenticated request never reaches the
desktop. Try it end to end — including a user who is deliberately refused —
with `nix run .#run-keycloak-demo`.

**Disable auth for local dev only:**

```bash
docker run --rm -p 8443:8443 --cap-add=NET_ADMIN -e QGIS_DESKTOP_AUTH_MODE=none \
  ghcr.io/kartoza/qgis-desktop-docker:latest
```

Notes:

- **`basic` vs `greeter`.** `basic` is the browser's own HTTP Basic Auth
  dialog — unstyled and hard to re-prompt after a failed login (browsers
  cache the credentials for the tab). `greeter` runs LightDM inside the
  X session, so failures and logouts return to a proper login form.
- **`oidc` composes.** `QGIS_DESKTOP_OIDC_INNER_MODE=greeter` requires single sign-on
  at the edge *and* gives each user their own Linux session inside.
- **Privileges.** `basic`, `none` and `oidc` run the desktop as UID 1000 after
  the root entrypoint drops privileges — the OIDC proxy runs unprivileged too.
  `greeter` keeps LightDM running as root inside the container so it can spawn
  each session as its target user; XFCE itself still runs unprivileged.
- **Secrets stay off the command line.** With the `_FILE` variables the client
  secret is read as root at boot and written to a `0400` config file owned by
  the proxy's UID — never visible in `ps` or `docker inspect`.
- **Custom brand or another SSO stack.** Front the container with your own
  reverse proxy (nginx, Traefik, Caddy + `basic_auth`, …) and set
  `QGIS_DESKTOP_AUTH_MODE=none` — but only when that proxy is the sole route in.

## License

GPL-2.0 -- see [LICENSE](LICENSE) for details.

KasmVNC is licensed under GPL-2.0. QGIS is licensed under GPL-2.0.

---

Made with love by [Kartoza](https://kartoza.com) | [Donate!](https://github.com/sponsors/kartoza) | [GitHub](https://github.com/kartoza/qgis-desktop-docker)

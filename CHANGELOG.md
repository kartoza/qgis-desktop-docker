# Changelog

All notable changes to **QGIS Desktop Docker** are recorded here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.3.0] — 2026-07-06

Secure-by-default release: multi-user auth, clipboard/DLP controls, an
nftables egress lockdown, plus a full mkdocs documentation site with a
Kartoza-branded PDF build.

### Added

#### Authentication
- HTTP BasicAuth is now the primary auth path. The browser prompts once; the
  same credentials are transparently re-used for the VNC handshake.
- `KASM_USERS_FILE` — bind-mount a `user:password` file (one entry per line,
  `#` comments supported). Default path: `/etc/kasmvnc/users`.
- `KASM_USERS` — inline `alice:pw1,bob:pw2` list; passwords may contain
  colons.
- Precedence: `KASM_USERS_FILE` → `KASM_USERS` → legacy `VNC_USER` / `VNC_PW`.
- `KASM_AUTH=0` — explicit opt-out for local dev; adds `-DisableBasicAuth`.

#### Kasm data-loss-prevention controls (all secure-by-default)
- `KASM_ALLOW_CLIPBOARD_IN` / `KASM_ALLOW_CLIPBOARD_OUT` — clipboard direction
  gating (default off).
- `KASM_ALLOW_PRIMARY_SELECTION` — X primary-selection (middle-click) gating.
- `KASM_CLIPBOARD_IN_MAX` / `KASM_CLIPBOARD_OUT_MAX` — per-op byte caps.
- `KASM_CLIPBOARD_DELAY_MS` — anti-spam delay.
- `KASM_CLIPBOARD_MIME_TYPES` — MIME allowlist.
- `KASM_WATERMARK_TEXT` — desktop watermark. `${USER}` expanded to the
  primary session user by `start-desktop.sh` (Xkasmvnc's own template engine
  handles only strftime).
- `KASM_DLP_LOG` — DLP audit level (`off` / `info` / `verbose`).

#### Egress network lockdown
- `KASM_EGRESS_LOCKDOWN` (default `1`) — nftables filter installed by a new
  root entrypoint before the desktop starts. Drops all outbound traffic
  except loopback, established/related, DNS to Docker's embedded resolver,
  and the allowlist.
- `KASM_EGRESS_ALLOW` — comma-separated IPv4 addresses, CIDRs, and hostnames
  (resolved once at startup).
- Fails **closed**: if the container lacks `NET_ADMIN`, the entrypoint prints
  a diagnostic and exits.
- New container architecture: root entrypoint installs firewall, then
  `setpriv --reuid=1000 --regid=1000 --inh-caps=-all --ambient-caps=-all`
  execs the desktop, so the QGIS process can neither observe nor modify the
  ruleset.

#### Documentation
- Full mkdocs site under `docs/` — Home, Getting Started, Configuration,
  Scenarios, Developer Guide, About.
- Kartoza brand pack v1.0.1 assets: logos, motif, tokens, Lato +
  JetBrains Mono fonts. Theme mirrors the InfrastructureMapper Material for
  MkDocs setup (Kartoza palette, Nunito → Lato, admonitions, tabbed content,
  glightbox, git-revision-date-localized).
- New scenario: **Analyst Locked-Down Session** — worked example with three
  hand-drawn SVG UML diagrams (deployment, login flow, container internals),
  a ready-to-run `examples/analyst-locked-down/docker-compose.yml` pairing
  `nix-xfce-kasm` with `postgis/postgis:16-3.4`, and a verification checklist.
- Kartoza-branded PDF build via `nix run .#docs-pdf` — pandoc + lualatex,
  vector SVG diagrams, real Kartoza logo on the cover, brand palette
  throughout.

#### `nix run` targets
- `run-multi-user`, `run-users-file`, `run-no-auth`, `run-locked-down`,
  `run-egress-locked`, `run-no-lockdown` — one target per auth / DLP posture.
- `run-analyst-scenario` — spins up the compose file above and tears
  everything down on `Ctrl-C`.
- `stop`, `logs` — container management convenience.
- `docs-serve`, `docs-build`, `docs-pdf` — documentation pipeline.

#### CI
- `.github/workflows/docs.yml` — builds the mkdocs site + PDF; deploys the
  site to GitHub Pages on release and push-to-main; attaches the PDF as a
  7-day artifact on every PR/push and as a long-lived asset on release.
- Docker workflow now assembles the PR-comment body on disk and passes it
  via `body-path` — no more slurping `build-report.md` into `GITHUB_ENV`.

### Changed

- Container entrypoint switched from `start-desktop` (uid 1000) to
  `qgis-entrypoint` (root → drops to uid 1000). Existing `docker run` usage
  is unchanged; add `--cap-add=NET_ADMIN` if you want the egress lockdown
  active.
- RFB `SecurityTypes` fixed to `None`. HTTP BasicAuth on `~/.kasmpasswd`
  gates all connections at the HTTP layer; the legacy `~/.vnc/passwd` file
  is no longer required (and never was, in this project's direct-Xkasmvnc
  setup).
- `docker-compose.yml` example now includes `cap_add: [NET_ADMIN]` and
  commented examples for every new env var.
- `README.md` documents authentication, permission, and egress-lockdown
  sections; adds a "Scenarios" index.
- `peter-evans/find-comment@v3` → `@v4`, `cachix/install-nix-action@v27` →
  `@v31` (Node 24 compatibility).

### Fixed

- **X server crash-loop**: `start-desktop.sh` now clears stale
  `/tmp/.X${N}-lock` and `/tmp/.X11-unix/X${N}` on entry, so a docker
  `restart` no longer pins the container into an endless retry with
  `Server is already active for display 1`.
- **`_XSERVTransmkdir: Owner of /tmp/.X11-unix should be set to root`**:
  root entrypoint creates the directory as `root:root` mode `1777` before
  handing off to uid 1000.
- **Watermark tofu**: `${USER}` in `KASM_WATERMARK_TEXT` is now expanded
  before Xkasmvnc sees it (perl `kasmvncserver` wrapper handled this; direct
  Xkasmvnc did not). ASCII-only characters recommended in the watermark
  string — the default font lacks em dash (U+2014).
- **`Argument list too long` in the Docker CI**: the PR-comment step no
  longer writes the CVE-heavy report into `GITHUB_ENV`. The env var was
  ~150 KB per subsequent step's `execve`, pushing Node 24 past
  `MAX_ARG_STRLEN`. Report is now assembled into `pr-comment.md` on disk
  and fed to `peter-evans/create-or-update-comment@v4` via `body-path`.
- **STUN noise**: `-publicIP 127.0.0.1` on `Xkasmvnc` short-circuits the
  ICE STUN probes that used to fail one by one under egress lockdown.

### Security

- Egress firewall on by default (fail-closed).
- Clipboard OFF by default in both directions.
- HTTP BasicAuth on the web endpoint by default.
- Desktop process runs uid 1000 with all inheritable + ambient capabilities
  cleared; `nft` cannot be re-invoked from the desktop.

## [1.2.0] — 2026-05-14

See [GitHub release notes](https://github.com/kartoza/qgis-desktop-docker/releases/tag/v1.2.0).

## [1.1.0] — 2026-05-14

See [GitHub release notes](https://github.com/kartoza/qgis-desktop-docker/releases/tag/v1.1.0).

## [1.0.0] — 2026-05-13

Initial release. See [GitHub release notes](https://github.com/kartoza/qgis-desktop-docker/releases/tag/v1.0.0).

[Unreleased]: https://github.com/kartoza/qgis-desktop-docker/compare/v1.3.0...HEAD
[1.3.0]: https://github.com/kartoza/qgis-desktop-docker/compare/v1.2.0...v1.3.0
[1.2.0]: https://github.com/kartoza/qgis-desktop-docker/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/kartoza/qgis-desktop-docker/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/kartoza/qgis-desktop-docker/releases/tag/v1.0.0

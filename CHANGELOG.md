# Changelog

All notable changes to **QGIS Desktop Docker** are recorded here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [2.0.0] — 2026-08-15

A fourth authentication pathway that puts Keycloak (or any OIDC provider) in
front of the desktop, everything the Giswater QGIS plugin needs to actually run
— including the two EPA hydraulic solvers, built from source — a terminal
lockdown, and the environment-variable rename that makes the major bump.

### Changed — BREAKING

**The default image is now QGIS LTR (3.44.9), not the current release
(4.0.1).** The LTR line only takes bug fixes, which is what belongs in front of
users; the current release is still published, as a second image, for testing
against what becomes the next LTR. `ghcr.io/kartoza/qgis-desktop-docker:latest`
therefore moves from QGIS 4.0.1 to 3.44.9 — pin `:qgis-latest` to stay on the
current release. See [QGIS version](README.md#qgis-version).

**Every variable that is this project's own behaviour moved from the `KASM_`
prefix to `QGIS_DESKTOP_`.** The old prefix implied KasmVNC provided features it
has nothing to do with: the nftables egress filter, the LightDM greeter, single
sign-on, the terminal lockdown. `KASM_` now means one thing — a setting that
maps straight onto a KasmVNC flag.

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
| *(mount)* `/etc/kasmvnc/users` | `/etc/qgis-desktop/users` |

**Unchanged**, because they are genuinely KasmVNC settings:
`KASM_ALLOW_CLIPBOARD_IN` / `_OUT`, `KASM_ALLOW_PRIMARY_SELECTION`,
`KASM_CLIPBOARD_IN_MAX` / `_OUT_MAX`, `KASM_CLIPBOARD_DELAY_MS`,
`KASM_CLIPBOARD_MIME_TYPES`, `KASM_WATERMARK_TEXT`, `KASM_DLP_LOG` — and all
the `VNC_*` session variables.

- **The container refuses to start if it sees an old name**, listing each one
  with its replacement, rather than ignoring it. A deployment that was locked
  down under the old names would otherwise come up with no egress allowlist and
  the default password. The same applies to a credentials file left at
  `/etc/kasmvnc/users`.
- Migration, including a one-line `sed`, is in
  [Configuration → Migrating from 1.x](docs/configuration/index.md#migrating-from-1x).
- Internals moved with them: the nftables table is now `inet
  qgis_desktop_egress`, runtime state lives under `/run/qgis-desktop/`, and the
  in-container helpers are `qgis-desktop-oidc-config`,
  `qgis-desktop-oidc-proxy` and `qgis-desktop-disable-terminal`.

### Added

#### Authentication — `QGIS_DESKTOP_AUTH_MODE=oidc`
- `oidc` (alias `keycloak`) fronts the desktop with
  [oauth2-proxy](https://oauth2-proxy.github.io/oauth2-proxy/). The proxy owns
  the published port; KasmVNC is rebound to `127.0.0.1:6901`, so an
  unauthenticated request never reaches the desktop at all.
- Provider defaults to `keycloak-oidc` (realm/client role filtering) but speaks
  plain OIDC discovery, so `QGIS_DESKTOP_OIDC_ISSUER_URL` can point at any compliant
  identity provider. `QGIS_DESKTOP_OIDC_PROVIDER=oidc` selects the generic provider.
- Configuration: `QGIS_DESKTOP_OIDC_ISSUER_URL`, `QGIS_DESKTOP_OIDC_CLIENT_ID`,
  `QGIS_DESKTOP_OIDC_CLIENT_SECRET[_FILE]`, `QGIS_DESKTOP_OIDC_REDIRECT_URL`,
  `QGIS_DESKTOP_OIDC_COOKIE_SECRET[_FILE]`, `QGIS_DESKTOP_OIDC_SCOPE`,
  `QGIS_DESKTOP_OIDC_EMAIL_DOMAINS`, `QGIS_DESKTOP_OIDC_EMAIL_CLAIM`,
  `QGIS_DESKTOP_OIDC_ALLOWED_GROUPS`, `QGIS_DESKTOP_OIDC_ALLOWED_ROLES`,
  `QGIS_DESKTOP_OIDC_COOKIE_SECURE`, `QGIS_DESKTOP_OIDC_COOKIE_EXPIRE`,
  `QGIS_DESKTOP_OIDC_TLS_CERT_FILE` / `_KEY_FILE`, `QGIS_DESKTOP_OIDC_REVERSE_PROXY`,
  `QGIS_DESKTOP_OIDC_INSECURE_SKIP_VERIFY`, `QGIS_DESKTOP_OIDC_UPSTREAM_PORT`,
  `QGIS_DESKTOP_OIDC_INNER_MODE`, `QGIS_DESKTOP_OIDC_EXTRA_ARGS`.
- `QGIS_DESKTOP_OIDC_INNER_MODE` composes with the existing modes: `none` (default —
  one shared desktop behind SSO) or `greeter` (SSO at the edge *and* a per-user
  Linux session inside).
- Secrets never reach a command line. `qgis-desktop-oidc-config` runs as root at boot,
  reads `*_FILE` secrets (so a `0400 root:root` mount works), and writes them
  to `/run/qgis-desktop/oidc/secrets.cfg` mode `0400` owned by UID 1000. `ps` inside the
  container and `docker inspect` outside it both stay clean.
- The proxy runs unprivileged under `setpriv` with all capabilities cleared,
  and a watchdog stops the container if it ever exits — the desktop cannot be
  left serving with nothing in front of it.
- The identity provider's host is added to the nftables egress allowlist
  automatically, since discovery and the code exchange happen server-side.
- Session cookies are marked `Secure` automatically when
  `QGIS_DESKTOP_OIDC_REDIRECT_URL` is `https://`, and the container warns at boot when
  it is not.
- New `nix run .#run-oidc` (against your own IdP) and
  `nix run .#run-keycloak-demo` (throwaway Keycloak with a pre-imported realm)
  targets, plus `examples/keycloak-oidc/`.

#### Home persistence — `QGIS_DESKTOP_PERSIST`
- The home directory is restored from object storage before the desktop starts,
  saved every `QGIS_DESKTOP_PERSIST_INTERVAL` seconds, and saved again on
  shutdown. One user, one container, one bucket prefix. Works against MinIO,
  DigitalOcean Spaces, Hetzner, any S3-compatible store, or a mounted directory
  (`QGIS_DESKTOP_PERSIST_TYPE=local`).
- A sync rather than a mount, deliberately: QGIS profiles and GeoPackages are
  SQLite, and object-storage FUSE drivers offer neither POSIX locking nor atomic
  partial writes. The cost is bounded and visible — work since the last save is
  lost to a hard kill — rather than unbounded and silent.
- With persistence on, the entrypoint stays PID 1 so it can catch `SIGTERM` and
  run a final save before Kubernetes follows up with `SIGKILL`.
- Five guards against the failure that matters, a save replacing good data with
  bad: a container that failed to restore never saves; a failed restore stops
  the container instead of showing an empty home; a home that lost most of its
  files is not mirrored; replaced and deleted objects move to
  `.persist-trash/<timestamp>/`; and a second container on the same prefix
  refuses to start (lease keyed on the hostname, so a recreated pod reclaims its
  own immediately).
- Client-side quota. Over it, saving stops and a `PERSISTENCE-WARNING.txt`
  appears in the home directory saying so — the user has no terminal to read
  logs in.
- Caches, session scaffolding and `.kasmpasswd` are never uploaded.

#### QGIS channels
- Two images from the same source, differing only in the QGIS package:
  `nix-xfce-kasm:ltr` (also tagged `:latest`) on the long-term release, and
  `nix-xfce-kasm:qgis-latest` on the current release. Published to GHCR as
  `:latest` / `:<version>` and `:qgis-latest` / `:<version>-qgis-latest`.
- `nix run .#build-docker` builds the LTR image;
  `nix run .#build-docker-qgis-latest` builds the other. Flake outputs
  `packages.docker-ltr`, `packages.docker-qgis-latest`, `packages.qgis-ltr` and
  `packages.qgis-latest` expose the pieces individually.
- Which QGIS is inside is visible three ways: the `com.kartoza.qgis.channel` /
  `com.kartoza.qgis.version` image labels (no need to start the container), the
  `QGIS:` line at the top of the boot log, and the `QGIS_DESKTOP_QGIS_CHANNEL` /
  `QGIS_DESKTOP_QGIS_VERSION` variables inside the session.
- CI builds and smoke-tests both channels in parallel, so a regression in the
  upcoming LTR surfaces on a pull request rather than on release day.

#### Giswater support
- QGIS is built with the Python packages the Giswater plugin imports —
  `jsonschema`, `debugpy`, `psutil`, `pyproj`, `matplotlib` — inside its own
  interpreter.
- **EPANET 2.2** and **SWMM 5.2.4**, the two US EPA solvers Giswater drives,
  built from upstream source in `nix/` (neither is in nixpkgs) and available as
  `runepanet`/`epanet`/`epanet2` and `runswmm`/`swmm5`. Both derivations solve a
  real model during `installCheckPhase`.
- `epa` command (`epa status|install|uninstall|test`). Giswater executes Windows
  binaries from fixed paths inside its own plugin folder; `epa install` replaces
  them with symlinks to the native solvers, keeping the originals as
  `*.shipped-windows`. It runs automatically on every desktop start and, in
  `greeter` mode, on every session start.
- `GISWATER_EPANET_EXE` and `GISWATER_SWMM_EXE` set image-wide; QGIS itself is
  wrapped so both solvers are on `PATH` and `LD_LIBRARY_PATH` for anything it
  spawns.
- New flake outputs: `packages.epanet`, `packages.swmm`, `packages.qgis`,
  `packages.epa`.

#### Terminal lockdown — `QGIS_DESKTOP_ALLOW_TERMINAL`
- `QGIS_DESKTOP_ALLOW_TERMINAL=0` removes terminal access from the desktop. The
  entrypoint deletes the terminal emulators (the `/bin` symlink *and* the
  binary behind it) and the command-runner dialogs (`xfce4-appfinder`,
  `xfrun4`, `exo-open`) from the container's own filesystem layer, then strips
  the panel launcher and hides the menu entries. Closes the panel launcher, the
  applications menu, Ctrl-Alt-T and Thunar's *Open Terminal Here*.
- Idempotent and per-container: nothing is written to the image, and restarting
  without the variable brings the terminal back.
- Documented honestly as an affordance control rather than a sandbox — QGIS's
  Python console can still start subprocesses. See
  [Terminal access](docs/configuration/permissions.md#terminal-access).
- The analyst locked-down scenario and `nix run .#run-locked-down` now set it.

#### Testing
- `scripts/test-oidc-config.sh` (`nix run .#test-oidc`) — 46 assertions over
  configuration validation, secret handling, TOML escaping, cookie-security
  defaults, authorisation lists and the TLS listener. No Docker and no identity
  provider needed; the proxy binary is stubbed. The last assertion checks every
  flag the launcher emits against the real `oauth2-proxy --help`, which is what
  caught `--silence-ping-logger` before release.
- `scripts/test-terminal-lockdown.sh` (`nix run .#test-terminal-lockdown`) — 27
  assertions driving the lockdown against a throwaway tree shaped like the
  container's `/bin` and `/home`.
- `scripts/test-persist.sh` (`nix run .#test-persist`) — 52 assertions driving
  the real persistence script against a local rclone remote: round trip,
  exclusions, every guard, the lease, and that the secret key never appears in
  output.
- `scripts/test-docs-glyphs.sh` (`nix run .#test-docs-glyphs`) — applies the
  PDF build's own substitutions to every page the PDF includes and fails if a
  byte pdflatex cannot set survives, naming the file and line. The substitutions
  now live in `docs/pdf/glyph-substitutions.tsv`, read by both the PDF build and
  the test, instead of a list inside `flake.nix` that grew one CI failure at a
  time.
- `nix run .#test` runs all five; `make test` does the same without Nix.
- CI runs them as a gate before the image build.

#### Packages
- `oauth2-proxy` and `cacert` added to the image. The image previously shipped
  **no CA bundle at all**, so TLS verification now works for the identity
  provider and for any HTTPS service QGIS talks to. Roughly +30 MB uncompressed,
  plus the Giswater Python packages and solvers.

### Fixed

- **Secrets reached the desktop session's environment.** The OIDC client secret
  (and, once persistence landed, the object-store credentials) were inherited by
  the desktop, so anything running as the desktop user — QGIS's Python console,
  for one — could read them out of `/proc/self/environ`. They are now removed
  from the environment once written to their root-owned config files, before any
  unprivileged process starts. Verified by searching every process readable by
  uid 1000 for the secret's value.

The two below were found while testing the OIDC path end to end against a real
Keycloak, and both affect every release since the egress lockdown landed in
1.3.0.

- **DNS was broken inside the container whenever the egress lockdown was on.**
  The entrypoint ran `nft flush ruleset`, which also deleted Docker's `ip nat`
  table — the one carrying the DNAT rules that make the embedded resolver at
  `127.0.0.11:53` answer at all, and which nftables explicitly labels
  "managed by iptables-nft, do not touch". On any user-defined or Compose
  network, every name lookup after startup failed with connection refused, so
  allowlisted hosts were reachable only by IP. The rules now live in a table of
  our own, `inet qgis_desktop_egress`, and only that table is replaced.
- **Hostnames in `KASM_EGRESS_ALLOW` never resolved.** `getent` is its own
  package in current nixpkgs and is no longer part of `glibc.bin`, so
  `resolve_host` silently failed for every name and logged
  `could not resolve '<host>' at startup; skipping`. `getent` is now an
  explicit image dependency, and a missing one is reported as an error rather
  than a per-host warning.

### Changed
- `KASM_BIND_INTERFACE` (default `0.0.0.0`) is honoured by both KasmVNC
  launchers. The entrypoint sets it to `127.0.0.1` in `oidc` mode.
- The authentication mode is now resolved *before* the egress filter is
  installed, so the issuer host can be allowlisted.
- `start-desktop.sh` and the greeter's `Xsession` run `epa install` before
  starting XFCE.
- Docs: new [Giswater](docs/configuration/giswater.md) and
  [Keycloak SSO](docs/scenarios/keycloak-sso.md) pages; authentication,
  kasm-permissions, egress-lockdown, architecture, project-structure, nix-flake
  and nix-workflow pages updated.
- The analyst locked-down scenario's verification checklist now runs the
  shell-based checks from the host via `docker exec`, since the desktop it
  describes no longer has a terminal.

### Notes
- The desktop session is shared across users in `oidc` mode unless
  `QGIS_DESKTOP_OIDC_INNER_MODE=greeter` is set — the same caveat that already applies
  to `basic`.
- Over plain HTTP the session cookie cannot be marked `Secure`. Terminate TLS in
  front of the container (or set `QGIS_DESKTOP_OIDC_TLS_CERT_FILE`) for anything beyond
  localhost.
- The egress allowlist resolves the IdP's hostname once at startup. Providers
  behind rotating IPs need an explicit `KASM_EGRESS_ALLOW` CIDR.
- The Giswater plugin itself is not pre-installed — install it from the QGIS
  plugin manager (and allow `plugins.qgis.org` through the egress filter).
- The EPA solver derivations are vendored from Kartoza's GISWater development
  environment and kept in sync by hand.

## [1.4.0] — 2026-07-08

Adds a third authentication pathway: an in-desktop LightDM greeter that
avoids the browser-cache pain of HTTP Basic Auth on failed logins.

### Added

#### Authentication
- `KASM_AUTH_MODE` — tri-state selector: `none` | `basic` (default) |
  `greeter`. `basic` and `none` behave exactly as before.
- `greeter` mode boots LightDM (with `lightdm-gtk-greeter`) inside the
  KasmVNC-served X session. Xkasmvnc runs with `-DisableBasicAuth`; the
  greeter is the auth boundary.
- Users defined via `KASM_USERS` / `KASM_USERS_FILE` / legacy
  `VNC_USER`+`VNC_PW` are materialised as real Linux accounts at container
  start, so PAM authenticates against `/etc/shadow`.
- New `nix run .#run-greeter` convenience app.
- Kartoza-branded greeter config (`config/lightdm/lightdm-gtk-greeter.conf`).

#### Packages
- `lightdm`, `lightdm-gtk-greeter`, `linux-pam`, `shadow`, `dbus` (system
  bus) added to the image. Roughly +40 MB uncompressed for the new closure.

### Changed
- Legacy `KASM_AUTH=0` continues to work — it is now interpreted as
  `KASM_AUTH_MODE=none`.
- `docker-compose.yml` and `docs/configuration/authentication.md`
  documented against the new tri-state.

### Notes
- In `greeter` mode LightDM runs as root inside the container so it can
  spawn each session as its target user. The XFCE session still runs
  unprivileged. The nftables egress lockdown is installed before LightDM
  starts and cannot be modified from inside the session.

## [1.3.0] — 2026-07-06

Secure-by-default release: multi-user auth, clipboard/DLP controls, an
nftables egress lockdown, plus a full mkdocs documentation site with a
Kartoza-branded PDF build.

### Added

#### Authentication
- HTTP BasicAuth is now the primary auth path. The browser prompts once; the
  same credentials are transparently re-used for the VNC handshake.
- `KASM_USERS_FILE` — bind-mount a `user:password` file (one entry per line,
  `#` comments supported). Default path: `/etc/qgis-desktop/users`.
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

[Unreleased]: https://github.com/kartoza/qgis-desktop-docker/compare/v2.0.0...HEAD
[2.0.0]: https://github.com/kartoza/qgis-desktop-docker/compare/v1.4.0...v2.0.0
[1.4.0]: https://github.com/kartoza/qgis-desktop-docker/compare/v1.3.0...v1.4.0
[1.3.0]: https://github.com/kartoza/qgis-desktop-docker/compare/v1.2.0...v1.3.0
[1.2.0]: https://github.com/kartoza/qgis-desktop-docker/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/kartoza/qgis-desktop-docker/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/kartoza/qgis-desktop-docker/releases/tag/v1.0.0

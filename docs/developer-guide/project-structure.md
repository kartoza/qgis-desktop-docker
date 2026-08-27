# Project structure

Annotated tree of the repo.

```text
qgis-desktop-docker/
├── flake.nix                   # Main flake: packages, Docker image, apps, dev shell
├── flake.lock                  # Pinned inputs — committed, updated in its own PR
├── kasmvnc.nix                 # KasmVNC package (v1.4.0 from Debian Bookworm deb)
├── libcrypt-compat.nix         # libcrypt.so.1 compat lib from Debian
│
├── entrypoint.sh               # Root entrypoint: nftables + auth mode dispatch
├── start-desktop.sh            # Unprivileged entrypoint (basic/none): Xkasmvnc + XFCE
│
├── config/                     # XFCE panel and desktop configuration
│   ├── xfce4/
│   │   ├── panel/default.xml
│   │   └── xfconf/xfce-perchannel-xml/xfce4-desktop.xml
│   │
│   ├── lightdm/                # LightDM greeter mode (QGIS_DESKTOP_AUTH_MODE=greeter)
│   │   ├── lightdm-gtk-greeter.conf   # Kartoza-branded greeter theme
│   │   ├── xkasmvnc-wrapper.sh        # X-server shim that starts Xkasmvnc
│   │   ├── check-password.sh          # pam_exec verifier (sha512crypt)
│   │   └── xfce.desktop               # Session .desktop entry lightdm reads
│   │
│   ├── oidc/                   # Single sign-on mode (QGIS_DESKTOP_AUTH_MODE=oidc)
│   │   ├── oidc-config.sh      # Root: validates config, writes 0400 secrets file
│   │   └── oidc-proxy.sh       # Unprivileged: builds flags, execs oauth2-proxy
│   │
│   ├── session/                # Desktop session lifecycle (basic/none/oidc)
│   │   └── session-supervisor.sh # Relaunches XFCE on log-out, with a crash-loop guard
│   │
│   └── lockdown/               # QGIS_DESKTOP_ALLOW_TERMINAL=0
│       └── disable-terminal.sh # Root: deletes terminals, strips launcher/menu
│
│   # lightdm.conf and Xsession are generated inline in flake.nix so
│   # nix store paths (fonts, XDG_DATA_DIRS, xkeyboard_config) can be
│   # baked in at build time.
│
├── nix/                        # Giswater's EPA solvers, built from source
│   ├── epanet.nix              # EPANET 2.2 (water supply)
│   ├── swmm.nix                # SWMM 5.2.4 (urban drainage)
│   ├── swmm-realpath-buffer-overflow.patch
│   └── swmm-smoke.inp          # Build-time smoke-test model
│
├── resources/                  # Static assets baked into the image
│   └── wallpaper.png
│
├── docker-compose.yml          # Docker Compose example (single-container)
├── Makefile                    # Make targets for build/run/summary
├── build-summary.sh            # Build summary generator (image + SBOM + CVE)
│
├── scripts/
│   ├── epa.sh                  # Wires the Giswater plugin to the native solvers
│   ├── test-oidc-config.sh     # Unit tests for the OIDC plumbing
│   ├── test-terminal-lockdown.sh # Unit tests for QGIS_DESKTOP_ALLOW_TERMINAL=0
│   ├── test-session-restart.sh # Unit tests for the session supervisor
│   ├── sbom_table.py           # SBOM JSON to markdown table
│   └── cve_table.py            # Grype CVE JSON to markdown table
│
├── examples/
│   ├── analyst-locked-down/
│   │   └── docker-compose.yml  # Multi-container scenario compose file
│   └── keycloak-oidc/          # Keycloak SSO demo
│       ├── docker-compose.yml
│       ├── realm-export.json   # Pre-imported demo realm (public credentials)
│       └── client-secret.txt   # Demo client secret (public — never reuse)
│
├── docs/                       # This mkdocs site
│   ├── index.md
│   ├── getting-started/
│   ├── configuration/
│   ├── scenarios/
│   ├── developer-guide/
│   └── about/
│
├── .github/workflows/
│   └── docker.yml              # Unified PR + Release workflow
│
├── README.md
└── LICENSE
```

## Where things happen

Build the image
: `flake.nix` → `packages.docker` → `pkgs.dockerTools.buildLayeredImage`.

Set the boot order
: `flake.nix` → `dockerImage.config.Cmd` → `qgis-entrypoint` (from
  `entrypoint.sh`) → `setpriv` → `start-desktop` (from
  `start-desktop.sh`).

Wire an env var
: The variable is read in `start-desktop.sh` or `entrypoint.sh` and,
  where it needs a compiled-in default, listed in
  `flake.nix` → `dockerImage.config.Env`.

Add a `nix run` target
: `flake.nix` → `apps.<name> = mkApp "<name>" '' ... '';`.

Add a package to the image
: `flake.nix` → `dockerImage.contents = [ ... ];`.

Change how the desktop is fronted in `oidc` mode
: `config/oidc/oidc-proxy.sh` builds the oauth2-proxy flag list;
  `config/oidc/oidc-config.sh` handles anything secret. Both are covered by
  `scripts/test-oidc-config.sh` (`nix run .#test-oidc`).

Touch the Giswater solvers
: `nix/epanet.nix` / `nix/swmm.nix` build them; `scripts/epa.sh` wires the
  plugin to them. Both derivations solve a real model at build time, so
  `nix build .#epanet` is the fastest check.

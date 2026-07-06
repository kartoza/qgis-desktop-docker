# Project structure

Annotated tree of the repo.

```text
qgis-desktop-docker/
├── flake.nix                   # Main flake: packages, Docker image, apps, dev shell
├── flake.lock                  # Pinned inputs — committed, updated in its own PR
├── kasmvnc.nix                 # KasmVNC package (v1.4.0 from Debian Bookworm deb)
├── libcrypt-compat.nix         # libcrypt.so.1 compat lib from Debian
│
├── entrypoint.sh               # Root entrypoint: nftables + setpriv drop
├── start-desktop.sh            # Unprivileged entrypoint: Xkasmvnc + XFCE
│
├── config/                     # XFCE panel and desktop configuration
│   └── xfce4/
│       ├── panel/default.xml
│       └── xfconf/xfce-perchannel-xml/xfce4-desktop.xml
│
├── resources/                  # Static assets baked into the image
│   └── wallpaper.png
│
├── docker-compose.yml          # Docker Compose example (single-container)
├── Makefile                    # Make targets for build/run/summary
├── build-summary.sh            # Build summary generator (image + SBOM + CVE)
│
├── scripts/
│   ├── sbom_table.py           # SBOM JSON to markdown table
│   └── cve_table.py            # Grype CVE JSON to markdown table
│
├── examples/
│   └── analyst-locked-down/
│       └── docker-compose.yml  # Multi-container scenario compose file
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

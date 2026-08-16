# Giswater support

The image ships everything the
[Giswater](https://www.giswater.org/) QGIS plugin needs at runtime: the Python
packages it imports, the two US EPA hydraulic solvers it drives, and the wiring
that makes the plugin actually find them on Linux.

The plugin itself is **not** pre-installed — install it from QGIS's plugin
manager (or drop it into your mounted profile) and everything else is already
in place.

## What is included

| Component | Why |
|-----------|-----|
| `jsonschema`, `psutil`, `pyproj`, `matplotlib`, `debugpy` | Imported by the plugin from inside QGIS's own interpreter |
| **EPANET 2.2** (`runepanet`, `epanet`, `epanet2`) | Solver for pressurised water supply — Giswater `ws` projects |
| **SWMM 5.2.4** (`runswmm`, `swmm5`) | Solver for urban drainage — Giswater `ud` projects |
| `epa` | Command that points the plugin at the native solvers |

Neither solver is in nixpkgs, so both are built from upstream source in
[`nix/`](https://github.com/kartoza/qgis-desktop-docker/tree/main/nix). Each
derivation **runs a real model during the build**: a solver that cannot solve
anything fails the build rather than reaching a user.

```bash
nix build .#epanet    # builds and smoke-tests EPANET
nix build .#swmm      # builds and smoke-tests SWMM
```

## Why the `epa` command exists

Giswater's `go2epa` tool does not search `PATH`. It shells out to two fixed
paths inside its own plugin directory:

```python
opener = f"{plugin_dir}/resources/epa/epanet/epanet.exe"   # ws projects
opener = f"{plugin_dir}/resources/epa/swmm/swmm5.exe"      # ud projects
```

The plugin ships **Windows** binaries at those paths. On Linux they exist — so
the plugin's `os.path.exists()` check passes — and then fail to execute.

`epa install` replaces them with symlinks to the natively built solvers, keeping
each original as `*.shipped-windows` so the change is reversible:

```bash
epa status      # solver paths and per-plugin wiring
epa install     # point the Giswater plugin(s) at the native solvers
epa uninstall   # put the shipped Windows binaries back
epa test        # run a model through both solvers
```

The command line signatures match, which is why a symlink is enough:

```text
runepanet <input.inp> <report.rpt> [<binary.bin>]
runswmm   <input.inp> <report.rpt> [<output.out>]
```

!!! tip "You rarely need to run it by hand"
    `epa install` runs automatically on every desktop start — and in
    `greeter` mode on every *session* start, so each user's profile is wired
    up separately. It is idempotent and a no-op when the plugin is absent.
    Install the plugin while the desktop is already running? Open a terminal,
    run `epa install`, and restart QGIS.

## First run

```bash
docker run --rm -p 8443:8443 --cap-add=NET_ADMIN \
  -v qgis-home:/home/user \
  -e QGIS_DESKTOP_EGRESS_ALLOW=plugins.qgis.org,gis.example.com \
  ghcr.io/kartoza/qgis-desktop-docker:latest
```

1. **Allow the egress you need.** The lockdown is on by default with an empty
   allowlist, so the QGIS plugin manager cannot reach `plugins.qgis.org` and
   the plugin cannot reach your PostGIS host until you list them. See
   [Egress lockdown](egress-lockdown.md).
2. In QGIS: **Plugins → Manage and Install Plugins → Giswater**.
3. Restart QGIS (or run `epa install` first, then restart) so the solvers are
   wired up.
4. Point Giswater at your PostGIS database in **Giswater → Connection**.

Mount `/home/user` on a volume as shown above, or the plugin and its
configuration are gone on the next container start.

## Verifying

```bash
epa status     # both solvers found, both plugin shims 'linked'
epa test       # solves a real model with each
```

`epa test` runs EPANET's bundled `Net1.inp` and a one-pipe SWMM model, and
checks each report ends with `Analysis ended`.

## Notes

- **The database is yours.** The image is a desktop, not a Giswater server:
  bring your own PostgreSQL/PostGIS instance and allow it through the egress
  filter. Giswater creates its own schemas from inside the plugin.
- **Newer Giswater releases** prefer the `hydraulic_engine` Python package when
  it is importable, which carries its own solver libraries. That path needs no
  wiring; the shims cover the fallback Giswater uses when it is absent.
- **The SWMM build carries a patch.** Upstream 5.2.4 aborts on startup on any
  hardened glibc build — including every nixpkgs build — because it passes a
  260-byte buffer to `realpath()`, which POSIX requires to hold `PATH_MAX`. The
  patch and its rationale are in
  [`nix/swmm-realpath-buffer-overflow.patch`](https://github.com/kartoza/qgis-desktop-docker/blob/main/nix/swmm-realpath-buffer-overflow.patch).
- **Licensing.** EPANET is MIT; SWMM is US federal government work released
  without copyright. Neither adds copyleft obligations to the image.

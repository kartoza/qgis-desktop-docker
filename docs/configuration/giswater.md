# Giswater support

The image ships everything the
[Giswater](https://www.giswater.org/) QGIS plugin needs: the plugin itself
(pre-installed and enabled in the default profile), the Python packages it
imports, the two US EPA hydraulic solvers it drives, and the wiring that
makes the plugin actually find them on Linux.

The plugin is baked into the image's default profile at
`~/.local/share/QGIS/QGIS3/profiles/default/python/plugins/giswater`
(pinned to a specific commit, see `giswaterPlugin` in `flake.nix`) and
pre-enabled via `QGIS3.ini`.

!!! warning "Only reaches a fresh home on a named volume"
    Docker copies the image's existing `/home/user` content into a **named
    volume** the first time it's used (`-v qgis-home:/home/user`, as in
    every example on this page). A **bind mount** replaces the mountpoint
    entirely instead and won't get it. If you're bind-mounting
    `/home/user`, seed the plugin yourself (copy it in before first start,
    or install it from the Plugin Manager as before).

## What is included

| Component | Why |
|-----------|-----|
| The **Giswater plugin itself** | Pre-installed and enabled in the default profile |
| `jsonschema`, `psutil`, `pyproj`, `matplotlib`, `debugpy` | Imported by the plugin from inside QGIS's own interpreter |
| **EPANET 2.2** (`runepanet`, `epanet`, `epanet2`) | Solver for pressurised water supply — Giswater `ws` projects |
| **SWMM 5.2.4** (`runswmm`, `swmm5`) | Solver for urban drainage — Giswater `ud` projects |
| `epa` | Command that points the plugin at the native solvers |
| Two demo projects (`wsex.qgs`, `udex.qgs`) | See [Demo projects](#demo-projects) below |
| A default `pg_service.conf` | See [Demo projects](#demo-projects) below |

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
  -e QGIS_DESKTOP_EGRESS_ALLOW=gis.example.com \
  ghcr.io/kartoza/qgis-desktop-docker:ltr
```

1. **Allow the egress you need.** The lockdown is on by default with an empty
   allowlist, so the plugin cannot reach your PostGIS host until you list it
   (`plugins.qgis.org` is only needed if you're browsing *other* plugins;
   Giswater itself is already installed). See
   [Egress lockdown](egress-lockdown.md).
2. Open QGIS. Giswater is already there, and `epa install` already ran
   automatically at desktop start, so the solvers are wired up too. Nothing
   to do in the Plugin Manager.
3. Open one of the demo projects on the Desktop (see below), or point
   Giswater at your own PostGIS database in **Giswater → Connection**.

Mount `/home/user` on a volume as shown above, or the plugin, the demo
projects, and the rest of this section's content are gone on the next
container start.

## Demo projects

`~/Desktop/giswater-projects/wsex.qgs` and `udex.qgs` are real Giswater
projects, generated from a live `giswater-suite` bootstrap run, not
hand-built. Their layers use `service='qwc_giswaterdb'` datasources
exclusively; no host, user, or password is embedded in either file.

Each ships with a `*_attachments.zip` sidecar (`wsex_attachments.zip`,
`udex_attachments.zip`). That's QGIS's own mechanism, not this repo's,
for plain-XML `.qgs` projects that reference an attached file
(`projectStyleId="attachment:///KzqWSL_styles.db"` in this case, a
project-scoped default style database) via its `attachment:///` URI
scheme, generated automatically when the project was saved. Keep each zip
next to its `.qgs`, QGIS can't resolve the reference without it.

That service resolves through `~/.pg_service.conf`
(`PGSERVICEFILE=/home/user/.pg_service.conf`, also baked in — see
`resources/pg_service.conf`), which by default points at
`host=giswater-db`, matching `giswater-suite`'s own local dev stack. The
projects open and work immediately when this image runs as that stack's
`qgis-desktop` service, no manual connection setup needed.

A matching **saved PostgreSQL connection named "Giswater"** (Browser panel
/ Data Source Manager → PostgreSQL), pointing at `service=qwc_giswaterdb`
with no host/database/username/password of its own, is baked into the
default profile's `QGIS3.ini` the same way the plugin flag is. It resolves
through the same `pg_service.conf`, so browsing the database directly
(outside the two demo projects) needs no manual connection setup either.

Running the image any other way (standalone, or as production QCD), the
baked default is a **fallback only, expected to be overwritten**:

- **Standalone** against your own database: overwrite `~/.pg_service.conf`
  (bind-mount a file over it, or edit it from inside the running desktop)
  with a `[qwc_giswaterdb]` service pointing at your own instance. The demo
  projects will then resolve against whatever schema is there.
- **Production (QCD)**: GeoHosting's own provisioner renders and injects a
  real per-EndUser `pg_service.conf` the same way. A single-file mount over
  `/home/user/.pg_service.conf` replaces the baked default cleanly
  regardless of what image content is underneath, no conflict with the
  named-volume-vs-bind-mount gotcha above (that one only bites when the
  *whole* `/home/user` is bind-mounted, not a single file inside it).

## Verifying

```bash
epa status     # both solvers found, both plugin shims 'linked'
epa test       # solves a real model with each
```

`epa test` runs EPANET's bundled `Net1.inp` and a one-pipe SWMM model, and
checks each report ends with `Analysis ended`.

## Notes

- **The database is still yours.** The image is a desktop, not a Giswater
  server. The two demo projects and the default `pg_service.conf` exist to
  make the plugin usable out of the box (see [Demo
  projects](#demo-projects)), not to bundle a database — bring your own
  PostgreSQL/PostGIS instance, allow it through the egress filter, and point
  `pg_service.conf` at it. Giswater creates its own schemas from inside the
  plugin.
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

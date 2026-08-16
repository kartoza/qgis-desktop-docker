<!--
SPDX-FileCopyrightText: Tim Sutton
SPDX-License-Identifier: MIT
-->

# EPA hydraulic solvers

The [Giswater](https://www.giswater.org/) QGIS plugin drives two US EPA
solvers, and its installation guide lists both as prerequisites:

| Solver | Used for | Giswater project type |
| ------ | -------- | --------------------- |
| EPANET | Pressurised water distribution networks | `ws` (water supply) |
| SWMM   | Urban drainage and stormwater | `ud` (urban drainage) |

Neither is in nixpkgs, so this directory packages both from upstream source.
They are baked into the desktop image and exposed as flake outputs.

## What is here

| File | Purpose |
| ---- | ------- |
| `epanet.nix` | EPANET 2.2 from the OpenWaterAnalytics distribution |
| `swmm.nix` | SWMM 5.2.4 from the USEPA solver distribution |
| `swmm-realpath-buffer-overflow.patch` | Fixes a fatal SWMM overflow on glibc |
| `swmm-smoke.inp` | One-pipe SWMM model used as a build-time smoke test |

Both derivations run a real simulation during `installCheckPhase`, so a build
that produces a solver which cannot actually solve anything fails the build
rather than reaching a user:

```bash
nix build .#epanet
nix build .#swmm
```

### Versions

EPANET is pinned to **2.2** and SWMM to **5.2.4**, matching the versions the
Giswater compatibility matrix lists for Giswater 3.x/4.x. Both are pinned by
tag with a content hash, so builds are reproducible.

### Licensing

EPANET is MIT. SWMM is US federal government work, released without copyright.
Neither adds copyleft obligations to the image.

## The SWMM patch

SWMM 5.2.4 aborts on startup on **every** hardened glibc build, which includes
every nixpkgs build:

```text
 o  Retrieving project data*** buffer overflow detected ***: terminated
```

`getAbsolutePath()` in `src/solver/swmm5.c` passes `InpDir`, a 260-byte array
sized after Windows' `MAX_PATH`, as the resolved-name buffer of `realpath()`.
POSIX requires that buffer to hold `PATH_MAX` (4096) bytes, and glibc's
`_FORTIFY_SOURCE` checks the destination object size at the call site and
aborts. It fires while reading the project file, before any simulation step.

The patch has glibc allocate the buffer instead (`realpath(fname, NULL)`) and
then copies the result back within the bounds of the caller's array. The
adjacent absolute-path branch had the same unbounded-copy shape and is bounded
too. The Windows branch is untouched, so the change is suitable to send
upstream as-is — it has not been submitted yet.

## How the plugin finds the solvers

Giswater's `go2epa` tool does not search `PATH`; it executes two fixed paths
inside its own plugin directory, where it ships Windows binaries. `scripts/epa.sh`
(installed into the image as `epa`) replaces them with symlinks to the natively
built solvers. See
[the Giswater configuration page](../docs/configuration/giswater.md) for the
full story and the `epa` command reference.

## Provenance

These derivations came from Kartoza's GISWater development environment and are
kept in sync with it by hand. Changes that are not specific to this image
should go back there too.

---

Made with 💗 by [Kartoza](https://kartoza.com)

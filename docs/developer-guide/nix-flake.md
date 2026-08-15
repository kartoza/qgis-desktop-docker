# Nix flake

The whole image is defined by three Nix files and two shell scripts. The
flake pins nixpkgs and produces the image as a
`pkgs.dockerTools.buildLayeredImage` derivation.

## Files

`flake.nix`
: The entry point. Declares the packages, the docker image, the
  `nix run .#*` apps, and the dev shell.

`kasmvnc.nix`
: A `callPackage`-able derivation that unpacks KasmVNC 1.4.0 from the
  Debian Bookworm `.deb`. This avoids building KasmVNC (with its large
  Perl and Xorg fork) from source and lets the flake pin the exact upstream
  binary.

`libcrypt-compat.nix`
: A tiny derivation that exposes `libcrypt.so.1` from Debian. Some Kasm
  binaries dynamically link against the pre-2.38 `libcrypt` soname; nixpkgs
  ships `libxcrypt` under a different soname, so we drop the compat shim
  next to the binaries.

`start-desktop.sh`
: The unprivileged desktop entrypoint. Wrapped in a
  `pkgs.writeShellApplication` called `start-desktop` so its
  `runtimeInputs` (KasmVNC, XFCE, dbus, xkbcomp, etc.) are on PATH.

`entrypoint.sh`
: The root entrypoint. Wrapped in a `pkgs.writeShellApplication` called
  `qgis-entrypoint` with `nftables`, `util-linux` (for `setpriv`),
  `iproute2`, `glibc.bin` (for `getent`), `start-desktop`, and the two
  OIDC scripts as runtime inputs.

`config/oidc/oidc-config.sh` and `config/oidc/oidc-proxy.sh`
: The single sign-on pathway, as two `writeShellApplication`s —
  `qgis-desktop-oidc-config` (root; validates and materialises secrets) and
  `qgis-desktop-oidc-proxy` (unprivileged; execs `oauth2-proxy`). Split so that only
  the first needs root, and only the second is long-running.

`config/lockdown/disable-terminal.sh`
: The terminal lockdown, as a `writeShellApplication` called
  `qgis-desktop-disable-terminal`. Its paths are overridable (`QGIS_DESKTOP_LOCKDOWN_BIN_DIR`,
  `QGIS_DESKTOP_LOCKDOWN_HOME_ROOT`) purely so the test suite can drive it against a
  throwaway tree.

`nix/epanet.nix` and `nix/swmm.nix`
: Giswater's EPA hydraulic solvers, built from upstream source because neither
  is in nixpkgs. Both run a real model in `installCheckPhase`, so a solver that
  cannot solve fails the build.

## Derivations

`packages.kasmvnc`
: The `kasmvnc.nix` package, exposed so it can be built and inspected
  independently.

`packages.docker` (also `packages.dockerImage`, `packages.default`)
: The layered docker image. Contains bash, coreutils, KasmVNC, the XFCE
  core (session, panel, terminal, desktop, wm, settings, xfconf, thunar),
  X11 essentials, dbus, shared-mime-info, icon themes, fonts, QGIS, and
  the egress-lockdown tooling (`nftables`, `setpriv`, `iproute2`,
  `getent`), plus `startupScript` and `entrypointScript`. Since 2.0.0 it also
  carries the EPA solvers, the `epa` tool, a CA bundle, and the OIDC scripts.

`packages.qgis`
: QGIS as the image ships it: `pkgs.qgis` with the Giswater Python packages
  overridden into its interpreter, then `symlinkJoin`-wrapped so every binary
  has EPANET and SWMM on `PATH` and `LD_LIBRARY_PATH`.

`packages.epanet`, `packages.swmm`, `packages.epa`
: The Giswater building blocks on their own, so they can be built and smoke
  tested without building the whole image.

## Apps

Apps are produced by a small `mkApp` helper:

```nix
mkApp = name: script: {
  type = "app";
  program = "${pkgs.writeShellApplication {
    inherit name;
    runtimeInputs = with pkgs; [ docker jq coreutils ];
    text = script;
  }}/bin/${name}";
};
```

This gives every `nix run .#foo` command a hermetic PATH with `docker`,
`jq`, and `coreutils` — no reliance on the user's shell environment. The
full list of apps is in [Nix workflow](../getting-started/nix-workflow.md).

## Dev shell

`nix develop` drops you into a shell with `docker`, `python3`, `syft`,
`grype`, and `jq`. The shell hook prints the same target list as
`nix run` so you always have the map to hand.

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
  `iproute2`, `glibc.bin` (for `getent`), and `start-desktop` as
  runtime inputs.

## Derivations

`packages.kasmvnc`
: The `kasmvnc.nix` package, exposed so it can be built and inspected
  independently.

`packages.docker` (also `packages.dockerImage`, `packages.default`)
: The layered docker image. Contains bash, coreutils, KasmVNC, the XFCE
  core (session, panel, terminal, desktop, wm, settings, xfconf, thunar),
  X11 essentials, dbus, shared-mime-info, icon themes, fonts, QGIS, and
  the egress-lockdown tooling (`nftables`, `setpriv`, `iproute2`,
  `getent`), plus `startupScript` and `entrypointScript`.

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

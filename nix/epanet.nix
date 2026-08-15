# SPDX-FileCopyrightText: Tim Sutton
# SPDX-License-Identifier: MIT
#
# EPANET — the US EPA water distribution network hydraulic/quality solver.
#
# Not in nixpkgs, so we build it from the OpenWaterAnalytics community fork,
# which is the reference source distribution for EPANET 2.2 (the version the
# Giswater compatibility matrix pins for Giswater 3.x water-supply projects).
#
# Upstream ships no CMake install rules for the 2.2 tag, so the install phase
# below places the artefacts by hand and repoints the CLI's RPATH at the
# store's lib directory.
{
  lib,
  stdenv,
  fetchFromGitHub,
  cmake,
  patchelf,
}:

stdenv.mkDerivation (finalAttrs: {
  pname = "epanet";
  version = "2.2";

  src = fetchFromGitHub {
    owner = "OpenWaterAnalytics";
    repo = "EPANET";
    rev = "v${finalAttrs.version}";
    hash = "sha256-rPWTKnz8g1n0A9i6glJB7ccbXxfjRKoMISlozuh3IVw=";
  };

  nativeBuildInputs = [
    cmake
    patchelf
  ];

  cmakeFlags = [
    "-DCMAKE_BUILD_TYPE=Release"
    "-DBUILD_TESTS=OFF"
    # The 2.2 tree declares `cmake_minimum_required (VERSION 2.8.8)`, which
    # modern CMake refuses outright. The sources themselves are fine under
    # current policies.
    "-DCMAKE_POLICY_VERSION_MINIMUM=3.5"
  ];

  # The 2.2 tree has no `install()` targets at all — everything lands in the
  # build tree under bin/ and lib/, so we place it ourselves.
  installPhase = ''
    runHook preInstall

    install -Dm755 bin/runepanet "$out/bin/runepanet"

    # libepanet2 is the toolkit itself; libepanet-output reads the binary
    # results files and is what result-parsing tooling links against.
    for so in lib/*${stdenv.hostPlatform.extensions.sharedLibrary}; do
      install -Dm755 "$so" "$out/lib/$(basename "$so")"
    done

    for header in "$src"/include/*.h; do
      install -Dm644 "$header" "$out/include/$(basename "$header")"
    done

    # Giswater and other callers invoke the solver under a handful of historical
    # names. Provide them all so no caller has to know which build produced it.
    ln -s runepanet "$out/bin/epanet"
    ln -s runepanet "$out/bin/epanet2"

    # Example networks are handy for smoke-testing an install.
    mkdir -p "$out/share/epanet"
    cp -r "$src/example-networks" "$out/share/epanet/example-networks"

    # runepanet finds libepanet2 through the build-tree RPATH, which does not
    # survive the copy into the store (and trips the audit-tmpdir check). Point
    # it at our own lib directory before fixup runs.
    ${lib.optionalString stdenv.hostPlatform.isLinux ''
      patchelf --set-rpath "$out/lib" "$out/bin/runepanet"
    ''}

    runHook postInstall
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck

    # Solve a bundled example network end to end. This exercises the same
    # `runepanet <inp> <rpt>` call Giswater makes, and proves the CLI resolves
    # libepanet2 from the store.
    "$out/bin/runepanet" \
      "$out/share/epanet/example-networks/Net1.inp" smoke.rpt
    grep -q "Analysis ended" smoke.rpt

    runHook postInstallCheck
  '';

  meta = {
    description = "US EPA water distribution system hydraulic and water quality solver";
    longDescription = ''
      EPANET models the hydraulic and water quality behaviour of pressurised
      pipe networks. This package builds the OpenWaterAnalytics distribution of
      EPANET 2.2, providing the `runepanet` command line solver (also available
      as `epanet` and `epanet2`) and the shared `libepanet2` toolkit library.
    '';
    homepage = "https://github.com/OpenWaterAnalytics/EPANET";
    license = lib.licenses.mit;
    mainProgram = "runepanet";
    platforms = lib.platforms.unix;
  };
})

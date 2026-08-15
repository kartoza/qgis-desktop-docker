# SPDX-FileCopyrightText: Tim Sutton
# SPDX-License-Identifier: MIT
#
# SWMM — the US EPA Storm Water Management Model solver.
#
# Not in nixpkgs, so we build the official USEPA solver distribution. Giswater
# drives SWMM for urban drainage (`ud`) projects.
#
# Upstream installs the shared library into bin/ (a Windows-ism); we relocate it
# to lib/ and repoint the CLI's RPATH so the result is a well-formed Unix
# package.
{
  lib,
  stdenv,
  fetchFromGitHub,
  cmake,
  patchelf,
  llvmPackages,
}:

stdenv.mkDerivation (finalAttrs: {
  pname = "swmm";
  version = "5.2.4";

  src = fetchFromGitHub {
    owner = "USEPA";
    repo = "Stormwater-Management-Model";
    rev = "v${finalAttrs.version}";
    hash = "sha256-gZqFgcxIljA2MIfvx512ICN5qW2F/b/MwUzxSzDMW9s=";
  };

  patches = [
    # Without this the solver aborts on startup on any hardened glibc build,
    # which includes every nixpkgs build. See the patch header for detail.
    ./swmm-realpath-buffer-overflow.patch
  ];

  nativeBuildInputs = [
    cmake
    patchelf
  ];

  # The solver parallelises its routing step with OpenMP. Clang needs the
  # runtime supplied explicitly; GCC bundles libgomp.
  buildInputs = lib.optionals stdenv.cc.isClang [ llvmPackages.openmp ];

  cmakeFlags = [
    "-DCMAKE_BUILD_TYPE=Release"
    "-DBUILD_TESTS=OFF"
  ];

  postInstall = ''
    # Upstream puts the shared library next to the executable because that is
    # what Windows wants. Move it to lib/ and leave a compatibility symlink.
    mkdir -p "$out/lib"
    for so in "$out"/bin/*${stdenv.hostPlatform.extensions.sharedLibrary}*; do
      [ -e "$so" ] || continue
      mv "$so" "$out/lib/"
      ln -s "../lib/$(basename "$so")" "$so"
    done

    # Giswater invokes the solver as `swmm5`; upstream names the CLI `runswmm`.
    ln -s runswmm "$out/bin/swmm5"

    # CMake drops the build-tree RPATH on install and upstream sets no install
    # RPATH, so the CLI would not find libswmm5 in its new home. Append rather
    # than replace, so the toolchain entry that supplies libgomp survives.
    ${lib.optionalString stdenv.hostPlatform.isLinux ''
      patchelf --add-rpath "$out/lib" "$out/bin/runswmm"
    ''}
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck

    # A one-pipe drainage network: enough to route a full simulation and so to
    # prove the solver, its OpenMP runtime and libswmm5 all resolve. This is the
    # same `runswmm <inp> <rpt> <out>` call Giswater makes.
    cp ${./swmm-smoke.inp} smoke.inp

    "$out/bin/runswmm" smoke.inp smoke.rpt smoke.out
    grep -q "Analysis ended" smoke.rpt

    runHook postInstallCheck
  '';

  meta = {
    description = "US EPA Storm Water Management Model rainfall-runoff and drainage solver";
    longDescription = ''
      SWMM simulates runoff quantity and quality from primarily urban
      catchments, together with flow routing through drainage networks. This
      package builds the USEPA solver distribution, providing the `runswmm`
      command line solver (also available as `swmm5`) and the shared `libswmm5`
      toolkit library.
    '';
    homepage = "https://github.com/USEPA/Stormwater-Management-Model";
    # Authored by the US federal government and released without copyright.
    license = lib.licenses.publicDomain;
    mainProgram = "runswmm";
    platforms = lib.platforms.unix;
  };
})

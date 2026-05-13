{ stdenv, fetchurl, dpkg }:

# Extract libcrypt.so.1 from the Debian Bookworm libcrypt1 package.
# KasmVNC's pre-built binaries are linked against libcrypt.so.1 (legacy ABI)
# which nixpkgs no longer ships (nixpkgs libxcrypt only provides libcrypt.so.2).
stdenv.mkDerivation rec {
  pname = "libcrypt-compat";
  version = "4.4.33-2";

  src = fetchurl {
    url = "https://deb.debian.org/debian/pool/main/libx/libxcrypt/libcrypt1_${version}_amd64.deb";
    sha256 = "sha256-9fYKXN/U5OqpQ4reUHild0Gnp41ln8sMcBIE9SPovSk=";
  };

  nativeBuildInputs = [ dpkg ];

  unpackPhase = ''
    dpkg-deb -x $src .
  '';

  installPhase = ''
    mkdir -p $out/lib
    cp -a lib/x86_64-linux-gnu/libcrypt.so.* $out/lib/
  '';
}

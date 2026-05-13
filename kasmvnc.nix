{ lib
, stdenv
, callPackage
, fetchurl
, autoPatchelfHook
, dpkg
, makeWrapper
, libpng
, zlib
, libunwind
, pixman
, libXfont2
, libXau
, systemd
, libGL
, mesa
, libwebp
, openssl
, freetype
, libbsd
, libmd
, libxshmfence
, libxdmcp
, libx11
, libxext
, libxtst
, libxrandr
, libxcursor
, libxfixes
, xkbcomp
, xkeyboard_config
}:

let
  libcryptCompat = callPackage ./libcrypt-compat.nix {};
in
stdenv.mkDerivation rec {
  pname = "kasmvnc";
  version = "1.4.0";

  src = fetchurl {
    url = "https://github.com/kasmtech/KasmVNC/releases/download/v${version}/kasmvncserver_bookworm_${version}_amd64.deb";
    sha256 = "0slmivk1pf472ad58aw31p7whcmi36qz571yfnxxi9wkipdvjnd0";
  };

  nativeBuildInputs = [
    autoPatchelfHook
    dpkg
    makeWrapper
  ];

  buildInputs = [
    libpng
    zlib
    libunwind
    pixman
    libXfont2
    libXau
    systemd
    libxshmfence
    libxdmcp
    libGL
    mesa
    libwebp
    openssl
    libcryptCompat
    freetype
    libbsd
    libmd
    stdenv.cc.cc.lib  # libstdc++
    libx11
    libxext
    libxtst
    libxrandr
    libxcursor
    libxfixes
  ];

  unpackPhase = ''
    dpkg-deb -x $src .
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out/bin $out/etc/kasmvnc $out/share/kasmvnc

    # Install binaries
    cp usr/bin/Xkasmvnc $out/bin/
    cp usr/bin/kasmvncpasswd $out/bin/
    cp usr/bin/kasmxproxy $out/bin/
    cp usr/bin/kasmvncconfig $out/bin/

    # Install web UI
    cp -r usr/share/kasmvnc/www $out/share/kasmvnc/

    # Install config
    cp etc/kasmvnc/kasmvnc.yaml $out/etc/kasmvnc/
    cp usr/share/kasmvnc/kasmvnc_defaults.yaml $out/share/kasmvnc/

    # Fix paths in defaults yaml
    substituteInPlace $out/share/kasmvnc/kasmvnc_defaults.yaml \
      --replace-quiet '/usr/share/kasmvnc/www' "$out/share/kasmvnc/www"

    runHook postInstall
  '';

  postFixup = ''
    wrapProgram $out/bin/Xkasmvnc \
      --set XKB_RULES_DIR "${xkeyboard_config}/share/X11/xkb/rules" \
      --set XKB_BASE_DIR "${xkeyboard_config}/share/X11/xkb" \
      --prefix PATH : "${lib.makeBinPath [ xkbcomp ]}"
  '';

  meta = with lib; {
    description = "KasmVNC - modern VNC server with web browser access and multi-monitor support";
    homepage = "https://kasmweb.com";
    license = licenses.gpl2Plus;
    platforms = [ "x86_64-linux" ];
  };
}

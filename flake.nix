{
  description = "Minimal XFCE desktop in a Docker container with KasmVNC web-based access";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };

        # KasmVNC package
        kasmvnc = pkgs.callPackage ./kasmvnc.nix {};

        # Startup script that launches KasmVNC + XFCE
        startupScript = pkgs.writeShellApplication {
          name = "start-desktop";
          runtimeInputs = with pkgs; [
            kasmvnc
            xfce4-session
            xfce4-panel
            xfce4-terminal
            xfdesktop
            xfwm4
            xfce4-settings
            xfconf
            dbus
            coreutils
            procps
            gnugrep
            xkbcomp
            xrdb
          ];
          text = builtins.readFile ./start-desktop.sh;
        };

        # Docker image built with Nix
        dockerImage = pkgs.dockerTools.buildLayeredImage {
          name = "nix-xfce-kasm";
          tag = "latest";
          maxLayers = 120;

          contents = with pkgs; [
            # Base system
            bashInteractive
            coreutils
            procps
            gnugrep
            gnused
            findutils
            which

            # KasmVNC
            kasmvnc

            # XFCE core (minimal)
            xfce4-session
            xfce4-panel
            xfce4-terminal
            xfdesktop
            xfwm4
            xfce4-settings
            xfconf
            thunar

            # X11 essentials
            xkbcomp
            xkeyboard_config
            xrdb

            # Desktop essentials
            dbus
            shared-mime-info
            hicolor-icon-theme
            adwaita-icon-theme
            gnome-themes-extra
            dejavu_fonts
            liberation_ttf

            # Applications
            qgis

            # The startup script
            startupScript
          ];

          fakeRootCommands = ''
            mkdir -p ./tmp ./run ./var/run ./var/log
            mkdir -p ./etc ./root
            mkdir -p ./home/user/.vnc
            mkdir -p ./home/user/.config/xfce4/panel
            mkdir -p ./etc/xdg/xfce4/xfconf/xfce-perchannel-xml

            # Custom panel config (single top panel with working launchers)
            cp ${./config/xfce4/panel/default.xml} ./home/user/.config/xfce4/panel/default.xml

            # Wallpaper config (system-wide default so xfconfd picks it up)
            cp ${./config/xfce4/xfconf/xfce-perchannel-xml/xfce4-desktop.xml} ./etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfce4-desktop.xml

            # Deploy wallpaper
            mkdir -p ./usr/share
            cp ${./resources/wallpaper.png} ./usr/share/wallpaper.png
            chmod 1777 ./tmp

            # Create /usr/bin symlinks for hardcoded paths
            mkdir -p ./usr/bin
            ln -s ${pkgs.xkbcomp}/bin/xkbcomp ./usr/bin/xkbcomp
            ln -s ${pkgs.coreutils}/bin/env ./usr/bin/env
            ln -s ${pkgs.dbus}/bin/dbus-daemon ./usr/bin/dbus-daemon
            ln -s ${pkgs.dbus}/bin/dbus-launch ./usr/bin/dbus-launch

            # dbus needs a proper machine-id and config
            mkdir -p ./var/lib/dbus ./etc/dbus-1
            echo "00000000000000000000000000000000" > ./etc/machine-id
            cp ./etc/machine-id ./var/lib/dbus/machine-id
            # Fix dbus circular include: the nixpkgs session.conf includes itself
            mkdir -p ./etc/dbus-1
            rm -f ./etc/dbus-1/session.conf
            cat > ./etc/dbus-1/session.conf <<DBUSEOF
<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig>
  <type>session</type>
  <keep_umask/>
  <listen>unix:tmpdir=/tmp</listen>
  <auth>EXTERNAL</auth>
  <standard_session_servicedirs />
  <policy context="default">
    <allow send_destination="*" eavesdrop="true"/>
    <allow eavesdrop="true"/>
    <allow own="*"/>
  </policy>
  <limit name="max_incoming_bytes">1000000000</limit>
  <limit name="max_outgoing_bytes">1000000000</limit>
  <limit name="max_message_size">1000000000</limit>
  <limit name="max_completed_connections">100000</limit>
  <limit name="max_incomplete_connections">10000</limit>
</busconfig>
DBUSEOF

            cat > ./etc/passwd <<EOF
root:x:0:0:root:/root:/bin/bash
user:x:1000:1000:user:/home/user:/bin/bash
nobody:x:65534:65534:Nobody:/:/noshell
EOF

            cat > ./etc/group <<EOF
root:x:0:
user:x:1000:
nogroup:x:65534:
EOF

            cat > ./etc/shadow <<EOF
root:!:1::::::
user:!:1::::::
EOF

            cat > ./etc/nsswitch.conf <<EOF
passwd: files
group: files
shadow: files
hosts: files dns
EOF

            chown -R 1000:1000 ./home/user
          '';

          config = {
            Labels = {
              "org.opencontainers.image.title" = "QGIS Desktop";
              "org.opencontainers.image.description" = "QGIS Desktop in a Docker container with KasmVNC web-based access, built with Nix";
              "org.opencontainers.image.url" = "https://github.com/kartoza/qgis-desktop-docker";
              "org.opencontainers.image.source" = "https://github.com/kartoza/qgis-desktop-docker";
              "org.opencontainers.image.documentation" = "https://github.com/kartoza/qgis-desktop-docker#readme";
              "org.opencontainers.image.vendor" = "Kartoza";
              "org.opencontainers.image.licenses" = "GPL-2.0";
              "org.opencontainers.image.authors" = "Tim Sutton <tim@kartoza.com>";
            };
            Env = [
              "HOME=/home/user"
              "USER=user"
              "DISPLAY=:1"
              "VNC_PORT=8443"
              "VNC_RESOLUTION=1280x720"
              "VNC_COL_DEPTH=24"
              "XDG_RUNTIME_DIR=/tmp/runtime-user"
              "FONTCONFIG_FILE=${pkgs.fontconfig.out}/etc/fonts/fonts.conf"
              "XDG_DATA_DIRS=${pkgs.lib.concatStringsSep ":" [
                "${pkgs.shared-mime-info}/share"
                "${pkgs.hicolor-icon-theme}/share"
                "${pkgs.adwaita-icon-theme}/share"
                "${pkgs.gnome-themes-extra}/share"
                "${pkgs.xfdesktop}/share"
                "${pkgs.xfce4-session}/share"
                "${pkgs.xfce4-panel}/share"
                "${pkgs.xfce4-settings}/share"
                "${pkgs.xfconf}/share"
                "${pkgs.thunar}/share"
                "${pkgs.qgis}/share"
              ]}"
              "XDG_CONFIG_DIRS=${pkgs.lib.concatStringsSep ":" [
                "${pkgs.xfce4-session}/etc/xdg"
                "${pkgs.xfce4-panel}/etc/xdg"
                "${pkgs.xfce4-settings}/etc/xdg"
                "${pkgs.xfdesktop}/etc/xdg"
                "${pkgs.xfwm4}/etc/xdg"
                "${pkgs.xfce4-terminal}/etc/xdg"
                "${pkgs.thunar}/etc/xdg"
                "/etc/xdg"
              ]}"
              "XKB_DEFAULT_RULES=evdev"
              "XKB_DEFAULT_MODEL=pc105"
              "XKB_DEFAULT_LAYOUT=us"
              "XKB_BASE_DIR=${pkgs.xkeyboard_config}/share/X11/xkb"
              "XKB_RULES_DIR=${pkgs.xkeyboard_config}/share/X11/xkb/rules"
            ];
            ExposedPorts = {
              "8443/tcp" = {};
            };
            Cmd = [ "${startupScript}/bin/start-desktop" ];
            WorkingDir = "/home/user";
            User = "user";
          };
        };

        mkApp = name: script: {
          type = "app";
          program = "${pkgs.writeShellApplication {
            inherit name;
            runtimeInputs = with pkgs; [ docker jq coreutils ];
            text = script;
          }}/bin/${name}";
        };

      in {
        packages = {
          kasmvnc = kasmvnc;
          dockerImage = dockerImage;
          docker = dockerImage;
          default = dockerImage;
        };

        apps = {
          build-docker = mkApp "build-docker" ''
            echo "Building Docker image with Nix..."
            nix build .#docker -o result
            OUT=$(nix build .#docker --print-out-paths)
            nix store cat "$OUT" | docker load
            echo ""
            echo "Image loaded: nix-xfce-kasm:latest"
            docker image inspect nix-xfce-kasm:latest --format \
              "Size: {{.Size}} bytes ($(docker image inspect nix-xfce-kasm:latest --format '{{.Size}}' | numfmt --to=iec-i --suffix=B))"
          '';

          run = mkApp "run" ''
            echo "Starting QGIS Desktop on http://localhost:8443 ..."
            docker run --rm -p 8443:8443 --name qgis-desktop nix-xfce-kasm:latest
          '';

          default = mkApp "help" ''
            echo "QGIS Desktop Docker - Available commands:"
            echo ""
            echo "  nix run .#build-docker  Build the Docker image"
            echo "  nix run .#run           Run the container"
            echo "  nix run .#summary       Generate build summary"
            echo "  make build-docker       Build via Make"
            echo "  make run                Run via Make"
          '';

          summary = mkApp "summary" ''
            bash build-summary.sh nix-xfce-kasm:latest build-summary.md
          '';
        };

        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            docker
            python3
            syft
            grype
            jq
          ];
          shellHook = ''
            echo "QGIS Desktop Docker - development shell"
            echo ""
            echo "  nix run .#build-docker  Build the Docker image"
            echo "  nix run .#run           Run the container"
            echo "  make build-docker       Build via Make"
            echo "  make run                Run via Make"
          '';
        };
      }
    );
}

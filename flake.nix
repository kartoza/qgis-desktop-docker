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

        # --- Giswater support -------------------------------------------
        # The two US EPA hydraulic solvers the Giswater plugin drives: EPANET
        # for pressurised water supply ('ws') projects, SWMM for urban drainage
        # ('ud'). Neither is in nixpkgs, so both are built from upstream source
        # here — see nix/README.md for the packaging notes and the SWMM patch.
        epanet = pkgs.callPackage ./nix/epanet.nix { };
        swmm = pkgs.callPackage ./nix/swmm.nix { };

        # Python packages Giswater imports from inside QGIS's own interpreter.
        # Deliberately minimal: everything here is a genuine runtime import of
        # the plugin, and anything Hydra has not built would land as a local
        # source build in every image build.
        giswaterPythonPackages = ps: [
          ps.jsonschema
          ps.debugpy
          ps.psutil
          ps.pyproj
          ps.matplotlib
        ];

        epaSolvers = [ epanet swmm ];
        epaPath = pkgs.lib.makeBinPath epaSolvers;
        epaLibPath = pkgs.lib.makeLibraryPath epaSolvers;

        # Giswater's go2epa tool shells out to the solvers, and its
        # hydraulic_engine backend dlopen()s the toolkit libraries. Wrapping
        # QGIS puts both within reach of anything QGIS spawns, without putting
        # them on every process's path.
        withEpaSolvers = qgisPackage:
          pkgs.symlinkJoin {
            name = "${qgisPackage.pname or "qgis"}-with-epa-solvers";
            paths = [ qgisPackage ];
            nativeBuildInputs = [ pkgs.makeWrapper ];
            postBuild = ''
              for exe in "$out"/bin/*; do
                # Skip anything that is not runnable — wrapProgram refuses
                # those, and a stray data file in bin/ should not fail a build.
                [ -f "$exe" ] && [ -x "$exe" ] || continue
                wrapProgram "$exe" \
                  --prefix PATH : "${epaPath}" \
                  --prefix LD_LIBRARY_PATH : "${epaLibPath}" \
                  --set-default GISWATER_EPANET_EXE "${epanet}/bin/runepanet" \
                  --set-default GISWATER_SWMM_EXE "${swmm}/bin/runswmm"
              done
            '';
            inherit (qgisPackage) meta;
          };

        # --- QGIS channels ----------------------------------------------
        # Two images are built from the same source: one on the long-term
        # release, one on the current release.
        #
        #   ltr    (default) — what you put in front of users. QGIS's LTR line
        #                      only takes bug fixes, so a project that opens
        #                      today opens the same way next month.
        #   latest           — the current release, for testing your projects,
        #                      plugins and data against what will become the
        #                      next LTR, before it becomes the next LTR.
        #
        # Same flake, same auth modes, same lockdown, same Giswater wiring —
        # the QGIS package is the only difference.
        withGiswater = qgisPackage: withEpaSolvers (qgisPackage.override {
          extraPythonPackages = giswaterPythonPackages;
        });

        qgisChannels = {
          ltr = {
            package = withGiswater pkgs.qgis-ltr;
            version = pkgs.qgis-ltr.version;
            tag = "qgis-ltr";
            description = "long-term release";
          };
          latest = {
            package = withGiswater pkgs.qgis;
            version = pkgs.qgis.version;
            tag = "qgis-latest";
            description = "current release";
          };
        };

        # The channel the plain `nix build .#docker` and every `nix run .#run-*`
        # target use.
        defaultChannel = qgisChannels.ltr;

        # scripts/epa.sh in the store, so the desktop can wire the plugin up
        # without a checkout being present. Giswater executes the solvers from
        # fixed paths inside its own plugin directory, where it ships Windows
        # binaries — repointing those is what makes go2epa work at all.
        epaTool = pkgs.runCommand "giswater-epa-tool" {
          nativeBuildInputs = [ pkgs.makeWrapper ];
        } ''
          install -Dm755 ${./scripts/epa.sh} "$out/bin/epa"
          # Explicit rather than relying on the fixup hook: wrapProgram hides
          # the real script as .epa-wrapped, and an unpatched
          # `/usr/bin/env bash` shebang would then fail.
          patchShebangs "$out/bin/epa"
          wrapProgram "$out/bin/epa" \
            --set-default GISWATER_EPANET_EXE "${epanet}/bin/runepanet" \
            --set-default GISWATER_SWMM_EXE "${swmm}/bin/runswmm" \
            --set-default GISWATER_SWMM_SMOKE_MODEL "${./nix/swmm-smoke.inp}" \
            --prefix PATH : "${pkgs.lib.makeBinPath (with pkgs; [
              coreutils
              findutils
              gnused
              gnugrep
            ])}"
        '';

        # --- Autostart (QGIS_DESKTOP_AUTOSTART_QGIS=1) --------------------
        # Runs as the desktop user from both session paths; writes an XDG
        # autostart entry that XFCE picks up.
        autostartScript = pkgs.writeShellApplication {
          name = "qgis-desktop-autostart";
          runtimeInputs = with pkgs; [ coreutils gnugrep ];
          text = builtins.readFile ./config/autostart/autostart.sh;
        };

        # --- Home persistence (QGIS_DESKTOP_PERSIST=1) --------------------
        # Restore/save the home directory against object storage. Runs as root
        # so the credentials stay unreadable by the desktop user, and so the
        # restore can write into a home owned by uid 1000.
        persistScript = pkgs.writeShellApplication {
          name = "qgis-desktop-persist";
          runtimeInputs = with pkgs; [
            rclone
            coreutils # timeout, numfmt, date, chown, id, cp
            gnused
            hostname
            util-linux # setpriv, to deliver files as the desktop user
            bash # the shell setpriv execs for that delivery
          ];
          text = builtins.readFile ./config/persist/persist.sh;
        };

        # --- Terminal lockdown (QGIS_DESKTOP_ALLOW_TERMINAL=0) ------------------
        disableTerminalScript = pkgs.writeShellApplication {
          name = "qgis-desktop-disable-terminal";
          runtimeInputs = with pkgs; [ coreutils gnused gnugrep ];
          text = builtins.readFile ./config/lockdown/disable-terminal.sh;
        };

        # --- OIDC (QGIS_DESKTOP_AUTH_MODE=oidc) ---------------------------------
        # Secret materialisation, run as root by the entrypoint.
        oidcConfigScript = pkgs.writeShellApplication {
          name = "qgis-desktop-oidc-config";
          runtimeInputs = with pkgs; [ coreutils gnused ];
          text = builtins.readFile ./config/oidc/oidc-config.sh;
        };

        # The proxy itself, run unprivileged.
        oidcProxyScript = pkgs.writeShellApplication {
          name = "qgis-desktop-oidc-proxy";
          runtimeInputs = with pkgs; [ oauth2-proxy coreutils ];
          text = builtins.readFile ./config/oidc/oidc-proxy.sh;
        };

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
          ] ++ [
            epaTool # `epa install` wires Giswater up to the native solvers
            autostartScript # honours QGIS_DESKTOP_AUTOSTART_QGIS
          ];
          text = builtins.readFile ./start-desktop.sh;
        };

        # pam_exec verifier for greeter mode. Wrapped as a writeShellApplication
        # so bash and openssl are on PATH regardless of pam_exec's env
        # stripping.
        checkPasswordScript = pkgs.writeShellApplication {
          name = "check-password";
          runtimeInputs = with pkgs; [ openssl gnugrep coreutils gawk ];
          text = builtins.readFile ./config/lightdm/check-password.sh;
        };

        # XDG_DATA_DIRS / XDG_CONFIG_DIRS for the XFCE session. Same set as
        # the image-level env vars in dockerImage.config.Env — repeated here
        # because lightdm strips those before spawning the user session.
        # Parameterised on the QGIS package so each channel's image points at
        # its own QGIS share directory.
        mkXfceXdgDataDirs = qgisPackage: pkgs.lib.concatStringsSep ":" [
          "${pkgs.shared-mime-info}/share"
          "${pkgs.hicolor-icon-theme}/share"
          "${pkgs.adwaita-icon-theme}/share"
          "${pkgs.xfdesktop}/share"
          "${pkgs.xfce4-session}/share"
          "${pkgs.xfce4-panel}/share"
          "${pkgs.xfce4-settings}/share"
          "${pkgs.xfconf}/share"
          "${pkgs.thunar}/share"
          "${qgisPackage}/share"
        ];
        xfceXdgConfigDirs = pkgs.lib.concatStringsSep ":" [
          "${pkgs.xfce4-session}/etc/xdg"
          "${pkgs.xfce4-panel}/etc/xdg"
          "${pkgs.xfce4-settings}/etc/xdg"
          "${pkgs.xfdesktop}/etc/xdg"
          "${pkgs.xfwm4}/etc/xdg"
          "${pkgs.xfce4-terminal}/etc/xdg"
          "${pkgs.thunar}/etc/xdg"
          "/etc/xdg"
        ];
        xfcePath = pkgs.lib.makeBinPath (with pkgs; [
          dbus
          xfce4-session
          xfce4-panel
          xfce4-terminal
          xfdesktop
          xfwm4
          xfce4-settings
          xfconf
          thunar
          coreutils
        ]);

        # LightDM session-wrapper. Runs as the authenticated user with a
        # stripped env — bake all the paths XFCE needs directly in.
        mkXsessionScript = qgisPackage: pkgs.writeShellScript "Xsession" ''
          #!${pkgs.bash}/bin/bash
          set -uo pipefail

          HOME="''${HOME:-/home/''${USER:-user}}"
          export HOME
          mkdir -p "$HOME/.config/xfce4/xfconf/xfce-perchannel-xml"
          mkdir -p "$HOME/.config/xfce4/panel"

          # Seed the wallpaper channel config from the system-wide default
          # baked into the image. xfconfd doesn't merge /etc/xdg into the
          # user store on first run, so without this the desktop comes up
          # with a black backdrop.
          if [ ! -f "$HOME/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-desktop.xml" ]; then
            cp /etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfce4-desktop.xml \
               "$HOME/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-desktop.xml" \
               2>/dev/null || true
          fi
          # Same for the panel config — otherwise XFCE builds an empty
          # panel on first launch.
          if [ ! -f "$HOME/.config/xfce4/panel/default.xml" ]; then
            cp /home/user/.config/xfce4/panel/default.xml \
               "$HOME/.config/xfce4/panel/default.xml" \
               2>/dev/null || true
          fi

          # Env vars lightdm strips that XFCE needs.
          export FONTCONFIG_FILE="${desktopFontsConf}"
          export XDG_DATA_DIRS="${mkXfceXdgDataDirs qgisPackage}"
          export XDG_CONFIG_DIRS="${xfceXdgConfigDirs}"
          export XKB_BASE_DIR="${pkgs.xkeyboard_config}/share/X11/xkb"
          export XKB_DEFAULT_RULES=evdev
          export XKB_DEFAULT_MODEL=pc105
          export XKB_DEFAULT_LAYOUT=us
          export XDG_RUNTIME_DIR="/tmp/runtime-''${USER:-user}"
          mkdir -p "$XDG_RUNTIME_DIR"
          chmod 700 "$XDG_RUNTIME_DIR" || true

          export PATH="${xfcePath}:$PATH"

          # Point the Giswater plugin at the native EPA solvers for THIS user's
          # profile. Greeter mode gives every user their own home directory, so
          # the wiring has to happen per session rather than once at boot.
          # No-op when the plugin is not installed.
          ${epaTool}/bin/epa install \
            || echo "WARN: could not wire up the EPA solvers — run 'epa status' for detail"

          # Same reasoning for the autostart entry: it lives in this user's home.
          ${autostartScript}/bin/qgis-desktop-autostart || true

          # Background XFCE so we can force the wallpaper via xfconf-query
          # once xfconfd has come up (mirrors start-desktop.sh's post-start
          # nudge for the different monitor property paths KasmVNC uses).
          ${pkgs.dbus}/bin/dbus-run-session -- ${pkgs.xfce4-session}/bin/startxfce4 &
          XFCE_PID=$!
          (
            sleep 3
            for monitor in monitorscreen monitor0 monitorVNC-0; do
              ${pkgs.xfconf}/bin/xfconf-query -c xfce4-desktop \
                -p "/backdrop/screen0/$monitor/workspace0/last-image" \
                -s /usr/share/wallpaper.png --create -t string 2>/dev/null || true
              ${pkgs.xfconf}/bin/xfconf-query -c xfce4-desktop \
                -p "/backdrop/screen0/$monitor/workspace0/image-style" \
                -s 5 --create -t int 2>/dev/null || true
            done
          ) &
          wait "$XFCE_PID"
        '';

        # Root entrypoint: sets up nftables egress filter, drops privileges,
        # then execs the desktop startup script. In QGIS_DESKTOP_AUTH_MODE=greeter it
        # instead materialises Linux user accounts and execs lightdm as root.
        entrypointScript = pkgs.writeShellApplication {
          name = "qgis-entrypoint";
          runtimeInputs = with pkgs; [
            nftables
            util-linux    # setpriv
            iproute2      # occasionally handy for debugging
            coreutils
            gawk
            gnugrep
            getent        # resolves allowlist hostnames; NOT part of glibc.bin
            glibc.bin     # ldd/ldconfig and friends
            shadow        # chpasswd (kept for later reuse; runtime uses openssl+sed)
            openssl       # openssl passwd -6 to hash user passwords (greeter mode)
            gnused        # sed -i to edit /etc/shadow in place (greeter mode)
            lightdm       # exec'd in greeter mode
            dbus          # dbus-daemon --system for greeter mode
            procps        # pgrep, guard against duplicate dbus
            kasmvnc       # Xkasmvnc on PATH so the lightdm xserver wrapper finds it
            xkeyboard_config # XKB_BASE_DIR sanity in greeter mode
            startupScript # so `start-desktop` is on PATH for setpriv --exec
          ] ++ [
            oidcConfigScript      # qgis-desktop-oidc-config (root: validates + writes secrets)
            oidcProxyScript       # qgis-desktop-oidc-proxy  (uid 1000: runs oauth2-proxy)
            disableTerminalScript # qgis-desktop-disable-terminal (root: QGIS_DESKTOP_ALLOW_TERMINAL=0)
            persistScript         # qgis-desktop-persist (root: home restore/save)
          ];
          text = builtins.readFile ./entrypoint.sh;
        };

        # Docker image built with Nix, once per QGIS channel. `channel` is one
        # of the qgisChannels attrsets above; everything else about the two
        # images is identical.
        mkDockerImage = channel: pkgs.dockerTools.buildLayeredImage {
          name = "nix-xfce-kasm";
          tag = channel.tag;
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
            dejavu_fonts
            liberation_ttf
            open-sans

            # Applications
            channel.package

            # Giswater's EPA hydraulic solvers, on PATH under both their
            # upstream names (runepanet / runswmm) and the aliases Giswater
            # and the wider tooling use (epanet, epanet2, swmm5).
            epanet
            swmm
            epaTool

            # Egress lockdown deps
            nftables
            util-linux    # setpriv
            iproute2
            # Hostname resolution for the egress allowlist. `getent` is its own
            # package in nixpkgs — it is NOT in glibc.bin, and without it every
            # hostname in QGIS_DESKTOP_EGRESS_ALLOW silently fails to resolve.
            getent
            glibc.bin

            # TLS trust store. Needed by oauth2-proxy to verify the identity
            # provider in QGIS_DESKTOP_AUTH_MODE=oidc, and by QGIS for any HTTPS
            # service — the image previously shipped no CA bundle at all.
            cacert

            # OIDC auth mode (QGIS_DESKTOP_AUTH_MODE=oidc). The oauth2-proxy binary
            # itself arrives through qgis-desktop-oidc-proxy's wrapper.
            oidcConfigScript
            oidcProxyScript

            # Terminal lockdown (QGIS_DESKTOP_ALLOW_TERMINAL=0).
            disableTerminalScript

            # Autostart QGIS with the session (QGIS_DESKTOP_AUTOSTART_QGIS=1).
            autostartScript

            # Home persistence (QGIS_DESKTOP_PERSIST=1). rclone arrives through
            # the wrapper; it is not on the desktop user's PATH.
            persistScript

            # Greeter mode (QGIS_DESKTOP_AUTH_MODE=greeter): LightDM + GTK greeter.
            # Kept out of the runtime path when mode != greeter, so basic /
            # none users don't pay a startup cost — but they do pay the
            # image-size cost. Roughly +40 MB uncompressed.
            lightdm
            lightdm-gtk-greeter
            linux-pam
            shadow        # useradd / chpasswd for user materialisation
            bash          # /etc/lightdm/Xsession and xserver-wrapper shebangs

            # Scripts
            startupScript
            entrypointScript
          ];

          fakeRootCommands = ''
            mkdir -p ./tmp ./run ./var/run ./var/log
            mkdir -p ./etc ./root
            # Runtime state the entrypoint writes: the listener override that
            # tells both KasmVNC launchers to move behind the OIDC proxy.
            mkdir -p ./run/qgis-desktop
            # Default mount point for a user:password file
            # (QGIS_DESKTOP_USERS_FILE).
            mkdir -p ./etc/qgis-desktop
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

            # nixpkgs' lightdm build defaults to spawning "Xephyr" (or "X" or
            # "Xorg") as its X server when there's no VT. Containers have no
            # VT, so lightdm's xserver-command config from [Seat:*] is
            # bypassed for the built-in "test" X path. Point all three
            # binary names at our wrapper so the wrapper is invoked no
            # matter which name lightdm chose.
            ln -sfn /etc/lightdm/xkasmvnc-wrapper ./usr/bin/Xephyr
            ln -sfn /etc/lightdm/xkasmvnc-wrapper ./usr/bin/X
            ln -sfn /etc/lightdm/xkasmvnc-wrapper ./usr/bin/Xorg

            # check-password (pam_exec verifier) needs openssl and grep at
            # known paths — pam_exec gives its child a stripped env with
            # only /bin:/usr/bin on PATH.
            ln -sfn ${pkgs.openssl}/bin/openssl ./usr/bin/openssl
            ln -sfn ${pkgs.gnugrep}/bin/grep    ./usr/bin/grep
            ln -sfn ${pkgs.coreutils}/bin/cut   ./usr/bin/cut
            ln -sfn ${pkgs.coreutils}/bin/tr    ./usr/bin/tr
            ln -sfn ${pkgs.gawk}/bin/awk        ./usr/bin/awk

            # TLS trust store at the conventional path. oauth2-proxy honours
            # SSL_CERT_FILE (set in Env below), but plenty of other tooling —
            # curl, python, GDAL — only looks here.
            mkdir -p ./etc/ssl/certs
            ln -sfn ${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt ./etc/ssl/certs/ca-certificates.crt
            ln -sfn ${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt ./etc/ssl/certs/ca-bundle.crt

            # LightDM strips the image env vars (incl. XKB_BASE_DIR) before
            # spawning children. Give the wrapper a fixed fallback path to
            # resolve to xkeyboard-config's xkb data.
            mkdir -p ./usr/share/X11
            ln -sfn ${pkgs.xkeyboard_config}/share/X11/xkb ./usr/share/X11/xkb

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

            # Several nixpkgs packages (shadow, glibc, dbus, lightdm) ship
            # default files under /etc/. They land as read-only symlinks
            # into the store; `cat >` fails with "Permission denied" on
            # them. Unlink first so our writes win.
            rm -f ./etc/passwd ./etc/group ./etc/shadow ./etc/nsswitch.conf ./etc/login.defs

            cat > ./etc/passwd <<EOF
root:x:0:0:root:/root:/bin/bash
user:x:1000:1000:user:/home/user:/bin/bash
lightdm:x:996:996:LightDM:/var/lib/lightdm:/bin/false
nobody:x:65534:65534:Nobody:/:/noshell
EOF

            cat > ./etc/group <<EOF
root:x:0:
user:x:1000:
lightdm:x:996:
nogroup:x:65534:
EOF

            cat > ./etc/shadow <<EOF
root:!:1::::::
user:!:1::::::
lightdm:!:1::::::
EOF

            cat > ./etc/nsswitch.conf <<EOF
passwd: files
group: files
shadow: files
hosts: files dns
EOF

            # --- LightDM (QGIS_DESKTOP_AUTH_MODE=greeter) ---------------------------
            # Config, session wrapper, xserver command, PAM stack, runtime
            # dirs, and a shared session .desktop file. All baked in so the
            # image works in greeter mode with zero mounted config.
            mkdir -p \
              ./etc/lightdm \
              ./etc/pam.d \
              ./lib \
              ./usr/share/xsessions \
              ./var/run/lightdm \
              ./var/log/lightdm \
              ./var/cache/lightdm \
              ./var/lib/lightdm \
              ./var/run/dbus

            # lightdm's nixpkgs derivation ships /etc/lightdm/*.conf as
            # read-only symlinks into the store; plain cp then fails with
            # "Permission denied". Break the symlinks first so our overlay
            # wins.
            rm -f \
              ./etc/lightdm/lightdm.conf \
              ./etc/lightdm/lightdm-gtk-greeter.conf \
              ./etc/lightdm/xkasmvnc-wrapper \
              ./etc/lightdm/Xsession \
              ./usr/share/xsessions/xfce.desktop

            install -Dm 0644 ${./config/lightdm/lightdm-gtk-greeter.conf} ./etc/lightdm/lightdm-gtk-greeter.conf
            install -Dm 0755 ${./config/lightdm/xkasmvnc-wrapper.sh}      ./etc/lightdm/xkasmvnc-wrapper
            ln -sfn ${mkXsessionScript channel.package}                                     ./etc/lightdm/Xsession
            ln -sfn ${checkPasswordScript}/bin/check-password             ./etc/lightdm/check-password
            install -Dm 0644 ${./config/lightdm/xfce.desktop}             ./usr/share/xsessions/xfce.desktop

            # LightDM.conf is templated at nix-build time so we can bake in
            # the nix-store path for greeters-directory (lightdm-gtk-greeter
            # ships its .desktop inside its own store share/xgreeters, and
            # lightdm doesn't scan /usr/share/xgreeters on this build).
            cat > ./etc/lightdm/lightdm.conf <<LIGHTDMCONF
[LightDM]
run-directory=/var/run/lightdm
log-directory=/var/log/lightdm
cache-directory=/var/cache/lightdm
greeters-directory=${pkgs.lightdm-gtk-greeter}/share/xgreeters
sessions-directory=/usr/share/xsessions
start-default-seat=true

[Seat:*]
xserver-command=/etc/lightdm/xkasmvnc-wrapper
xserver-share=true
greeter-session=lightdm-gtk-greeter
greeter-hide-users=false
greeter-show-manual-login=true
greeter-allow-guest=false
allow-guest=false
session-wrapper=/etc/lightdm/Xsession
user-session=xfce
autologin-user=
autologin-user-timeout=0
LIGHTDMCONF

            # PAM needs to find pam_unix.so and friends. NixOS ships them in
            # ${pkgs.linux-pam}/lib/security; on non-NixOS PAM's default
            # search path is /lib/security. Symlink so a bare "pam_unix.so"
            # in /etc/pam.d/* resolves. -f in case anything else already
            # created the symlink.
            ln -sfn ${pkgs.linux-pam}/lib/security ./lib/security

            # Minimal PAM stacks. No pam_systemd (no systemd inside the
            # container), no pam_ck_connector (no ConsoleKit). pam_env picks
            # up locale settings. pam_unix hits /etc/shadow directly, which
            # is what chpasswd writes to in entrypoint.sh.
            # PAM stacks: lightdm may have shipped defaults from its
            # nixpkgs derivation; unlink first so our overlay wins.
            rm -f ./etc/pam.d/lightdm ./etc/pam.d/lightdm-greeter ./etc/pam.d/lightdm-autologin
            # Auth via pam_exec + our own /etc/lightdm/check-password verifier.
            # pam_unix is unusable here (delegates to non-SUID unix_chkpwd and
            # always returns PAM_AUTHINFO_UNAVAIL). pam_permit follows pam_exec
            # on the auth stack so pam_setcred (which lightdm calls before
            # launching the session) has a module returning PAM_SUCCESS —
            # pam_exec only implements sm_authenticate, not sm_setcred.
            # Account / session default to permit so the greeter can start
            # XFCE without extra setup.
            cat > ./etc/pam.d/lightdm <<PAMEOF
auth       required   pam_exec.so quiet expose_authtok /etc/lightdm/check-password
auth       required   pam_permit.so
account    required   pam_permit.so
password   required   pam_permit.so
session    required   pam_permit.so
session    optional   pam_env.so
PAMEOF

            cat > ./etc/pam.d/lightdm-greeter <<PAMEOF
auth       required   pam_permit.so
account    required   pam_permit.so
password   required   pam_deny.so
session    required   pam_unix.so
session    optional   pam_env.so
PAMEOF

            # A tiny /etc/login.defs so shadow's chpasswd doesn't warn about
            # missing PASS_MAX_DAYS etc. Sensible defaults; not consulted at
            # login time (PAM handles that).
            cat > ./etc/login.defs <<'LOGINDEFS'
ENCRYPT_METHOD  YESCRYPT
UID_MIN         1000
UID_MAX         60000
GID_MIN         1000
GID_MAX         60000
UMASK           022
LOGINDEFS

            # dbus system bus config. The nixpkgs default lives inside the
            # store and pulls in policy fragments we don't ship; write a
            # minimal permissive one that's fine for a single-container use.
            rm -f ./etc/dbus-1/system.conf
            cat > ./etc/dbus-1/system.conf <<DBUSEOF
<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig>
  <type>system</type>
  <listen>unix:path=/var/run/dbus/system_bus_socket</listen>
  <pidfile>/var/run/dbus/pid</pidfile>
  <auth>EXTERNAL</auth>
  <policy context="default">
    <allow send_destination="*" eavesdrop="true"/>
    <allow eavesdrop="true"/>
    <allow own="*"/>
  </policy>
</busconfig>
DBUSEOF

            chown -R 1000:1000 ./home/user
            chown -R 996:996 ./var/lib/lightdm ./var/cache/lightdm ./var/log/lightdm ./var/run/lightdm
          '';

          config = {
            Labels = {
              "org.opencontainers.image.title" = "QGIS Desktop";
              "org.opencontainers.image.description" = "QGIS ${channel.version} (${channel.description}) in a Docker container with KasmVNC web-based access, built with Nix";
              # Which QGIS is inside, without having to start the container.
              "org.opencontainers.image.version" = channel.version;
              "com.kartoza.qgis.channel" = channel.tag;
              "com.kartoza.qgis.version" = channel.version;
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
              "VNC_USER=user"
              "VNC_PW=password"
              "DISPLAY=:1"
              "VNC_PORT=8443"
              "VNC_RESOLUTION=1280x720"
              "VNC_COL_DEPTH=24"
              # Which QGIS this image was built from. Read-only: changing it
              # does not change the QGIS inside — pick the image tag instead.
              "QGIS_DESKTOP_QGIS_CHANNEL=${channel.tag}"
              "QGIS_DESKTOP_QGIS_VERSION=${channel.version}"
              # Auth mode: basic (default) | none | greeter | oidc.
              # See docs/configuration/authentication.md.
              "QGIS_DESKTOP_AUTH_MODE=basic"
              # Terminal access. Set to 0 to remove the terminal emulators and
              # command-runner dialogs from the desktop entirely.
              "QGIS_DESKTOP_ALLOW_TERMINAL=1"
              # Start QGIS automatically with the desktop session. Off by
              # default: the desktop is useful without it, and QGIS takes a
              # while to load.
              "QGIS_DESKTOP_AUTOSTART_QGIS=0"
              # Home-directory persistence against object storage. Off unless
              # configured; see docs/configuration/persistence.md.
              "QGIS_DESKTOP_PERSIST=0"
              "QGIS_DESKTOP_PERSIST_INTERVAL=300"
              # Where the desktop listens when the OIDC proxy is in front of
              # it. Only consulted in QGIS_DESKTOP_AUTH_MODE=oidc.
              "QGIS_DESKTOP_OIDC_UPSTREAM_PORT=6901"
              # Egress lockdown defaults ON. Requires --cap-add=NET_ADMIN
              # on `docker run`. Set to 0 to disable (dev only).
              "QGIS_DESKTOP_EGRESS_LOCKDOWN=1"
              "QGIS_DESKTOP_EGRESS_ALLOW="
              "XDG_RUNTIME_DIR=/tmp/runtime-user"
              "FONTCONFIG_FILE=${desktopFontsConf}"
              "XDG_DATA_DIRS=${pkgs.lib.concatStringsSep ":" [
                "${pkgs.shared-mime-info}/share"
                "${pkgs.hicolor-icon-theme}/share"
                "${pkgs.adwaita-icon-theme}/share"
                "${pkgs.xfdesktop}/share"
                "${pkgs.xfce4-session}/share"
                "${pkgs.xfce4-panel}/share"
                "${pkgs.xfce4-settings}/share"
                "${pkgs.xfconf}/share"
                "${pkgs.thunar}/share"
                "${channel.package}/share"
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
              # TLS trust store for anything that reads the environment rather
              # than /etc/ssl/certs (oauth2-proxy, python, requests).
              "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
              "NIX_SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
              # Giswater reads these to locate the EPA solvers directly, for the
              # code paths that do not go through the QGIS wrapper.
              "GISWATER_EPANET_EXE=${epanet}/bin/runepanet"
              "GISWATER_SWMM_EXE=${swmm}/bin/runswmm"
              "GISWATER_SWMM_SMOKE_MODEL=${./nix/swmm-smoke.inp}"
            ];
            ExposedPorts = {
              "8443/tcp" = {};
            };
            # Root entrypoint sets up the nftables egress filter, then drops
            # to UID 1000 via setpriv before exec-ing the desktop.
            Cmd = [ "${entrypointScript}/bin/qgis-entrypoint" ];
            WorkingDir = "/home/user";
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

        # Compose file for the "analyst locked-down" scenario. Pinned into the
        # nix store so `nix run .#run-analyst-scenario` works from any PWD.
        analystComposeFile = ./examples/analyst-locked-down/docker-compose.yml;

        # Self-contained Keycloak + desktop demo for QGIS_DESKTOP_AUTH_MODE=oidc.
        keycloakComposeDir = ./examples/keycloak-oidc;

        # Python environment with mkdocs + Material + IM's plugin set.
        mkdocsPython = pkgs.python3.withPackages (ps: with ps; [
          mkdocs
          mkdocs-material
          mkdocs-glightbox
          mkdocs-git-revision-date-localized-plugin
          pymdown-extensions
        ]);

        # TeX Live for the PDF builder. scheme-medium gives us pandoc's
        # writer requirements + fontspec etc.; the extras are what our
        # preamble/cover pulls in on top of that. Kept as a `combine` (not
        # scheme-full) so the closure stays at ~500 MB.
        pdfLatex = pkgs.texlive.combine {
          inherit (pkgs.texlive)
            scheme-medium
            # preamble.tex
            titlesec sectsty fancyhdr fvextra soul booktabs enumitem
            xcolor pgf fontspec unicode-math selnolig
            # pandoc's default LaTeX writer requirements
            upquote microtype parskip xurl bookmark hyperref
            xkeyval etoolbox pdftexcmds infwarerr kvoptions ltxcmds
            fontawesome5 sourcecodepro sourcesanspro sourceserifpro
            # Kartoza brand-pack body font (Lato) + its transitive deps.
            lato inconsolata fontaxes mweights
            ;
        };

        # Fontconfig needs a config file + font directories at runtime so
        # lualatex can resolve mainfont / sansfont / monofont via fontspec.
        # Lato + JetBrains Mono are the Kartoza brand-pack fonts (v1.0.1);
        # DejaVu + Liberation are fallbacks for glyphs those two don't cover.
        pdfFontsConf = pkgs.makeFontsConf {
          fontDirectories = [
            pkgs.lato
            pkgs.jetbrains-mono
            pkgs.dejavu_fonts
            pkgs.liberation_ttf
          ];
        };

        # Fontconfig for the desktop image. The default nixpkgs
        # /etc/fonts/fonts.conf doesn't scan the specific font packages
        # we bake into the image, so QGIS / XFCE / lightdm-gtk-greeter
        # come up complaining that Open Sans and friends are missing.
        # Building our own config with makeFontsConf points fontconfig
        # at exactly the font packages listed in dockerImage.contents.
        desktopFontsConf = pkgs.makeFontsConf {
          fontDirectories = [
            pkgs.dejavu_fonts
            pkgs.liberation_ttf
            pkgs.open-sans
          ];
        };

        # Helper for docs-related apps that need the mkdocs Python env.
        mkDocsApp = name: extraInputs: script: {
          type = "app";
          program = "${pkgs.writeShellApplication {
            inherit name;
            runtimeInputs = [ mkdocsPython ] ++ extraInputs;
            text = script;
          }}/bin/${name}";
        };

      in {
        packages = {
          kasmvnc = kasmvnc;

          # QGIS LTR is the default everywhere: it is the build you put in
          # front of users.
          dockerImage = mkDockerImage defaultChannel;
          docker = mkDockerImage defaultChannel;
          default = mkDockerImage defaultChannel;
          docker-ltr = mkDockerImage qgisChannels.ltr;

          # The current QGIS release, for testing projects and plugins against
          # what becomes the next LTR.
          docker-qgis-latest = mkDockerImage qgisChannels.latest;

          # Giswater building blocks, exposed so they can be built and smoke
          # tested on their own: `nix build .#epanet` runs a real model through
          # the solver as part of the derivation's install check.
          inherit epanet swmm;
          qgis = defaultChannel.package;
          qgis-ltr = qgisChannels.ltr.package;
          qgis-latest = qgisChannels.latest.package;
          epa = epaTool;
        };

        apps = {
          # QGIS LTR — the default. Also tagged :latest, because that is the
          # image every run-* target and the compose files expect, and because
          # "latest" in Docker means "the one you should be using", not "the
          # newest upstream release".
          build-docker = mkApp "build-docker" ''
            echo "Building Docker image with Nix (QGIS ${qgisChannels.ltr.version}, ${qgisChannels.ltr.description})..."
            nix build .#docker -o result
            OUT=$(nix build .#docker --print-out-paths)
            nix store cat "$OUT" | docker load
            docker tag nix-xfce-kasm:qgis-ltr nix-xfce-kasm:latest
            echo ""
            echo "Image loaded: nix-xfce-kasm:qgis-ltr (also tagged :latest)"
            docker image inspect nix-xfce-kasm:latest --format \
              "Size: {{.Size}} bytes ($(docker image inspect nix-xfce-kasm:latest --format '{{.Size}}' | numfmt --to=iec-i --suffix=B))"
          '';

          # The current QGIS release, side by side with the LTR image. Nothing
          # else differs, so a project that works here and not there is a QGIS
          # regression worth reporting upstream before it reaches an LTR.
          build-docker-qgis-latest = mkApp "build-docker-qgis-latest" ''
            echo "Building Docker image with Nix (QGIS ${qgisChannels.latest.version}, ${qgisChannels.latest.description})..."
            OUT=$(nix build .#docker-qgis-latest --print-out-paths)
            nix store cat "$OUT" | docker load
            echo ""
            echo "Image loaded: nix-xfce-kasm:qgis-latest"
            echo "Run it with:  docker run --rm -p 8443:8443 --cap-add=NET_ADMIN nix-xfce-kasm:qgis-latest"
            docker image inspect nix-xfce-kasm:qgis-latest --format \
              "Size: {{.Size}} bytes ($(docker image inspect nix-xfce-kasm:qgis-latest --format '{{.Size}}' | numfmt --to=iec-i --suffix=B))"
          '';

          # Foreground run with default single-user auth (Ctrl-C to stop).
          # Login as VNC_USER/VNC_PW baked into the image (user / password).
          run = mkApp "run" ''
            docker rm -f qgis-desktop 2>/dev/null || true
            echo "▶ Auth: single-user (default VNC_USER=user, VNC_PW=password)"
            echo "  Open http://localhost:8443 — browser will prompt for creds."
            docker run --rm -p 8443:8443 --cap-add=NET_ADMIN --name qgis-desktop nix-xfce-kasm:latest
          '';

          # Multi-user via inline env var.
          run-multi-user = mkApp "run-multi-user" ''
            docker rm -f qgis-desktop 2>/dev/null || true
            echo "▶ Auth: multi-user via QGIS_DESKTOP_USERS env"
            echo "  Log in as  alice / pw1   or   bob / pw2"
            echo "  Open http://localhost:8443"
            docker run --rm -p 8443:8443 --cap-add=NET_ADMIN --name qgis-desktop \
              -e QGIS_DESKTOP_USERS='alice:pw1,bob:pw2' \
              nix-xfce-kasm:latest
          '';

          # Multi-user via mounted file. Generates a temp file, mounts it 0600,
          # cleans it up on exit.
          run-users-file = mkApp "run-users-file" ''
            USERS_FILE=$(mktemp -t qgis-users.XXXXXX)
            trap 'rm -f "$USERS_FILE"' EXIT
            cat > "$USERS_FILE" <<'USERS'
            # QGIS desktop test users
            alice:hunter2
            bob:correct-horse-battery-staple
            USERS
            chmod 600 "$USERS_FILE"
            docker rm -f qgis-desktop 2>/dev/null || true
            echo "▶ Auth: multi-user via mounted file ($USERS_FILE)"
            echo "  Log in as  alice / hunter2   or   bob / correct-horse-battery-staple"
            echo "  Open http://localhost:8443"
            docker run --rm -p 8443:8443 --cap-add=NET_ADMIN --name qgis-desktop \
              -v "$USERS_FILE:/etc/qgis-desktop/users:ro" \
              nix-xfce-kasm:latest
          '';

          # No auth at all — for local sanity checks only.
          run-no-auth = mkApp "run-no-auth" ''
            docker rm -f qgis-desktop 2>/dev/null || true
            echo "⚠  Auth: DISABLED. Do NOT expose this port to any untrusted network."
            echo "  Open http://localhost:8443 — connects with no prompt."
            docker run --rm -p 8443:8443 --cap-add=NET_ADMIN --name qgis-desktop \
              -e QGIS_DESKTOP_AUTH_MODE=none \
              nix-xfce-kasm:latest
          '';

          # LightDM greeter mode: browser sees an X-server-hosted login form
          # instead of the browser's HTTP BasicAuth dialog. Log out or fail to
          # authenticate and the greeter re-prompts cleanly (no browser cache
          # to fight).
          run-greeter = mkApp "run-greeter" ''
            docker rm -f qgis-desktop 2>/dev/null || true
            echo "▶ Auth mode: greeter (LightDM inside the X session)"
            echo "  Log in as  user / password  (default single-user creds)"
            echo "  For multi-user try:  nix run .#run-greeter-multi"
            echo "  Open http://localhost:8443"
            docker run --rm -p 8443:8443 --cap-add=NET_ADMIN --name qgis-desktop \
              -e QGIS_DESKTOP_AUTH_MODE=greeter \
              nix-xfce-kasm:latest
          '';

          # Greeter mode with two demo users (alice / bob). Each gets a real
          # Linux account and home directory at container start.
          run-greeter-multi = mkApp "run-greeter-multi" ''
            docker rm -f qgis-desktop 2>/dev/null || true
            echo "▶ Auth mode: greeter (multi-user)"
            echo "  Log in as  alice / hunter2   or   bob / correct-horse-battery-staple"
            echo "  Open http://localhost:8443"
            docker run --rm -p 8443:8443 --cap-add=NET_ADMIN --name qgis-desktop \
              -e QGIS_DESKTOP_AUTH_MODE=greeter \
              -e QGIS_DESKTOP_USERS='alice:hunter2,bob:correct-horse-battery-staple' \
              nix-xfce-kasm:latest
          '';

          # OIDC / Keycloak mode against a real identity provider. Everything
          # comes from the caller's environment, so no flake edit is needed:
          #   QGIS_DESKTOP_OIDC_ISSUER_URL=https://sso.example.com/realms/gis \
          #   QGIS_DESKTOP_OIDC_CLIENT_ID=qgis-desktop \
          #   QGIS_DESKTOP_OIDC_CLIENT_SECRET=… \
          #   nix run .#run-oidc
          # For a batteries-included local IdP, use nix run .#run-keycloak-demo.
          run-oidc = mkApp "run-oidc" ''
            : "''${QGIS_DESKTOP_OIDC_ISSUER_URL:?set QGIS_DESKTOP_OIDC_ISSUER_URL (e.g. https://sso.example.com/realms/gis)}"
            : "''${QGIS_DESKTOP_OIDC_CLIENT_ID:?set QGIS_DESKTOP_OIDC_CLIENT_ID}"
            : "''${QGIS_DESKTOP_OIDC_CLIENT_SECRET:?set QGIS_DESKTOP_OIDC_CLIENT_SECRET}"
            REDIRECT_URL="''${QGIS_DESKTOP_OIDC_REDIRECT_URL:-http://localhost:8443/oauth2/callback}"
            docker rm -f qgis-desktop 2>/dev/null || true
            echo "▶ Auth mode: oidc — oauth2-proxy fronting KasmVNC"
            echo "  Issuer:    $QGIS_DESKTOP_OIDC_ISSUER_URL"
            echo "  Client:    $QGIS_DESKTOP_OIDC_CLIENT_ID"
            echo "  Redirect:  $REDIRECT_URL"
            echo "  The identity provider's host is added to the egress allowlist"
            echo "  automatically. Open http://localhost:8443 to be sent to the IdP."
            docker run --rm -p 8443:8443 --cap-add=NET_ADMIN --name qgis-desktop \
              -e QGIS_DESKTOP_AUTH_MODE=oidc \
              -e QGIS_DESKTOP_OIDC_ISSUER_URL \
              -e QGIS_DESKTOP_OIDC_CLIENT_ID \
              -e QGIS_DESKTOP_OIDC_CLIENT_SECRET \
              -e QGIS_DESKTOP_OIDC_REDIRECT_URL="$REDIRECT_URL" \
              -e QGIS_DESKTOP_OIDC_ALLOWED_GROUPS \
              -e QGIS_DESKTOP_OIDC_ALLOWED_ROLES \
              -e QGIS_DESKTOP_OIDC_EMAIL_DOMAINS \
              -e QGIS_DESKTOP_OIDC_INNER_MODE \
              nix-xfce-kasm:latest
          '';

          # End-to-end OIDC demo: a throwaway Keycloak with a pre-imported
          # realm, plus the desktop wired to it. See
          # examples/keycloak-oidc/README.md — the one manual step is a hosts
          # entry, because the browser and the container must resolve the
          # issuer to the same name.
          run-keycloak-demo = mkApp "run-keycloak-demo" ''
            cat <<'BANNER'
            ▶ Keycloak single sign-on demo

              Login:     alice / hunter2   (realm: qgis)
              Admin:     http://localhost:8080  (admin / admin)
              Desktop:   http://keycloak:8443   ← note the host name
              Docs:      examples/keycloak-oidc/README.md

              REQUIRED once, on the host running the browser:
                echo '127.0.0.1 keycloak' | sudo tee -a /etc/hosts

              The browser and the container have to reach the issuer under the
              same name, or the token's `iss` will not match what the proxy
              expects. Press Ctrl-C to stop and remove both containers.
            BANNER

            if ! docker image inspect nix-xfce-kasm:latest >/dev/null 2>&1; then
              echo ""
              echo "ERROR: image 'nix-xfce-kasm:latest' not found."
              echo "       Build it first with:  nix run .#build-docker"
              exit 1
            fi

            cleanup() {
              echo ""
              echo "Stopping demo…"
              docker compose --project-name keycloak-oidc \
                -f ${keycloakComposeDir}/docker-compose.yml down -v --remove-orphans 2>/dev/null || true
            }
            trap cleanup EXIT INT TERM

            docker compose --project-name keycloak-oidc \
              -f ${keycloakComposeDir}/docker-compose.yml up
          '';

          # Locked-down demo: auth on, clipboard blocked, watermarked, DLP info logging.
          # Handy for validating the permission controls end-to-end.
          run-locked-down = mkApp "run-locked-down" ''
            docker rm -f qgis-desktop 2>/dev/null || true
            echo "▶ Locked-down mode:"
            echo "  - Auth ON (log in as user / password)"
            echo "  - Clipboard IN and OUT blocked"
            echo "  - Watermark overlay enabled"
            echo "  - DLP audit log = info"
            echo "  - Terminal access removed"
            echo "  Open http://localhost:8443"
            docker run --rm -p 8443:8443 --cap-add=NET_ADMIN --name qgis-desktop \
              -e KASM_WATERMARK_TEXT='CONFIDENTIAL - ''${USER} %H:%M' \
              -e KASM_DLP_LOG=info \
              -e KASM_CLIPBOARD_DELAY_MS=500 \
              -e QGIS_DESKTOP_ALLOW_TERMINAL=0 \
              nix-xfce-kasm:latest
          '';

          # Demo the egress lockdown with a small allowlist. Try `curl 1.1.1.1`
          # inside the desktop terminal — it should succeed. Try `curl 8.8.8.8`
          # (not on the list) — it should hang/fail.
          run-egress-locked = mkApp "run-egress-locked" ''
            docker rm -f qgis-desktop 2>/dev/null || true
            echo "▶ Egress lockdown demo:"
            echo "  Allowlist: 1.1.1.1 (Cloudflare), example.com"
            echo "  Everything else is blocked. DNS to Docker's resolver stays open."
            echo "  Log in as user / password  ·  Open http://localhost:8443"
            docker run --rm -p 8443:8443 --cap-add=NET_ADMIN --name qgis-desktop \
              -e QGIS_DESKTOP_EGRESS_ALLOW='1.1.1.1,example.com' \
              nix-xfce-kasm:latest
          '';

          # End-to-end scenario: bob / password123, clipboard blocked, egress
          # allowlist = the co-located kartoza/postgis service. Compose file
          # ships from the nix store so this works from any PWD.
          run-analyst-scenario = mkApp "run-analyst-scenario" ''
            cat <<'BANNER'
            ▶ Analyst locked-down scenario

              Login:      bob / password123
              DB:         host=db  user=bob  password=password123  db=gis  port=5432
              Clipboard:  IN and OUT blocked, primary selection blocked
              Watermark:  RESTRICTED — bob HH:MM
              Egress:     only the "db" service is reachable
              Docs:       docs/scenarios/analyst-locked-down.md

              Open http://localhost:8443 after the containers are healthy.
              Press Ctrl-C to stop and remove both containers.
            BANNER

            if ! docker image inspect nix-xfce-kasm:latest >/dev/null 2>&1; then
              echo ""
              echo "ERROR: image 'nix-xfce-kasm:latest' not found."
              echo "       Build it first with:  nix run .#build-docker"
              exit 1
            fi

            cleanup() {
              echo ""
              echo "Stopping scenario…"
              docker compose --project-name analyst-locked-down \
                -f ${analystComposeFile} down -v --remove-orphans 2>/dev/null || true
            }
            trap cleanup EXIT INT TERM

            docker compose --project-name analyst-locked-down \
              -f ${analystComposeFile} up
          '';

          # Full-open dev mode: no auth, no egress lockdown. Diagnostics only.
          run-no-lockdown = mkApp "run-no-lockdown" ''
            docker rm -f qgis-desktop 2>/dev/null || true
            echo "⚠  Dev mode: auth OFF and egress lockdown OFF."
            echo "  Open http://localhost:8443 — connects with no prompt, full network access."
            docker run --rm -p 8443:8443 --cap-add=NET_ADMIN --name qgis-desktop \
              -e QGIS_DESKTOP_AUTH_MODE=none \
              -e QGIS_DESKTOP_EGRESS_LOCKDOWN=0 \
              nix-xfce-kasm:latest
          '';

          # Convenience: hard-stop the running container from another terminal.
          stop = mkApp "stop" ''
            if [ -n "$(docker ps -aq -f name=^qgis-desktop$)" ]; then
              docker rm -f qgis-desktop
              echo "Container 'qgis-desktop' stopped."
            else
              echo "No 'qgis-desktop' container running."
            fi
          '';

          # Convenience: follow logs (useful when a run-* was started detached elsewhere).
          logs = mkApp "logs" ''
            docker logs -f qgis-desktop
          '';

          default = mkApp "help" ''
            cat <<HELP
            QGIS Desktop Docker — available commands

              Build
                nix run .#build-docker      Build the image on QGIS LTR (default, tagged :qgis-ltr + :latest)
                nix run .#build-docker-qgis-latest
                                            Build the image on the current QGIS release (:qgis-latest)

              Run (foreground, Ctrl-C to stop)
                nix run .#run               Default: auth on, egress locked (empty allowlist)
                nix run .#run-multi-user    Multi-user via QGIS_DESKTOP_USERS env
                nix run .#run-users-file    Multi-user via bind-mounted file
                nix run .#run-no-auth       Auth DISABLED (dev only)
                nix run .#run-greeter       LightDM greeter (in-session login form)
                nix run .#run-greeter-multi Greeter with alice + bob accounts
                nix run .#run-oidc          Keycloak/OIDC SSO (reads QGIS_DESKTOP_OIDC_* from your env)
                nix run .#run-locked-down   Auth + full DLP (clipboard blocked, watermark, logging)
                nix run .#run-egress-locked Demo egress allowlist (1.1.1.1, example.com only)
                nix run .#run-no-lockdown   Auth OFF and egress lockdown OFF (dev only)

              Scenario
                nix run .#run-analyst-scenario   bob / password123 + kartoza/postgis db;
                                                  clipboard blocked, egress restricted to db.
                                                  See docs/scenarios/analyst-locked-down.md
                nix run .#run-keycloak-demo      Throwaway Keycloak + SSO desktop.
                                                  See examples/keycloak-oidc/README.md

              Giswater
                nix build .#epanet          EPA water-supply solver (runs a model on build)
                nix build .#swmm            EPA drainage solver (runs a model on build)
                epa status                  Solver + plugin wiring state (inside the desktop)

              All run-* targets pass --cap-add=NET_ADMIN so the entrypoint can
              manage nftables. Egress lockdown is ON by default in the image.

              Test
                nix run .#test              Run every check that needs no Docker
                nix run .#test-oidc         Unit-test the OIDC plumbing
                nix run .#test-terminal-lockdown   Unit-test the terminal lockdown
                nix run .#test-renamed-variables   Unit-test the 2.0.0 rename guard
                nix run .#test-persist      Unit-test home persistence
                nix run .#test-docs-glyphs  Check the docs against the PDF build

              Manage
                nix run .#stop              Stop and remove the qgis-desktop container
                nix run .#logs              Follow container logs
                nix run .#summary           Generate build summary

              Docs
                nix run .#docs-serve        mkdocs serve at http://127.0.0.1:8000
                nix run .#docs-build        Build the static site into ./site/
                nix run .#docs-pdf          Assemble docs into a Kartoza-branded PDF

              Make equivalents
                make build-docker           Build via Make
                make run                    Run via Make
            HELP
          '';

          # Unit tests for the OIDC plumbing: configuration validation, secret
          # handling and the flag list handed to oauth2-proxy. Runs in a couple
          # of seconds with no Docker, no container and no identity provider —
          # the proxy binary is stubbed out.
          test-oidc = {
            type = "app";
            program = "${pkgs.writeShellApplication {
              name = "test-oidc";
              # oauth2-proxy is here so the suite can validate every flag the
              # launcher emits against the real binary's --help.
              runtimeInputs = with pkgs; [ bash coreutils gnused gnugrep gawk oauth2-proxy ];
              text = ''
                export QGIS_DESKTOP_PROJECT_ROOT=${self}
                exec bash ${self}/scripts/test-oidc-config.sh
              '';
            }}/bin/test-oidc";
          };

          # Unit tests for the terminal lockdown, driven against a throwaway
          # tree shaped like the container's /bin and /home.
          test-terminal-lockdown = {
            type = "app";
            program = "${pkgs.writeShellApplication {
              name = "test-terminal-lockdown";
              runtimeInputs = with pkgs; [ bash coreutils gnused gnugrep ];
              text = ''
                export QGIS_DESKTOP_PROJECT_ROOT=${self}
                exec bash ${self}/scripts/test-terminal-lockdown.sh
              '';
            }}/bin/test-terminal-lockdown";
          };

          # Unit tests for the QGIS autostart flag.
          test-autostart = {
            type = "app";
            program = "${pkgs.writeShellApplication {
              name = "test-autostart";
              runtimeInputs = with pkgs; [ bash coreutils gnugrep ];
              text = ''
                export QGIS_DESKTOP_PROJECT_ROOT=${self}
                exec bash ${self}/scripts/test-autostart.sh
              '';
            }}/bin/test-autostart";
          };

          # Guards the PDF build: any character pdflatex cannot set fails here,
          # in a second, instead of ten minutes into `docs-pdf`.
          test-docs-glyphs = {
            type = "app";
            program = "${pkgs.writeShellApplication {
              name = "test-docs-glyphs";
              runtimeInputs = with pkgs; [ bash coreutils gnused gnugrep ];
              text = ''
                export QGIS_DESKTOP_PROJECT_ROOT=${self}
                exec bash ${self}/scripts/test-docs-glyphs.sh
              '';
            }}/bin/test-docs-glyphs";
          };

          # Unit tests for home persistence, driven against a local rclone
          # remote — the whole restore/save/guard cycle without S3.
          test-persist = {
            type = "app";
            program = "${pkgs.writeShellApplication {
              name = "test-persist";
              runtimeInputs = with pkgs; [
                bash coreutils gnused gnugrep findutils rclone
                util-linux # setpriv, for the privileged delivery path
              ];
              text = ''
                export QGIS_DESKTOP_PROJECT_ROOT=${self}
                exec bash ${self}/scripts/test-persist.sh
              '';
            }}/bin/test-persist";
          };

          # Unit tests for the 2.0.0 rename guard: every legacy KASM_* name is
          # refused, and KasmVNC's own settings are left alone.
          test-renamed-variables = {
            type = "app";
            program = "${pkgs.writeShellApplication {
              name = "test-renamed-variables";
              runtimeInputs = with pkgs; [ bash coreutils gnused gnugrep ];
              text = ''
                export QGIS_DESKTOP_PROJECT_ROOT=${self}
                exec bash ${self}/scripts/test-renamed-variables.sh
              '';
            }}/bin/test-renamed-variables";
          };

          # Everything that can be checked without Docker.
          test = {
            type = "app";
            program = "${pkgs.writeShellApplication {
              name = "test";
              runtimeInputs = with pkgs; [
                bash coreutils gnused gnugrep gawk findutils oauth2-proxy rclone
              ];
              text = ''
                export QGIS_DESKTOP_PROJECT_ROOT=${self}
                rc=0
                bash ${self}/scripts/test-oidc-config.sh || rc=1
                echo ""
                bash ${self}/scripts/test-terminal-lockdown.sh || rc=1
                echo ""
                bash ${self}/scripts/test-renamed-variables.sh || rc=1
                echo ""
                bash ${self}/scripts/test-persist.sh || rc=1
                echo ""
                bash ${self}/scripts/test-docs-glyphs.sh || rc=1
                echo ""
                bash ${self}/scripts/test-autostart.sh || rc=1
                exit "$rc"
              '';
            }}/bin/test";
          };

          summary = mkApp "summary" ''
            bash build-summary.sh nix-xfce-kasm:latest build-summary.md
          '';

          # --- Documentation apps -----------------------------------------
          # Local preview at http://127.0.0.1:8000.
          # `site_url` points at GitHub Pages, and mkdocs serve honours its path
          # component — so a plain `mkdocs serve` answers on
          # /qgis-desktop-docker/ and 404s at the root, which is a poor way to
          # review your own docs. Serve through a temporary config that
          # inherits everything and overrides the URL. Relative paths in an
          # inherited config resolve against the child file, so docs_dir and
          # site_dir have to be spelled out absolutely.
          docs-serve = mkDocsApp "docs-serve" (with pkgs; [ coreutils ]) ''
            ADDR="''${1:-127.0.0.1:8000}"
            WORK=$(mktemp -d -t qgis-docs-serve.XXXXXX)
            trap 'rm -rf "$WORK"' EXIT

            cat > "$WORK/mkdocs.yml" <<CFG
            INHERIT: $PWD/mkdocs.yml
            site_url: http://$ADDR/
            docs_dir: $PWD/docs
            site_dir: $WORK/site
            CFG
            sed -i 's/^            //' "$WORK/mkdocs.yml"

            echo "Serving docs at http://$ADDR (Ctrl-C to stop)"
            mkdocs serve -f "$WORK/mkdocs.yml" -a "$ADDR"
          '';

          # Build the static site into ./site/.
          docs-build = mkDocsApp "docs-build" [] ''
            mkdocs build --strict
            echo "Built site into ./site/"
          '';

          # Assemble the docs into a Kartoza-branded PDF via pandoc + lualatex.
          # SVG diagrams are pre-rendered to PDF with rsvg-convert so they stay
          # vector in the output. Result written to ./qgis-desktop-docker.pdf
          # (or the first CLI arg).
          # We use lualatex rather than xelatex because xetex's internal
          # xdvipdfmx invocation goes through /bin/sh (via C system(3)), which
          # doesn't exist on non-FHS distros like NixOS. lualatex writes PDF
          # directly, no /bin/sh needed.
          docs-pdf = mkDocsApp "docs-pdf" (with pkgs; [
            pandoc
            pdfLatex
            fontconfig
            dejavu_fonts
            liberation_ttf
            librsvg
            gnused
            findutils
            gawk
            coreutils
            glibcLocales
          ]) ''
            export FONTCONFIG_FILE=${pdfFontsConf}
            # lualatex refuses to start with "Unable to read locale data" if
            # the locale is unset (which it is in a bare `nix run` env).
            export LOCALE_ARCHIVE=${pkgs.glibcLocales}/lib/locale/locale-archive
            export LC_ALL=C.UTF-8
            export LANG=C.UTF-8
            # luaotfload caches its font database in $TEXMFCACHE. If unset it
            # tries ~/.texlive2025/texmf-var/luatex-cache which doesn't exist,
            # then fails silently and fontspec reports the font as missing.
            OUT="''${1:-qgis-desktop-docker.pdf}"
            case "$OUT" in
              /*) OUT_ABS="$OUT" ;;
              *)  OUT_ABS="$PWD/$OUT" ;;
            esac

            WORK=$(mktemp -d -t qgis-docs-pdf.XXXXXX)
            # Preserve WORK on failure so the tex log survives for debugging.
            # Written as a function so shellcheck can see rc's assignment
            # (it can't follow $? inside a quoted trap string).
            _docs_pdf_cleanup() {
              rc=$?
              if [ "$rc" -eq 0 ]; then
                rm -rf "$WORK"
              else
                echo "docs-pdf failed; kept work dir at: $WORK"
              fi
              exit "$rc"
            }
            trap _docs_pdf_cleanup EXIT

            # Writable dirs for luaotfload font-cache and TeX aux files.
            # luaotfload writes to $LUAOTFLOAD_CACHE_DIR (if set) or looks up
            # $TEXMFCACHE. In both cases it wants to actually CREATE the dir
            # tree; a bare $TEXMFCACHE is refused with "no writeable cache
            # path, quiting". Point it at a place we know is writable.
            export TEXMFCACHE="$WORK/tex-cache"
            export TEXMFVAR="$WORK/tex-var"
            export LUAOTFLOAD_CACHE_DIR="$WORK/tex-cache/luaotfload"
            export HOME="$WORK"
            mkdir -p "$TEXMFCACHE" "$TEXMFVAR" "$LUAOTFLOAD_CACHE_DIR"

            echo "Assembling PDF at $OUT_ABS"

            # Nav order to match mkdocs.yml.
            #
            # docs/index.md is deliberately absent: it is a landing page built
            # from a hero, call-to-action buttons and icon shortcodes, none of
            # which mean anything in print — and the PDF has its own cover
            # (docs/pdf/cover.tex). The content it summarises is in the pages
            # below anyway.
            DOCS_DIR=${./docs}
            PAGES=(
              "$DOCS_DIR/getting-started/index.md"
              "$DOCS_DIR/getting-started/quickstart.md"
              "$DOCS_DIR/getting-started/nix-workflow.md"
              "$DOCS_DIR/getting-started/building.md"
              "$DOCS_DIR/configuration/index.md"
              "$DOCS_DIR/configuration/environment.md"
              "$DOCS_DIR/configuration/permissions.md"
              "$DOCS_DIR/configuration/authentication.md"
              "$DOCS_DIR/configuration/egress-lockdown.md"
              "$DOCS_DIR/configuration/giswater.md"
              "$DOCS_DIR/configuration/persistence.md"
              "$DOCS_DIR/scenarios/index.md"
              "$DOCS_DIR/scenarios/analyst-locked-down.md"
              "$DOCS_DIR/scenarios/multi-user-greeter.md"
              "$DOCS_DIR/scenarios/keycloak-sso.md"
              "$DOCS_DIR/developer-guide/index.md"
              "$DOCS_DIR/developer-guide/architecture.md"
              "$DOCS_DIR/developer-guide/nix-flake.md"
              "$DOCS_DIR/developer-guide/project-structure.md"
              "$DOCS_DIR/developer-guide/contributing.md"
              "$DOCS_DIR/about/index.md"
              "$DOCS_DIR/about/specification.md"
              "$DOCS_DIR/about/sponsors.md"
              "$DOCS_DIR/about/license.md"
            )

            # Convert SVGs to PDF so pandoc/xelatex can embed them at vector
            # quality.
            mkdir -p "$WORK/diagrams"
            for svg in "$DOCS_DIR/scenarios/diagrams"/*.svg; do
              name=$(basename "$svg" .svg)
              rsvg-convert -f pdf -o "$WORK/diagrams/$name.pdf" "$svg"
            done

            # Concatenate pages with page breaks between chapters. Chapters map
            # to top-level sections in the nav.
            # Glyph substitutions come from a single source of truth that
            # scripts/test-docs-glyphs.sh checks the docs against, so a
            # character pdflatex cannot set fails in a second rather than ten
            # minutes into this build. Neither column ever contains '|', which
            # is what lets it be the sed delimiter.
            GLYPH_ARGS=()
            while IFS=$'\t' read -r glyph replacement; do
              case "$glyph" in "" | "#"*) continue ;; esac
              GLYPH_ARGS+=(-e "s|$glyph|$replacement|g")
            done < ${./docs/pdf/glyph-substitutions.tsv}
            echo "Applying ''${#GLYPH_ARGS[@]} glyph substitutions (2 args each)"

            {
              cat <<'META'
---
title: QGIS Desktop Docker
subtitle: Documentation
lang: en
---

META
              chapter=0
              for page in "''${PAGES[@]}"; do
                chapter=$((chapter + 1))
                [ "$chapter" -gt 1 ] && printf '\n\n\\newpage\n\n'
                # Rewrite SVG references in the analyst scenario to point at
                # the pre-rendered PDFs, transform admonitions to bold labels,
                # and replace the glyphs pdflatex cannot set (it does not take
                # arbitrary UTF-8 without inputenc utf8x, which we don't ship).
                sed \
                  -e 's|diagrams/\([a-z-]*\)\.svg|'"$WORK/diagrams/"'\1.pdf|g' \
                  -e 's|!!! note|**Note:**|g' \
                  -e 's|!!! tip|**Tip:**|g' \
                  -e 's|!!! warning|**Warning:**|g' \
                  -e 's|!!! danger|**Danger:**|g' \
                  -e 's|!!! quote ""||g' \
                  "''${GLYPH_ARGS[@]}" \
                  "$page"
              done
            } > "$WORK/combined.md"

            # Copy templates + the reversed vertical logo used by the cover.
            cp ${./docs/pdf/preamble.tex} "$WORK/preamble.tex"
            cp ${./docs/pdf/cover.tex}    "$WORK/cover.tex"
            cp ${./docs/assets/brand/kartoza-logo-vertical-reversed.png} \
               "$WORK/cover-logo.png"

            mkdir -p "$WORK/texout"
            cd "$WORK"
            pandoc combined.md \
              --pdf-engine=pdflatex \
              --pdf-engine-opt=-interaction=nonstopmode \
              --pdf-engine-opt=-output-directory="$WORK/texout" \
              --resource-path=".:$DOCS_DIR:$DOCS_DIR/about:$DOCS_DIR/scenarios" \
              --include-in-header=preamble.tex \
              --include-before-body=cover.tex \
              --toc --toc-depth=2 \
              -V fontfamily=lato \
              -V fontfamilyoptions=default \
              -V geometry:margin=2.5cm \
              -V colorlinks=true \
              -V linkcolor=kartozablue \
              -V urlcolor=kartozablue \
              -V toccolor=kartozablue \
              -V documentclass=article \
              -o "$OUT_ABS"

            echo ""
            echo "Wrote $OUT_ABS"
          '';
        };

        devShells.default = pkgs.mkShell {
          buildInputs = (with pkgs; [
            docker
            python3
            syft
            grype
            jq
          ]) ++ [ mkdocsPython ];
          shellHook = ''
            cat <<'BANNER'
            QGIS Desktop Docker — dev shell

              Build
                nix run .#build-docker      Build the image on QGIS LTR (default)
                nix run .#build-docker-qgis-latest   Build it on the current QGIS release

              Run (foreground, Ctrl-C to stop)
                nix run .#run               Default: auth on, egress locked (empty allowlist)
                nix run .#run-multi-user    Multi-user via QGIS_DESKTOP_USERS env
                nix run .#run-users-file    Multi-user via bind-mounted file
                nix run .#run-no-auth       Auth DISABLED (dev only)
                nix run .#run-greeter       LightDM greeter (in-session login form)
                nix run .#run-greeter-multi Greeter with alice + bob accounts
                nix run .#run-oidc          Keycloak/OIDC SSO (reads QGIS_DESKTOP_OIDC_* from your env)
                nix run .#run-locked-down   Auth + full DLP (clipboard blocked, watermark, logging)
                nix run .#run-egress-locked Demo egress allowlist (1.1.1.1, example.com only)
                nix run .#run-no-lockdown   Auth OFF and egress lockdown OFF (dev only)

              Scenario
                nix run .#run-analyst-scenario   bob + kartoza/postgis (see docs/)
                nix run .#run-keycloak-demo      Keycloak SSO demo (see examples/)

              Test
                nix run .#test-oidc         Unit-test the OIDC plumbing

              Manage
                nix run .#stop              Stop the qgis-desktop container
                nix run .#logs              Follow container logs

              Docs
                nix run .#docs-serve        Live-preview mkdocs at :8000
                nix run .#docs-build        Build the static site into ./site/
                nix run .#docs-pdf          Assemble docs into a Kartoza PDF
            BANNER
          '';
        };
      }
    );
}

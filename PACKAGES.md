# Packages

Every package inside `kartoza:qgis-desktop-ltr`, grouped by what it is there
for. Generated from a built image, not from the flake — the flake lists what we
*ask* for, and most of what lands in the image arrives transitively.

**517 store paths.** The image is 2.63 GB, down from 3.66 GB.

Sizes are of the store path itself, so they do not sum to the image size: nix
deduplicates, and the layered image shares paths between layers.

## Why this file exists

The flake's `contents` list is about forty entries. The image has five hundred.
The gap is where unwanted things hide — a C compiler arrived because a text file
in HDF4 quoted its path, and a Perl interpreter arrived because a settings
dialog wanted a cross-desktop library that wanted a system-information script.
Neither was visible from the flake.

Regenerate with:

```bash
docker run --rm --entrypoint sh kartoza:qgis-desktop-ltr -c '
  for d in /nix/store/*/; do
    b=$(basename "$d"); printf "%s\t%s\n" "$(du -sk "$d" | cut -f1)" "${b#*-}"
  done | sort -rn'
```

## What has been deliberately removed

| Removed | Why | How |
|---------|-----|-----|
| `gcc` and its toolchain | A compiler on a box that untrusted subscribers run code on. QGIS's Python console is an arbitrary-code path even with the terminal locked down. | `hdf4` quoted the compiler path in `lib/libhdf4.settings`; scrubbing that file dropped the reference. |
| `gdb` | A debugger with `ptrace` is useful to an attacker and to nobody else here. | Removed `pydevd_attach_to_process` from `debugpy` — its only referrer, and a code-injection feature in its own right. |
| `perl`, `inxi` | An interpreter and a system-information tool, neither reachable from the desktop. | Left with `xapp`. |
| `xapp`, `mate-panel`, `libmateweather`, `marco`, `zenity`, GTK4, `libadwaita` | Most of a second desktop environment, in an XFCE image. | Dropped `xapp` from `xfce4-settings`' build inputs. |
| `flite`, `freepats`, `pipewire`, `openal-soft`, `gst-plugins-bad` | Text-to-speech, MIDI patches and audio servers, in a container with no sound device. | Left with the `xapp` chain. |
| ~60 rclone storage backends | Proton Drive, Dropbox, Mega, Yandex and the rest, none reachable: `persist.sh` accepts only `s3` and `local`. | Replaced `backend/all/all.go`. |

## Still present, and why

`systemd` (28 MB) has five referrers including KasmVNC itself; nothing executes
it and there is no init in the container. `cups` and `sane-backends` (18 MB) are
reachable from `qtbase` and `colord` respectively — removing cups means
rebuilding Qt, which risks the print composer for 9 MB. Fifty-six `-dev` outputs
(29 MB) are headers and `.pc` files from ten unrelated packages: inert data, no
executables, and no separate SBOM entries.

### QGIS itself

**11 packages, 216 MB**

| Package | Size |
|---------|------|
| `qgis-ltr-unwrapped-3.44.9` | 190.5 MB |
| `qgis-ltr-3.44.9` | 12.8 MB |
| `qgis-ltr-with-epa-solvers` | 12.8 MB |
| `qgis-entrypoint` | 0.0 MB |
| `qgis-desktop-persist` | 0.0 MB |
| `qgis-desktop-oidc-proxy` | 0.0 MB |
| `qgis-desktop-session` | 0.0 MB |
| `qgis-desktop-oidc-config` | 0.0 MB |
| `qgis-desktop-manage-link` | 0.0 MB |
| `qgis-desktop-disable-terminal` | 0.0 MB |
| `qgis-desktop-autostart` | 0.0 MB |

### Geospatial libraries

**44 packages, 249 MB**

| Package | Size |
|---------|------|
| `google-cloud-cpp-2.44.0` | 29.0 MB |
| `gdal-3.12.4` | 26.5 MB |
| `lapack-3` | 25.9 MB |
| `blas-3` | 25.9 MB |
| `arrow-cpp-23.0.0` | 22.6 MB |
| `grpc-1.80.0` | 17.0 MB |
| `openblas-0.3.32` | 13.0 MB |
| `pdal-2.9.3` | 9.0 MB |
| `protobuf-34.1` | 7.4 MB |
| `tiledb-2.30.0` | 6.9 MB |
| `draco-1.5.7` | 6.8 MB |
| `poppler-data-0.4.12` | 6.0 MB |
| `geos-3.14.1` | 5.5 MB |
| `libspatialite-5.1.0` | 5.1 MB |
| `xerces-c-3.3.0` | 4.6 MB |
| *…29 more* | 38 MB |

### Python for QGIS

**47 packages, 211 MB**

| Package | Size |
|---------|------|
| `python3-3.13.12` | 79.0 MB |
| `python3.13-numpy-2.4.4` | 23.5 MB |
| `python3.13-matplotlib-3.10.8` | 19.9 MB |
| `python3.13-pyqt5-5.15.10` | 10.8 MB |
| `python3.13-setuptools-80.10.1` | 9.1 MB |
| `python3.13-fonttools-4.61.1` | 9.0 MB |
| `python3.13-pygments-2.20.0` | 8.0 MB |
| `python3.13-sip-6.15.1` | 6.9 MB |
| `python3.13-debugpy-1.8.20` | 6.8 MB |
| `python3.13-pytz-2026.1.post1` | 6.3 MB |
| `python3.13-pyqt-builder-1.19.1` | 6.1 MB |
| `python3.13-lxml-6.0.2` | 3.1 MB |
| `python3.13-pillow-12.2.0` | 3.0 MB |
| `python3.13-owslib-0.35.0` | 2.1 MB |
| `python3.13-pyproj-3.7.2` | 1.3 MB |
| *…32 more* | 16 MB |

### Desktop: XFCE

**13 packages, 38 MB**

| Package | Size |
|---------|------|
| `xfwm4-4.20.0` | 5.6 MB |
| `thunar-4.20.8` | 4.6 MB |
| `xfce4-settings-4.20.4` | 4.4 MB |
| `xfce4-panel-4.20.7` | 4.3 MB |
| `xfdesktop-4.20.2` | 3.7 MB |
| `xfce4-session-4.20.4` | 2.5 MB |
| `xfce4-terminal-1.2.0` | 2.3 MB |
| `libxfce4ui-4.20.2` | 2.2 MB |
| `exo-4.20.0` | 2.0 MB |
| `garcon-4.20.0` | 1.7 MB |
| `xfconf-4.20.0` | 1.7 MB |
| `libxfce4util-4.20.1` | 1.5 MB |
| `libxfce4windowing-4.20.5` | 1.2 MB |

### Desktop: GTK, Qt and X11

**108 packages, 206 MB**

| Package | Size |
|---------|------|
| `gtk+3-3.24.52` | 19.7 MB |
| `glibc-2.42-61` | 17.1 MB |
| `icu4c-76.1` | 16.5 MB |
| `qtbase-5.15.18` | 16.4 MB |
| `iso-codes-4.20.1` | 14.2 MB |
| `glib-2.86.3` | 8.0 MB |
| `shared-mime-info-2.4` | 7.3 MB |
| `qtdeclarative-5.15.18` | 6.4 MB |
| `librsvg-2.61.4` | 6.3 MB |
| `hicolor-icon-theme-0.18` | 5.9 MB |
| `qttranslations-5.15.18` | 5.7 MB |
| `adwaita-icon-theme-49.0` | 5.4 MB |
| `qttools-5.15.18` | 5.1 MB |
| `qt3d-5.15.18-bin` | 4.0 MB |
| `qtlocation-5.15.18-bin` | 3.8 MB |
| *…93 more* | 64 MB |

### Fonts

**5 packages, 16 MB**

| Package | Size |
|---------|------|
| `lato-2.0` | 6.5 MB |
| `dejavu-fonts-2.37` | 5.3 MB |
| `liberation-fonts-2.1.5` | 2.6 MB |
| `open-sans-1.11` | 1.4 MB |
| `dejavu-fonts-minimal-2.37` | 0.4 MB |

### Printing and scanning (removal candidates)

**6 packages, 49 MB**

| Package | Size |
|---------|------|
| `ghostscript-with-X-10.06.0` | 24.2 MB |
| `sane-backends-1.4.0` | 9.4 MB |
| `cups-2.4.16` | 9.0 MB |
| `ghostscript-with-X-10.06.0-fonts` | 4.8 MB |
| `cups-2.4.16-lib` | 1.3 MB |
| `libspectre-0.2.12` | 0.1 MB |

### Media codecs

**18 packages, 28 MB**

| Package | Size |
|---------|------|
| `alsa-ucm-conf-1.2.15.3` | 5.7 MB |
| `x265-4.1` | 5.3 MB |
| `gst-plugins-base-1.26.11` | 4.6 MB |
| `libaom-3.12.1` | 3.5 MB |
| `gstreamer-1.26.11` | 3.5 MB |
| `alsa-lib-1.2.15.3` | 1.1 MB |
| `libheif-1.21.2-lib` | 1.0 MB |
| `dav1d-1.5.3` | 0.9 MB |
| `libde265-1.0.18` | 0.5 MB |
| `flac-1.5.0` | 0.4 MB |
| `libtheora-1.2.0` | 0.4 MB |
| `libvorbis-1.3.7` | 0.3 MB |
| `libsndfile-1.2.2` | 0.3 MB |
| `lame-3.100-lib` | 0.2 MB |
| `alsa-topology-conf-1.2.5.1` | 0.1 MB |
| *…3 more* | 0 MB |

### Remote desktop and auth

**23 packages, 39 MB**

| Package | Size |
|---------|------|
| `oauth2-proxy-7.15.2` | 10.5 MB |
| `kasmvnc-1.4.0` | 3.8 MB |
| `openssl-3.6.1` | 3.6 MB |
| `p11-kit-0.26.2` | 2.9 MB |
| `linux-pam-1.7.1` | 2.6 MB |
| `lightdm-1.32.0` | 2.5 MB |
| `gnutls-3.8.12` | 1.9 MB |
| `nss-3.112.3` | 1.8 MB |
| `lightdm-gtk-greeter-2.0.9` | 1.8 MB |
| `krb5-1.22.1-lib` | 1.4 MB |
| `openssl-3.6.1-dev` | 1.0 MB |
| `libgpg-error-1.59` | 0.8 MB |
| `libgcrypt-1.11.2-lib` | 0.8 MB |
| `libidn2-2.3.8` | 0.7 MB |
| `curl-8.19.0` | 0.6 MB |
| *…8 more* | 2 MB |

### Persistence and networking

**8 packages, 26 MB**

| Package | Size |
|---------|------|
| `rclone-1.74.0` | 20.7 MB |
| `iproute2-6.19.0` | 2.8 MB |
| `iptables-1.8.13-lib` | 0.8 MB |
| `nftables-1.1.6` | 0.8 MB |
| `libnftnl-1.3.1` | 0.2 MB |
| `jansson-2.15.0` | 0.1 MB |
| `libnfnetlink-1.0.2` | 0.1 MB |
| `libmnl-1.0.5` | 0.0 MB |

### Giswater / EPA solvers

**2 packages, 1 MB**

| Package | Size |
|---------|------|
| `swmm-5.2.4` | 0.4 MB |
| `epanet-2.2` | 0.3 MB |

### Base system

**59 packages, 100 MB**

| Package | Size |
|---------|------|
| `systemd-260.1` | 27.6 MB |
| `systemd-minimal-260.1` | 10.5 MB |
| `ncurses-6.6` | 9.6 MB |
| `util-linux-2.42-lib` | 6.1 MB |
| `tzdata-2026a` | 5.8 MB |
| `util-linux-2.42-bin` | 4.9 MB |
| `util-linux-minimal-2.42-bin` | 4.4 MB |
| `gcc-15.2.0-lib` | 3.9 MB |
| `bash-interactive-5.3p9` | 3.6 MB |
| `shadow-4.19.4` | 2.6 MB |
| `systemd-minimal-libs-260.1` | 1.9 MB |
| `gawk-5.4.0` | 1.8 MB |
| `findutils-4.10.0` | 1.5 MB |
| `gnugrep-3.12` | 1.3 MB |
| `gnused-4.9` | 1.1 MB |
| *…44 more* | 13 MB |

### Uncategorised

**173 packages, 130 MB**

| Package | Size |
|---------|------|
| `gfortran-15.2.0-lib` | 5.3 MB |
| `xkeyboard-config-2.47` | 5.3 MB |
| `boost-1.89.0` | 5.1 MB |
| `libjxl-0.11.2` | 4.5 MB |
| `tcl-8.6.16` | 4.3 MB |
| `libgphoto2-2.5.33` | 3.9 MB |
| `aws-sdk-cpp-1.11.647` | 3.7 MB |
| `libimagequant-4.4.1` | 3.7 MB |
| `kbd-2.9.0` | 3.7 MB |
| `capnproto-1.4.0` | 3.6 MB |
| `tinysparql-3.10.1` | 3.4 MB |
| `qhull-2020.2` | 3.3 MB |
| `plymouth-24.004.60` | 3.2 MB |
| `hwdata-0.406` | 2.8 MB |
| `procps-4.0.6` | 2.6 MB |
| *…158 more* | 71 MB |

---

Made with love by [Kartoza](https://kartoza.com) —
[Donate!](https://github.com/sponsors/kartoza) —
[GitHub](https://github.com/kartoza/qgis-desktop-docker).

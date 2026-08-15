#!/usr/bin/env bash
# SPDX-FileCopyrightText: Tim Sutton
# SPDX-License-Identifier: MIT
#
# EPA hydraulic solver management for the GISWater dev environment.
# Usage: epa <command>
#
# Giswater's go2epa tool runs the EPA solvers by shelling out to two fixed
# paths inside its own plugin directory:
#
#   <plugin>/resources/epa/epanet/epanet.exe   (water supply, 'ws' projects)
#   <plugin>/resources/epa/swmm/swmm5.exe      (urban drainage, 'ud' projects)
#
# Those shipped files are Windows binaries, so on Linux they exist — which
# satisfies the plugin's os.path.exists() check — and then fail to execute.
# This script swaps them for symlinks to the natively built solvers from the
# flake (see nix/epanet.nix and nix/swmm.nix), keeping the originals aside so
# the change is fully reversible.
#
# Commands:
#   status     Show solver paths, versions and shim state for each plugin
#   install    Point the Giswater plugin(s) at the native solvers
#   uninstall  Restore the plugin's original shipped binaries
#   test       Run a model through both solvers to prove they work
#   help       Show this help

set -euo pipefail

# Resolve project root: this script lives in <root>/scripts/. Inside the
# container the script is installed into the nix store instead, where there is
# no checkout above it — GISWATER_SWMM_SMOKE_MODEL (baked in by the flake)
# supplies the smoke model directly, and PROJECT_ROOT is never consulted.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"

PROFILE_NAME="${GISWATER_PROFILE:-GISWater}"
QGIS_PROFILES_DIR="${QGIS_PROFILES_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/QGIS/QGIS3/profiles}"

# Solver binaries. The flake's devShell and QGIS wrapper both export these; the
# PATH lookup is the fallback for anyone running the script bare.
EPANET_EXE="${GISWATER_EPANET_EXE:-$(command -v runepanet 2>/dev/null || true)}"
SWMM_EXE="${GISWATER_SWMM_EXE:-$(command -v runswmm 2>/dev/null || true)}"

# Where the shims live inside a plugin, and what to call the displaced original.
declare -Ar SHIM_RELPATH=(
  [epanet]="resources/epa/epanet/epanet.exe"
  [swmm]="resources/epa/swmm/swmm5.exe"
)
BACKUP_SUFFIX=".shipped-windows"

c_reset=$'\033[0m'
c_bold=$'\033[1m'
c_green=$'\033[32m'
c_red=$'\033[31m'
c_yellow=$'\033[33m'
c_cyan=$'\033[36m'
c_dim=$'\033[2m'

ok() { printf '%s✓%s %s\n' "$c_green" "$c_reset" "$*"; }
warn() { printf '%s!%s %s\n' "$c_yellow" "$c_reset" "$*"; }
err() { printf '%s✗%s %s\n' "$c_red" "$c_reset" "$*" >&2; }
hdr() { printf '%s%s%s\n' "$c_bold" "$*" "$c_reset"; }

solver_exe() {
  # $1 = epanet|swmm
  case "$1" in
  epanet) printf '%s' "$EPANET_EXE" ;;
  swmm) printf '%s' "$SWMM_EXE" ;;
  esac
}

require_solvers() {
  local missing=0
  [[ -x "$EPANET_EXE" ]] || {
    err "EPANET solver not found (looked for \$GISWATER_EPANET_EXE and 'runepanet' on PATH)"
    missing=1
  }
  [[ -x "$SWMM_EXE" ]] || {
    err "SWMM solver not found (looked for \$GISWATER_SWMM_EXE and 'runswmm' on PATH)"
    missing=1
  }
  if ((missing)); then
    err "Are you inside 'nix develop'? The solvers come from this project's flake."
    exit 1
  fi
}

# Print every Giswater plugin directory we can find, one per line.
# A Giswater install is identified by the resources/epa layout it ships.
find_plugin_dirs() {
  local -a roots=()
  [[ -d "$QGIS_PROFILES_DIR" ]] && roots+=("$QGIS_PROFILES_DIR")
  # QGIS_PLUGINPATH may hold extra colon-separated plugin roots.
  if [[ -n "${QGIS_PLUGINPATH:-}" ]]; then
    local IFS=:
    for extra in $QGIS_PLUGINPATH; do
      [[ -d "$extra" ]] && roots+=("$extra")
    done
  fi
  ((${#roots[@]})) || return 0

  find "${roots[@]}" -mindepth 1 -maxdepth 6 -type d -name epa \
    -path '*/resources/epa' -printf '%h\n' 2>/dev/null |
    sed 's|/resources$||' | sort -u
}

# Shim state for one solver in one plugin: linked | shipped | missing | foreign
shim_state() {
  local plugin_dir="$1" solver="$2"
  local target="$plugin_dir/${SHIM_RELPATH[$solver]}"
  if [[ -L "$target" ]]; then
    if [[ "$(readlink -f "$target")" == "$(readlink -f "$(solver_exe "$solver")")" ]]; then
      printf 'linked'
    else
      printf 'foreign'
    fi
  elif [[ -e "$target" ]]; then
    printf 'shipped'
  else
    printf 'missing'
  fi
}

install_shim() {
  local plugin_dir="$1" solver="$2"
  local target="$plugin_dir/${SHIM_RELPATH[$solver]}"
  local backup="$target$BACKUP_SUFFIX"
  local exe
  exe="$(solver_exe "$solver")"

  mkdir -p "$(dirname "$target")"

  # Preserve the shipped Windows binary exactly once. A second install must not
  # overwrite the real original with a symlink from a previous run.
  if [[ -e "$target" && ! -L "$target" && ! -e "$backup" ]]; then
    mv "$target" "$backup"
    printf '    %skept original as %s%s\n' "$c_dim" "$(basename "$backup")" "$c_reset"
  fi

  ln -sfn "$exe" "$target"
  ok "  $solver → $exe"
}

uninstall_shim() {
  local plugin_dir="$1" solver="$2"
  local target="$plugin_dir/${SHIM_RELPATH[$solver]}"
  local backup="$target$BACKUP_SUFFIX"

  if [[ ! -L "$target" ]]; then
    warn "  $solver: not a shim, leaving alone"
    return 0
  fi
  rm -f "$target"
  if [[ -e "$backup" ]]; then
    mv "$backup" "$target"
    ok "  $solver: restored shipped binary"
  else
    ok "  $solver: shim removed (no shipped binary to restore)"
  fi
}

cmd_install() {
  require_solvers
  hdr "🔗 Pointing Giswater at the native EPA solvers"

  local -a plugins
  mapfile -t plugins < <(find_plugin_dirs)
  if ((${#plugins[@]} == 0)); then
    warn "No Giswater plugin found under $QGIS_PROFILES_DIR"
    warn "Install the Giswater plugin in QGIS first, then run: epa install"
    return 0
  fi

  local plugin solver
  for plugin in "${plugins[@]}"; do
    printf '  %s%s%s\n' "$c_cyan" "$plugin" "$c_reset"
    for solver in epanet swmm; do
      install_shim "$plugin" "$solver"
    done
  done
}

cmd_uninstall() {
  hdr "↩️  Restoring Giswater's shipped EPA binaries"

  local -a plugins
  mapfile -t plugins < <(find_plugin_dirs)
  if ((${#plugins[@]} == 0)); then
    warn "No Giswater plugin found under $QGIS_PROFILES_DIR"
    return 0
  fi

  local plugin solver
  for plugin in "${plugins[@]}"; do
    printf '  %s%s%s\n' "$c_cyan" "$plugin" "$c_reset"
    for solver in epanet swmm; do
      uninstall_shim "$plugin" "$solver"
    done
  done
}

cmd_status() {
  hdr "📊 EPA solver status"
  printf '  %sprofile%s   %s\n' "$c_cyan" "$c_reset" "$PROFILE_NAME"
  printf '  %sprofiles%s  %s\n' "$c_cyan" "$c_reset" "$QGIS_PROFILES_DIR"

  local solver exe
  for solver in epanet swmm; do
    exe="$(solver_exe "$solver")"
    if [[ -x "$exe" ]]; then
      printf '  %s%-8s%s %s\n' "$c_cyan" "$solver" "$c_reset" "$exe"
    else
      printf '  %s%-8s%s %snot found%s\n' "$c_cyan" "$solver" "$c_reset" "$c_yellow" "$c_reset"
    fi
  done

  local -a plugins
  mapfile -t plugins < <(find_plugin_dirs)
  if ((${#plugins[@]} == 0)); then
    warn "No Giswater plugin found — nothing to wire up yet"
    return 0
  fi

  local plugin state colour
  for plugin in "${plugins[@]}"; do
    printf '\n  %s%s%s\n' "$c_cyan" "$plugin" "$c_reset"
    for solver in epanet swmm; do
      state="$(shim_state "$plugin" "$solver")"
      case "$state" in
      linked) colour="$c_green" ;;
      *) colour="$c_yellow" ;;
      esac
      printf '    %-8s %s%s%s\n' "$solver" "$colour" "$state" "$c_reset"
    done
  done

  printf '\n  %sshipped%s = plugin still holds its Windows binary; run '\''epa install'\''\n' \
    "$c_dim" "$c_reset"
  printf '  %sforeign%s = symlink points somewhere other than this flake'\''s solver\n\n' \
    "$c_dim" "$c_reset"
}

cmd_test() {
  require_solvers
  hdr "🧪 Running both solvers end to end"

  local workdir
  workdir="$(mktemp -d)"
  # shellcheck disable=SC2064 # expand workdir now, not at trap time
  trap "rm -rf '$workdir'" EXIT

  # EPANET ships example networks alongside the binary in the nix store.
  local epanet_share net
  epanet_share="$(dirname "$(dirname "$(readlink -f "$EPANET_EXE")")")/share/epanet/example-networks"
  net="$epanet_share/Net1.inp"
  if [[ -f "$net" ]]; then
    "$EPANET_EXE" "$net" "$workdir/net1.rpt" >/dev/null
    if grep -q "Analysis ended" "$workdir/net1.rpt"; then
      ok "EPANET solved Net1.inp"
    else
      err "EPANET produced no completed report"
      exit 1
    fi
  else
    warn "EPANET example networks not found at $epanet_share — skipping EPANET run"
  fi

  local swmm_model="${GISWATER_SWMM_SMOKE_MODEL:-$PROJECT_ROOT/nix/swmm-smoke.inp}"
  if [[ -f "$swmm_model" ]]; then
    "$SWMM_EXE" "$swmm_model" "$workdir/smoke.rpt" "$workdir/smoke.out" >/dev/null
    if grep -q "Analysis ended" "$workdir/smoke.rpt"; then
      ok "SWMM solved the smoke model"
    else
      err "SWMM produced no completed report"
      exit 1
    fi
  else
    warn "SWMM smoke model not found at $swmm_model — skipping SWMM run"
  fi

  ok "Both solvers are working"
}

cmd_help() {
  cat <<EOF
${c_bold}epa${c_reset} — EPA hydraulic solvers (EPANET & SWMM) for GISWater

${c_bold}Usage:${c_reset} epa <command>

  ${c_cyan}status${c_reset}     Show solver paths and per-plugin shim state
  ${c_cyan}install${c_reset}    Point the Giswater plugin(s) at the native solvers
  ${c_cyan}uninstall${c_reset}  Restore the plugin's original shipped binaries
  ${c_cyan}test${c_reset}       Run a model through both solvers to prove they work
  ${c_cyan}help${c_reset}       Show this help

Giswater executes ${c_dim}<plugin>/resources/epa/{epanet/epanet.exe,swmm/swmm5.exe}${c_reset}.
Those shipped files are Windows binaries; 'epa install' replaces them with
symlinks to the solvers built by this flake, keeping the originals as
${c_dim}*${BACKUP_SUFFIX}${c_reset} so 'epa uninstall' can put them back.

EPANET:  ${EPANET_EXE:-<not found>}
SWMM:    ${SWMM_EXE:-<not found>}
EOF
}

main() {
  local cmd="${1:-help}"
  shift || true
  case "$cmd" in
  status) cmd_status "$@" ;;
  install) cmd_install "$@" ;;
  uninstall) cmd_uninstall "$@" ;;
  test) cmd_test "$@" ;;
  help | -h | --help) cmd_help ;;
  *)
    err "Unknown command: $cmd"
    cmd_help
    exit 2
    ;;
  esac
}

main "$@"

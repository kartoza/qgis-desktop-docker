#!/usr/bin/env bash
# Build summary script - outputs version info, sizes, and SBOM
# Usage: ./build-summary.sh [image-name:tag]
set -euo pipefail

IMAGE="${1:-nix-xfce-kasm:latest}"
SUMMARY_FILE="${2:-build-summary.md}"

echo "Generating build summary for ${IMAGE}..."

# Image size (compressed tarball)
COMPRESSED_SIZE="unknown"
if [ -L result ]; then
  STORE_PATH=$(readlink result)
  COMPRESSED_SIZE=$(nix store ls --store auto -l "$STORE_PATH" 2>/dev/null | awk '{print $4}' || echo "unknown")
  if [ "$COMPRESSED_SIZE" = "unknown" ] || [ -z "$COMPRESSED_SIZE" ]; then
    COMPRESSED_SIZE=$(nix path-info --size "$STORE_PATH" 2>/dev/null | awk '{print $1}' || echo "unknown")
  fi
fi

# Docker image size
DOCKER_SIZE=$(docker image inspect "$IMAGE" --format='{{.Size}}' 2>/dev/null || echo "0")
DOCKER_SIZE_HR=$(numfmt --to=iec-i --suffix=B "$DOCKER_SIZE" 2>/dev/null || echo "${DOCKER_SIZE} bytes")

# Get versions from running container or by running a throwaway one
get_version() {
  docker run --rm --entrypoint /bin/bash "$IMAGE" -c "$1" 2>/dev/null || echo "unknown"
}

QGIS_VERSION=$(get_version 'qgis --version 2>&1 | grep -oP "QGIS \K[0-9]+\.[0-9]+\.[0-9]+"')
QGIS_CODENAME=$(get_version 'qgis --version 2>&1 | grep -oP "'"'"'\K[^'"'"']+'"'"'"' | head -1')
KASMVNC_VERSION=$(get_version 'Xkasmvnc -version 2>&1 | grep -oP "KasmVNC \K[0-9]+\.[0-9]+\.[0-9]+"')
LIBCRYPT_VERSION=$(get_version 'ls /nix/store/*libcrypt-compat*/lib/libcrypt.so.*.*.* 2>/dev/null | grep -oP "libcrypt.so.\K.*"')
XFCE_VERSION=$(get_version 'xfce4-session --version 2>&1 | grep -oP "xfce4-session \K[0-9]+\.[0-9]+\.[0-9]+" || echo unknown')
NIXPKGS_REV=$(jq -r '.nodes.nixpkgs.locked.rev // "unknown"' flake.lock 2>/dev/null || echo "unknown")

# Generate SBOM (list of all nix store paths in the image)
echo "Generating SBOM..."
SBOM_FILE="sbom.txt"
docker run --rm --entrypoint /bin/bash "$IMAGE" -c '
  ls -1 /nix/store/ | grep -v "\.drv$" | grep -v "^\.links$" | sort | while read -r p; do
    echo "/nix/store/$p"
  done
' > "$SBOM_FILE" 2>/dev/null || echo "SBOM generation failed" > "$SBOM_FILE"

SBOM_COUNT=$(wc -l < "$SBOM_FILE")

# Write summary
cat > "$SUMMARY_FILE" <<EOF
# Build Summary

## Image
| Property | Value |
|----------|-------|
| Image | \`${IMAGE}\` |
| Docker Image Size | ${DOCKER_SIZE_HR} |
| Nix Store Packages | ${SBOM_COUNT} |

## Versions
| Component | Version |
|-----------|---------|
| QGIS | ${QGIS_VERSION} (${QGIS_CODENAME}) |
| KasmVNC | ${KASMVNC_VERSION} |
| libcrypt-compat | ${LIBCRYPT_VERSION} |
| XFCE | ${XFCE_VERSION} |
| nixpkgs | \`${NIXPKGS_REV:0:12}\` |

## SBOM
<details>
<summary>${SBOM_COUNT} packages (click to expand)</summary>

\`\`\`
$(cat "$SBOM_FILE")
\`\`\`
</details>
EOF

echo ""
cat "$SUMMARY_FILE"
echo ""
echo "Summary written to ${SUMMARY_FILE}"
echo "SBOM written to ${SBOM_FILE}"

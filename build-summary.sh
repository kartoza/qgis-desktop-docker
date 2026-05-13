#!/usr/bin/env bash
# Build summary script - outputs version info, sizes, and SBOM
# Usage: ./build-summary.sh [image-name:tag] [output-file]
set -euo pipefail

IMAGE="${1:-nix-xfce-kasm:latest}"
SUMMARY_FILE="${2:-build-summary.md}"

echo "Generating build summary for ${IMAGE}..."

# Docker image size
DOCKER_SIZE=$(docker image inspect "$IMAGE" --format='{{.Size}}' 2>/dev/null || echo "0")
DOCKER_SIZE_HR=$(numfmt --to=iec-i --suffix=B "$DOCKER_SIZE" 2>/dev/null || echo "${DOCKER_SIZE} bytes")

# Get versions by running throwaway containers
run_in_image() {
  docker run --rm --entrypoint /bin/bash "$IMAGE" -c "$1" 2>/dev/null || echo "unknown"
}

QGIS_FULL=$(run_in_image "qgis --version 2>&1 | tail -1")
QGIS_VERSION=$(echo "$QGIS_FULL" | grep -oP "QGIS \K[0-9]+\.[0-9]+\.[0-9]+" || echo "unknown")
QGIS_CODENAME=$(echo "$QGIS_FULL" | sed -n "s/.*'\(.*\)'.*/\1/p" || echo "unknown")
KASMVNC_VERSION=$(run_in_image "Xkasmvnc -version 2>&1 | grep -oP 'KasmVNC \K[0-9]+\.[0-9]+\.[0-9]+'")
LIBCRYPT_VERSION=$(run_in_image "find /nix/store -maxdepth 1 -name '*libcrypt-compat*' | head -1 | grep -oP 'compat-\K[0-9]+\.[0-9]+\.[0-9]+-[0-9]+'")
XFCE_VERSION=$(run_in_image "xfce4-session --version 2>&1 | grep -oP 'xfce4-session \K[0-9]+\.[0-9]+\.[0-9]+' || echo unknown")
NIXPKGS_REV=$(jq -r '.nodes.nixpkgs.locked.rev // "unknown"' flake.lock 2>/dev/null || echo "unknown")

# Generate SBOM (list of all nix store paths in the image)
echo "Generating SBOM..."
SBOM_FILE="sbom.txt"
run_in_image "ls -1d /nix/store/*/ 2>/dev/null | sed 's|/$||' | sort" > "$SBOM_FILE"
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

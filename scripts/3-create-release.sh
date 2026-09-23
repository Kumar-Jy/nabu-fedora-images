#!/bin/bash

# ==============================================================================
# 3-create-release.sh
#
# Create a GitHub Release from the artifacts produced by the build-variants job:
#   - each nabu-fedora-installer-<variant> directory is packaged as a
#     flashable ZIP (bin/, DBKP/, efi/, images/, installer/, META-INF/,
#     flash-linux.bat/.sh)
#   - the EFI files zip and flashable ESP image are attached as extras
#
# Requires: GH_TOKEN (or GH_CLI) and the `artifacts/` directory downloaded
# with actions/download-artifact.
# ==============================================================================

set -e
set -u
set -o pipefail

if [ -n "${GITHUB_WORKSPACE}" ]; then
    git config --global --add safe.directory "${GITHUB_WORKSPACE}"
fi

BUILD_VERSION="${BUILD_VERSION:-45}"
ARTIFACTS_DIR="artifacts"

if [ -z "${GH_TOKEN:-}" ]; then
    echo "ERROR: GH_TOKEN is not set" >&2
    exit 1
fi

ASSETS_TO_UPLOAD=()

TMP_WORK=$(mktemp -d)
trap 'rm -rf "$TMP_WORK"' EXIT

echo "INFO: Scanning ${ARTIFACTS_DIR} for installer artifacts..."
INSTALLER_DIRS=($(find "${ARTIFACTS_DIR}" -maxdepth 1 -type d -name "nabu-fedora-installer-*" | sort))

if [ ${#INSTALLER_DIRS[@]} -eq 0 ]; then
    echo "ERROR: no nabu-fedora-installer-* artifacts found" >&2
    ls -R "${ARTIFACTS_DIR}" || true
    exit 1
fi

for DIR in "${INSTALLER_DIRS[@]}"; do
    VARIANT="$(basename "$DIR" | sed 's/^nabu-fedora-installer-//')"
    ZIP_NAME="nabu-fedora-${BUILD_VERSION}-${VARIANT}-installer.zip"
    echo "INFO: Packaging ${DIR} -> ${ZIP_NAME}"
    (cd "$DIR" && zip -r "${TMP_WORK}/${ZIP_NAME}" . -x '*.pyc' >/dev/null)
    ASSETS_TO_UPLOAD+=("${TMP_WORK}/${ZIP_NAME}")
done

# EFI files zip + ESP image as extra assets
EFI_ZIP=$(find "${ARTIFACTS_DIR}" -type f -name "efi-files.zip" | head -1 || true)
if [ -n "$EFI_ZIP" ]; then
    cp "$EFI_ZIP" "${TMP_WORK}/efi-files-${BUILD_VERSION}.zip"
    ASSETS_TO_UPLOAD+=("${TMP_WORK}/efi-files-${BUILD_VERSION}.zip")
fi

ESP_IMG=$(find "${ARTIFACTS_DIR}" -type f -name "flashable_esp.img.zst" | head -1 || true)
if [ -n "$ESP_IMG" ]; then
    cp "$ESP_IMG" "${TMP_WORK}/esp-${BUILD_VERSION}.img.zst"
    ASSETS_TO_UPLOAD+=("${TMP_WORK}/esp-${BUILD_VERSION}.img.zst")
fi

if [ ${#ASSETS_TO_UPLOAD[@]} -eq 0 ]; then
    echo "ERROR: no assets to upload" >&2
    exit 1
fi

TAG="release-$(date +'%Y%m%d-%H%M')"
RELEASE_TITLE="Fedora ${BUILD_VERSION} for Nabu - $(date +'%Y%m%d-%H%M')"

CHANGELOG="* No changelog provided."
if [ -f "docs/release-notes.md" ]; then
    CHANGELOG=$(cat docs/release-notes.md)
fi

COMMIT_URL="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-your/repo}/commit/${GITHUB_SHA:-HEAD}"

ASSET_NOTES=""
for ASSET in "${ASSETS_TO_UPLOAD[@]}"; do
    FILENAME=$(basename "${ASSET}")
    if [[ "${FILENAME}" == *-installer.zip ]]; then
        ASSET_NOTES="${ASSET_NOTES}- \`${FILENAME}\` - Flashable installer ZIP (run \`flash-linux.sh\` or \`fastboot\` commands on the device).
"
    elif [[ "${FILENAME}" == efi-files-*.zip ]]; then
        ASSET_NOTES="${ASSET_NOTES}- \`${FILENAME}\` - EFI files (manual copy to ESP if you don't want to overwrite the whole partition).
"
    elif [[ "${FILENAME}" == esp-*.img.zst ]]; then
        ASSET_NOTES="${ASSET_NOTES}- \`${FILENAME}\` - Flashable ESP image (contains bootloader + UKI). Decompress with \`unzstd\`.
"
    fi
done

RELEASE_NOTES=$(cat <<EOF
Automated build of Fedora ${BUILD_VERSION} for Xiaomi Pad 5 (nabu).

## Changelog

${CHANGELOG}

## Assets

${ASSET_NOTES}

This build is based on commit: [${GITHUB_SHA:0:7}](${COMMIT_URL})
EOF
)

echo "INFO: Creating GitHub release '${TAG}' with ${#ASSETS_TO_UPLOAD[@]} assets..."
gh release create "$TAG" \
    --title "$RELEASE_TITLE" \
    --notes "$RELEASE_NOTES" \
    --latest \
    "${ASSETS_TO_UPLOAD[@]}"

echo "✅ SUCCESS: Release ${TAG} created."
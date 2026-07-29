#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${1:-release}"
PRODUCT="ProGhostty"
VERSION="${VERSION:-0.1.0}"
ARCH_NAME="$(uname -m)"
DIST_DIR="${ROOT_DIR}/dist"
ZIP_NAME="${PRODUCT}-${VERSION}-${ARCH_NAME}.zip"
ZIP_PATH="${DIST_DIR}/${ZIP_NAME}"

mkdir -p "${DIST_DIR}"
rm -f "${ZIP_PATH}"

# Build the .app (same call as build-dmg.sh)
APP_DIR="$(VERSION="${VERSION}" BUILD="${BUILD:-1}" "${ROOT_DIR}/scripts/build-app-bundle.sh" "${CONFIGURATION}")"

# Stage a fresh copy so we don't mutate the build output
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/proghostty-zip.XXXXXX")"
cleanup() {
  rm -rf "${STAGING_DIR}"
}
trap cleanup EXIT

cp -R "${APP_DIR}" "${STAGING_DIR}/${PRODUCT}.app"

# Ad-hoc sign the .app (same as DMG flow)
codesign --force --sign - --deep "${STAGING_DIR}/${PRODUCT}.app" >/dev/null

# Create the zip from the staging directory
cd "${STAGING_DIR}"
ditto -c -k --sequesterRsrc --keepParent "${PRODUCT}.app" "${ZIP_PATH}"

# NOTE: The .zip itself is intentionally NOT signed.
# Unsigned archives don't trigger Gatekeeper on the archive itself,
# reducing the number of security prompts for the user.

echo "${ZIP_PATH}"

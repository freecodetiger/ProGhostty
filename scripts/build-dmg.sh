#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${1:-release}"
PRODUCT="ProGhostty"
VERSION="${VERSION:-0.1.0}"
ARCH_NAME="$(uname -m)"
DIST_DIR="${ROOT_DIR}/dist"
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/proghostty-dmg.XXXXXX")"
DMG_NAME="${PRODUCT}-${VERSION}-${ARCH_NAME}.dmg"
DMG_PATH="${DIST_DIR}/${DMG_NAME}"

cleanup() {
  rm -rf "${STAGING_DIR}"
}
trap cleanup EXIT

mkdir -p "${DIST_DIR}"
rm -f "${DMG_PATH}"

APP_DIR="$(VERSION="${VERSION}" BUILD="${BUILD:-1}" "${ROOT_DIR}/scripts/build-app-bundle.sh" "${CONFIGURATION}")"
cp -R "${APP_DIR}" "${STAGING_DIR}/${PRODUCT}.app"
ln -s /Applications "${STAGING_DIR}/Applications"

codesign --force --sign - --deep "${STAGING_DIR}/${PRODUCT}.app" >/dev/null
hdiutil create \
  -volname "${PRODUCT} ${VERSION}" \
  -srcfolder "${STAGING_DIR}" \
  -fs HFS+ \
  -format UDZO \
  "${DMG_PATH}" >/dev/null

codesign --force --sign - "${DMG_PATH}" >/dev/null 2>&1 || true
echo "${DMG_PATH}"

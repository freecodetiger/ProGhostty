#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${1:-release}"
PRODUCT="ProGhostty"
VERSION="${VERSION:-0.1.0}"
ARCH_NAME="$(uname -m)"
DIST_DIR="${ROOT_DIR}/dist"
DMG_NAME="${PRODUCT}-${VERSION}-${ARCH_NAME}.dmg"
DMG_PATH="${DIST_DIR}/${DMG_NAME}"

# Unset SIGNING_IDENTITY means a local, unsigned build: skip notarization and
# keep the ad-hoc signature so the artifact is still runnable on this Mac.
SIGNING_IDENTITY="${SIGNING_IDENTITY:--}"

mkdir -p "${DIST_DIR}"
rm -f "${DMG_PATH}"

# A release pipeline can build one signed, notarized, stapled staging directory
# and hand it to both packagers, so the app is built and submitted to Apple once
# instead of once per artifact. Unset → build and notarize it here.
if [ -n "${APP_STAGING_DIR:-}" ]; then
  STAGING_DIR="${APP_STAGING_DIR}"
else
  STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/proghostty-dmg.XXXXXX")"
  cleanup() {
    rm -rf "${STAGING_DIR}"
  }
  trap cleanup EXIT

  APP_DIR="$(VERSION="${VERSION}" BUILD="${BUILD:-1}" "${ROOT_DIR}/scripts/build-app-bundle.sh" "${CONFIGURATION}")"
  # `ditto`, not `cp -R`: it preserves the extended attributes and resource fork
  # the code signature seals, and a staging copy that drops them invalidates it.
  ditto "${APP_DIR}" "${STAGING_DIR}/${PRODUCT}.app"
  ln -s /Applications "${STAGING_DIR}/Applications"

  if [ "${SIGNING_IDENTITY}" != "-" ]; then
    # Notarize and staple the .app BEFORE it goes into the DMG. Stapling is what
    # lets Gatekeeper accept it with no network, and the ZIP artifact has no
    # ticket of its own — the app inside it must carry one.
    "${ROOT_DIR}/scripts/notarize.sh" "${STAGING_DIR}/${PRODUCT}.app"
  fi
fi

hdiutil create \
  -volname "${PRODUCT} ${VERSION}" \
  -srcfolder "${STAGING_DIR}" \
  -fs HFS+ \
  -format UDZO \
  "${DMG_PATH}" >/dev/null

if [ "${SIGNING_IDENTITY}" != "-" ]; then
  codesign --force --sign "${SIGNING_IDENTITY}" --timestamp "${DMG_PATH}" >/dev/null
  "${ROOT_DIR}/scripts/notarize.sh" "${DMG_PATH}"
fi

echo "${DMG_PATH}"

#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${1:-debug}"
PRODUCT="ProGhostty"
VERSION="${VERSION:-0.1.0}"
BUILD="${BUILD:-1}"
BUILD_DIR="$(cd "${ROOT_DIR}" && swift build -c "${CONFIGURATION}" --show-bin-path)"
APP_DIR="${BUILD_DIR}/${PRODUCT}.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
ICON_FILE="ProGhostty.icns"
SOURCE_ICON="${ROOT_DIR}/logo.png"
GENERATED_ICON="${ROOT_DIR}/Resources/${ICON_FILE}"

cd "${ROOT_DIR}"
swift build -c "${CONFIGURATION}" >&2
"${ROOT_DIR}/scripts/generate-app-icon.sh" "${SOURCE_ICON}" "${GENERATED_ICON}" >/dev/null

rm -rf "${APP_DIR}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"
cp "${BUILD_DIR}/${PRODUCT}" "${MACOS_DIR}/${PRODUCT}"
cp "${GENERATED_ICON}" "${RESOURCES_DIR}/${ICON_FILE}"

cat > "${CONTENTS_DIR}/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>${PRODUCT}</string>
  <key>CFBundleIdentifier</key>
  <string>com.freecodetiger.ProGhostty</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>${PRODUCT}</string>
  <key>CFBundleIconFile</key>
  <string>ProGhostty</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${VERSION}</string>
  <key>CFBundleVersion</key>
  <string>${BUILD}</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSAutoFillRequiresTextContentTypeForOneTimeCodeOnMac</key>
  <true/>
</dict>
</plist>
PLIST

codesign --force --sign - "${APP_DIR}" >/dev/null
echo "${APP_DIR}"

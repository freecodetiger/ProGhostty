#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_ICON="${1:-"${ROOT_DIR}/logo.png"}"
OUTPUT_ICON="${2:-"${ROOT_DIR}/Resources/ProGhostty.icns"}"

if [[ ! -f "${SOURCE_ICON}" ]]; then
  echo "missing icon source: ${SOURCE_ICON}" >&2
  exit 1
fi

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/proghostty-iconset.XXXXXX")"
ICONSET_DIR="${WORK_DIR}/ProGhostty.iconset"
mkdir -p "${ICONSET_DIR}"
trap 'rm -rf "${WORK_DIR}"' EXIT

make_icon() {
  local pixels="$1"
  local filename="$2"
  sips -s format png -z "${pixels}" "${pixels}" "${SOURCE_ICON}" \
    --out "${ICONSET_DIR}/${filename}" >/dev/null
}

make_icon 16 "icon_16x16.png"
make_icon 32 "icon_16x16@2x.png"
make_icon 32 "icon_32x32.png"
make_icon 64 "icon_32x32@2x.png"
make_icon 128 "icon_128x128.png"
make_icon 256 "icon_128x128@2x.png"
make_icon 256 "icon_256x256.png"
make_icon 512 "icon_256x256@2x.png"
make_icon 512 "icon_512x512.png"
make_icon 1024 "icon_512x512@2x.png"

mkdir -p "$(dirname "${OUTPUT_ICON}")"
iconutil -c icns "${ICONSET_DIR}" -o "${OUTPUT_ICON}"
echo "${OUTPUT_ICON}"

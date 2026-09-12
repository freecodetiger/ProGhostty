#!/usr/bin/env bash
set -euo pipefail

# Submits an artifact to Apple's notary service and staples the resulting
# ticket. See docs/release-signing.md for how to obtain the credentials.
#
# Usage:
#   scripts/notarize.sh <artifact> [staple-path]
#
# <artifact> is a .app, .dmg or .zip. A .app is zipped to a temp file first —
# notarytool only accepts zip/dmg/pkg — and the ticket is then stapled to the
# .app itself, which is what lets Gatekeeper accept it offline.
#
# staple-path defaults to <artifact>. Pass it explicitly when the submitted
# artifact cannot hold a ticket (a .zip).
#
# Credentials, in priority order:
#   1. NOTARY_KEY_PATH + NOTARY_KEY_ID [+ NOTARY_ISSUER_ID]
#      App Store Connect API key. Use this in CI — no keychain, no prompts.
#      NOTARY_ISSUER_ID is required for a Team key and must be left UNSET for
#      an Individual key; notarytool rejects the combination.
#   2. NOTARY_PROFILE
#      A keychain profile stored once via `xcrun notarytool store-credentials`.

ARTIFACT="${1:?usage: notarize.sh <artifact> [staple-path]}"
STAPLE_PATH="${2:-${ARTIFACT}}"
[ -e "${ARTIFACT}" ] || { echo "notarize: not found: ${ARTIFACT}" >&2; exit 1; }

CREDENTIALS=()
if [ -n "${NOTARY_KEY_PATH:-}" ]; then
  : "${NOTARY_KEY_ID:?NOTARY_KEY_ID is required alongside NOTARY_KEY_PATH}"
  CREDENTIALS=(--key "${NOTARY_KEY_PATH}" --key-id "${NOTARY_KEY_ID}")
  # Individual API keys have no issuer; passing one is an error, not a no-op.
  [ -n "${NOTARY_ISSUER_ID:-}" ] && CREDENTIALS+=(--issuer "${NOTARY_ISSUER_ID}")
else
  : "${NOTARY_PROFILE:?set NOTARY_PROFILE, or NOTARY_KEY_PATH + NOTARY_KEY_ID}"
  CREDENTIALS=(--keychain-profile "${NOTARY_PROFILE}")
fi

TEMP_DIR=""
# An `[ -n ... ] && rm -rf` one-liner here would leave the function returning 1
# whenever TEMP_DIR is empty (the .dmg case), and that non-zero status from an
# EXIT trap becomes the script's exit code — a successful run reported as
# failure. An `if` with no branch taken returns 0.
cleanup() {
  if [ -n "${TEMP_DIR}" ]; then
    rm -rf "${TEMP_DIR}"
  fi
}
trap cleanup EXIT

SUBMIT_PATH="${ARTIFACT}"
if [[ "${ARTIFACT}" == *.app ]]; then
  TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/proghostty-notarize.XXXXXX")"
  SUBMIT_PATH="${TEMP_DIR}/$(basename "${ARTIFACT}").zip"
  # ditto, not zip: it preserves the bundle's symlinks and extended attributes.
  ditto -c -k --sequesterRsrc --keepParent "${ARTIFACT}" "${SUBMIT_PATH}"
fi

echo "notarize: submitting $(basename "${SUBMIT_PATH}") — this takes a few minutes" >&2

# Some notarytool builds exit 0 for an Invalid result, so the status line is
# what decides, not the exit code.
output=""
if ! output="$(xcrun notarytool submit "${SUBMIT_PATH}" "${CREDENTIALS[@]}" --wait 2>&1)"; then
  echo "${output}" >&2
  echo "notarize: submission failed" >&2
  exit 1
fi

if ! grep -q "status: Accepted" <<<"${output}"; then
  echo "${output}" >&2
  # The submission log names the offending file and reason (unsigned nested
  # binary, missing hardened runtime, no secure timestamp, ...). Without it a
  # rejection is unactionable, so always fetch it before failing.
  submission_id="$(sed -n 's/^ *id: //p' <<<"${output}" | head -1)"
  if [ -n "${submission_id}" ]; then
    echo "notarize: fetching log for ${submission_id}" >&2
    xcrun notarytool log "${submission_id}" "${CREDENTIALS[@]}" >&2 || true
  fi
  echo "notarize: rejected" >&2
  exit 1
fi

xcrun stapler staple "${STAPLE_PATH}"
xcrun stapler validate "${STAPLE_PATH}" >&2
echo "notarize: stapled $(basename "${STAPLE_PATH}")" >&2

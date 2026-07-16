#!/usr/bin/env bash
# Architecture layering guard.
#
# Enforces the dependency-direction rules from .claude/ARCHITECTURE_PLAN.md:
#   1. ProGhosttyCore must not import SwiftUI (UI framework belongs in the App layer).
#   2. AppKit inside Core is only allowed in the rendering / view layer; window
#      chrome, settings, and pure-logic files must stay AppKit-free.
#
# Exits non-zero on violation so it can gate CI.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE_DIR="${ROOT_DIR}/Sources/ProGhosttyCore"
status=0

# Rule 1: no SwiftUI in Core.
if swiftui_hits="$(grep -rln "import SwiftUI" "${CORE_DIR}" --include='*.swift' 2>/dev/null)"; then
  echo "ARCH VIOLATION: ProGhosttyCore must not import SwiftUI:" >&2
  echo "${swiftui_hits}" | sed 's|^|  |' >&2
  status=1
fi

# Rule 2: AppKit in Core is allowed only under these paths (rendering / views).
# Everything else importing AppKit is a layering violation to review.
#
# Tracked exception: Settings/AppSettings.swift uses NSFont/NSFontManager for
# font-availability queries. Removing this coupling is deferred to phase 5 of
# ARCHITECTURE_PLAN.md (extract a FontCatalog service). Listed here so the guard
# still catches NEW violations without failing on this known debt.
allowed_appkit_regex='ProGhosttyCore/(TerminalCore/(Renderer/|PTY/|LibGhostty/|Mock/|TerminalModels\.swift|TerminalSurfaceStyle\.swift)|Settings/AppSettings\.swift)'
while IFS= read -r file; do
  [ -z "${file}" ] && continue
  rel="${file#"${ROOT_DIR}/Sources/"}"
  if ! echo "${rel}" | grep -qE "${allowed_appkit_regex}"; then
    echo "ARCH VIOLATION: unexpected 'import AppKit' in Core (not a rendering/view file): ${rel}" >&2
    status=1
  fi
done < <(grep -rln "import AppKit" "${CORE_DIR}" --include='*.swift' 2>/dev/null || true)

if [ "${status}" -eq 0 ]; then
  echo "Architecture guard: OK"
fi
exit "${status}"

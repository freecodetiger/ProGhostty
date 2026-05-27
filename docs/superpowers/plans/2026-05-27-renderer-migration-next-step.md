# Renderer Migration Next Step Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Simplify ProGhostty's terminal rendering chain so the app defaults to the highest-performance GPU path internally, preserves smooth pixel scrolling, and removes the transitional `MetalLive` path without exposing renderer choices to users.

**Architecture:** Keep `MetalDirect` as the primary live renderer and `GhosttyVTCellGrid` as the stable fallback. Move backend choice into a small renderer policy object, keep PTY I/O separate from output coalescing, then delete the old bitmap-presenter `MetalLive` path. The migration must preserve legacy settings compatibility so existing users with `"rendererMode": "metalLive"` do not fail to launch.

**Tech Stack:** Swift 6, Swift Testing, AppKit, Metal, existing ProGhostty terminal renderer diagnostics.

---

## Current Baseline

- Branch: `render`
- Current uncommitted baseline already includes `TerminalOutputCoordinator`.
- Verification already run:

```bash
swift test
```

Expected current output:

```text
Test run with 434 tests passed
```

Do not start by deleting renderer code. First checkpoint the output-coordinator extraction, then migrate renderer selection.

---

## File Structure

- Keep: `Sources/ProGhosttyCore/TerminalCore/PTY/TerminalOutputCoordinator.swift`
  - Owns PTY output coalescing and last-write-wins delayed flush behavior.
- Create: `Sources/ProGhosttyCore/TerminalCore/Renderer/TerminalRendererPolicy.swift`
  - Owns renderer-selection rules and fallback reasons.
- Modify: `Sources/ProGhosttyCore/TerminalCore/Renderer/TerminalRendererBackend.swift`
  - Keep common renderer data structures and diagnostics.
  - Remove `metalLive` from public renderer mode/backend enums after policy tests pass.
- Modify: `Sources/ProGhosttyCore/TerminalCore/PTY/PTYTerminalEngine.swift`
  - Remove direct renderer-selection logic from `PTYTerminalSurfaceRegistry`.
  - Stop storing `isMetalLiveAvailable`.
- Modify: `Sources/ProGhosttyCore/Settings/AppSettings.swift`
  - Decode legacy `"metalLive"` settings as `.auto`.
- Modify: `Sources/ProGhosttyApp/UI/AppText.swift`
  - Remove stale user-facing `Metal live` text.
- Delete: `Sources/ProGhosttyCore/TerminalCore/Renderer/MetalLiveRendererBackend.swift`
  - This file contains both `MetalLiveRendererBackend` and `MetalLiveFrameEncoder`.
- Modify: `Tests/ProGhosttyCoreTests/TerminalRendererBackendTests.swift`
  - Replace `MetalLive` tests with policy and direct/fallback tests.
- Modify: `Tests/ProGhosttyCoreTests/TerminalSurfaceTests.swift`
  - Replace surface-level `MetalLive` tests with `MetalDirect` and fallback coverage.
- Modify: `Tests/ProGhosttyCoreTests/AppSettingsTests.swift`
  - Add legacy settings migration coverage.

---

## Task 1: Checkpoint Output Coordinator Baseline

**Files:**
- Existing: `Sources/ProGhosttyCore/TerminalCore/PTY/TerminalOutputCoordinator.swift`
- Existing: `Sources/ProGhosttyCore/TerminalCore/PTY/PTYTerminalEngine.swift`
- Existing: `Tests/ProGhosttyCoreTests/TerminalSurfaceTests.swift`

- [ ] **Step 1: Verify the coordinator-specific tests**

Run:

```bash
swift test --filter TerminalSurfaceTests/terminalOutputCoordinatorKeepsLatestSnapshotDuringCoalescingWindow
swift test --filter TerminalSurfaceTests/liveCellGridCoalescesTransientCodexCursorMovesBeforePresentingOutput
```

Expected:

```text
passed
```

- [ ] **Step 2: Verify the full suite before renderer deletion**

Run:

```bash
swift test
```

Expected:

```text
Test run with 434 tests passed
```

- [ ] **Step 3: Commit only the coordinator baseline**

Run:

```bash
git add Sources/ProGhosttyCore/TerminalCore/PTY/TerminalOutputCoordinator.swift \
  Sources/ProGhosttyCore/TerminalCore/PTY/PTYTerminalEngine.swift \
  Tests/ProGhosttyCoreTests/TerminalSurfaceTests.swift
git commit -m "refactor: extract terminal output coordinator"
```

Expected: one commit containing only the output-coordinator extraction and tests. Leave `.superpowers/` untracked.

---

## Task 2: Extract Renderer Policy With Target GPU-First Rules

**Files:**
- Create: `Sources/ProGhosttyCore/TerminalCore/Renderer/TerminalRendererPolicy.swift`
- Modify: `Sources/ProGhosttyCore/TerminalCore/Renderer/TerminalRendererBackend.swift`
- Modify: `Sources/ProGhosttyCore/TerminalCore/PTY/PTYTerminalEngine.swift`
- Test: `Tests/ProGhosttyCoreTests/TerminalRendererBackendTests.swift`

- [ ] **Step 1: Write failing policy tests**

Add these tests to `TerminalRendererBackendTests`:

```swift
@Test func rendererPolicyResolvesAutoToDirectMetalWhenAvailable() {
  let selection = TerminalRendererPolicy.resolve(
    mode: .auto,
    hasFrame: true,
    isMetalDirectAvailable: true
  )

  #expect(selection.presentation == .liveCellGrid)
  #expect(selection.activeBackend == .metalDirect)
  #expect(selection.requestedBackend == nil)
  #expect(selection.fallbackReason == nil)
}

@Test func rendererPolicyFallsBackToCellGridWhenDirectMetalIsUnavailable() {
  let selection = TerminalRendererPolicy.resolve(
    mode: .auto,
    hasFrame: true,
    isMetalDirectAvailable: false
  )

  #expect(selection.presentation == .liveCellGrid)
  #expect(selection.activeBackend == .ghosttyVTCellGrid)
  #expect(selection.requestedBackend == nil)
  #expect(selection.fallbackReason == nil)
}

@Test func rendererPolicyResolvesDirectMetalRequestToCellGridFallback() {
  let selection = TerminalRendererPolicy.resolve(
    mode: .metalDirect,
    hasFrame: true,
    isMetalDirectAvailable: false
  )

  #expect(selection.presentation == .liveCellGrid)
  #expect(selection.activeBackend == .ghosttyVTCellGrid)
  #expect(selection.requestedBackend == .metalDirect)
  #expect(selection.fallbackReason == TerminalRendererDiagnostics.metalDirectUnavailableFallbackReason)
}
```

- [ ] **Step 2: Run the red tests**

Run:

```bash
swift test --filter TerminalRendererBackendTests/rendererPolicy
```

Expected: fail because `TerminalRendererPolicy` does not exist yet.

- [ ] **Step 3: Implement the policy type**

Create `TerminalRendererPolicy.swift`:

```swift
import Foundation

public enum TerminalRendererPolicy {
  public static func resolve(
    mode: TerminalRendererMode,
    hasFrame: Bool,
    isMetalDirectAvailable: Bool
  ) -> TerminalRendererBackendSelection {
    switch mode {
    case .ghosttyVTTextFallback:
      return TerminalRendererBackendSelection(
        presentation: .textFallback,
        activeBackend: .ghosttyVTTextFallback,
        requestedBackend: nil,
        fallbackReason: nil
      )
    case .metalDirect:
      guard hasFrame else {
        return TerminalRendererBackendSelection(
          presentation: .textFallback,
          activeBackend: .ghosttyVTTextFallback,
          requestedBackend: .metalDirect,
          fallbackReason: nil
        )
      }
      return TerminalRendererBackendSelection(
        presentation: .liveCellGrid,
        activeBackend: isMetalDirectAvailable ? .metalDirect : .ghosttyVTCellGrid,
        requestedBackend: .metalDirect,
        fallbackReason: isMetalDirectAvailable ? nil : TerminalRendererDiagnostics.metalDirectUnavailableFallbackReason
      )
    case .ghosttyVTCellGrid:
      return TerminalRendererBackendSelection(
        presentation: hasFrame ? .liveCellGrid : .textFallback,
        activeBackend: hasFrame ? .ghosttyVTCellGrid : .ghosttyVTTextFallback,
        requestedBackend: nil,
        fallbackReason: nil
      )
    case .auto:
      guard hasFrame else {
        return TerminalRendererBackendSelection(
          presentation: .textFallback,
          activeBackend: .ghosttyVTTextFallback,
          requestedBackend: nil,
          fallbackReason: nil
        )
      }
      return TerminalRendererBackendSelection(
        presentation: .liveCellGrid,
        activeBackend: isMetalDirectAvailable ? .metalDirect : .ghosttyVTCellGrid,
        requestedBackend: nil,
        fallbackReason: nil
      )
    }
  }
}
```

At this point `TerminalRendererMode.metalLive` still exists, so the switch will not compile until Task 3 removes that case. If implementing Task 2 independently, temporarily add this branch and remove it in Task 3:

```swift
    case .metalLive:
      return resolve(
        mode: .auto,
        hasFrame: hasFrame,
        isMetalDirectAvailable: isMetalDirectAvailable
      )
```

- [ ] **Step 4: Route existing selection through the policy**

Replace `TerminalRendererBackendSelection.resolve(...)` body in `TerminalRendererBackend.swift` with:

```swift
  public static func resolve(
    mode: TerminalRendererMode,
    hasFrame: Bool,
    isMetalLiveAvailable: Bool = false,
    isMetalDirectAvailable: Bool = false
  ) -> TerminalRendererBackendSelection {
    TerminalRendererPolicy.resolve(
      mode: mode,
      hasFrame: hasFrame,
      isMetalDirectAvailable: isMetalDirectAvailable
    )
  }
```

This keeps old call sites compiling while centralizing the decision. The unused `isMetalLiveAvailable` parameter is removed in Task 3.

- [ ] **Step 5: Run policy tests**

Run:

```bash
swift test --filter TerminalRendererBackendTests/rendererPolicy
```

Expected: policy tests pass.

- [ ] **Step 6: Commit policy extraction**

Run:

```bash
git add Sources/ProGhosttyCore/TerminalCore/Renderer/TerminalRendererPolicy.swift \
  Sources/ProGhosttyCore/TerminalCore/Renderer/TerminalRendererBackend.swift \
  Tests/ProGhosttyCoreTests/TerminalRendererBackendTests.swift
git commit -m "refactor: centralize terminal renderer policy"
```

---

## Task 3: Remove MetalLive From the Runtime Model

**Files:**
- Modify: `Sources/ProGhosttyCore/TerminalCore/Renderer/TerminalRendererBackend.swift`
- Modify: `Sources/ProGhosttyCore/TerminalCore/PTY/PTYTerminalEngine.swift`
- Delete: `Sources/ProGhosttyCore/TerminalCore/Renderer/MetalLiveRendererBackend.swift`
- Test: `Tests/ProGhosttyCoreTests/TerminalRendererBackendTests.swift`
- Test: `Tests/ProGhosttyCoreTests/TerminalSurfaceTests.swift`

- [ ] **Step 1: Replace MetalLive tests with target behavior**

Remove tests whose names include `metalLive`. Add this surface test:

```swift
@MainActor @Test func autoRendererFallsBackToCellGridWhenDirectMetalUnavailable() throws {
  let registry = PTYTerminalSurfaceRegistry(isMetalDirectAvailable: false)
  registry.applyRendererOptions(TerminalRendererOptions(mode: .auto))
  let session = TerminalSessionID()
  registry.createSurface(session: session)
  let bridge = try bridgeWithFrame(rows: ["prompt"], cols: 12)

  registry.render(bridge, session: session)
  registry.flushPendingRenderers()

  let surfaceView = try #require(registry.viewForSession(session) as? PTYTerminalSurfaceView)
  let diagnostics = try #require(registry.rendererDiagnostics(for: session))
  #expect(surfaceView.liveGridView is MetalDirectRendererView == false)
  #expect(diagnostics.backend == .ghosttyVTCellGrid)
}
```

- [ ] **Step 2: Run the red renderer/surface tests**

Run:

```bash
swift test --filter TerminalRendererBackendTests
swift test --filter TerminalSurfaceTests
```

Expected: fail until `metalLive` references are removed or rewritten.

- [ ] **Step 3: Delete public MetalLive cases**

In `TerminalRendererBackend.swift`, remove:

```swift
case metalLive
```

from `TerminalRendererMode`, and remove:

```swift
case metalLive = "MetalLive"
```

from `TerminalRendererBackendKind`.

Also delete:

```swift
public static let metalLiveUnavailableFallbackReason = "Metal live renderer unavailable; using AppKit cell grid"
```

- [ ] **Step 4: Remove MetalLive availability and factory branches**

In `PTYTerminalSurfaceRegistry`, remove stored state and initializer arguments for `isMetalLiveAvailable`.

Change selection calls from:

```swift
TerminalRendererBackendSelection.resolve(
  mode: rendererOptions.mode,
  hasFrame: true,
  isMetalLiveAvailable: isMetalLiveAvailable,
  isMetalDirectAvailable: isMetalDirectAvailable
)
```

to:

```swift
TerminalRendererPolicy.resolve(
  mode: rendererOptions.mode,
  hasFrame: true,
  isMetalDirectAvailable: isMetalDirectAvailable
)
```

Remove the `switch` branch:

```swift
case .metalLive:
  return MetalLiveRendererBackend(options: rendererOptions)
```

- [ ] **Step 5: Delete MetalLive implementation**

Delete:

```bash
Sources/ProGhosttyCore/TerminalCore/Renderer/MetalLiveRendererBackend.swift
```

Run:

```bash
rg -n "MetalLive|metalLive|isMetalLiveAvailable" Sources Tests
```

Expected: no matches outside this plan or historical docs.

- [ ] **Step 6: Run renderer and surface tests**

Run:

```bash
swift test --filter TerminalRendererBackendTests
swift test --filter TerminalSurfaceTests
```

Expected: all tests pass.

- [ ] **Step 7: Commit runtime deletion**

Run:

```bash
git add Sources/ProGhosttyCore/TerminalCore/Renderer/TerminalRendererBackend.swift \
  Sources/ProGhosttyCore/TerminalCore/PTY/PTYTerminalEngine.swift \
  Tests/ProGhosttyCoreTests/TerminalRendererBackendTests.swift \
  Tests/ProGhosttyCoreTests/TerminalSurfaceTests.swift
git add -u Sources/ProGhosttyCore/TerminalCore/Renderer/MetalLiveRendererBackend.swift
git commit -m "refactor: remove metal live renderer path"
```

---

## Task 4: Preserve Legacy Settings Compatibility

**Files:**
- Modify: `Sources/ProGhosttyCore/Settings/AppSettings.swift`
- Modify: `Sources/ProGhosttyApp/UI/AppText.swift`
- Test: `Tests/ProGhosttyCoreTests/AppSettingsTests.swift`

- [ ] **Step 1: Add a failing legacy decode test**

Add this test to `AppSettingsTests`:

```swift
@Test func decodesLegacyMetalLiveRendererSettingAsAuto() throws {
  let legacy = """
    {
      "rendererMode": "metalLive",
      "defaultShell": "/bin/zsh",
      "fontFamily": "Menlo",
      "fontSize": 14,
      "themeName": "dark"
    }
    """.data(using: .utf8)!

  let settings = try JSONDecoder().decode(AppSettings.self, from: legacy)

  #expect(settings.rendererMode == .auto)
}
```

- [ ] **Step 2: Run the red test**

Run:

```bash
swift test --filter AppSettingsTests/decodesLegacyMetalLiveRendererSettingAsAuto
```

Expected: fail until `AppSettings` decodes renderer mode from a raw string.

- [ ] **Step 3: Decode renderer mode through a migration helper**

In `AppSettings.init(from:)`, replace:

```swift
rendererMode = try container.decodeIfPresent(TerminalRendererMode.self, forKey: .rendererMode) ?? Self.defaults.rendererMode
```

with:

```swift
let rawRendererMode = try container.decodeIfPresent(String.self, forKey: .rendererMode)
rendererMode = TerminalRendererMode(rawValue: rawRendererMode ?? "") ?? Self.defaults.rendererMode
```

This maps removed or unknown renderer modes to `.auto`.

- [ ] **Step 4: Remove stale MetalLive UI copy**

Delete from `AppText.swift`:

```swift
var rendererMetalLive: String { text("Metal live", "Metal 实时渲染") }
```

- [ ] **Step 5: Run settings tests**

Run:

```bash
swift test --filter AppSettingsTests
```

Expected: all settings tests pass.

- [ ] **Step 6: Commit settings migration**

Run:

```bash
git add Sources/ProGhosttyCore/Settings/AppSettings.swift \
  Sources/ProGhosttyApp/UI/AppText.swift \
  Tests/ProGhosttyCoreTests/AppSettingsTests.swift
git commit -m "fix: migrate legacy metal live renderer setting"
```

---

## Task 5: Move Surface Registry Out of PTYTerminalEngine

**Files:**
- Create: `Sources/ProGhosttyCore/TerminalCore/PTY/PTYTerminalSurfaceRegistry.swift`
- Modify: `Sources/ProGhosttyCore/TerminalCore/PTY/PTYTerminalEngine.swift`
- Test: `Tests/ProGhosttyCoreTests/TerminalSurfaceTests.swift`
- Test: `Tests/ProGhosttyCoreTests/PTYLaunchTests.swift`

- [ ] **Step 1: Move the type without behavior changes**

Move this type from `PTYTerminalEngine.swift` into the new file:

```swift
public final class PTYTerminalSurfaceRegistry: TerminalSurfaceRegistry
```

Keep the nested `SurfaceState` private inside the moved file.

- [ ] **Step 2: Run surface and PTY tests**

Run:

```bash
swift test --filter TerminalSurfaceTests
swift test --filter PTYLaunchTests
```

Expected: pass with no behavior change.

- [ ] **Step 3: Commit the file split**

Run:

```bash
git add Sources/ProGhosttyCore/TerminalCore/PTY/PTYTerminalSurfaceRegistry.swift \
  Sources/ProGhosttyCore/TerminalCore/PTY/PTYTerminalEngine.swift
git commit -m "refactor: split terminal surface registry"
```

---

## Task 6: Final Verification and Relaunch

**Files:**
- No new source edits unless verification exposes failures.

- [ ] **Step 1: Confirm removed path is gone**

Run:

```bash
rg -n "MetalLive|metalLive|isMetalLiveAvailable" Sources Tests
```

Expected: no matches.

- [ ] **Step 2: Run full test suite**

Run:

```bash
swift test
```

Expected:

```text
Test run with all tests passed
```

- [ ] **Step 3: Rebuild app bundle**

Run:

```bash
scripts/build-app-bundle.sh debug
```

Expected: debug app bundle builds successfully.

- [ ] **Step 4: Restart ProGhostty from the debug bundle**

Run:

```bash
osascript -e 'tell application "ProGhostty" to quit'
open /Users/zpc/projects/proghostty/.build/arm64-apple-macosx/debug/ProGhostty.app
```

Expected: app launches on `MetalDirect` when available and falls back to `GhosttyVTCellGrid` when not available, without exposing a new renderer choice to users.

---

## Non-Goals For This Migration

- Do not redesign glyph atlas, shader pipeline, or text shaping in this migration.
- Do not remove pixel-scroll behavior.
- Do not remove `GhosttyVTCellGrid`; it remains the stability fallback.
- Do not add user-facing renderer selection. Diagnostics can keep reporting backend and fallback reason.
- Do not push to `main`; keep this work on the `render` branch.

## Success Criteria

- `MetalDirect` is the only GPU live-renderer path.
- `GhosttyVTCellGrid` is the only live-renderer fallback.
- `MetalLiveRendererBackend` no longer exists in `Sources`.
- Legacy `"rendererMode": "metalLive"` settings decode as `.auto`.
- `PTYTerminalEngine.swift` no longer owns renderer-policy logic.
- Full `swift test` passes.
- The app rebuilds and relaunches from the debug bundle.

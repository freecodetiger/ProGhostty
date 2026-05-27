# Renderer Path Simplification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Simplify the terminal rendering chain so ProGhostty defaults to a GPU-first path without exposing renderer choice to users, while keeping long-history Codex sessions stable and preserving the current pixel-scroll and fallback behavior.

**Architecture:** Keep `MetalDirect` as the primary live renderer and `GhosttyVTCellGrid` as the final fallback. Remove the `MetalLive` bitmap-presenter path and split `PTYTerminalEngine` into smaller coordination pieces so PTY I/O, output coalescing, and surface presentation are no longer coupled in one class. The renderer-selection policy stays explicit and internal, but the live rendering path becomes shorter, easier to reason about, and less dependent on transitional code.

**Tech Stack:** Swift 6, Swift Testing, AppKit, Metal, CoreText, existing ProGhostty renderer diagnostics.

---

## File Structure

- Create `Sources/ProGhosttyCore/TerminalCore/PTY/TerminalOutputCoordinator.swift`
  - Owns output snapshot coalescing, transient Codex frame suppression, and flush scheduling.
- Create `Sources/ProGhosttyCore/TerminalCore/Renderer/TerminalRendererPolicy.swift`
  - Owns renderer selection and fallback policy so `PTYTerminalEngine` and the surface registry do not need to know backend details.
- Modify `Sources/ProGhosttyCore/TerminalCore/PTY/PTYTerminalEngine.swift`
  - Remove output-render buffering and delegate to the new coordinator.
- Modify `Sources/ProGhosttyCore/TerminalCore/PTY/PTYTerminalEngine.swift`
  - Keep PTY spawn/read/write/resize responsibilities only.
- Modify `Sources/ProGhosttyCore/TerminalCore/PTY/PTYTerminalEngine.swift`
  - Route render snapshots through the new policy and coordinator.
- Modify `Sources/ProGhosttyCore/TerminalCore/Renderer/TerminalRendererBackend.swift`
  - Remove `metalLive` from the public mode set and collapse selection rules to `metalDirect`, `ghosttyVTCellGrid`, and text fallback.
- Modify `Sources/ProGhosttyCore/TerminalCore/Renderer/MetalLiveRendererBackend.swift`
  - Delete after replacement tests pass.
- Modify `Sources/ProGhosttyCore/TerminalCore/Renderer/MetalLiveFrameEncoder.swift`
  - Delete after replacement tests pass.
- Modify `Sources/ProGhosttyApp/UI/AppText.swift`
  - Remove any user-facing text that refers to the `MetalLive` mode.
- Modify `Tests/ProGhosttyCoreTests/TerminalRendererBackendTests.swift`
  - Update backend-selection tests and add removal coverage.
- Modify `Tests/ProGhosttyCoreTests/TerminalSurfaceTests.swift`
  - Add coverage for the extracted output coordinator and stable direct-render activation.
- Modify `Tests/ProGhosttyCoreTests/PTYLaunchTests.swift`
  - Add PTY lifecycle coverage if output coordination moves enough logic out of the session manager.

---

## Task 1: Extract Output Coalescing Out of PTYTerminalEngine

**Files:**
- Create: `Sources/ProGhosttyCore/TerminalCore/PTY/TerminalOutputCoordinator.swift`
- Modify: `Sources/ProGhosttyCore/TerminalCore/PTY/PTYTerminalEngine.swift`
- Test: `Tests/ProGhosttyCoreTests/TerminalSurfaceTests.swift`

- [ ] **Step 1: Write the failing test**

Add a test that proves transient Codex-style bursts are still coalesced after the output logic moves out of `PTYTerminalEngine`:

```swift
@MainActor @Test func outputCoordinatorCoalescesTransientCodexFramesBeforePresentingOutput() async throws {
  let registry = PTYTerminalSurfaceRegistry()
  registry.applyRendererOptions(TerminalRendererOptions(mode: .ghosttyVTCellGrid))
  let session = TerminalSessionID()
  registry.createSurface(session: session)
  let bridge = try codexLikeBridge(suggestions: [
    "/resume       resume a previous session",
    "/review       review current changes",
  ])

  registry.render(bridge, session: session)
  registry.flushPendingRenderers()
  let surfaceView = try #require(registry.viewForSession(session) as? PTYTerminalSurfaceView)
  let initialCursor = try #require(surfaceView.liveGridView.cursorCellRect)

  bridge.write(Data("\u{1B}[8;1H".utf8))
  let transientSnapshot = ResizeRenderSnapshot.capture(from: bridge)
  registry.renderOutput(transientSnapshot, bridge: bridge, session: session, wasPinnedToBottom: true)
  try await Task.sleep(nanoseconds: 1_000_000)

  #expect(surfaceView.liveGridView.cursorCellRect == initialCursor)
}
```

- [ ] **Step 2: Run the red test**

Run:

```bash
swift test --filter TerminalSurfaceTests/outputCoordinatorCoalescesTransientCodexFramesBeforePresentingOutput
```

Expected: fail until the output coordinator owns the coalescing window.

- [ ] **Step 3: Implement the coordinator**

Move the following responsibilities out of `PTYTerminalEngine`:

- snapshot buffering for `renderOutput`
- delayed flush scheduling
- last-write-wins replacement for transient Codex frames
- explicit flush support for `flushPendingRenderers`

Keep the coordinator small and single-purpose. It should only know how to buffer `ResizeRenderSnapshot` values and forward them to the existing surface registry.

- [ ] **Step 4: Run the green test**

Run:

```bash
swift test --filter TerminalSurfaceTests/outputCoordinatorCoalescesTransientCodexFramesBeforePresentingOutput
```

Expected: pass.

---

## Task 2: Remove MetalLive From the Public Rendering Model

**Files:**
- Modify: `Sources/ProGhosttyCore/TerminalCore/Renderer/TerminalRendererBackend.swift`
- Modify: `Sources/ProGhosttyCore/TerminalCore/Renderer/MetalLiveRendererBackend.swift`
- Modify: `Sources/ProGhosttyCore/TerminalCore/Renderer/MetalLiveFrameEncoder.swift`
- Modify: `Sources/ProGhosttyApp/UI/AppText.swift`
- Modify: `Tests/ProGhosttyCoreTests/TerminalRendererBackendTests.swift`
- Modify: `Tests/ProGhosttyCoreTests/TerminalSurfaceTests.swift`

- [ ] **Step 1: Write the failing selection tests**

Update tests to reflect the new policy:

```swift
@Test func rendererBackendSelectionResolvesDirectMetalWhenAvailable() {
  let selection = TerminalRendererBackendSelection.resolve(
    mode: .metalDirect,
    hasFrame: true,
    isMetalLiveAvailable: true,
    isMetalDirectAvailable: true
  )

  #expect(selection.presentation == .liveCellGrid)
  #expect(selection.activeBackend == .metalDirect)
  #expect(selection.requestedBackend == .metalDirect)
  #expect(selection.fallbackReason == nil)
}

@Test func rendererBackendSelectionFallsBackFromDirectMetalWhenUnavailable() {
  let selection = TerminalRendererBackendSelection.resolve(
    mode: .metalDirect,
    hasFrame: true,
    isMetalLiveAvailable: false,
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
swift test --filter TerminalRendererBackendTests/rendererBackendSelection
```

Expected: fail until `metalLive` is removed from the selection model and `metalDirect` is the only GPU mode.

- [ ] **Step 3: Remove the MetalLive mode**

Delete `metalLive` from:

- `TerminalRendererMode`
- `TerminalRendererBackendKind`
- user-facing renderer text
- selection paths in `TerminalRendererBackendSelection.resolve(...)`
- any tests that describe MetalLive behavior

Remove `MetalLiveRendererBackend` and `MetalLiveFrameEncoder` after the tests no longer reference them.

- [ ] **Step 4: Update surface creation**

Ensure `PTYTerminalSurfaceRegistry` only creates:

- `MetalDirectRendererBackend` when available and selected
- `GhosttyVTCellGridRendererBackend` otherwise
- `GhosttyVTTextRendererBackend` for text fallback

Do not keep an intermediate bitmap-presenter branch.

- [ ] **Step 5: Run the green selection tests**

Run:

```bash
swift test --filter TerminalRendererBackendTests/rendererBackendSelection
swift test --filter TerminalSurfaceTests
```

Expected: all selection and surface tests pass with `metalLive` removed.

---

## Task 3: Split Renderer Policy Out of PTYTerminalEngine

**Files:**
- Create: `Sources/ProGhosttyCore/TerminalCore/Renderer/TerminalRendererPolicy.swift`
- Modify: `Sources/ProGhosttyCore/TerminalCore/PTY/PTYTerminalEngine.swift`
- Modify: `Sources/ProGhosttyCore/TerminalCore/Renderer/TerminalRendererBackend.swift`
- Test: `Tests/ProGhosttyCoreTests/TerminalRendererBackendTests.swift`

- [ ] **Step 1: Write the failing policy test**

Add a test that asserts renderer selection can be resolved without constructing a surface:

```swift
@Test func rendererPolicyResolvesDirectMetalWithoutSurfaceCreation() {
  let selection = TerminalRendererPolicy.resolve(
    mode: .auto,
    hasFrame: true,
    isMetalLiveAvailable: false,
    isMetalDirectAvailable: true
  )

  #expect(selection.presentation == .liveCellGrid)
  #expect(selection.activeBackend == .metalDirect)
}
```

- [ ] **Step 2: Run the red test**

Run:

```bash
swift test --filter TerminalRendererBackendTests/rendererPolicyResolvesDirectMetalWithoutSurfaceCreation
```

Expected: fail until the policy is separated from the PTY plumbing.

- [ ] **Step 3: Implement the policy type**

Move the selection logic out of the session manager and surface registry path. The PTY layer should call the policy, not duplicate backend decisions or fallback strings.

- [ ] **Step 4: Run the green test**

Run:

```bash
swift test --filter TerminalRendererBackendTests/rendererPolicyResolvesDirectMetalWithoutSurfaceCreation
```

Expected: pass.

---

## Task 4: Cleanup and Verification

**Files:**
- Modify: `Sources/ProGhosttyCore/TerminalCore/PTY/PTYTerminalEngine.swift`
- Modify: `Sources/ProGhosttyCore/TerminalCore/Renderer/TerminalRendererBackend.swift`
- Modify: `Sources/ProGhosttyApp/UI/AppText.swift`
- Delete: `Sources/ProGhosttyCore/TerminalCore/Renderer/MetalLiveRendererBackend.swift`
- Delete: `Sources/ProGhosttyCore/TerminalCore/Renderer/MetalLiveFrameEncoder.swift`
- Test: `Tests/ProGhosttyCoreTests/TerminalRendererBackendTests.swift`
- Test: `Tests/ProGhosttyCoreTests/TerminalSurfaceTests.swift`

- [ ] **Step 1: Remove dead imports and dead branches**

Delete any stale `metalLive` references left behind by the earlier tasks, including dead diagnostics text and now-unused initialization paths.

- [ ] **Step 2: Run the full renderer and surface test sets**

Run:

```bash
swift test --filter TerminalRendererBackendTests
swift test --filter TerminalSurfaceTests
```

Expected: all tests pass and no references to `MetalLive` remain in the build.

- [ ] **Step 3: Run the full suite**

Run:

```bash
swift test
```

Expected: full green test run.

- [ ] **Step 4: Rebuild and relaunch the app**

Run:

```bash
scripts/build-app-bundle.sh debug
osascript -e 'tell application "ProGhostty" to quit'
open /Users/zpc/projects/proghostty/.build/arm64-apple-macosx/debug/ProGhostty.app
```

Expected: the debug app launches from the simplified renderer path.

---

## Coverage Check

- PTY output coalescing: Task 1
- removal of `MetalLive`: Task 2
- policy extraction: Task 3
- cleanup and verification: Task 4

## Immediate Next Step

Start with Task 1, because it preserves the current cursor-stability fix while removing `PTYTerminalEngine` from the hot-path buffering job.

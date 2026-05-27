# GPU-First Renderer Rework Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make ProGhostty default to a GPU-first renderer that keeps long-history Codex sessions stable: no cursor drift, no input shake, no visible top-to-bottom resize churn, and no user-facing renderer choice.

**Architecture:** Keep `libghostty-vt` authoritative for terminal semantics. Treat the CPU as the source of truth for PTY, scrollback, selection, link detection, resize intent, and pixel-scroll state, while the GPU owns retained presentation of cells, overlays, and the final draw/present path. The renderer should submit compact generation-tagged scene updates and only present the newest complete frame.

**Tech Stack:** Swift 6, Swift Testing, AppKit, Metal, MetalKit, CoreText, existing ProGhostty renderer diagnostics.

**Current baseline:** The foundation is already in place:

- generation contract is wired through render snapshots and transactions
- cursor overlay is separated from text redraw
- pixel scroll is composited at presentation time
- resize staging uses latest-wins swap behavior
- link hover coordinates stay aligned with pixel scroll
- the full test suite is currently green

**What is still missing:** the renderer still rebuilds too much on the CPU. The next step is a true retained GPU scene so redraws become incremental updates instead of frame reconstruction.

---

## File Structure

- Modify `Sources/ProGhosttyCore/TerminalCore/Renderer/MetalDirectRendererBackend.swift`
  - Own presentation scheduling, generation acceptance, resize staging, diagnostics, and fallback policy.
- Modify `Sources/ProGhosttyCore/TerminalCore/Renderer/MetalDirectRenderEngine.swift`
  - Stop treating each frame as a fresh CPU-built scene; move toward retained GPU state and incremental uploads.
- Modify `Sources/ProGhosttyCore/TerminalCore/Renderer/MetalCellInstanceBuffer.swift`
  - Store and update cell instance data as retained GPU-backed scene state, not just a dirty-range helper.
- Modify `Sources/ProGhosttyCore/TerminalCore/Renderer/MetalOverlayBuffer.swift`
  - Keep cursor, selection, link hover, and marked text overlays generation-aware and independently updatable.
- Modify `Sources/ProGhosttyCore/TerminalCore/Renderer/MetalGlyphAtlas.swift`
  - Make glyph uploads incremental and cache-safe under long histories and font/scale changes.
- Modify `Sources/ProGhosttyCore/TerminalCore/Renderer/TerminalRendererBackend.swift`
  - Keep backend choice internal, preserve fallback metadata, and expose diagnostics for GPU-first behavior.
- Modify `Sources/ProGhosttyCore/TerminalCore/PTY/PTYTerminalEngine.swift`
  - Keep surface selection, viewport updates, and resize hooks aligned with the GPU-first backend.
- Modify `Tests/ProGhosttyCoreTests/TerminalRendererBackendTests.swift`
  - Cover retained scene updates, stale completion rejection, and diagnostics.
- Modify `Tests/ProGhosttyCoreTests/TerminalSurfaceTests.swift`
  - Cover backend selection, resize stability, and pixel-scroll parity.
- Modify `Tests/ProGhosttyCoreTests/TerminalResizeCoordinatorTests.swift`
  - Cover resize staging and atomic swap behavior if the backend path changes again.

---

## Task 1: Build a Retained GPU Scene

**Files:**
- Modify: `Sources/ProGhosttyCore/TerminalCore/Renderer/MetalDirectRenderEngine.swift`
- Modify: `Sources/ProGhosttyCore/TerminalCore/Renderer/MetalCellInstanceBuffer.swift`
- Modify: `Sources/ProGhosttyCore/TerminalCore/Renderer/MetalOverlayBuffer.swift`
- Modify: `Sources/ProGhosttyCore/TerminalCore/Renderer/MetalGlyphAtlas.swift`
- Test: `Tests/ProGhosttyCoreTests/TerminalRendererBackendTests.swift`

- [ ] **Step 1: Write the failing tests**

Add tests that prove the renderer keeps a retained scene and updates only dirty regions after the first upload:

```swift
@Test func metalDirectRendererBackendReusesRetainedCellSceneAfterInitialFrame() {
  let backend = MetalDirectRendererBackend()

  backend.render(TerminalRenderFrame(frame: frame(rows: ["one", "two"], cols: 8, cursorX: 0, cursorY: 0)))
  backend.flushPendingFrame()
  backend.render(TerminalRenderFrame(frame: frame(rows: ["one", "TWO"], cols: 8, cursorX: 0, cursorY: 0)))
  backend.flushPendingFrame()

  #expect(backend.diagnostics.backend == .metalDirect)
  #expect(backend.diagnostics.metalDirectUploadedCellCount < 16)
  #expect(backend.diagnostics.metalDirectDrawPassCount == 2)
}
```

```swift
@Test func metalDirectRendererBackendUpdatesCursorWithoutRebuildingTextScene() {
  let backend = MetalDirectRendererBackend()

  backend.render(TerminalRenderFrame(frame: frame(rows: ["prompt"], cols: 8, cursorX: 1, cursorY: 0)))
  backend.flushPendingFrame()
  backend.setFocused(true)
  backend.render(TerminalRenderFrame(frame: frame(rows: ["prompt"], cols: 8, cursorX: 2, cursorY: 0)))
  backend.flushPendingFrame()

  #expect(backend.diagnostics.metalDirectUploadedCellCount < 8)
  #expect(backend.diagnostics.metalDirectDrawPassCount == 2)
}
```

- [ ] **Step 2: Run the red tests**

Run:

```bash
swift test --filter TerminalRendererBackendTests/metalDirectRendererBackendReusesRetainedCellSceneAfterInitialFrame
swift test --filter TerminalRendererBackendTests/metalDirectRendererBackendUpdatesCursorWithoutRebuildingTextScene
```

Expected: fail because the current engine still treats too much of the frame as rebuilt CPU-side.

- [ ] **Step 3: Implement retained scene storage**

Introduce persistent scene state for:

- cell instances
- style/color attributes
- glyph atlas texture slices
- cursor and overlay primitives

Update only the dirty rows and overlay regions on subsequent frames. Keep full rebuilds only for size changes, palette changes, font changes, or other invalidation events.

- [ ] **Step 4: Run the green tests**

Run:

```bash
swift test --filter TerminalRendererBackendTests/metalDirectRendererBackendReusesRetainedCellSceneAfterInitialFrame
swift test --filter TerminalRendererBackendTests/metalDirectRendererBackendUpdatesCursorWithoutRebuildingTextScene
```

Expected: pass.

---

## Task 2: Make Presentation Latest-Wins

**Files:**
- Modify: `Sources/ProGhosttyCore/TerminalCore/Renderer/MetalDirectRendererBackend.swift`
- Modify: `Sources/ProGhosttyCore/TerminalCore/Renderer/MetalDirectRenderEngine.swift`
- Test: `Tests/ProGhosttyCoreTests/TerminalRendererBackendTests.swift`

- [ ] **Step 1: Write the failing tests**

Add tests that prove stale GPU completions cannot present older frames after a newer generation has been accepted:

```swift
@MainActor @Test func metalDirectRendererBackendDropsStaleCompletionAfterNewerGeneration() {
  let backend = MetalDirectRendererBackend()

  backend.render(TerminalRenderFrame(frame: frame(rows: ["old"], cols: 8, cursorX: 0, cursorY: 0), generation: 41))
  backend.render(TerminalRenderFrame(frame: frame(rows: ["new"], cols: 8, cursorX: 0, cursorY: 0), generation: 42))
  backend.flushPendingFrame()

  #expect(backend.diagnostics.metalDirectLatestPresentedGeneration == 42)
  #expect(backend.diagnostics.metalDirectStaleCompletionCount >= 1)
}
```

- [ ] **Step 2: Run the red test**

Run:

```bash
swift test --filter TerminalRendererBackendTests/metalDirectRendererBackendDropsStaleCompletionAfterNewerGeneration
```

Expected: fail because the scheduler still needs stronger generation enforcement at the present boundary.

- [ ] **Step 3: Implement latest-wins scheduling**

Keep a single pending render transaction, reject stale completions, and only allow the newest complete generation to reach presentation. The command-buffer completion handler must not be able to overwrite a newer accepted frame.

- [ ] **Step 4: Run the green test**

Run:

```bash
swift test --filter TerminalRendererBackendTests/metalDirectRendererBackendDropsStaleCompletionAfterNewerGeneration
```

Expected: pass.

---

## Task 3: Keep Resize Atomic

**Files:**
- Modify: `Sources/ProGhosttyCore/TerminalCore/Renderer/MetalDirectRendererBackend.swift`
- Modify: `Sources/ProGhosttyCore/TerminalCore/PTY/PTYTerminalEngine.swift`
- Test: `Tests/ProGhosttyCoreTests/TerminalSurfaceTests.swift`
- Test: `Tests/ProGhosttyCoreTests/TerminalResizeCoordinatorTests.swift`

- [ ] **Step 1: Write the failing tests**

Add tests that prove resize does not expose intermediate frames and does not regress pixel scroll:

```swift
@MainActor @Test func metalDirectRendererBackendStagesResizeUntilDiagnosticsComplete() throws {
  let registry = PTYTerminalSurfaceRegistry(isMetalDirectAvailable: true)
  registry.applyRendererOptions(TerminalRendererOptions(mode: .metalDirect))
  let session = TerminalSessionID()
  registry.createSurface(session: session)
  let bridge = try GhosttyVTBridge(cols: 12, rows: 2, maxScrollback: 100)

  bridge.write(Data("prompt".utf8))
  registry.render(bridge, session: session)
  registry.flushPendingRenderers()

  bridge.resize(cols: 20, rows: 4)
  registry.markResizePending(session: session)
  let snapshot = ResizeRenderSnapshot.capture(from: bridge)
  registry.render(snapshot, bridge: bridge, session: session)

  let diagnostics = try #require(registry.rendererDiagnostics(for: session))
  #expect(diagnostics.backend == .metalDirect)
  #expect(diagnostics.pendingResize)

  registry.applyResizeDiagnostics(TerminalResizeDiagnostics(totalDuration: 0, vtDuration: 0, snapshotDuration: 0), session: session)
  registry.flushPendingRenderers()

  let after = try #require(registry.rendererDiagnostics(for: session))
  #expect(after.pendingResize == false)
}
```

```swift
@Test func resizeSwapDoesNotInvalidatePixelScrollTranslation() {
  #expect(PTYGridView.visualScrollTranslationY(for: TerminalViewport(visualOffsetY: 5)) == 0)
  #expect(PTYGridView.visualScrollTranslationY(for: TerminalViewport(visualOffsetY: -5)) == 0)
}
```

- [ ] **Step 2: Run the red tests**

Run:

```bash
swift test --filter TerminalSurfaceTests/metalDirectRendererBackendStagesResizeUntilDiagnosticsComplete
swift test --filter TerminalResizeCoordinatorTests
```

Expected: fail if resize staging still leaks intermediate scene updates or if the swap logic is not fully atomic.

- [ ] **Step 3: Implement atomic resize swap**

Keep the old scene visible until the new size is fully prepared. Only swap the retained GPU scene after the new render frame, diagnostics, and viewport state are ready together.

- [ ] **Step 4: Run the green tests**

Run:

```bash
swift test --filter TerminalSurfaceTests
swift test --filter TerminalResizeCoordinatorTests
```

Expected: pass.

---

## Task 4: Make Diagnostics Useful During Fallback

**Files:**
- Modify: `Sources/ProGhosttyCore/TerminalCore/Renderer/TerminalRendererBackend.swift`
- Modify: `Sources/ProGhosttyCore/TerminalCore/Renderer/MetalDirectRendererBackend.swift`
- Modify: `Sources/ProGhosttyApp/DebugLog.swift`
- Test: `Tests/ProGhosttyCoreTests/TerminalRendererBackendTests.swift`

- [ ] **Step 1: Write the failing tests**

Add tests that prove fallback remains internal and visible in diagnostics:

```swift
@Test func rendererDiagnosticsExposeRequestedBackendActiveBackendAndFallbackReason() {
  var diagnostics = TerminalRendererDiagnostics(backend: .ghosttyVTCellGrid)
  diagnostics.requestedBackend = .metalDirect
  diagnostics.backendFallbackReason = TerminalRendererDiagnostics.metalDirectUnavailableFallbackReason

  #expect(diagnostics.requestedBackend == .metalDirect)
  #expect(diagnostics.backend == .ghosttyVTCellGrid)
  #expect(diagnostics.backendFallbackReason == TerminalRendererDiagnostics.metalDirectUnavailableFallbackReason)
}
```

- [ ] **Step 2: Run the red test**

Run:

```bash
swift test --filter TerminalRendererBackendTests/rendererDiagnosticsExposeRequestedBackendActiveBackendAndFallbackReason
```

Expected: fail if fallback metadata is incomplete or stale.

- [ ] **Step 3: Implement diagnostics and logging**

Record:

- requested backend
- active backend
- fallback reason
- dropped frames
- coalesced frames
- resize staging state
- retained-scene rebuild count

Keep the logs visible in settings or debug output, but do not expose renderer-choice controls to users.

- [ ] **Step 4: Run the green test**

Run:

```bash
swift test --filter TerminalRendererBackendTests/rendererDiagnosticsExposeRequestedBackendActiveBackendAndFallbackReason
swift test
```

Expected: pass.

---

## Completion Criteria

This work is done when:

- long-history Codex input no longer triggers visible top-to-bottom refresh churn
- input does not cause cursor drift
- pixel-level scrolling remains intact
- resize uses atomic scene swap behavior
- the renderer still falls back internally when GPU assumptions are violated
- `swift test` passes

## Notes

- Do not add a user-facing renderer selector.
- Do not move VT parsing, selection, or link detection into GPU code.
- Prefer retained GPU state over per-frame reconstruction.
- If a GPU path becomes unstable, preserve scroll stability and cursor stability first, then recover performance.

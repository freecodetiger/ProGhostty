# GPU Rendering Performance Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Metal-backed live terminal presenter that removes visible top-to-bottom redraws while keeping `libghostty-vt` authoritative and preserving pixel scroll, selection, cursor, and resize behavior.

**Architecture:** Keep the existing `TerminalRenderFrame` boundary and the current PTY/libghostty-vt scroll semantics. Build a second live presentation backend that consumes immutable frames and presents only the latest completed frame; keep `PTYGridView` as the interaction surface for wheel, selection, and link hit testing. Metal is a presentation detail, not a second terminal runtime.

**Tech Stack:** Swift 6, Swift Testing, AppKit, Metal/MetalKit, existing Ghostty bridge, existing renderer diagnostics.

---

### Task 1: Add a testable Metal backend selection seam

**Files:**
- Modify: `Sources/ProGhosttyCore/TerminalCore/Renderer/TerminalRendererBackend.swift`
- Modify: `Sources/ProGhosttyCore/TerminalCore/PTY/PTYTerminalEngine.swift`
- Modify tests: `Tests/ProGhosttyCoreTests/TerminalRendererBackendTests.swift`
- Modify tests: `Tests/ProGhosttyCoreTests/TerminalSurfaceTests.swift`

- [ ] **Step 1: Write the failing tests**

Add tests that prove the branch can distinguish between requested mode, active backend, and fallback when Metal is available or unavailable:

```swift
@Test func rendererBackendSelectionPrefersMetalWhenAvailable() {
  let selection = TerminalRendererBackendSelection.resolve(
    mode: .metalLive,
    hasFrame: true,
    isMetalLiveAvailable: true
  )

  #expect(selection.presentation == .liveCellGrid)
  #expect(selection.activeBackend == .metalLive)
  #expect(selection.requestedBackend == .metalLive)
  #expect(selection.fallbackReason == nil)
}

@MainActor @Test func surfaceRegistryUsesMetalBackendWhenAvailable() throws {
  let registry = PTYTerminalSurfaceRegistry(isMetalLiveAvailable: true)
  registry.applyRendererOptions(TerminalRendererOptions(mode: .metalLive))
  let session = TerminalSessionID()
  registry.createSurface(session: session)
  let bridge = try GhosttyVTBridge(cols: 12, rows: 2, maxScrollback: 100)

  bridge.write(Data("prompt".utf8))
  registry.render(bridge, session: session)
  registry.flushPendingRenderers()

  let diagnostics = try #require(registry.rendererDiagnostics(for: session))
  #expect(diagnostics.requestedBackend == .metalLive)
  #expect(diagnostics.backend == .metalLive)
  #expect(diagnostics.backendFallbackReason == nil)
}
```

- [ ] **Step 2: Run the focused tests and confirm red**

Run:

```bash
swift test --filter TerminalRendererBackendTests/rendererBackendSelectionPrefersMetalWhenAvailable
swift test --filter TerminalSurfaceTests/surfaceRegistryUsesMetalBackendWhenAvailable
```

Expected: both tests fail because the registry still hardcodes the fallback path and no Metal backend exists yet.

- [ ] **Step 3: Implement the seam with minimal surface area**

Add an availability flag or backend-factory injection to `PTYTerminalSurfaceRegistry`, defaulting to `false` so current behavior does not change. Route backend creation through `TerminalRendererBackendSelection.resolve(...)` and create a Metal backend only when both the mode requests it and availability is true.

Skeleton:

```swift
public init(isMetalLiveAvailable: Bool = false) {
  self.isMetalLiveAvailable = isMetalLiveAvailable
}

private func rendererSelection(for frame: GhosttyTerminalFrame?) -> TerminalRendererBackendSelection {
  TerminalRendererBackendSelection.resolve(
    mode: rendererOptions.mode,
    hasFrame: frame != nil,
    isMetalLiveAvailable: isMetalLiveAvailable
  )
}
```

Keep the AppKit cell-grid fallback as the default active backend when Metal is unavailable.

- [ ] **Step 4: Run the focused tests and confirm green**

Run:

```bash
swift test --filter TerminalRendererBackendTests
swift test --filter TerminalSurfaceTests
```

Expected: the new selection tests pass, and existing renderer tests keep their current behavior.

- [ ] **Step 5: Commit**

```bash
git add Sources/ProGhosttyCore/TerminalCore/Renderer/TerminalRendererBackend.swift Sources/ProGhosttyCore/TerminalCore/PTY/PTYTerminalEngine.swift Tests/ProGhosttyCoreTests/TerminalRendererBackendTests.swift Tests/ProGhosttyCoreTests/TerminalSurfaceTests.swift
git commit -m "Add metal live backend selection seam"
```

### Task 2: Build the Metal live presenter

**Files:**
- Create: `Sources/ProGhosttyCore/TerminalCore/Renderer/MetalLiveRendererBackend.swift`
- Create: `Sources/ProGhosttyCore/TerminalCore/Renderer/MetalLiveRendererView.swift`
- Create: `Sources/ProGhosttyCore/TerminalCore/Renderer/MetalLiveFrameEncoder.swift`
- Modify: `Sources/ProGhosttyCore/TerminalCore/Renderer/TerminalRendererBackend.swift`
- Modify: `Sources/ProGhosttyCore/TerminalCore/PTY/PTYTerminalEngine.swift`
- Modify tests: `Tests/ProGhosttyCoreTests/TerminalRendererBackendTests.swift`

- [ ] **Step 1: Write the failing tests**

Add tests that prove the Metal backend keeps only the latest frame, preserves the render-frame boundary, and reports drops when a frame is superseded before present:

```swift
@MainActor @Test func metalBackendDropsStaleFramesBeforePresent() {
  let backend = MetalLiveRendererBackend()
  backend.render(TerminalRenderFrame(frame: frame(rows: ["one"], cols: 8, cursorX: 0, cursorY: 0)))
  backend.render(TerminalRenderFrame(frame: frame(rows: ["two"], cols: 8, cursorX: 0, cursorY: 0)))
  backend.flushPendingFrame()

  #expect(backend.diagnostics.backend == .metalLive)
  #expect(backend.diagnostics.droppedFrames >= 1)
  #expect(backend.view is MetalLiveRendererView)
}

@Test func metalFrameEncoderPreservesScrollPresentation() {
  let scrollFrame = scrollFrame(
    viewportRows: ["two", "three"],
    overscanTop: ["one"],
    overscanBottom: ["four"],
    cols: 8
  )
  let renderFrame = TerminalRenderFrame(scrollFrame: scrollFrame, isFocused: true)
  let encoded: MetalLiveRenderPlan = MetalLiveFrameEncoder.encode(renderFrame)

  #expect(encoded.presentation == .scrollFrame)
  #expect(encoded.viewport.rows == 2)
  #expect(encoded.overscanTopRows == 1)
  #expect(encoded.overscanBottomRows == 1)
}
```

- [ ] **Step 2: Run the focused tests and confirm red**

Run:

```bash
swift test --filter TerminalRendererBackendTests/metalBackendDropsStaleFramesBeforePresent
swift test --filter TerminalRendererBackendTests/metalFrameEncoderPreservesScrollPresentation
```

Expected: both tests fail because the new Metal backend and encoder do not exist yet.

- [ ] **Step 3: Implement the backend**

Create a small Metal presenter that:

```swift
final class MetalLiveRendererBackend: TerminalRendererBackend {
  let metalView: MetalLiveRendererView
  var view: NSView { metalView }
  private var isFocused = false
  private var pendingFrame: TerminalRenderFrame?

  func setFocused(_ isFocused: Bool) {
    self.isFocused = isFocused
  }

  func render(_ renderFrame: TerminalRenderFrame) {
    pendingFrame = TerminalRenderFrame(
      frame: renderFrame.frame,
      isFocused: renderFrame.isFocused || isFocused
    )
  }

  func flushPendingFrame() {
    guard let frame = pendingFrame else { return }
    pendingFrame = nil
    metalView.present(frame: frame)
  }
}

struct MetalLiveRenderPlan {
  var presentation: TerminalRenderFramePresentation
  var viewport: GhosttyTerminalFrame
  var overscanTopRows: Int
  var overscanBottomRows: Int
  var isFocused: Bool
}
```

Minimum behavior:

- use `MTKView` or a `CAMetalLayer`-backed `NSView`
- encode the latest `TerminalRenderFrame` off screen
- present only after the frame is complete
- increment `coalescedFrames` when multiple renders collapse into one present
- increment `droppedFrames` when a stale frame is superseded
- keep `setInputHandler`, `setActivationHandler`, `setFocused`, `applyPalette`, and `applyFont` wired through without changing PTY behavior

The first implementation can reuse existing frame/cell helpers for row runs, colors, cursor overlays, and selection geometry. Do not move VT parsing, scrollback, or wheel logic into the Metal layer.

- [ ] **Step 4: Run the focused tests and confirm green**

Run:

```bash
swift test --filter TerminalRendererBackendTests
```

Expected: the Metal encoder/backend tests pass, and the existing cell-grid tests still pass unchanged.

- [ ] **Step 5: Commit**

```bash
git add Sources/ProGhosttyCore/TerminalCore/Renderer/MetalLiveRendererBackend.swift Sources/ProGhosttyCore/TerminalCore/Renderer/MetalLiveRendererView.swift Sources/ProGhosttyCore/TerminalCore/Renderer/MetalLiveFrameEncoder.swift Sources/ProGhosttyCore/TerminalCore/Renderer/TerminalRendererBackend.swift Sources/ProGhosttyCore/TerminalCore/PTY/PTYTerminalEngine.swift Tests/ProGhosttyCoreTests/TerminalRendererBackendTests.swift
git commit -m "Add metal live renderer backend"
```

### Task 3: Keep resize, scroll, and interaction parity stable

**Files:**
- Modify: `Sources/ProGhosttyCore/TerminalCore/PTY/PTYTerminalEngine.swift`
- Modify: `Sources/ProGhosttyApp/UI/TerminalCanvasView.swift`
- Modify tests: `Tests/ProGhosttyCoreTests/TerminalSurfaceTests.swift`
- Modify tests: `Tests/ProGhosttyCoreTests/TerminalResizeCoordinatorTests.swift`

- [ ] **Step 1: Write the failing tests**

Add tests that prove the new backend does not reintroduce visible intermediate frames during resize and does not break selection, link hover, or pixel scroll:

```swift
@MainActor @Test func metalBackendDropsResizeFramesThatNoLongerMatchSurfaceSize() throws {
  let registry = PTYTerminalSurfaceRegistry(isMetalLiveAvailable: true)
  registry.applyRendererOptions(TerminalRendererOptions(mode: .metalLive))
  let session = TerminalSessionID()
  registry.createSurface(session: session)
  let bridge = try GhosttyVTBridge(cols: 20, rows: 3, maxScrollback: 100)

  bridge.write(Data("one\r\ntwo\r\nthree\r\nfour".utf8))
  registry.render(bridge, session: session)
  registry.flushPendingRenderers()

  let before = try #require(registry.rendererDiagnostics(for: session))
  bridge.resize(cols: 28, rows: 5)
  registry.markResizePending(session: session)
  registry.render(ResizeRenderSnapshot.capture(from: bridge), bridge: bridge, session: session)
  registry.applyResizeDiagnostics(TerminalResizeDiagnostics(totalDuration: 0, vtDuration: 0, snapshotDuration: 0), session: session)
  registry.flushPendingRenderers()

  let after = try #require(registry.rendererDiagnostics(for: session))
  #expect(after.droppedFrames >= before.droppedFrames)
  #expect(after.pendingResize == false)
}
```

Also keep the existing resize-coordinator tests around live resize deferral and latest-pending-grid commit. They are the safety net for the window-size policy.

- [ ] **Step 2: Run the focused tests and confirm red**

Run:

```bash
swift test --filter TerminalSurfaceTests/metalBackendDropsResizeFramesThatNoLongerMatchSurfaceSize
swift test --filter TerminalResizeCoordinatorTests
```

Expected: the resize test fails until stale-frame dropping is wired through the Metal backend and the registry.

- [ ] **Step 3: Implement the resize and interaction policy**

Keep these invariants:

- the live resize commit policy stays in `TerminalResizeCommitCoordinator`
- the Metal backend never becomes the source of truth for viewport, selection, or overscan
- `PTYGridView` continues to own wheel translation, selection geometry, and link hit testing
- the backend only receives already-decided frames and presentations
- stale frames are discarded when the surface size changes before present

If needed, add a small generation token to the backend render queue so a resize invalidates older pending frames before present.

- [ ] **Step 4: Run the focused tests and confirm green**

Run:

```bash
swift test --filter TerminalSurfaceTests
swift test --filter TerminalResizeCoordinatorTests
swift test
```

Expected: all tests pass, and the full suite stays green.

- [ ] **Step 5: Commit**

```bash
git add Sources/ProGhosttyCore/TerminalCore/PTY/PTYTerminalEngine.swift Sources/ProGhosttyApp/UI/TerminalCanvasView.swift Tests/ProGhosttyCoreTests/TerminalSurfaceTests.swift Tests/ProGhosttyCoreTests/TerminalResizeCoordinatorTests.swift
git commit -m "Stabilize metal live resize and interaction parity"
```

---

## Self-Review

### Spec coverage

- Frame boundary and backend selection: Task 1.
- Metal-backed live renderer: Task 2.
- Atomic present and stale-frame dropping during resize: Task 3.
- Preserve pixel scroll, selection, cursor, and link interaction: Task 3.
- Keep AppKit cell-grid fallback intact: Tasks 1 and 2.

### Placeholder scan

- No `TBD`, `TODO`, or "implement later" markers.
- Every task names exact files and concrete test commands.

### Type consistency

- `TerminalRendererBackendSelection.resolve(...)` is the only selection entrypoint.
- `TerminalRendererBackendKind.metalLive` is the active backend name for the Metal path.
- `TerminalRenderFrame` remains the immutable input boundary for live rendering.
- `MetalLiveRendererBackend` is the new backend implementation class.

### Open gap

- If Metal is unavailable on a CI runner, Task 2 still needs the backend tests to run without depending on real GPU output. The plan assumes the backend can be exercised through state and diagnostics rather than pixel screenshots alone.

# Metal Direct Renderer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the current bitmap-presenter Metal path with a direct Metal terminal renderer that draws terminal cells, glyphs, overlays, and pixel-scroll offsets without AppKit bitmap capture on the hot path.

**Architecture:** Keep `libghostty-vt`, `TerminalRenderFrame`, `PaneScrollCoordinator`, and `ScrollCommitCoordinator` as the source of terminal and scroll truth. Add a `MetalDirectRendererBackend` that consumes immutable render frames, encodes GPU-facing render plans, updates Metal buffers/textures, and presents completed frames atomically while preserving the AppKit cell-grid fallback.

**Tech Stack:** Swift 6, Swift Testing, AppKit, Metal, CoreText, existing ProGhostty renderer diagnostics.

**Current branch status:** The direct backend surface is already wired in on the `render` branch: renderer mode selection, direct backend selection, diagnostics, frame encoding, glyph atlas caching, dirty-row instance mapping, and the first round of tests are in place. The remaining work starts at the actual Metal draw pipeline and the transition-safe GPU presentation path. The direct backend still uses `PTYGridView.render(...)` as a temporary interaction-state bridge, so the hot-path bitmap capture is gone, but the true GPU draw pass is not finished yet.

**Audit note:** Start with the remaining phases below. Treat Tasks 1-4 as the foundation that has already been landed, and use them as regression coverage while finishing the GPU renderer.

---

## File Structure

- Create `Sources/ProGhosttyCore/TerminalCore/Renderer/MetalDirectRendererBackend.swift`
  - Owns the direct Metal backend, view, command queue, pipeline setup, frame coalescing, diagnostics, and fallback-safe render entrypoints.
- Create `Sources/ProGhosttyCore/TerminalCore/Renderer/MetalTerminalFrameEncoder.swift`
  - Converts `TerminalRenderFrame` and view state into immutable `MetalTerminalRenderPlan` values.
- Create `Sources/ProGhosttyCore/TerminalCore/Renderer/MetalGlyphAtlas.swift`
  - Caches CoreText-rasterized glyphs and uploads the atlas to Metal textures.
- Create `Sources/ProGhosttyCore/TerminalCore/Renderer/MetalCellInstanceBuffer.swift`
  - Maps dirty terminal rows to per-cell GPU instance ranges.
- Create `Sources/ProGhosttyCore/TerminalCore/Renderer/MetalOverlayBuffer.swift`
  - Encodes cursor, selection, and link overlay primitives.
- Modify `Sources/ProGhosttyCore/TerminalCore/Renderer/TerminalRendererBackend.swift`
  - Add direct Metal renderer mode, backend kind, diagnostics fields, and backend selection rules.
- Modify `Sources/ProGhosttyCore/TerminalCore/PTY/PTYTerminalEngine.swift`
  - Create the direct backend when requested and available; preserve AppKit fallback.
- Modify `Sources/ProGhosttyApp/UI/AppText.swift`
  - Add display text for the direct Metal renderer mode.
- Modify `Tests/ProGhosttyCoreTests/TerminalRendererBackendTests.swift`
  - Add unit tests for selection, plan encoding, glyph atlas, dirty ranges, frame coalescing, and no bitmap capture.
- Modify `Tests/ProGhosttyCoreTests/TerminalSurfaceTests.swift`
  - Add integration tests for direct backend activation, fallback, pixel-scroll parity, and interaction preservation.

## Task 1: Phase 2A Direct Backend Skeleton

**Files:**
- Create: `Sources/ProGhosttyCore/TerminalCore/Renderer/MetalDirectRendererBackend.swift`
- Modify: `Sources/ProGhosttyCore/TerminalCore/Renderer/TerminalRendererBackend.swift`
- Modify: `Sources/ProGhosttyCore/TerminalCore/PTY/PTYTerminalEngine.swift`
- Modify: `Sources/ProGhosttyApp/UI/AppText.swift`
- Test: `Tests/ProGhosttyCoreTests/TerminalRendererBackendTests.swift`
- Test: `Tests/ProGhosttyCoreTests/TerminalSurfaceTests.swift`

- [ ] **Step 1: Write failing backend-selection tests**

Add tests:

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
    isMetalLiveAvailable: true,
    isMetalDirectAvailable: false
  )

  #expect(selection.presentation == .liveCellGrid)
  #expect(selection.activeBackend == .ghosttyVTCellGrid)
  #expect(selection.requestedBackend == .metalDirect)
  #expect(selection.fallbackReason == TerminalRendererDiagnostics.metalDirectUnavailableFallbackReason)
}
```

- [ ] **Step 2: Run red tests**

Run:

```bash
swift test --filter TerminalRendererBackendTests/rendererBackendSelectionResolvesDirectMetalWhenAvailable
swift test --filter TerminalRendererBackendTests/rendererBackendSelectionFallsBackFromDirectMetalWhenUnavailable
```

Expected: tests fail because `.metalDirect`, direct backend kind, and direct fallback reason do not exist.

- [ ] **Step 3: Implement selection surface**

Add:

```swift
case metalDirect
```

to `TerminalRendererMode`, add:

```swift
case metalDirect = "MetalDirect"
```

to `TerminalRendererBackendKind`, add:

```swift
public static let metalDirectUnavailableFallbackReason =
  "Metal direct renderer unavailable; using AppKit cell grid"
```

and extend `TerminalRendererBackendSelection.resolve(...)` with an
`isMetalDirectAvailable` parameter.

- [ ] **Step 4: Run selection tests green**

Run:

```bash
swift test --filter TerminalRendererBackendTests/rendererBackendSelection
```

Expected: direct Metal selection tests pass and existing selection tests still pass.

- [ ] **Step 5: Write failing direct backend tests**

Add tests:

```swift
@MainActor @Test func metalDirectRendererBackendReportsDirectBackendAndDoesNotUseBitmapCapture() {
  let backend = MetalDirectRendererBackend()

  #expect(backend.diagnostics.backend == .metalDirect)
  #expect(backend.diagnostics.usesBitmapCapture == false)
  #expect(backend.gridView is MetalDirectRendererView)
}

@MainActor @Test func metalDirectRendererBackendCoalescesAndDropsPendingFrames() {
  let backend = MetalDirectRendererBackend()

  backend.render(TerminalRenderFrame(frame: frame(rows: ["one"], cols: 8, cursorX: 0, cursorY: 0)))
  backend.render(TerminalRenderFrame(frame: frame(rows: ["two"], cols: 8, cursorX: 0, cursorY: 0)))
  backend.flushPendingFrame()

  #expect(backend.diagnostics.backend == .metalDirect)
  #expect(backend.diagnostics.coalescedFrames == 1)
  #expect(backend.diagnostics.droppedFrames == 1)
}
```

- [ ] **Step 6: Run direct backend tests red**

Run:

```bash
swift test --filter TerminalRendererBackendTests/metalDirectRendererBackend
```

Expected: tests fail because `MetalDirectRendererBackend`, `MetalDirectRendererView`, and `usesBitmapCapture` do not exist.

- [ ] **Step 7: Implement direct backend skeleton**

Create a direct backend that:

- conforms to `TerminalLiveRendererBackend`
- owns a `MetalDirectRendererView`
- does not create or reference `GhosttyVTCellGridRendererBackend`
- stores the latest pending `TerminalRenderFrame`
- tracks coalesced and dropped frames
- updates diagnostics with `backend = .metalDirect`
- returns `usesBitmapCapture = false`
- renders background-only frames for now

- [ ] **Step 8: Add surface registry activation tests**

Add tests:

```swift
@MainActor @Test func metalDirectRendererModeUsesDirectBackendWhenAvailable() throws {
  let registry = PTYTerminalSurfaceRegistry(isMetalDirectAvailable: true)
  registry.applyRendererOptions(TerminalRendererOptions(mode: .metalDirect))
  let session = TerminalSessionID()
  registry.createSurface(session: session)
  let bridge = try GhosttyVTBridge(cols: 12, rows: 2, maxScrollback: 100)

  bridge.write(Data("prompt".utf8))
  registry.render(bridge, session: session)
  registry.flushPendingRenderers()

  let surfaceView = try #require(registry.viewForSession(session) as? PTYTerminalSurfaceView)
  let diagnostics = try #require(registry.rendererDiagnostics(for: session))

  #expect(surfaceView.liveGridView is MetalDirectRendererView)
  #expect(diagnostics.backend == .metalDirect)
  #expect(diagnostics.usesBitmapCapture == false)
}
```

- [ ] **Step 9: Implement registry direct backend creation**

Add an `isMetalDirectAvailable` registry initializer parameter and route
`.metalDirect` mode to `MetalDirectRendererBackend` when available.

- [ ] **Step 10: Run Phase 2A verification**

Run:

```bash
swift test --filter TerminalRendererBackendTests
swift test --filter TerminalSurfaceTests
```

Expected: all focused renderer and surface tests pass.

## Task 2: Phase 2B Frame Encoder and Pixel Scroll Plan

**Files:**
- Create: `Sources/ProGhosttyCore/TerminalCore/Renderer/MetalTerminalFrameEncoder.swift`
- Test: `Tests/ProGhosttyCoreTests/TerminalRendererBackendTests.swift`

- [ ] **Step 1: Write failing encoder tests**

Tests must cover:

- scroll-frame presentation survives encoding
- overscan top/bottom counts survive encoding
- pixel remainder is copied from `PTYGridView` viewport state
- dirty row set maps to stable row ranges

- [ ] **Step 2: Implement `MetalTerminalRenderPlan`**

The plan must include:

- `presentation`
- `viewportRows`
- `cols`
- `overscanTopRows`
- `overscanBottomRows`
- `pixelRemainderY`
- `dirtyRows`
- `isFocused`

- [ ] **Step 3: Run encoder tests**

Run:

```bash
swift test --filter TerminalRendererBackendTests/metalTerminal
```

Expected: encoder tests pass.

## Task 3: Phase 2C Glyph Atlas and Text Drawing

**Files:**
- Create: `Sources/ProGhosttyCore/TerminalCore/Renderer/MetalGlyphAtlas.swift`
- Modify: `Sources/ProGhosttyCore/TerminalCore/Renderer/MetalDirectRendererBackend.swift`
- Test: `Tests/ProGhosttyCoreTests/TerminalRendererBackendTests.swift`

- [ ] **Step 1: Write failing atlas tests**

Tests must cover:

- repeated glyphs reuse the same atlas entry
- font changes invalidate atlas entries
- backing scale changes invalidate atlas entries
- CJK glyphs are measurable and cacheable

- [ ] **Step 2: Implement CoreText-backed atlas**

Rasterize glyphs into an atlas bitmap on CPU and upload atlas bytes to a Metal
texture only when the atlas changes.

- [ ] **Step 3: Draw glyph quads**

Add glyph quad encoding and a minimal Metal shader pipeline.

- [ ] **Step 4: Run atlas/text tests**

Run:

```bash
swift test --filter TerminalRendererBackendTests/metalGlyph
swift test --filter TerminalSurfaceTests/metalDirect
```

Expected: glyph atlas tests and direct renderer activation tests pass.

## Task 4: Phase 2D Dirty Row Instance Updates

**Files:**
- Create: `Sources/ProGhosttyCore/TerminalCore/Renderer/MetalCellInstanceBuffer.swift`
- Modify: `Sources/ProGhosttyCore/TerminalCore/Renderer/MetalDirectRendererBackend.swift`
- Test: `Tests/ProGhosttyCoreTests/TerminalRendererBackendTests.swift`

- [ ] **Step 1: Write failing dirty-range tests**

Tests must cover:

- single-character changes update one row range
- cursor movement updates old and new cursor rows
- selection changes update affected rows
- grid size changes force full rebuild

- [ ] **Step 2: Implement row-to-instance mapping**

Map row indexes to contiguous `MetalCellInstance` ranges and expose diagnostics
for uploaded row count and uploaded byte count.

- [ ] **Step 3: Run dirty-row tests**

Run:

```bash
swift test --filter TerminalRendererBackendTests/metalCellInstance
```

Expected: dirty row tests pass.

## Task 5: Phase 2E GPU Pixel Scroll

**Files:**
- Modify: `Sources/ProGhosttyCore/TerminalCore/Renderer/MetalDirectRendererBackend.swift`
- Modify: `Sources/ProGhosttyCore/TerminalCore/Renderer/MetalTerminalFrameEncoder.swift`
- Test: `Tests/ProGhosttyCoreTests/TerminalSurfaceTests.swift`

- [ ] **Step 1: Write failing pixel-scroll tests**

Tests must cover:

- sub-row wheel input changes direct renderer pixel offset
- VT viewport is not committed for sub-row movement
- committed row deltas still use `ScrollCommitCoordinator`
- link hit testing matches visible pixel-scrolled rows

- [ ] **Step 2: Implement pixel-scroll uniform**

Apply `-pixelRemainderY` as a draw uniform over viewport plus overscan rows.

- [ ] **Step 3: Run pixel-scroll tests**

Run:

```bash
swift test --filter TerminalSurfaceTests/metalDirect
```

Expected: pixel-scroll tests pass.

## Task 6: Phase 2F GPU Overlays

**Files:**
- Create: `Sources/ProGhosttyCore/TerminalCore/Renderer/MetalOverlayBuffer.swift`
- Modify: `Sources/ProGhosttyCore/TerminalCore/Renderer/MetalDirectRendererBackend.swift`
- Test: `Tests/ProGhosttyCoreTests/TerminalSurfaceTests.swift`

- [ ] **Step 1: Write failing overlay tests**

Tests must cover:

- block, bar, underline, and hollow cursor semantics
- unfocused session cursor dimming
- selection geometry during pixel scroll
- command-click URL/file/OSC8 behavior remains CPU-correct

- [ ] **Step 2: Implement overlay buffer**

Draw cursor, selection, and link overlays as GPU primitives while preserving CPU
hit testing.

- [ ] **Step 3: Run overlay tests**

Run:

```bash
swift test --filter TerminalSurfaceTests/metalDirect
```

Expected: overlay tests pass.

## Task 7: Phase 2G Resize and Burst Stability

**Files:**
- Modify: `Sources/ProGhosttyCore/TerminalCore/Renderer/MetalDirectRendererBackend.swift`
- Modify: `Sources/ProGhosttyCore/TerminalCore/PTY/PTYTerminalEngine.swift`
- Test: `Tests/ProGhosttyCoreTests/TerminalSurfaceTests.swift`
- Test: `Tests/ProGhosttyCoreTests/TerminalResizeCoordinatorTests.swift`

- [ ] **Step 1: Write failing stale-frame tests**

Tests must cover:

- resize burst drops stale frames
- old completed frame remains visible until new frame is complete
- Codex-like output bursts coalesce to latest frame
- no partially encoded frame is presented

- [ ] **Step 2: Implement generation tracking**

Track frame size and render generation in the direct backend. Drop pending
frames whose dimensions no longer match the current surface size.

- [ ] **Step 3: Run resize/burst tests**

Run:

```bash
swift test --filter TerminalResizeCoordinatorTests
swift test --filter TerminalSurfaceTests/metalDirect
swift test
```

Expected: resize, surface, and full test suites pass.

## Completion Criteria

The implementation is complete only when:

- direct Metal mode renders common terminal text without AppKit bitmap capture
- the hot path does not use `NSBitmapImageRep`, PNG encoding, or
  `MTKTextureLoader` per frame
- pixel scrolling remains overscan-based and bounded to one cell height
- dirty row changes update GPU buffers without full AppKit redraw
- resize bursts keep old complete frames visible until new frames are ready
- selection, cursor, URL/file/OSC8 links, IME input, and paste remain compatible
  with the AppKit backend
- `swift test` passes

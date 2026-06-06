# Rendering Path and Optimization Plan

Last updated: 2026-06-04

## Purpose

This document records the current ProGhostty terminal rendering path and the
next optimization plan. Future renderer performance work should update this
document first, then keep implementation tasks aligned with it.

The current priority is scroll smoothness in long interactive terminal sessions,
especially row-commit frames during trackpad scrolling.

## Core Invariants

- `libghostty-vt` remains the single source of terminal state.
- The UI may keep a sub-row pixel remainder for presentation, but it must not
  keep an independent scrollback mirror.
- Alternate-screen and TUI correctness take priority over scroll animation.
- AppKit cell-grid rendering remains the fallback path.
- Metal draws pixels; terminal semantics stay in `libghostty-vt` and CPU-side
  interaction code.

## Default Renderer Selection

The default settings are:

- `rendererMode: .auto`
- `smoothPixelScrollingEnabled: true`
- `dirtyRowRenderingEnabled: true`
- `forceFullRedrawEnabled: false`

In `.auto`, `PTYTerminalSurfaceRegistry` resolves the live renderer through
`TerminalRendererPolicy`. If Metal direct rendering is available and the direct
renderer pipeline is ready, the live renderer is `MetalDirectRendererBackend`.
Otherwise the live renderer falls back to `GhosttyVTCellGridRendererBackend`.
The text fallback remains available for non-live projection.

Relevant files:

- `Sources/ProGhosttyCore/Settings/AppSettings.swift`
- `Sources/ProGhosttyCore/TerminalCore/Renderer/TerminalRendererPolicy.swift`
- `Sources/ProGhosttyCore/TerminalCore/PTY/PTYTerminalSurfaceRegistry.swift`

## Current Render Path

### Output Render Path

Normal PTY output follows this shape:

```text
PTY bytes
  -> GhosttyVTBridge.write
  -> libghostty-vt
  -> PTYTerminalSurfaceRegistry.render
  -> GhosttyVTBridge.frame
  -> GhosttyVTBridge.scrollFrame(overscanTop: 2, overscanBottom: 2)
  -> TerminalRenderFrame
  -> TerminalLiveRendererBackend.render
  -> scheduled or forced backend flush
```

When the live renderer is Metal direct:

```text
TerminalRenderFrame
  -> MetalDirectRendererBackend.render
  -> MetalDirectRendererBackend.flushPendingFrame
  -> MetalDirectRendererView.present
  -> PTYGridView state update
  -> MetalDirectRendererBackend.updateDiagnostics
  -> MetalTerminalFrameEncoder.encode
  -> dirty row / dirty cell calculation
  -> glyph atlas scan
  -> style stats cache update
  -> resize sensitivity cache update
  -> MetalDirectRenderEngine.render
  -> CAMetalLayer.nextDrawable
  -> command buffer commit / present
```

Important detail: `MetalDirectRendererView` inherits `PTYGridView`. Its
`draw(_:)` is empty, but `present(_:)` still calls `super.render(...)` to keep
grid state, input presentation, cursor rects, selection, link hover, and IME
state aligned. For scroll frames it currently passes a full dirty result for
the visible viewport.

### Scroll Render Path

The interactive scroll path is:

```text
trackpad / wheel event
  -> PTYGridView.scrollWheel
  -> PaneScrollCoordinator.scroll
  -> update viewport.visualOffsetY for sub-row motion
  -> if accumulated delta crosses a row:
       ScrollCommitCoordinator.enqueue
       or immediate commit for slow accumulated single-row movement
  -> PTYGridView.commitViewportScroll
  -> PTYTerminalSurfaceRegistry.scrollViewport
  -> GhosttyVTBridge.scrollViewport
  -> GhosttyVTBridge.scrollbar
  -> PTYTerminalSurfaceRegistry.render
  -> GhosttyVTBridge.frame
  -> GhosttyVTBridge.scrollFrame
  -> backend.render
  -> backend.flushPendingFrame
  -> resetViewportStartRowKeepingVisualOffset
```

The key performance distinction:

- Pure sub-row pixel movement is relatively cheap.
- Row commit frames are heavier because they update the authoritative
  `libghostty-vt` viewport, capture a new snapshot, render it, and currently
  force a backend flush.

## Existing Caches and Coalescing

The current implementation already has several optimization layers:

- `ScrollCommitCoordinator` coalesces row deltas at about 120 Hz.
- `PaneScrollCoordinator` keeps a pixel remainder smaller than one cell height.
- `CellGridDirtyTracker` computes dirty rows and dirty cell ranges.
- `MetalGlyphAtlas` caches rendered glyph images.
- `MetalDirectRenderEngine` caches Metal textures by glyph atlas entry id and
  generation.
- `StyleStatsCache` avoids rescanning style stats for unchanged rows.
- `ResizeSensitivityCache` avoids rescanning all rows below the cursor unless
  the cache key changes.
- `TerminalOutputCoordinator` coalesces output snapshots for transient output
  bursts.

The issue is not that caching is absent. The current weak point is that row
commit frames can still do too much work synchronously on the main actor.

## Known Heavy Points

### Synchronous Scroll Commit Flush

`PTYTerminalSurfaceRegistry.scrollViewport` currently calls:

```text
bridge.scrollViewport
surface.scrollbar = bridge.scrollbar
render(bridge, surface, session)
backend.flushPendingFrame
```

This means a row commit frame can include VT state mutation, snapshot capture,
renderer update, and Metal/AppKit flush before control returns to the scroll
event path.

### Duplicate Bridge Snapshot Work

The scroll path captures `scrollbar`, then `render(bridge, ...)` captures
`frame` and `scrollFrame`. The debug block in `render(bridge, ...)` can capture
another `scrollbar` and `scrollFrame`.

Each snapshot crosses the bridge lock and copies cells into Swift values.

### MetalDirect Still Updates PTYGridView State

Metal direct rendering does not draw through AppKit, but it still uses
`PTYGridView` for input, selection, cursor rects, links, IME, and viewport
state. This keeps behavior correct, but it means Metal direct is not a pure GPU
path yet.

### ScrollFrame Expanded Frame Allocation

Several places build an expanded frame:

```text
overscanTop.flatMap(\.cells)
  + viewport.cells
  + overscanBottom.flatMap(\.cells)
```

This happens in the backend, the engine, overlay code, and the AppKit fallback
view. During scrolling, repeated array construction can add CPU pressure.

### Full Scene Rebuild Heuristics

`MetalDirectRendererBackend.scrollFrameNeedsFullSceneRebuild` can force a full
dirty result when scroll-frame presentation changes, dimensions change,
overscan counts change, or overscan rows changed.

This is conservative and correct, but it can make row commit frames expensive.

### GPU Wait Conditions

`MetalDirectRenderEngine.shouldWaitForCommandCompletion` currently waits when
any of these are true:

- first frame
- offscreen texture resized
- redraw mode is full
- render pass load policy is clear
- cursor row is dirty
- scene renders with load policy
- drawable transient overlays exist

This protects correctness, but it can create occasional scroll spikes.

### Glyph and Texture Misses

Glyph and texture caches are useful once warm. New glyphs, new styles, CJK
characters, backing scale changes, and font changes can still create main-path
work during rendering.

## Working Hypothesis for Occasional Scroll Stutter

The most likely cause is not a single missing cache. It is the combination of:

1. A row commit is triggered during scrolling.
2. The row commit synchronously mutates `libghostty-vt` and captures snapshots.
3. The renderer is immediately flushed.
4. The frame is classified as full or near-full dirty because of scrollFrame or
   overscan state.
5. Metal builds a large number of vertices and may create glyph textures.
6. The command buffer may wait for completion.

This explains why the issue is occasional: most pixel-scroll events are cheap,
but row commit frames can hit several expensive paths at once.

## Diagnostics to Add First

Before changing renderer behavior, add diagnostics that identify which layer
caused a slow frame.

Current status:

- Added: full redraw reason, expanded frame cell count, glyph texture hit/miss
  count, texture cache hit rate, and GPU wait reason for Metal direct frames.
- Added: bridge scroll commit and snapshot timings, plus bridge snapshot cell
  count.
- Pending: per-stage render timings after the bridge snapshot enters the
  backend.

### Bridge Diagnostics

Add per-frame durations:

- `bridgeScrollViewportDuration` - added
- `bridgeScrollbarSnapshotDuration` - added
- `bridgeFrameSnapshotDuration` - added
- `bridgeScrollFrameSnapshotDuration` - added
- `bridgeSnapshotCellCount` - added

These are also emitted in `TerminalRendererDiagnostics.debugSummary` as:

- `bridgeScrollViewportMs`
- `bridgeScrollbarSnapshotMs`
- `bridgeFrameSnapshotMs`
- `bridgeScrollFrameSnapshotMs`
- `bridgeSnapshotCells`

### MetalDirect Backend Diagnostics

Add or refine:

- `metalDirectFullRedrawReason` - added
- `metalDirectExpandedFrameCellCount` - added
- `metalDirectGlyphTextureHitCount` - added
- `metalDirectGlyphTextureMissCount` - added
- `metalDirectTextureCacheHitRate` - added
- `metalDirectGPUWaitReason` - added

### Scroll Diagnostics

Keep watching:

- `lastScrollCommitDuration`
- `lastScrollRenderDuration`
- `coalescedWheelEvents`
- `pendingScrollRowDelta`
- `pixelRemainderY`
- `redrawMode`
- `metalDirectWaitedForCompletion`
- `metalDirectGlyphScanCellCount`
- `metalDirectDrawnCellCount`

## Optimization Plan

### Phase 1: Measure the Slow Frames

Goal: prove which component produces scroll spikes.

Tasks:

- Add bridge timing diagnostics. Status: added for direct bridge render and
  scroll commit paths.
- Add full-redraw and GPU-wait reason diagnostics. Status: added for
  MetalDirect frames.
- Add glyph texture hit/miss diagnostics. Status: added for MetalDirect frames.
- Exercise long scrollback, slow trackpad crossing, fast inertial scroll, ASCII
  output, styled output, and CJK output.

Success criteria:

- A slow scroll frame can be classified as bridge-bound, CPU-rebuild-bound,
  texture-miss-bound, or GPU-wait-bound.
- Diagnostics remain lightweight enough to leave enabled in normal debug builds.

Slow-frame triage guide:

- Bridge-bound: `bridgeScrollViewportMs`, `bridgeScrollbarSnapshotMs`,
  `bridgeFrameSnapshotMs`, or `bridgeScrollFrameSnapshotMs` spikes alongside
  `scrollCommitMs`.
- CPU rebuild-bound: bridge timings stay low, but `scrollRenderMs`,
  `metalDirectExpandedFrameCells`, `metalDirectGlyphScanCells`,
  `metalDirectStyleScanCells`, or `metalDirectDrawnCells` spikes.
- Texture-miss-bound: `metalDirectGlyphTextureMisses` rises or
  `metalDirectTextureHitRate` drops during the stutter.
- GPU-wait-bound: `metalDirectWaited=true` with
  `metalDirectGPUWaitReason` other than `none`.

### Phase 2: Remove Synchronous Backend Flush From Scroll Commit

Goal: keep row commits from forcing a full render flush inside the scroll event
path.

Planned change:

- In `PTYTerminalSurfaceRegistry.scrollViewport`, keep the authoritative
  `bridge.scrollViewport` commit.
- Keep rendering the new snapshot into the backend.
- Do not immediately call `backend.flushPendingFrame()` on the scroll path.
- Let the backend's existing scheduled flush coalesce and present the newest
  frame.
- Preserve `resetViewportStartRowKeepingVisualOffset` timing so slow trackpad
  row crossing does not twitch.

Success criteria:

- Slow accumulated single-row scroll remains visually stable.
- Fast scrolling coalesces row commits without visibly lagging behind.
- `lastScrollCommitDuration` no longer includes a forced renderer flush.
- Existing scroll regression tests pass.

### Phase 3: Capture One Render Snapshot Per Frame

Goal: avoid repeated bridge snapshot work in one render frame.

Planned change:

- Introduce or extend a small render snapshot boundary containing:
  - `frame`
  - `scrollFrame`
  - `scrollbar`
  - optional `html`
  - optional `plainText`
- Use this boundary in output render, resize render, and scroll render.
- Remove duplicate `scrollbar` and `scrollFrame` capture from debug-only logging,
  or guard it behind an explicit debug flag.

Success criteria:

- Scroll commit captures at most one frame snapshot and one scrollFrame snapshot.
- Bridge snapshot duration and allocation pressure drop.
- Rendering behavior does not change.

### Phase 4: Reduce ScrollFrame Full Rebuilds

Goal: avoid treating normal scroll commits as full scene rebuilds when only a
small set of rows or overscan boundaries changed.

Planned change:

- Centralize expanded-frame construction so it is not rebuilt independently in
  several places.
- Track whether the viewport content changed separately from overscan-only
  changes.
- Avoid full dirty result when a smaller dirty range can preserve correctness.
- Keep cursor, selection, IME, and link hover overlays correct.

Success criteria:

- `redrawMode == .full` becomes rare during ordinary scrollback scrolling.
- `metalDirectDrawnCellCount` is well below full viewport plus overscan on most
  row commit frames.
- Selection, cursor, link hover, and IME tests still pass.

### Phase 5: Reduce GPU Wait and Glyph Miss Spikes

Goal: remove remaining occasional frame spikes after the scroll commit path is
lighter.

Planned change:

- Narrow `shouldWaitForCommandCompletion` conditions where correctness allows.
- Track exact wait reasons before changing behavior.
- Consider glyph texture prewarming or batched upload for newly visible rows.
- Avoid repeated texture lookup work within the same frame when possible.

Success criteria:

- `metalDirectWaitedForCompletion` is uncommon during scroll.
- New glyph-heavy content produces fewer visible spikes.
- No stale or torn frame presentation appears during pixel scroll.

## Regression Coverage To Maintain

Keep or add tests for:

- high-frequency wheel events do not synchronously commit every event
- slow accumulated single-row scroll remains stable
- row commit reaches `libghostty-vt`
- pixel remainder remains within one cell height
- alternate-screen wheel input is forwarded to the TUI
- pinned output and user input reset pixel scroll state correctly
- MetalDirect fallback to `GhosttyVTCellGrid` remains observable
- selection, command-click links, cursor, and IME overlays stay aligned

## Maintenance Notes

When renderer performance work changes the path:

1. Update this document before or with the code change.
2. Record whether the change affects output rendering, scroll rendering, resize
   rendering, or fallback behavior.
3. Record which diagnostics prove the change helped.
4. Keep `docs/renderer-scrolling.md` focused on scroll semantics; keep this
   document focused on end-to-end path and optimization status.

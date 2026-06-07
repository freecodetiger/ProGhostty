# Rendering Path and Optimization Plan

Last updated: 2026-06-07

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
state aligned. For scroll frames it passes a full dirty result to `PTYGridView`
for state synchronization only; Metal dirty-row evaluation is computed
separately in `MetalDirectRendererBackend.updateDiagnostics`.

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
  -> PTYTerminalSurfaceRegistry.renderScrollCommit
  -> GhosttyVTBridge.scrollFrame
  -> backend.render
  -> resetViewportStartRowKeepingVisualOffset
  -> scheduled backend flush on the next main-queue turn
```

The key performance distinction:

- Pure sub-row pixel movement is relatively cheap.
- Row commit frames are heavier because they update the authoritative
  `libghostty-vt` viewport, capture a new scroll snapshot, render it into the
  backend, and schedule presentation.

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

### Scroll Commit Main-Actor Work

`PTYTerminalSurfaceRegistry.scrollViewport` now avoids the previous synchronous
`backend.flushPendingFrame()` call on the scroll path. The current shape is:

```text
bridge.scrollViewport
surface.scrollbar = bridge.scrollbar
renderScrollCommit(bridge, surface, session)
surface.liveRenderer.resetViewportStartRowKeepingVisualOffset
```

This removes the renderer flush from `lastScrollCommitDuration`, but a row
commit still includes VT state mutation, scrollbar capture, scroll-frame
snapshot capture, backend staging, and viewport-remainder reset on the main
actor.

### Duplicate Bridge Snapshot Work

The scroll commit path has a dedicated single-snapshot boundary:
`scrollbar` plus one `scrollFrame(overscanTop: 2, overscanBottom: 2)`.
It no longer calls `bridge.frame()` during row commits.

The output render path still captures both `frame()` and `scrollFrame(...)`
when live-grid rendering is selected. Resize rendering uses an explicit
`ResizeRenderSnapshot` boundary.

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

`MetalDirectRendererBackend.scrollFrameFullSceneRebuildReason` can force a full
dirty result when scroll-frame presentation changes, dimensions change,
overscan counts change, or the previous expanded frame is missing.

The current pass removed the old `overscan-content-changed` full-redraw reason
for consecutive scrollFrame renders with stable shape. This keeps normal
continuous scroll commits closer to dirty-row rendering, while retaining
conservative full redraws for ambiguous shape or presentation changes.

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
3. The renderer stages the newest frame and flushes it on the next main-queue
   turn.
4. The frame may be classified as full or near-full dirty because of
   scrollFrame or overscan state.
5. Metal builds a large number of vertices and may create glyph textures.
6. The command buffer may wait for completion.

This explains why the issue is occasional: most pixel-scroll events are cheap,
but row commit frames can still hit several expensive paths close together.

## Diagnostics

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

Available per-frame durations:

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

Available MetalDirect fields:

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

## Optimization Plan Status

### Phase 1: Measure the Slow Frames

Goal: prove which component produces scroll spikes.

Status: mostly implemented. Continue using the diagnostics during manual
long-history scroll testing.

Completed:

- Bridge timing diagnostics for direct bridge render and scroll commit paths.
- Full-redraw and GPU-wait reason diagnostics for MetalDirect frames.
- Glyph texture hit/miss diagnostics for MetalDirect frames.

Still useful to exercise:

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

Status: implemented.

Current behavior:

- In `PTYTerminalSurfaceRegistry.scrollViewport`, keep the authoritative
  `bridge.scrollViewport` commit.
- Keep rendering the new snapshot into the backend.
- Do not immediately call `backend.flushPendingFrame()` on the scroll path.
- Let the backend's existing scheduled flush coalesce and present the newest
  frame.
- Keep `resetViewportStartRowKeepingVisualOffset` on the scroll commit path so
  slow trackpad row crossing does not twitch.

Success criteria:

- Slow accumulated single-row scroll remains visually stable.
- Fast scrolling coalesces row commits without visibly lagging behind.
- `lastScrollCommitDuration` no longer includes a forced renderer flush.
- Existing scroll regression tests pass.

### Phase 3: Capture One Render Snapshot Per Frame

Goal: avoid repeated bridge snapshot work in one render frame.

Status: partially implemented for scroll commits.

Implemented:

- Scroll commits use `renderScrollCommit`.
- Scroll commits capture `scrollbar` plus one `scrollFrame(...)`.
- Scroll commits do not capture `bridge.frame()`.

Remaining planned change:

- Introduce or extend a small render snapshot boundary containing:
  - `frame`
  - `scrollFrame`
  - `scrollbar`
  - optional `html`
  - optional `plainText`
- Use this boundary consistently in output render and any future resize or
  fallback paths that need it.
- Remove duplicate `scrollbar` and `scrollFrame` capture from debug-only logging,
  or guard it behind an explicit debug flag.

Success criteria:

- Scroll commit captures at most one frame snapshot and one scrollFrame snapshot.
- Bridge snapshot duration and allocation pressure drop.
- Rendering behavior does not change.

### Phase 4: Reduce ScrollFrame Full Rebuilds

Goal: avoid treating normal scroll commits as full scene rebuilds when only a
small set of rows or overscan boundaries changed.

Status: partially implemented.

Implemented:

- Consecutive scrollFrame renders with stable shape no longer trigger a full
  redraw only because top/bottom overscan content changed.
- Full redraws remain for presentation changes, grid-size changes, focus
  changes, transient overlay changes, missing previous expanded frame, and
  scrollFrame shape mismatches.

Remaining planned change:

- Centralize expanded-frame construction so it is not rebuilt independently in
  several places.
- Track whether smaller dirty ranges can preserve correctness for more
  scrollFrame transitions.
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

## Current Pass Summary

This optimization pass uses a gradual, low-risk strategy. The goal is to reduce
long-history scroll stutter without changing `libghostty-vt` as the single
source of terminal truth and without keeping a full scrollback mirror in the UI.

Implemented in this pass:

- Added `renderScrollCommit` so row commits capture one `scrollFrame(...)`
  snapshot and do not call `bridge.frame()`.
- Removed the scroll-path forced `backend.flushPendingFrame()`. Scroll commits
  now rely on the backend's existing scheduled flush.
- Kept `resetViewportStartRowKeepingVisualOffset` immediately after staging the
  scroll frame to preserve slow-row-crossing cursor stability.
- Removed the old `overscan-content-changed` full-redraw reason for consecutive
  scrollFrame renders with stable shape.

Expected effect:

- `lastScrollCommitDuration` no longer includes renderer presentation.
- `bridgeFrameSnapshotMs` should be `0` on scroll commits.
- `bridgeSnapshotCells` should stay bounded by viewport plus overscan rows.
- `metalDirectFullRedrawReason=overscan-content-changed` should not appear
  during ordinary continuous scrollback scrolling.

Rollback trigger:

- If cursor, selection, link hover, IME, or pixel remainder drift appears, keep
  the single-snapshot boundary and revert only the forced-flush removal first.

### Reassess Full Async Pipeline

Only introduce a full `ScrollFramePipeline` if the first three stages still show
row-commit frames exceeding the frame budget.

Status: pending manual diagnostics after the implemented stages.

Escalation criteria:

- `scrollCommitMs` still spikes after removing the forced scroll-path flush.
- Bridge snapshot timings remain high even after duplicate capture is removed.
- MainActor work still blocks fast wheel input during long-history scrolling.

If escalation is needed, split the architecture into:

- `ScrollInteractionState` for pixel remainder and pending row delta.
- `ScrollFramePipeline` for coalescing row commits and dropping stale snapshots.
- `ViewportSnapshotProvider` for `bridge.scrollViewport`, `scrollbar`, and
  `scrollFrame` capture.
- `RendererFrameScheduler` for presenting the latest snapshot on display-frame
  timing.

This full pipeline should remain internal and should still avoid full scrollback
mirroring.

## Verification Commands

Targeted tests:

```bash
swift test --filter TerminalSurfaceTests/liveCellGridWheelRowCommitsAreCoalescedUntilRendererFlush --no-parallel
swift test --filter TerminalSurfaceTests/liveCellGridScrollsLibGhosttyViewportForScrollbackHistory --no-parallel
swift test --filter TerminalSurfaceTests --no-parallel
swift test --filter TerminalRendererBackendTests --no-parallel
```

Full regression:

```bash
swift test --no-parallel
```

Manual diagnostics:

- Generate 20k to 100k lines of scrollback.
- Fast-scroll with a trackpad through cold and warm history.
- Compare `scrollCommitMs`, `scrollRenderMs`, `bridgeScrollViewportMs`,
  `bridgeFrameSnapshotMs`, `bridgeScrollFrameSnapshotMs`,
  `metalDirectFullRedrawReason`, `metalDirectWaited`,
  `metalDirectGPUWaitReason`, and `metalDirectGlyphTextureMisses` before and
  after each stage.

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

# Metal Direct Renderer Design

## Goal

Build a real GPU-backed terminal renderer for ProGhostty that produces a
visible performance improvement during long-history output, resize bursts, and
pixel scrolling.

The renderer must keep the current terminal semantics intact:

- `libghostty-vt` remains the only source of terminal state.
- CPU-side scroll coordinators remain responsible for row commits and pixel
  remainder.
- selection, link hit testing, input handling, and PTY behavior remain
  compatible with the current cell-grid path.
- AppKit cell-grid rendering remains available as a fallback.

## Current State

The current Metal path is a first-stage presenter, not a direct GPU renderer.

It works like this:

```text
TerminalRenderFrame
  -> GhosttyVTCellGridRendererBackend
  -> PTYGridView AppKit drawing
  -> NSBitmapImageRep snapshot
  -> PNG / CGImage conversion
  -> MTKTextureLoader
  -> CAMetalLayer blit
  -> present
```

This proves the backend boundary, fallback logic, and Metal presentation path,
but it still pays the AppKit drawing and bitmap conversion cost. It can improve
presentation behavior, but it cannot deliver the full performance win expected
from GPU rendering.

The next phase must remove this hot path:

```text
NSBitmapImageRep -> PNG -> CGImage -> Metal texture
```

## Decision

Create a direct Metal renderer that converts terminal frames into GPU draw
inputs:

```text
PTY bytes
  -> libghostty-vt
  -> GhosttyTerminalFrame / GhosttyTerminalScrollFrame
  -> TerminalRenderFrame
  -> MetalTerminalRenderPlan
  -> GlyphAtlas + CellInstanceBuffer + OverlayBuffer
  -> Metal draw pass
  -> CAMetalLayer present
```

The GPU owns drawing only. It must not own scrollback, viewport state, PTY
state, terminal parsing, or link/selection semantics.

## Architecture

### CPU Responsibilities

- PTY lifecycle and resize propagation
- `libghostty-vt` parsing, scrollback, modes, cursor state, and styles
- `PaneScrollCoordinator` pixel remainder and row conversion
- `ScrollCommitCoordinator` wheel commit coalescing
- selection range state
- URL/file/OSC8 link detection and hit testing
- renderer backend selection and fallback
- diagnostics and test hooks

### GPU Responsibilities

- background cell quad drawing
- glyph quad drawing from an atlas
- foreground/background blending
- cursor and selection overlays
- present-time pixel scroll offset
- double-buffered or ring-buffered frame presentation
- stale frame dropping during resize or burst output

## Key Invariant

Pixel scrolling must remain a CPU-owned scroll state plus a GPU-owned draw
offset.

```text
visualOffsetY = PaneScrollCoordinator.pixelRemainderY
drawOriginY = baseOriginY - visualOffsetY
```

When overscan rows are available, the direct renderer draws the viewport plus
top/bottom overscan rows and applies the sub-cell offset as a uniform. The VT
viewport is committed only when the scroll coordinator emits a row delta.

When overscan rows are unavailable, the renderer falls back to row-based
scrolling or the AppKit backend.

## Components

### `MetalTerminalRenderPlan`

Responsibility: immutable GPU-facing description of one presentable terminal
frame.

Contains:

- viewport frame
- optional scroll frame
- visible rows and overscan rows
- cell metrics
- backing scale
- focus state
- cursor state
- pixel scroll offset
- dirty row set
- palette identity
- font identity

It must not contain mutable terminal state or references to `GhosttyVTBridge`.

### `MetalTerminalFrameEncoder`

Responsibility: convert `TerminalRenderFrame` plus view/render state into a
`MetalTerminalRenderPlan`.

Rules:

- preserve `GhosttyTerminalScrollFrame` overscan rows
- preserve `TerminalRenderFrame.presentation`
- preserve cursor visibility and shape
- preserve explicit foreground/background styles
- keep wide characters addressable by cell coordinates
- derive dirty rows from the existing cell-grid dirty tracker where possible

### `MetalGlyphAtlas`

Responsibility: cache rasterized glyphs and expose texture coordinates to the
renderer.

Initial scope:

- CoreText rasterizes glyphs into an atlas bitmap on CPU
- atlas bitmap is uploaded to `MTLTexture`
- atlas is invalidated on font family, font size, backing scale, or fallback
  font changes
- ASCII and common terminal text are optimized first
- CJK and emoji fallback must be correct before the renderer can become the
  default

The atlas is a rendering cache, not a text shaping authority.

### `MetalCellInstanceBuffer`

Responsibility: hold per-cell draw instances.

Each instance contains:

- row and column
- glyph atlas rect
- foreground color
- background color
- style flags
- cell occupancy flags

Dirty row rendering updates only the affected instance ranges. Full redraw is
reserved for grid size changes, font changes, palette changes, or fallback
state changes.

### `MetalOverlayBuffer`

Responsibility: hold GPU overlay primitives.

Initial overlays:

- block, bar, underline, and hollow cursors
- selection rectangles
- link hover underline or highlight
- marked text overlay if required by the existing input composition behavior

Hit testing remains CPU-side.

### `MetalDirectRendererBackend`

Responsibility: implement `TerminalLiveRendererBackend` without snapshotting an
AppKit view.

It should:

- consume `TerminalRenderFrame`
- encode a `MetalTerminalRenderPlan`
- update glyph atlas and instance buffers
- draw directly into a Metal render pass
- keep the old completed frame visible until the next frame is fully encoded
- drop stale frames during resize or render bursts
- report diagnostics for upload time, encode time, draw time, present time,
  dropped frames, and fallback reason

## Fallback Rules

Fallback to the AppKit cell-grid renderer when:

- Metal is unavailable
- shader compilation or pipeline creation fails
- glyph atlas upload fails
- frame dimensions exceed safe buffer limits
- required overscan rows are unavailable while pixel scrolling is active
- a text feature is not yet supported by the direct renderer

Fallback must be explicit in diagnostics:

```text
backend=GhosttyVTCellGrid
requestedBackend=MetalDirect
fallbackReason="..."
```

## Implementation Plan

### Phase 2A: Direct Renderer Skeleton

Create the direct backend and render background cells only.

Deliverables:

- `MetalDirectRendererBackend`
- `MetalDirectRendererView`
- backend selection mode for direct Metal
- diagnostics showing direct renderer activation
- AppKit fallback remains unchanged

Tests:

- direct backend is selected only when requested and available
- direct backend falls back when unavailable
- direct backend does not use bitmap capture
- direct backend keeps only the latest pending frame

### Phase 2B: Frame Encoder and Pixel Scroll Plan

Create `MetalTerminalRenderPlan` and `MetalTerminalFrameEncoder`.

Deliverables:

- render plan preserves frame vs scroll-frame presentation
- render plan includes overscan row counts
- render plan includes pixel remainder
- render plan includes dirty row set

Tests:

- overscan top/bottom rows survive encoding
- pixel remainder is preserved
- dirty rows map to stable row ranges
- alternate-screen frames disable scrollback pixel motion

### Phase 2C: Glyph Atlas and Text Drawing

Draw terminal glyphs directly from a Metal texture atlas.

Deliverables:

- CoreText-backed glyph atlas
- glyph texture upload path
- glyph quad shader
- foreground/background color support
- basic style support: bold, italic, faint, underline, inverse

Tests:

- repeated glyphs reuse atlas entries
- font changes invalidate atlas entries
- backing scale changes invalidate atlas entries
- default foreground/background match existing palette behavior
- inverse and faint styles match the AppKit renderer expectations

### Phase 2D: Dirty Row Instance Updates

Update only changed rows in GPU buffers.

Deliverables:

- row-to-instance-range mapping
- dirty range upload path
- full redraw path for grid size changes
- diagnostics for uploaded row count and buffer bytes

Tests:

- single-character changes update one row range
- cursor movement updates old and new cursor rows
- selection changes update affected rows
- grid size changes force full buffer rebuild

### Phase 2E: GPU Pixel Scroll

Apply pixel scrolling as a GPU uniform.

Deliverables:

- `pixelRemainderY` draw uniform
- overscan drawing path
- row commit behavior remains unchanged
- no VT viewport mutation for sub-row scroll movement

Tests:

- sub-row wheel input changes only draw offset
- committed row deltas still go through `ScrollCommitCoordinator`
- link hit testing matches visible pixel-scrolled rows
- selection copies visible overscan text during pixel scroll

### Phase 2F: Cursor, Selection, and Link Overlays

Move overlays into the Metal render pass.

Deliverables:

- cursor overlay drawing
- selection overlay drawing
- link hover overlay drawing
- focus-sensitive cursor behavior

Tests:

- block, bar, underline, and hollow cursors match existing semantics
- unfocused session dims cursor correctly
- selection geometry matches AppKit path
- command-click URL/file/OSC8 link behavior remains CPU-correct

### Phase 2G: Resize and Burst Stability

Keep old frames visible until a new direct GPU frame is complete.

Deliverables:

- in-flight frame generation tracking
- stale frame drop logic
- resize-size validation
- present latency diagnostics

Tests:

- resize burst drops stale frames
- old frame remains valid until new frame is ready
- Codex-like output bursts coalesce to latest frame
- no partially encoded frame is presented

## Test Strategy

Use TDD for each phase.

Focused commands:

```bash
swift test --filter TerminalRendererBackendTests
swift test --filter TerminalSurfaceTests
swift test --filter TerminalResizeCoordinatorTests
```

Final command:

```bash
swift test
```

Rendering correctness should be tested at two levels:

- pure Swift tests for frame encoding, dirty row ranges, atlas cache behavior,
  and fallback decisions
- AppKit/Metal integration tests for backend selection, diagnostics, pixel
  scroll preservation, and interaction parity

## Success Criteria

The direction is considered viable when:

- direct Metal mode can render common terminal output without AppKit bitmap
  capture
- pixel scrolling remains smooth and bounded to one cell height
- resize bursts do not show top-to-bottom redraw
- Codex-like long histories stay usable while resizing panels
- selection, cursor, URL/file/OSC8 links, IME input, and paste behavior remain
  compatible with the current backend
- AppKit fallback remains available and diagnosable

The direction is not complete until:

- the hot path no longer uses `NSBitmapImageRep`, PNG encoding, or
  `MTKTextureLoader` for every frame
- dirty row changes update GPU buffers without full AppKit redraw
- text quality is acceptable for ASCII, CJK, Retina scale, and common shell
  output

## Explicit Non-Goals

- do not import Ghostty's full macOS renderer runtime
- do not move VT parsing into GPU code
- do not create a second scrollback model
- do not make the GPU renderer responsible for link detection
- do not remove the AppKit fallback during phase two
- do not make direct Metal the default until text quality and interaction parity
  are proven

## Audit Checklist

Before implementation starts, confirm:

- the direct renderer has a separate backend from the current bitmap presenter
- the direct renderer does not snapshot `PTYGridView`
- pixel scrolling remains modeled by the existing scroll coordinators
- the renderer consumes immutable render frames
- fallback reasons are observable in diagnostics
- every phase has failing tests before implementation

Before enabling direct Metal by default, confirm:

- full test suite passes
- manual resize testing shows no top-to-bottom refresh
- long Codex-style histories remain responsive
- CJK and common fallback glyphs render correctly
- selection and link behavior match the AppKit backend

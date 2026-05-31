# GPU Live Rendering Performance Design

## Goal

Improve ProGhostty's rendering performance without losing the current
pixel-level scroll behavior.

The target outcome is:

- no visible top-to-bottom redraw during resize or repaint bursts
- keep overscan-based pixel scrolling
- keep terminal semantics in `libghostty-vt`
- keep scrollback, selection, cursor, and link interaction correct
- avoid importing Ghostty's full macOS renderer runtime

## Problem

Today the live terminal surface is rendered by the AppKit cell-grid path.
That path already has good semantic layering:

- PTY and `libghostty-vt` own terminal state
- `PTYGridView` owns the current viewport, pixel remainder, and overscan draw
- `ScrollCommitCoordinator` coalesces wheel commits
- resize is deferred and coalesced before the PTY is resized

That structure is correct, but the present AppKit drawing path still makes
large redraws feel visible. During dense output or resize bursts, the user can
see a top-to-bottom refresh pattern.

The goal of GPU rendering is not to move terminal semantics onto the GPU. The
goal is to change the presentation layer so the terminal frame is composed off
screen and presented atomically.

## Decision

Use a thin GPU-backed presentation layer for the live terminal surface.
Keep all terminal semantics, scroll behavior, and resize policy on the CPU.

Do not reuse Ghostty's full macOS renderer runtime directly. It is tightly
coupled to its own renderer thread, frame state, swap chain, and surface
runtime. ProGhostty should borrow the architectural shape, not embed the whole
renderer stack.

## Approaches Considered

### 1. Thin Metal compositor over existing terminal frame model

Recommended.

Render terminal cells into a GPU-backed surface using immutable frame inputs:

- `GhosttyTerminalFrame` or `GhosttyTerminalScrollFrame`
- current palette, font metrics, and cursor state
- pixel scroll offset and overscan rows
- selection and link overlay geometry

The GPU layer presents completed frames atomically. The old frame stays on
screen until the new frame is ready.

Tradeoffs:

- best chance of removing visible refresh artifacts
- keeps the existing scroll/resize model intact
- requires a new renderer backend and frame encoder

### 2. Reuse Ghostty's full Metal renderer

Not recommended.

Ghostty's renderer is not just a drawing library. It owns its own frame state,
swap chain, display callback, and Metal surface lifecycle. Pulling that into
ProGhostty would add a second terminal runtime and make debugging harder.

Tradeoffs:

- less code to invent initially
- much higher coupling
- harder to test and reason about inside ProGhostty

### 3. Keep AppKit and only optimize invalidation

Not enough.

This is the smallest change, but it does not address the main visual problem:
the repaint itself is still visible.

Tradeoffs:

- low risk
- limited impact on the visible refresh pattern

## Recommended Architecture

```text
PTY bytes
  -> libghostty-vt
  -> GhosttyTerminalFrame / GhosttyTerminalScrollFrame
  -> TerminalRenderFrame
  -> Metal terminal backend
  -> CAMetalLayer / IOSurface-backed presentation
```

### Core Responsibilities

- `libghostty-vt`: terminal state, scrollback, cursor, styles, modes
- `PTYGridView` or its successor: input handling, wheel handling, selection
  geometry, pixel scroll remainder, overscan policy
- `TerminalRenderFrame`: immutable render input for one presentable frame
- GPU backend: texture upload, glyph drawing, blending, and atomic present
- App layer: windowing, split views, workspaces, titlebar, settings

### What stays on the CPU

- PTY and resize propagation
- `ScrollCommitCoordinator`
- `PaneScrollCoordinator`
- selection hit testing
- URL/link detection
- cursor/link geometry
- fallback logic when overscan is not available

### What moves to the GPU

- final cell compositing
- background and foreground blending
- text and cell quad drawing
- double buffering or swap-chain based presentation
- present-time clipping and scaling

## Data Flow

### Live frame

1. PTY receives output.
2. `libghostty-vt` produces a frame or scroll frame.
3. The terminal engine converts that into a render frame.
4. The GPU backend builds the next surface off screen.
5. The completed frame is presented in one swap.

### Pixel scroll

1. Wheel input updates `viewport.visualOffsetY`.
2. If overscan rows exist, the backend applies a sub-cell translation.
3. Row commits still happen through the existing coalescing path.
4. The GPU presents the translated frame atomically.

### Resize

1. Resize events continue to be coalesced and deferred.
2. The old frame remains visible while the new terminal size is being
   prepared.
3. Only the completed frame is presented.
4. A stale in-flight frame is discarded if its size no longer matches.

This is the main protection against visible top-to-bottom refresh.

## Fallback Rules

The GPU path must fall back cleanly when:

- Metal is unavailable
- the frame model is incomplete
- overscan rows are missing and pixel translation cannot be represented
- a backend-specific failure occurs during frame upload or present

Fallback should use the current AppKit cell-grid renderer, not a partial or
broken GPU frame.

## Phased Implementation

### Phase 1: Frame Model and Backend Boundary

- define a narrow immutable render frame type
- make the live renderer consume that frame instead of drawing directly
- keep the current AppKit backend as the fallback implementation
- add tests for frame conversion and backend selection

### Phase 2: Metal Live Renderer

- create a Metal-backed implementation of the live renderer backend
- render the current terminal frame into an off-screen target
- present completed frames atomically
- preserve current pixel scroll and overscan behavior

### Phase 3: Resize and Scroll Stabilization

- keep the existing resize coalescing policy
- keep the row-commit coalescing policy
- ensure old frames remain visible until a new frame is ready
- add diagnostics for pending frames, dropped frames, and present latency

### Phase 4: Selection and Interaction Polish

- preserve selection geometry
- preserve URL hover and command-click behavior
- verify cursor rendering and focus changes in the GPU backend

## Testing Strategy

Add tests at three levels:

1. Frame conversion tests:
   - frame to render-frame mapping is stable
   - overscan and pixel offset are preserved
   - cursor and selection state survive conversion

2. Backend behavior tests:
   - resize events do not force visible intermediate frames
   - stale frames are dropped when the surface size changes
   - pixel scroll remains bounded to one cell height

3. Regression tests:
   - long-history Codex-style output does not flicker during resize
   - scrollback still uses overscan-based pixel motion
   - alternate-screen behavior remains row-based

## Non-Goals

- do not import Ghostty's full renderer runtime
- do not move VT parsing into GPU code
- do not create a second authoritative scrollback model
- do not change shell or PTY semantics
- do not remove the current AppKit fallback until the GPU path is stable

## Success Criteria

- resize no longer shows a visible top-to-bottom refresh
- long Codex histories stay smooth while the window is being resized
- pixel scroll and overscan still work
- cursor, selection, and link interactions still match terminal state
- the GPU path remains replaceable and debuggable

# GPU-first Renderer Rework

## Goal

Build a GPU-first terminal renderer for ProGhostty that keeps Codex-style long history and high-frequency TUI updates stable:

- input does not shake;
- cursor does not drift;
- resize does not show top-to-bottom refresh artifacts;
- pixel-level scrolling remains smooth;
- users do not choose rendering paths;
- the app defaults to the highest-performance stable renderer and falls back internally when needed.

This is not a plan to move terminal protocol parsing to the GPU. PTY IO, ANSI/VT parsing, scrollback semantics, Unicode width, cursor state, and terminal modes should remain CPU/libghostty-vt responsibilities. GPU-first means the visible terminal scene is retained and presented by the GPU, while the CPU submits compact state changes and frame transactions.

## Files In Scope

The rewrite should stay focused on the existing renderer stack:

- `Sources/ProGhosttyCore/TerminalCore/Renderer/TerminalRendererBackend.swift`
- `Sources/ProGhosttyCore/TerminalCore/Renderer/MetalDirectRendererBackend.swift`
- `Sources/ProGhosttyCore/TerminalCore/Renderer/MetalDirectRenderEngine.swift`
- `Sources/ProGhosttyCore/TerminalCore/Renderer/MetalTerminalFrameEncoder.swift`
- `Sources/ProGhosttyCore/TerminalCore/Renderer/MetalOverlayBuffer.swift`
- `Sources/ProGhosttyCore/TerminalCore/Renderer/MetalCellInstanceBuffer.swift`
- `Sources/ProGhosttyCore/TerminalCore/Renderer/MetalGlyphAtlas.swift`
- `Sources/ProGhosttyCore/TerminalCore/Renderer/GhosttyVTCellGridRendererBackend.swift`
- `Sources/ProGhosttyCore/TerminalCore/PTY/PTYTerminalEngine.swift`
- `Tests/ProGhosttyCoreTests/TerminalRendererBackendTests.swift`
- `Tests/ProGhosttyCoreTests/TerminalSurfaceTests.swift`

## Implementation Prompt

Use this document as the execution contract for the renderer rewrite.

Working rules:

- optimize first for stable input, stable cursor, and stable resize behavior under long histories;
- preserve pixel-level scrolling unless a fallback is required;
- keep renderer choice internal, not user-facing;
- prefer a retained GPU scene over per-frame immediate redraw;
- write the failing tests before changing renderer behavior;
- treat stale generations as discardable, never presentable.

The first implementation slice should be narrow:

1. add generation tracking to render snapshots and transactions;
2. prevent stale command buffer completions from presenting;
3. split cursor presentation out of row redraw logic;
4. keep the existing live grid fallback intact.

Do not attempt a full renderer rewrite in one step. The objective is to get a safe contract in place, then move the visible layers onto it incrementally.

## Delivery Sequence

Implement in this order:

1. generation contract and stale-completion rejection
2. cursor overlay separation from text redraw
3. display coalescing for rapid Codex-style updates
4. retained GPU buffers for cells, style, and overlays
5. pixel scroll compositor
6. atomic resize scene swap

Each step should land with tests before moving to the next one.

## Current Problem

The current MetalDirect path is still CPU-led immediate rendering:

1. PTY bytes arrive from the shell or Codex TUI.
2. libghostty-vt parses bytes and exposes a frame or scroll frame.
3. ProGhostty computes dirty rows, style stats, glyph atlas changes, resize sensitivity, cursor data, overlay data, and scroll state on CPU.
4. MetalDirect builds draw vertices for each render pass.
5. GPU draws the generated quads and presents them.

This improves final drawing, but the CPU still controls most frame construction and the renderer can expose intermediate terminal states. Codex completion refreshes are a good stress case: typing `/res` can generate multiple VT operations per character, such as cursor movement, clearing suggestion rows, rewriting suggestions, and moving the cursor back. If any intermediate state is presented, the cursor can appear to jump to a previous line or fixed origin for one frame.

The deeper issue is not only speed. It is frame ownership and synchronization:

- text layer and cursor layer are not strongly tied to one frame generation;
- dirty row rendering can present partial state;
- display timing follows render submissions rather than a stable presentation clock;
- AppKit-visible grid state and Metal-presented state can diverge;
- resize can reveal incremental reconstruction instead of an atomic scene swap.

## Design Principle

The renderer should present complete visual transactions, not raw intermediate VT updates.

A terminal frame should become visible only when all visible parts belong to the same generation:

- cell contents;
- glyph atlas entries;
- cursor overlay;
- marked text overlay;
- selection overlay;
- link hover overlay;
- scroll transform;
- clip and viewport metadata.

If a newer complete generation exists, older pending generations should be discarded before presentation. This favors perceptual stability over showing every intermediate TUI operation.

## Target Architecture

### 1. TerminalFrameProducer

Responsible for reading stable snapshots from libghostty-vt.

Inputs:

- `GhosttyVTBridge`
- viewport and scrollback state
- requested overscan rows
- focus state

Outputs:

- immutable `TerminalFrameSnapshot`
- immutable `TerminalScrollSnapshot`
- monotonically increasing `generation`

Rules:

- never expose mutable bridge state to the renderer;
- snapshot cursor, cells, scroll position, and terminal mode together;
- treat snapshot generation as the unit of visual correctness.

### 2. RenderTransactionBuilder

Responsible for diffing snapshots into compact GPU updates.

Inputs:

- previous accepted snapshot
- next snapshot

Outputs:

- `RenderTransaction`

Transaction contents:

- `generation`
- dirty cell ranges, not only dirty rows
- cursor state
- scroll state
- overlay state
- resize metadata
- glyph invalidation requests

Rules:

- do not touch Metal;
- do not mutate view state;
- produce deterministic output that can be unit tested;
- mark transactions as complete only when all required parts are available.

### 3. MetalTerminalScene

Responsible for retained GPU resources.

Owns:

- persistent cell instance buffer;
- persistent style buffer;
- persistent glyph atlas textures;
- cursor overlay buffer;
- selection/link/marked text overlay buffers;
- offscreen render target;
- presentation texture;
- resize staging texture.

Rules:

- update buffers incrementally;
- avoid rebuilding full-screen vertex arrays per frame;
- upload only changed cell ranges and overlay changes;
- keep scroll as a uniform transform when possible.

### 4. MetalFrameScheduler

Responsible for presentation order and frame coalescing.

Inputs:

- render transactions
- display tick
- command buffer completion

Behavior:

- coalesce multiple terminal updates into one display-frame presentation;
- submit only the newest complete generation;
- drop stale command buffer completions;
- never present generation `N` after generation `N+1`;
- never mix text from one generation with cursor from another.

This component is the main fix for Codex-style cursor drift.

### 5. MetalCursorLayer

Responsible for cursor rendering independent of text dirty rows.

Rules:

- cursor is its own overlay layer;
- cursor always carries a generation;
- cursor update does not require redrawing the row text;
- cursor blink must not mutate the cell buffer;
- cursor hide/show during marked text composition must be a layer state change.

Expected effect:

- typing changes cursor position without exposing stale row redraws;
- `/res` completion refreshes cannot show cursor from a different frame.

### 6. PixelScrollCompositor

Responsible for pixel-level scrolling and overscan composition.

Rules:

- sub-row scrolling updates a transform uniform;
- crossing a full row requests new overscan rows;
- visible content should not be re-laid out for every pixel delta;
- scroll commit and visual scroll offset must be generation-aware;
- selection and cursor coordinates must use the same transformed coordinate space.

Expected effect:

- current pixel-level scroll feel is retained;
- scrolling does not force full text reconstruction;
- long history remains responsive.

### 7. ResizeSceneCoordinator

Responsible for resize without visible top-to-bottom rebuild.

Behavior:

- collect resize event bursts;
- request a new terminal snapshot at the target size;
- prepare a new retained scene or resized buffers offscreen;
- atomically swap to the new scene when complete;
- keep old scene visible while the new scene is not ready.

Expected effect:

- resizing panels should not show a rapid top-to-bottom redraw;
- Codex long history should not cause seconds of visible refresh churn.

## Data Flow

```text
PTY bytes
  -> libghostty-vt
  -> TerminalFrameProducer
  -> TerminalFrameSnapshot(generation)
  -> RenderTransactionBuilder
  -> RenderTransaction(generation)
  -> MetalFrameScheduler
  -> MetalTerminalScene
  -> CAMetalLayer
```

Display timing should look like this:

```text
Many VT updates within 8-16 ms
  -> build latest complete transaction
  -> discard older transactions
  -> submit generation N
  -> present generation N only if still latest
```

## Frame Generation Contract

Every visual component must carry a generation:

- cell buffer updates;
- glyph atlas availability;
- cursor layer;
- marked text layer;
- selection layer;
- link hover layer;
- scroll transform;
- resize scene.

The renderer must enforce:

```text
presented.textGeneration == presented.cursorGeneration
presented.textGeneration == presented.overlayGeneration
presented.textGeneration == presented.scrollGeneration
```

If the contract cannot be satisfied, the renderer should keep the previous complete generation visible.

## Handling Codex TUI Updates

Codex completion updates can produce intermediate terminal states. GPU-first should not present each one.

Example input sequence when typing `/res`:

```text
write "/r"
move cursor
clear suggestion rows
write suggestions
move cursor back to prompt
write "/re"
clear suggestion rows
write suggestions
move cursor back to prompt
write "/res"
...
```

The renderer should coalesce these into stable display frames:

```text
generation 101: prompt "/r" + suggestions + correct cursor
generation 102: prompt "/re" + suggestions + correct cursor
generation 103: prompt "/res" + suggestions + correct cursor
```

It should not present:

```text
prompt "/res" + cleared suggestions + cursor at temporary VT position
```

or:

```text
text from generation 103 + cursor from generation 102
```

## Fallback Policy

Fallback should be internal and stability-first.

Priority order:

1. keep input stable;
2. keep cursor generation-correct;
3. keep pixel-level scroll;
4. keep GPU retained rendering;
5. degrade optional effects.

Fallback examples:

- If glyph atlas upload misses the current display tick, keep the previous complete frame visible.
- If retained scene update fails, fall back to cell-grid rendering for that session.
- If Metal is unavailable, use the existing live grid path.
- If pixel scroll lacks overscan rows, degrade only the scroll commit mode, not the whole terminal renderer.

Fallback should be observable in diagnostics but not exposed as a normal user choice.

## Diagnostics

Add detailed renderer diagnostics for settings/debug UI:

- active renderer backend;
- requested renderer backend;
- fallback reason;
- latest snapshot generation;
- latest transaction generation;
- latest submitted generation;
- latest presented generation;
- stale command completions;
- dropped transactions;
- coalesced VT updates;
- dirty cell count;
- dirty row count;
- glyph uploads;
- cursor generation;
- overlay generation;
- scroll generation;
- resize staging status;
- average CPU transaction time;
- average GPU command time;
- present latency.

These logs should make it clear whether a cursor issue came from:

- VT snapshot state;
- transaction building;
- Metal scheduling;
- cursor overlay generation mismatch;
- AppKit/input anchor mismatch;
- fallback transition.

## Implementation Stages

### Stage 1: Generation Contract

Add explicit generation IDs to terminal snapshots, render transactions, Metal submissions, and diagnostics.

Success criteria:

- tests can assert that stale command completions cannot present;
- diagnostics show latest snapshot/submitted/presented generation;
- no user-visible renderer behavior changes required yet.

### Stage 2: Cursor Overlay Independence

Move cursor rendering out of dirty row text rendering.

Success criteria:

- cursor movement updates only cursor layer when text cells are unchanged;
- cursor blink does not dirty terminal rows;
- marked text composition hides cursor via overlay state;
- Codex `/res` input does not show cursor from an older generation.

### Stage 3: Display Tick Coalescing

Introduce a scheduler that presents at display cadence and only presents complete latest transactions.

Success criteria:

- repeated Codex-like ANSI refreshes are coalesced;
- intermediate VT states are not visible;
- stale command buffer completions are ignored;
- dropped transaction count is visible in diagnostics.

### Stage 4: Retained GPU Cell Buffers

Replace per-frame quad rebuilding with retained GPU cell/style buffers.

Success criteria:

- normal typing uploads only changed cells and cursor overlay;
- long-history terminal output avoids full visible frame rebuild;
- dirty cell count is more precise than dirty row count.

### Stage 5: Pixel Scroll Compositor

Move pixel scrolling to transform/uniform-driven composition.

Success criteria:

- sub-row scroll does not rebuild visible text;
- overscan rows cover pixel scroll edges;
- cursor, selection, link hover, and marked text use the same transformed geometry.

### Stage 6: Atomic Resize Scene Swap

Stage resized scene updates offscreen and swap only when complete.

Success criteria:

- panel resizing does not show top-to-bottom refresh;
- old scene remains visible while new scene prepares;
- resize diagnostics expose staging and swap timing.

## Testing Strategy

### Unit Tests

Test pure logic first:

- generation monotonicity;
- transaction completeness;
- stale generation rejection;
- cursor layer generation matching;
- dirty cell range calculation;
- pixel scroll transform calculation;
- resize staging state transitions.

### Renderer Backend Tests

Test Metal-facing behavior with test doubles:

- latest generation wins;
- command completion from older generation is ignored;
- cursor overlay can update without dirty row upload;
- glyph upload miss does not present partial generation;
- fallback reason is recorded.

### Surface Tests

Test Codex-like behavior:

- typing `/r`, `/re`, `/res` keeps cursor anchored;
- suggestions can expand/collapse without cursor drift;
- temporary disappearance of suggestions does not switch rendering path;
- resizing long history does not reveal top-to-bottom redraw.

### Manual Smoke Tests

Manual scenarios:

- Codex `/res` completion list;
- long Codex conversation history;
- rapid split panel resize;
- smooth wheel/trackpad scroll;
- IME marked text;
- selection and command-click links;
- theme/font changes.

## Non-goals

- Do not rewrite libghostty-vt.
- Do not parse ANSI/VT on GPU.
- Do not expose renderer path as a normal user-facing choice.
- Do not sacrifice pixel-level scrolling to make GPU rendering easier.
- Do not build a separate rendering architecture for Codex only.

## Main Risk

The main risk is adding another parallel renderer that drifts from the existing live grid behavior.

Mitigation:

- keep one shared snapshot and transaction model;
- treat Metal as a presentation backend, not a second terminal implementation;
- enforce generation contracts in tests;
- preserve cell-grid fallback;
- add diagnostics before replacing behavior broadly.

## Recommended Next Step

Start with Stage 1 and Stage 2 only:

1. add generation-aware render transactions;
2. split cursor into an independent generation-bound overlay;
3. write Codex `/res` regression tests before implementation.

This directly targets the current cursor drift problem while laying the foundation for the full GPU-first renderer.

## Exit Criteria

The rewrite is only ready for normal use when all of the following are true:

- `auto` defaults to the highest-performance stable backend available
- user-facing renderer selection remains unchanged or hidden
- input does not visibly shake during Codex completion updates
- cursor position remains anchored during `/res`-style updates
- resize does not show a long top-to-bottom refresh sweep
- pixel scrolling still feels continuous and smooth
- stale GPU completions cannot replace a newer frame
- fallback reasons are visible in diagnostics

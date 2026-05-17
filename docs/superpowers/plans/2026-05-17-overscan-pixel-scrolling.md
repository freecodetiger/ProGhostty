# Overscan Pixel Scrolling Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add true pixel-level scroll feel to the AppKit cell-grid renderer without letting UI state diverge from libghostty-vt viewport state.

**Architecture:** Keep `PTY -> libghostty-vt -> cell-grid -> AppKit` as the only main terminal rendering path. Extend the bridge to expose a scroll snapshot containing visible rows plus real overscan rows from libghostty-vt; `PTYGridView` may only apply a bounded sub-row `visualOffsetY` when those rows are present.

**Tech Stack:** Swift, AppKit, Swift Testing, C bridge over vendored `libghostty-vt`, existing `GhosttyVTCellGridRendererBackend`.

---

## File Structure

- Modify: `Sources/ProGhosttyGhosttyVT/include/ProGhosttyGhosttyVT.h`
  - Add C structs and functions for scroll snapshots only after API research proves real overscan rows can be read.
- Modify: `Sources/ProGhosttyGhosttyVT/ProGhosttyGhosttyVT.c`
  - Implement scroll snapshot extraction from libghostty-vt render state or return an explicit unavailable result.
- Modify: `Sources/ProGhosttyCore/TerminalCore/LibGhostty/GhosttyVTBridge.swift`
  - Add Swift models and bridge methods for `GhosttyTerminalScrollFrame`.
- Modify: `Sources/ProGhosttyCore/TerminalCore/Renderer/CellGridModel.swift`
  - Add dirty diff support for scroll frames without changing normal `GhosttyTerminalFrame` behavior.
- Modify: `Sources/ProGhosttyCore/TerminalCore/Renderer/GhosttyVTCellGridRendererBackend.swift`
  - Add an experimental scroll-frame render entrypoint gated by renderer options.
- Modify: `Sources/ProGhosttyCore/TerminalCore/PTY/PTYTerminalEngine.swift`
  - Route wheel deltas through the overscan path only when diagnostics say overscan is available.
- Modify: `Sources/ProGhosttyCore/TerminalCore/Renderer/TerminalRendererBackend.swift`
  - Extend diagnostics with overscan availability and pixel-scroll state.
- Test: `Tests/ProGhosttyCoreTests/GhosttyVTBridgeTests.swift`
  - Verify bridge capability and frame shape.
- Test: `Tests/ProGhosttyCoreTests/TerminalRendererBackendTests.swift`
  - Verify bounded visual offsets, row commits, and dirty-row behavior.
- Test: `Tests/ProGhosttyCoreTests/TerminalSurfaceTests.swift`
  - Verify no regressions for Codex-like alternate screen, scrollback history, and focus.
- Create: `docs/renderer-overscan-research.md`
  - Record the API result and the reason pixel scrolling is enabled or remains unavailable.

---

### Task 1: Research libghostty-vt Overscan Capability

**Files:**
- Create: `docs/renderer-overscan-research.md`
- Read: `vendor/ghostty/include/ghostty/vt/render.h`
- Read: `vendor/ghostty/include/ghostty/vt/terminal.h`
- Read: `vendor/ghostty/src/terminal/c/render.zig`

- [ ] **Step 1: Inspect render and terminal APIs**

Run:

```bash
rg -n "viewport|scroll|row_iterator|ROW_ITERATOR|SCROLLBAR|scroll_viewport" \
  vendor/ghostty/include/ghostty/vt \
  vendor/ghostty/src/terminal/c
```

Expected: output includes `ghostty_terminal_scroll_viewport`, scrollbar APIs, and render row iterator APIs.

- [ ] **Step 2: Confirm whether rows outside the current viewport can be read without mutating viewport**

Run:

```bash
sed -n '120,240p' vendor/ghostty/include/ghostty/vt/render.h
sed -n '640,740p' vendor/ghostty/include/ghostty/vt/terminal.h
sed -n '430,610p' vendor/ghostty/src/terminal/c/render.zig
```

Expected:
- If an API exists for non-mutating viewport-relative row access, document it.
- If no API exists, document that true overscan is unavailable and stop before Task 2.

- [ ] **Step 3: Write the research document**

Create `docs/renderer-overscan-research.md` with this exact structure:

```markdown
# Renderer Overscan Research

## Decision

Status: `available` or `unavailable`

## Required Invariant

The UI must not invent scrollback rows. Pixel scrolling may only use rows returned by libghostty-vt.

## API Findings

- Render state row iterator:
- Terminal viewport APIs:
- Scrollbar APIs:
- Non-mutating overscan row access:

## Implementation Consequence

If `available`, implement `GhosttyVTBridge.scrollFrame(overscanTop:overscanBottom:)`.

If `unavailable`, keep diagnostics at:

```text
pixel smooth scroll: unavailable
reason: missing overscan rows from libghostty-vt snapshot
```
```

- [ ] **Step 4: Commit research document**

Run:

```bash
git add docs/renderer-overscan-research.md
git commit -m "document overscan renderer research"
```

Expected: commit succeeds. Do not modify renderer code in this task.

---

### Task 2: Add Scroll Frame Models

**Files:**
- Modify: `Sources/ProGhosttyCore/TerminalCore/LibGhostty/GhosttyVTBridge.swift`
- Test: `Tests/ProGhosttyCoreTests/GhosttyVTBridgeTests.swift`

- [ ] **Step 1: Write the failing model test**

Add this test to `GhosttyVTBridgeTests`:

```swift
@Test func scrollFrameReportsVisibleAndOverscanRowsSeparately() throws {
  let bridge = try GhosttyVTBridge(cols: 20, rows: 4, maxScrollback: 100)
  bridge.write(Data("one\r\ntwo\r\nthree\r\nfour\r\nfive\r\nsix".utf8))

  let frame = try bridge.scrollFrame(overscanTop: 1, overscanBottom: 1)

  #expect(frame.viewport.cols == 20)
  #expect(frame.viewport.rows == 4)
  #expect(frame.overscanTop.count <= 1)
  #expect(frame.overscanBottom.count <= 1)
  #expect(frame.requestedOverscanTop == 1)
  #expect(frame.requestedOverscanBottom == 1)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
swift test --filter GhosttyVTBridgeTests/scrollFrameReportsVisibleAndOverscanRowsSeparately --no-parallel
```

Expected: FAIL because `scrollFrame` and `GhosttyTerminalScrollFrame` do not exist.

- [ ] **Step 3: Add Swift model types**

In `GhosttyVTBridge.swift`, add:

```swift
public struct GhosttyTerminalCellRow: Sendable, Equatable {
  public var cells: [GhosttyTerminalFrame.Cell]

  public init(cells: [GhosttyTerminalFrame.Cell]) {
    self.cells = cells
  }
}

public struct GhosttyTerminalScrollFrame: Sendable, Equatable {
  public var viewport: GhosttyTerminalFrame
  public var overscanTop: [GhosttyTerminalCellRow]
  public var overscanBottom: [GhosttyTerminalCellRow]
  public var requestedOverscanTop: Int
  public var requestedOverscanBottom: Int
  public var viewportStartRow: UInt64?

  public init(
    viewport: GhosttyTerminalFrame,
    overscanTop: [GhosttyTerminalCellRow],
    overscanBottom: [GhosttyTerminalCellRow],
    requestedOverscanTop: Int,
    requestedOverscanBottom: Int,
    viewportStartRow: UInt64?
  ) {
    self.viewport = viewport
    self.overscanTop = overscanTop
    self.overscanBottom = overscanBottom
    self.requestedOverscanTop = requestedOverscanTop
    self.requestedOverscanBottom = requestedOverscanBottom
    self.viewportStartRow = viewportStartRow
  }
}
```

- [ ] **Step 4: Add temporary unavailable implementation**

Add this method to `GhosttyVTBridge`:

```swift
public func scrollFrame(overscanTop: Int, overscanBottom: Int) throws -> GhosttyTerminalScrollFrame {
  let viewport = try frame()
  let scrollbar = try? scrollbar()
  return GhosttyTerminalScrollFrame(
    viewport: viewport,
    overscanTop: [],
    overscanBottom: [],
    requestedOverscanTop: max(0, overscanTop),
    requestedOverscanBottom: max(0, overscanBottom),
    viewportStartRow: scrollbar?.offset
  )
}
```

- [ ] **Step 5: Run test to verify it passes**

Run:

```bash
swift test --filter GhosttyVTBridgeTests/scrollFrameReportsVisibleAndOverscanRowsSeparately --no-parallel
```

Expected: PASS. This task only creates the model contract; real overscan comes later.

- [ ] **Step 6: Commit model contract**

Run:

```bash
git add Sources/ProGhosttyCore/TerminalCore/LibGhostty/GhosttyVTBridge.swift Tests/ProGhosttyCoreTests/GhosttyVTBridgeTests.swift
git commit -m "add terminal scroll frame model"
```

---

### Task 3: Implement Bridge Overscan or Preserve Explicit Unavailable State

**Files:**
- Modify: `Sources/ProGhosttyGhosttyVT/include/ProGhosttyGhosttyVT.h`
- Modify: `Sources/ProGhosttyGhosttyVT/ProGhosttyGhosttyVT.c`
- Modify: `Sources/ProGhosttyCore/TerminalCore/LibGhostty/GhosttyVTBridge.swift`
- Test: `Tests/ProGhosttyCoreTests/GhosttyVTBridgeTests.swift`

- [ ] **Step 1: Write a capability test**

Add this test to `GhosttyVTBridgeTests`:

```swift
@Test func scrollFrameCapabilityMatchesOverscanRows() throws {
  let bridge = try GhosttyVTBridge(cols: 20, rows: 3, maxScrollback: 100)
  bridge.write(Data("one\r\ntwo\r\nthree\r\nfour\r\nfive".utf8))

  let frame = try bridge.scrollFrame(overscanTop: 1, overscanBottom: 1)

  if frame.overscanAvailable {
    #expect(frame.overscanTop.count + frame.overscanBottom.count > 0)
  } else {
    #expect(frame.overscanTop.isEmpty)
    #expect(frame.overscanBottom.isEmpty)
  }
}
```

- [ ] **Step 2: Add `overscanAvailable` to the Swift model**

Update `GhosttyTerminalScrollFrame`:

```swift
public var overscanAvailable: Bool {
  !overscanTop.isEmpty || !overscanBottom.isEmpty
}
```

- [ ] **Step 3: Run capability test**

Run:

```bash
swift test --filter GhosttyVTBridgeTests/scrollFrameCapabilityMatchesOverscanRows --no-parallel
```

Expected: PASS with `overscanAvailable == false` until the C bridge can return real rows.

- [ ] **Step 4: If research found a non-mutating row API, implement C bridge extraction**

Only do this if Task 1 documented an available API. Add C structs mirroring `ProGhosttyVTCell` rows and expose:

```c
int proghostty_vt_scroll_snapshot(
  ProGhosttyVT *vt,
  uint16_t overscan_top,
  uint16_t overscan_bottom,
  ProGhosttyVTScrollSnapshot *out
);
```

Expected behavior:
- `out->viewport` contains the same cells as `proghostty_vt_snapshot`.
- `out->overscan_top_count <= overscan_top`.
- `out->overscan_bottom_count <= overscan_bottom`.
- Function does not mutate terminal viewport.

- [ ] **Step 5: If no API exists, do not fake overscan**

Keep `scrollFrame` returning empty overscan arrays and ensure diagnostics remain unavailable in Task 4.

- [ ] **Step 6: Run bridge tests**

Run:

```bash
swift test --filter GhosttyVTBridgeTests --no-parallel
```

Expected: all bridge tests pass.

- [ ] **Step 7: Commit bridge capability**

Run:

```bash
git add Sources/ProGhosttyGhosttyVT Sources/ProGhosttyCore/TerminalCore/LibGhostty/GhosttyVTBridge.swift Tests/ProGhosttyCoreTests/GhosttyVTBridgeTests.swift
git commit -m "add ghostty vt overscan capability probe"
```

---

### Task 4: Add Renderer Diagnostics for Overscan Pixel Scrolling

**Files:**
- Modify: `Sources/ProGhosttyCore/TerminalCore/Renderer/TerminalRendererBackend.swift`
- Modify: `Sources/ProGhosttyCore/TerminalCore/Renderer/GhosttyVTCellGridRendererBackend.swift`
- Test: `Tests/ProGhosttyCoreTests/TerminalRendererBackendTests.swift`

- [ ] **Step 1: Write failing diagnostics test**

Add this test:

```swift
@MainActor @Test func rendererDiagnosticsReportOverscanPixelScrollAvailability() {
  var diagnostics = TerminalRendererDiagnostics(backend: .ghosttyVTCellGrid)

  #expect(diagnostics.pixelSmoothScroll == .unavailable)
  #expect(diagnostics.pixelSmoothScrollReason == TerminalRendererDiagnostics.missingOverscanRowsReason)

  diagnostics.overscanTopRows = 1
  diagnostics.overscanBottomRows = 1
  diagnostics.pixelSmoothScroll = .experimental
  diagnostics.pixelSmoothScrollReason = "overscan rows available from libghostty-vt snapshot"

  #expect(diagnostics.debugSummary.contains("overscanTop=1"))
  #expect(diagnostics.debugSummary.contains("overscanBottom=1"))
  #expect(diagnostics.debugSummary.contains("pixelSmoothScroll=experimental"))
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
swift test --filter TerminalRendererBackendTests/rendererDiagnosticsReportOverscanPixelScrollAvailability --no-parallel
```

Expected: FAIL because overscan diagnostics fields do not exist.

- [ ] **Step 3: Add diagnostics fields**

In `TerminalRendererDiagnostics`, add:

```swift
public var overscanTopRows: Int
public var overscanBottomRows: Int
```

Add init parameters:

```swift
overscanTopRows: Int = 0,
overscanBottomRows: Int = 0,
```

Add to `debugSummary`:

```swift
overscanTop=\(overscanTopRows) overscanBottom=\(overscanBottomRows)
```

- [ ] **Step 4: Run diagnostics test**

Run:

```bash
swift test --filter TerminalRendererBackendTests/rendererDiagnosticsReportOverscanPixelScrollAvailability --no-parallel
```

Expected: PASS.

- [ ] **Step 5: Commit diagnostics**

Run:

```bash
git add Sources/ProGhosttyCore/TerminalCore/Renderer Tests/ProGhosttyCoreTests/TerminalRendererBackendTests.swift
git commit -m "expose overscan scroll diagnostics"
```

---

### Task 5: Wire Experimental Pixel Scroll Path Without Enabling by Default

**Files:**
- Modify: `Sources/ProGhosttyCore/TerminalCore/PTY/PTYTerminalEngine.swift`
- Modify: `Sources/ProGhosttyCore/TerminalCore/Renderer/GhosttyVTCellGridRendererBackend.swift`
- Test: `Tests/ProGhosttyCoreTests/TerminalSurfaceTests.swift`

- [ ] **Step 1: Write failing fallback test**

Add this test to `TerminalSurfaceTests`:

```swift
@MainActor @Test func liveCellGridDoesNotUsePixelOffsetWithoutOverscanRows() throws {
  let registry = PTYTerminalSurfaceRegistry()
  let session = TerminalSessionID()
  registry.createSurface(session: session)
  let surfaceView = try #require(registry.viewForSession(session) as? PTYTerminalSurfaceView)
  let bridge = try GhosttyVTBridge(cols: 20, rows: 2, maxScrollback: 100)
  bridge.write(Data("first\r\nsecond\r\nthird".utf8))

  registry.render(bridge, session: session)
  surfaceView.liveGridView.testScrollWheelDeltaY(5)

  #expect(surfaceView.liveGridView.viewport.visualOffsetY == 0)
  #expect(try #require(registry.rendererDiagnostics(for: session)).pixelSmoothScroll == .unavailable)
}
```

- [ ] **Step 2: Run test**

Run:

```bash
swift test --filter TerminalSurfaceTests/liveCellGridDoesNotUsePixelOffsetWithoutOverscanRows --no-parallel
```

Expected: PASS in current behavior. If it fails, fix by ensuring `visualOffsetY` is reset when no overscan rows are available.

- [ ] **Step 3: Add internal feature flag only**

Use existing `RendererDebug.enableExperimentalPixelScroll`. Do not expose a normal Settings toggle.

Expected behavior:
- `PROGHOSTTY_EXPERIMENTAL_PIXEL_SCROLL=1` can attempt overscan path.
- Without the env var, renderer remains row-based.

- [ ] **Step 4: Add overscan-aware render path**

Only when all are true:
- `RendererDebug.enableExperimentalPixelScroll == true`
- `bridge.scrollFrame(overscanTop:overscanBottom:)` returns real overscan rows
- active screen is not a TUI alternate-screen case that should consume wheel events

Then:
- accumulate `visualOffsetY` within one row height.
- when absolute offset reaches one row, commit a row delta through `ghostty_terminal_scroll_viewport`.
- fetch a fresh scroll frame.

- [ ] **Step 5: Run surface tests**

Run:

```bash
swift test --filter TerminalSurfaceTests --no-parallel
```

Expected: all surface tests pass; Codex-like refresh tests remain stable.

- [ ] **Step 6: Commit experimental wiring**

Run:

```bash
git add Sources/ProGhosttyCore/TerminalCore/PTY/PTYTerminalEngine.swift Sources/ProGhosttyCore/TerminalCore/Renderer Tests/ProGhosttyCoreTests/TerminalSurfaceTests.swift
git commit -m "gate pixel scrolling on real overscan rows"
```

---

### Task 6: Full Verification and Manual Runtime Check

**Files:**
- No new source files unless a test failure requires a fix.

- [ ] **Step 1: Run full automated verification**

Run:

```bash
swift test --no-parallel
git diff --check
swift build
```

Expected:
- Swift tests pass.
- `git diff --check` exits 0.
- Build exits 0.

- [ ] **Step 2: Restart the latest debug app**

Run:

```bash
pid=$(pgrep -f '/Users/zpc/projects/proghostty/.build/arm64-apple-macosx/debug/ProGhostty.app/Contents/MacOS/ProGhostty' | head -1); if [ -n "$pid" ]; then kill "$pid"; fi
cp .build/arm64-apple-macosx/debug/ProGhostty .build/arm64-apple-macosx/debug/ProGhostty.app/Contents/MacOS/ProGhostty
codesign --force --deep --sign - .build/arm64-apple-macosx/debug/ProGhostty.app
open .build/arm64-apple-macosx/debug/ProGhostty.app
```

Expected: app launches from the rebuilt bundle.

- [ ] **Step 3: Manual behavior check**

In ProGhostty:

```bash
printf 'line %03d\n' {1..120}
```

Check:
- Row-based scrolling remains stable when experimental flag is not set.
- No reverse jump.
- No edge jitter.
- Codex/Claude TUI still does not flicker.

- [ ] **Step 4: Commit verification fixes if needed**

If changes were required:

```bash
git add Sources Tests docs
git commit -m "stabilize overscan pixel scrolling"
```

---

## Self-Review

- Spec coverage:
  - Uses libghostty-vt as source of truth.
  - Keeps `visualOffsetY` bounded to sub-row use only.
  - Disables pixel scrolling when real overscan rows are unavailable.
  - Does not use HTML/WKWebView/TextKit as the main terminal renderer.
  - Preserves stable row-based scrolling as the default path.
- Placeholder scan:
  - The only conditional section is intentionally gated on Task 1 research outcome.
  - No task asks the implementer to invent overscan rows.
- Type consistency:
  - `GhosttyTerminalScrollFrame`, `GhosttyTerminalCellRow`, `scrollFrame(overscanTop:overscanBottom:)`, and diagnostics names are consistent across tasks.

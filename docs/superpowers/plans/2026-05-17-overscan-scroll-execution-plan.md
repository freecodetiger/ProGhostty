# Overscan Scroll Execution Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move ProGhostty toward true pixel scrolling without weakening the stable `PTY -> libghostty-vt -> cell-grid -> AppKit` renderer path.

**Architecture:** The default renderer stays row-based and uses libghostty-vt as the only source of terminal viewport truth. Pixel scrolling may become available only when the C bridge returns real rows above and below the visible viewport, and even then it remains behind `PROGHOSTTY_EXPERIMENTAL_PIXEL_SCROLL=1`.

**Tech Stack:** Swift, AppKit, Swift Testing, C bridge, vendored `libghostty-vt`, existing `GhosttyVTCellGridRendererBackend`.

---

## Current Baseline

Remote `main` is pushed through:

```text
44e29ba add terminal scroll frame model
```

Already completed:

- `docs/renderer-overscan-research.md` documents that bounded overscan is possible through `ghostty_terminal_grid_ref`.
- `GhosttyTerminalScrollFrame` and `GhosttyTerminalCellRow` exist in `GhosttyVTBridge.swift`.
- `GhosttyVTBridge.scrollFrame(overscanTop:overscanBottom:)` exists but currently returns empty overscan rows.
- Default diagnostics still report row-based scrolling and pixel scrolling unavailable.

Local working tree note:

- There is a local, uncommitted failing test probe for real overscan rows.
- Do not push that probe until the C bridge implementation makes it pass.

## Non-Negotiable Invariants

- `libghostty-vt` viewport is the only real terminal scroll state.
- The UI must not invent rows.
- `visualOffsetY` must not participate in default drawing.
- Main terminal rendering must not use HTML, WKWebView, or TextKit.
- TUI stability for Codex, Claude Code, vim, and tmux is higher priority than scroll smoothness.
- Overscan row access must be bounded to a very small number of rows.
- The visible viewport must continue to use the render-state row iterator, not `grid_ref`.

## File Responsibilities

- `Sources/ProGhosttyGhosttyVT/include/ProGhosttyGhosttyVT.h`
  - Owns C ABI types for scroll snapshots.
- `Sources/ProGhosttyGhosttyVT/ProGhosttyGhosttyVT.c`
  - Owns bounded overscan extraction from libghostty-vt.
- `Sources/ProGhosttyCore/TerminalCore/LibGhostty/GhosttyVTBridge.swift`
  - Converts C scroll snapshots into Swift `GhosttyTerminalScrollFrame`.
- `Sources/ProGhosttyCore/TerminalCore/Renderer/TerminalRendererBackend.swift`
  - Owns renderer diagnostics and experimental capability reporting.
- `Sources/ProGhosttyCore/TerminalCore/Renderer/GhosttyVTCellGridRendererBackend.swift`
  - Owns cell-grid render diagnostics and dirty-row behavior.
- `Sources/ProGhosttyCore/TerminalCore/PTY/PTYTerminalEngine.swift`
  - Owns scroll input routing and viewport commits.
- `Tests/ProGhosttyCoreTests/GhosttyVTBridgeTests.swift`
  - Verifies libghostty-vt bridge frame and overscan behavior.
- `Tests/ProGhosttyCoreTests/TerminalRendererBackendTests.swift`
  - Verifies diagnostics and renderer guardrails.

---

### Task 1: Implement Real Overscan Snapshot in the C Bridge

**Files:**

- Modify: `Sources/ProGhosttyGhosttyVT/include/ProGhosttyGhosttyVT.h`
- Modify: `Sources/ProGhosttyGhosttyVT/ProGhosttyGhosttyVT.c`
- Modify: `Sources/ProGhosttyCore/TerminalCore/LibGhostty/GhosttyVTBridge.swift`
- Test: `Tests/ProGhosttyCoreTests/GhosttyVTBridgeTests.swift`

- [ ] **Step 1: Keep the failing bridge test**

Use this test as the acceptance probe:

```swift
@Test func scrollFrameCapabilityMatchesOverscanRows() throws {
  let bridge = try GhosttyVTBridge(cols: 20, rows: 3, maxScrollback: 100)
  bridge.write(Data("one\r\ntwo\r\nthree\r\nfour\r\nfive".utf8))
  bridge.scrollViewport(deltaRows: -1)

  let frame = try bridge.scrollFrame(overscanTop: 1, overscanBottom: 1)

  #expect(frame.overscanAvailable)
  #expect(frame.overscanTop.count == 1)
  #expect(frame.overscanBottom.count == 1)
  #expect(frame.overscanTop.first?.text(cols: frame.viewport.cols).contains("one") == true)
  #expect(frame.overscanBottom.first?.text(cols: frame.viewport.cols).contains("five") == true)
}
```

Run:

```bash
swift test --filter GhosttyVTBridgeTests/scrollFrameCapabilityMatchesOverscanRows --no-parallel
```

Expected before implementation: FAIL because `scrollFrame` returns no overscan rows.

- [ ] **Step 2: Add C snapshot ABI**

Add a C type that keeps the visible viewport and overscan buffers separate:

```c
typedef struct {
  ProGhosttyVTSnapshot viewport;
  ProGhosttyVTCell *overscan_top_cells;
  size_t overscan_top_rows;
  ProGhosttyVTCell *overscan_bottom_cells;
  size_t overscan_bottom_rows;
  uint16_t requested_overscan_top;
  uint16_t requested_overscan_bottom;
  uint64_t viewport_start_row;
} ProGhosttyVTScrollSnapshot;

int proghostty_vt_scroll_snapshot(
  ProGhosttyVT *vt,
  uint16_t overscan_top,
  uint16_t overscan_bottom,
  ProGhosttyVTScrollSnapshot *out);

void proghostty_vt_scroll_snapshot_free(ProGhosttyVTScrollSnapshot *snapshot);
```

- [ ] **Step 3: Implement bounded grid-ref row extraction**

In `ProGhosttyGhosttyVT.c`, implement the scroll snapshot as:

```text
1. memset out to zero
2. call proghostty_vt_snapshot for viewport
3. if viewport.alternate_screen, return success with empty overscan
4. read ProGhosttyVTScrollbar
5. compute top row range:
   max(0, offset - overscan_top) ..< offset
6. compute bottom row range:
   offset + length ..< min(total, offset + length + overscan_bottom)
7. use ghostty_terminal_grid_ref with GHOSTTY_POINT_TAG_SCREEN for those rows only
8. copy cells immediately into owned ProGhosttyVTCell buffers
```

Important implementation details:

- Clamp requested overscan to at most `2` rows per side for now.
- Do not use `grid_ref` for visible viewport rows.
- Free `viewport` and both overscan buffers in `proghostty_vt_scroll_snapshot_free`.
- Preserve `inverse` as a style bit. Do not pre-swap foreground and background in the C bridge.
- If `grid_ref` fails for an individual cell, write a blank default cell instead of failing the entire snapshot.

- [ ] **Step 4: Convert the C snapshot in Swift**

In `GhosttyVTBridge.scrollFrame(overscanTop:overscanBottom:)`:

```text
1. call proghostty_vt_scroll_snapshot
2. convert snapshot.viewport through the same cell mapping used by frame()
3. convert flat overscan cell buffers into [GhosttyTerminalCellRow]
4. free the C snapshot with proghostty_vt_scroll_snapshot_free
```

Extract a helper so `frame()` and `scrollFrame()` use identical cell conversion:

```swift
private static func cell(from rawCell: ProGhosttyVTCell) -> GhosttyTerminalFrame.Cell
```

- [ ] **Step 5: Verify bridge behavior**

Run:

```bash
swift test --filter GhosttyVTBridgeTests --no-parallel
```

Expected: PASS.

- [ ] **Step 6: Commit**

Run:

```bash
git add Sources/ProGhosttyGhosttyVT Sources/ProGhosttyCore/TerminalCore/LibGhostty/GhosttyVTBridge.swift Tests/ProGhosttyCoreTests/GhosttyVTBridgeTests.swift
git commit -m "add ghostty vt overscan snapshot"
```

---

### Task 2: Expose Overscan Capability in Diagnostics

**Files:**

- Modify: `Sources/ProGhosttyCore/TerminalCore/Renderer/TerminalRendererBackend.swift`
- Modify: `Sources/ProGhosttyCore/TerminalCore/Renderer/GhosttyVTCellGridRendererBackend.swift`
- Test: `Tests/ProGhosttyCoreTests/TerminalRendererBackendTests.swift`

- [ ] **Step 1: Add failing diagnostics test**

Add:

```swift
@Test func rendererDiagnosticsReportOverscanRows() {
  var diagnostics = TerminalRendererDiagnostics(backend: .ghosttyVTCellGrid)

  #expect(diagnostics.scrollMode == .rowBased)
  #expect(diagnostics.overscanTopRows == 0)
  #expect(diagnostics.overscanBottomRows == 0)
  #expect(diagnostics.pixelSmoothScroll == .unavailable)

  diagnostics.overscanTopRows = 1
  diagnostics.overscanBottomRows = 1
  diagnostics.pixelSmoothScroll = .experimental
  diagnostics.pixelSmoothScrollReason = TerminalRendererDiagnostics.overscanRowsAvailableReason

  #expect(diagnostics.debugSummary.contains("overscanTop=1"))
  #expect(diagnostics.debugSummary.contains("overscanBottom=1"))
  #expect(diagnostics.debugSummary.contains("pixelSmoothScroll=experimental"))
}
```

Run:

```bash
swift test --filter TerminalRendererBackendTests/rendererDiagnosticsReportOverscanRows --no-parallel
```

Expected before implementation: FAIL because overscan diagnostics fields do not exist.

- [ ] **Step 2: Add diagnostics fields**

Add to `TerminalRendererDiagnostics`:

```swift
public static let overscanRowsAvailableReason = "overscan rows available from libghostty-vt snapshot"
public var overscanTopRows: Int
public var overscanBottomRows: Int
```

Add constructor defaults:

```swift
overscanTopRows: Int = 0,
overscanBottomRows: Int = 0,
```

Append to `debugSummary`:

```text
overscanTop=\(overscanTopRows) overscanBottom=\(overscanBottomRows)
```

- [ ] **Step 3: Keep default unavailable**

Ensure a default `TerminalRendererDiagnostics(backend: .ghosttyVTCellGrid)` still reports:

```text
scrollMode=row-based
pixelSmoothScroll=unavailable
pixelSmoothScrollReason="missing overscan rows from libghostty-vt snapshot"
overscanTop=0
overscanBottom=0
```

- [ ] **Step 4: Verify diagnostics tests**

Run:

```bash
swift test --filter TerminalRendererBackendTests --no-parallel
```

Expected: PASS.

- [ ] **Step 5: Commit**

Run:

```bash
git add Sources/ProGhosttyCore/TerminalCore/Renderer/TerminalRendererBackend.swift Sources/ProGhosttyCore/TerminalCore/Renderer/GhosttyVTCellGridRendererBackend.swift Tests/ProGhosttyCoreTests/TerminalRendererBackendTests.swift
git commit -m "expose overscan renderer diagnostics"
```

---

### Task 3: Gate Experimental Pixel Scrolling on Real Overscan

**Files:**

- Modify: `Sources/ProGhosttyCore/TerminalCore/PTY/PTYTerminalEngine.swift`
- Modify: `Sources/ProGhosttyCore/TerminalCore/Renderer/CellGridModel.swift`
- Modify: `Sources/ProGhosttyCore/TerminalCore/Renderer/GhosttyVTCellGridRendererBackend.swift`
- Test: `Tests/ProGhosttyCoreTests/TerminalRendererBackendTests.swift`
- Test: `Tests/ProGhosttyCoreTests/TerminalSurfaceTests.swift`

- [ ] **Step 1: Add guardrail tests**

Add tests that prove default rendering is unchanged:

```swift
@Test func defaultRendererKeepsVisualOffsetOutOfDrawing() {
  #expect(PTYGridView.visualScrollTranslationY(for: TerminalViewport(visualOffsetY: 8)) == 0)
  #expect(PTYGridView.contentDirtyRect(
    forDrawing: NSRect(x: 0, y: 10, width: 100, height: 20),
    viewport: TerminalViewport(visualOffsetY: 8)
  ) == NSRect(x: 0, y: 10, width: 100, height: 20))
}
```

Add a second test that verifies alternate screen keeps normal TUI input routing:

```swift
@Test func smoothScrollControllerForwardsAlternateScreenWheelInput() {
  var controller = SmoothScrollController()

  let decision = controller.scroll(deltaY: 18, cellHeight: 16, maxStartRow: 20, alternateScreen: true)

  #expect(decision == .forwardToPTY)
  #expect(controller.viewport.visualOffsetY == 0)
}
```

- [ ] **Step 2: Add experimental capability conditions**

Only attempt sub-row visual offset when all are true:

```text
RendererDebug.enableExperimentalPixelScroll == true
frame.isAlternateScreen == false
scrollFrame.overscanAvailable == true
scrollFrame.overscanTop.count > 0 or scrollFrame.overscanBottom.count > 0 for the intended direction
```

If any condition fails:

```text
commit whole-row scroll to libghostty
set visualOffsetY = 0
diagnostics pixelSmoothScroll = unavailable
```

- [ ] **Step 3: Keep Codex and Claude Code stable**

Codex and Claude Code normally use alternate screen semantics. For those frames:

```text
no scrollback visual interpolation
no local viewport transform
wheel/input events are forwarded consistently
dirty-row rendering remains the only optimization path
```

- [ ] **Step 4: Verify default and experimental modes separately**

Default:

```bash
swift test --filter TerminalRendererBackendTests --no-parallel
swift test --filter TerminalSurfaceTests --no-parallel
```

Experimental:

```bash
PROGHOSTTY_EXPERIMENTAL_PIXEL_SCROLL=1 swift test --filter TerminalRendererBackendTests --no-parallel
```

Expected: PASS. Experimental mode must not make default-mode tests depend on visual transform behavior.

- [ ] **Step 5: Commit**

Run:

```bash
git add Sources/ProGhosttyCore/TerminalCore/PTY/PTYTerminalEngine.swift Sources/ProGhosttyCore/TerminalCore/Renderer Tests/ProGhosttyCoreTests
git commit -m "gate pixel scrolling on real overscan rows"
```

---

### Task 4: Manual TUI Verification

**Files:**

- No code required unless bugs are found.

- [ ] **Step 1: Build**

Run:

```bash
swift build
```

Expected: build succeeds.

- [ ] **Step 2: Launch app**

Run the existing local launch command used for this project. If needed:

```bash
swift run ProGhostty
```

Expected: app launches with the latest local build.

- [ ] **Step 3: Verify normal shell**

In a normal shell pane:

```bash
seq 1 200
```

Expected:

- Row-based scrolling works.
- No flicker.
- No content drift.
- No false pixel-scroll transform in default mode.

- [ ] **Step 4: Verify Codex**

Run:

```bash
codex --yolo
```

Expected:

- Slash menu input does not lose focus.
- No full-screen clear flash during ordinary typing.
- Cursor stays aligned with the input row.
- Box drawing stays inside the terminal columns.

- [ ] **Step 5: Verify split panes**

Create two or more panes and resize them.

Expected:

- Each pane keeps its own PTY session.
- Resize propagates to libghostty-vt.
- Focus changes do not trigger titlebar or renderer flicker.

---

### Task 5: Final Audit and Push

**Files:**

- All touched files.

- [ ] **Step 1: Check status**

Run:

```bash
git status --short --branch
```

Expected: only intentional changes are present.

- [ ] **Step 2: Run verification**

Run:

```bash
swift test --no-parallel
git diff --check
swift build
```

Expected: all pass.

- [ ] **Step 3: Push**

Run:

```bash
git push
```

Expected: remote `main` receives all commits.

## Explicitly Deferred

- Do not replace the main renderer with HTML, WKWebView, or TextKit.
- Do not implement pixel scrolling by moving the current viewport snapshot without real overscan rows.
- Do not use `grid_ref` for the visible viewport render loop.
- Do not expose a normal Settings toggle for pixel scrolling.
- Do not make pixel scrolling block split panes, workspace management, or plugin manager work.

## Success Criteria

- Default mode remains stable row-based scrolling.
- Renderer diagnostics show overscan availability explicitly.
- Experimental pixel scrolling is unavailable unless real overscan rows exist.
- Codex and Claude Code do not flicker or lose focus because of scroll changes.
- Dirty-row rendering remains intact.
- Full test suite passes before pushing implementation commits.

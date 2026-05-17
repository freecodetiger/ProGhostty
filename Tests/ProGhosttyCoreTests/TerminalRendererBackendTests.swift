import AppKit
import Testing

@testable import ProGhosttyCore

@Suite("Terminal renderer backend")
struct TerminalRendererBackendTests {
  @Test func cellGridDirtyTrackerScopesSingleCharacterChangeToOneRow() {
    let old = frame(rows: ["abc", "def"], cols: 8, cursorX: 1, cursorY: 0)
    let new = frame(rows: ["abc", "dxf"], cols: 8, cursorX: 1, cursorY: 0)

    let result = CellGridDirtyTracker.diff(previous: old, next: new)

    #expect(result.mode == .dirty)
    #expect(result.rows == [1])
  }

  @Test func cellGridDirtyTrackerScopesCursorMoveToOldAndNewRows() {
    let old = frame(rows: ["abc", "def", "ghi"], cols: 8, cursorX: 1, cursorY: 0)
    let new = frame(rows: ["abc", "def", "ghi"], cols: 8, cursorX: 1, cursorY: 2)

    let result = CellGridDirtyTracker.diff(previous: old, next: new)

    #expect(result.mode == .dirty)
    #expect(result.rows == [0, 2])
  }

  @Test func cellGridDirtyTrackerIncludesSelectionRows() {
    let old = frame(rows: ["abc", "def", "ghi"], cols: 8, cursorX: 1, cursorY: 0)
    let new = frame(rows: ["abc", "def", "ghi"], cols: 8, cursorX: 1, cursorY: 0)

    let result = CellGridDirtyTracker.diff(
      previous: old,
      next: new,
      previousSelectionRows: [1],
      nextSelectionRows: [2]
    )

    #expect(result.mode == .dirty)
    #expect(result.rows == [1, 2])
  }

  @Test func cellGridDirtyTrackerMarksFullDirtyWhenGridSizeChanges() {
    let old = frame(rows: ["abc", "def"], cols: 8, cursorX: 1, cursorY: 0)
    let new = frame(rows: ["abc", "def", "ghi"], cols: 8, cursorX: 1, cursorY: 0)

    let result = CellGridDirtyTracker.diff(previous: old, next: new)

    #expect(result.mode == .full)
    #expect(result.rows == [0, 1, 2])
  }

  @Test func smoothScrollControllerConvertsPixelRemainderIntoStartRow() {
    var controller = SmoothScrollController()

    let decision = controller.scroll(deltaY: 37, cellHeight: 16, maxStartRow: 20, alternateScreen: false)

    #expect(decision == .consumed(rowDelta: 2))
    #expect(controller.viewport.startRow == 2)
    #expect(controller.viewport.visualOffsetY == 5)
  }

  @MainActor @Test func liveGridVisualScrollTranslationMatchesViewportDirection() {
    #expect(PTYGridView.visualScrollTranslationY(for: TerminalViewport(visualOffsetY: 5)) == 0)
    #expect(PTYGridView.visualScrollTranslationY(for: TerminalViewport(visualOffsetY: -5)) == 0)
  }

  @MainActor @Test func liveGridDirtyRectCullingAccountsForVisualScrollTransform() {
    let dirtyRect = NSRect(x: 0, y: 20, width: 80, height: 16)

    #expect(
      PTYGridView.contentDirtyRect(
        forDrawing: dirtyRect,
        viewport: TerminalViewport(visualOffsetY: 5)
      ) == NSRect(x: 0, y: 20, width: 80, height: 16)
    )
    #expect(
      PTYGridView.contentDirtyRect(
        forDrawing: dirtyRect,
        viewport: TerminalViewport(visualOffsetY: -5)
      ) == NSRect(x: 0, y: 20, width: 80, height: 16)
    )
  }

  @MainActor @Test func liveGridContentClipRectMatchesTerminalColumns() {
    let rect = PTYGridView.terminalContentClipRect(
      cols: 80,
      rows: 24,
      cellSize: CGSize(width: 9, height: 18),
      inset: CGSize(width: 14, height: 12)
    )

    #expect(rect == NSRect(x: 14, y: 12, width: 720, height: 432))
    #expect(rect.maxX == 734)
  }

  @MainActor @Test func liveGridTextGlyphRectsStayPinnedToTerminalColumns() {
    let run = CellDrawRun(
      range: 77..<80,
      text: "──│",
      style: frame(rows: ["   "], cols: 3, cursorX: 0, cursorY: 0).cells[0]
    )

    let rects = PTYGridView.textGlyphRects(
      for: run,
      row: 4,
      cellSize: CGSize(width: 9, height: 18),
      inset: CGSize(width: 14, height: 12)
    )

    #expect(rects.map(\.minX) == [707, 716, 725])
    #expect(rects.last?.maxX == 734)
  }

  @Test func rendererDiagnosticsExposeRowBasedScrollingAndPixelScrollReason() {
    let diagnostics = TerminalRendererDiagnostics(backend: .ghosttyVTCellGrid)

    #expect(diagnostics.scrollMode == .rowBased)
    #expect(diagnostics.pixelSmoothScroll == .unavailable)
    #expect(diagnostics.pixelSmoothScrollReason == TerminalRendererDiagnostics.missingOverscanRowsReason)
    #expect(diagnostics.debugSummary.contains("scrollMode=row-based"))
    #expect(diagnostics.debugSummary.contains("pixelSmoothScroll=unavailable"))
    #expect(diagnostics.debugSummary.contains("missing overscan rows from libghostty-vt snapshot"))
  }

  @Test func smoothScrollControllerIgnoresScrollPastEdges() {
    var topController = SmoothScrollController()

    let topDecision = topController.scroll(deltaY: -37, cellHeight: 16, maxStartRow: 20, alternateScreen: false)

    #expect(topDecision == .ignored)
    #expect(topController.viewport.startRow == 0)
    #expect(topController.viewport.visualOffsetY == 0)

    var bottomController = SmoothScrollController(
      viewport: TerminalViewport(startRow: 20),
      isEnabled: true
    )

    let bottomDecision = bottomController.scroll(deltaY: 37, cellHeight: 16, maxStartRow: 20, alternateScreen: false)

    #expect(bottomDecision == .ignored)
    #expect(bottomController.viewport.startRow == 20)
    #expect(bottomController.viewport.visualOffsetY == 0)
  }

  @Test func smoothScrollControllerDoesNotScrollNormalScrollbackOnAlternateScreen() {
    var controller = SmoothScrollController()

    let decision = controller.scroll(deltaY: 37, cellHeight: 16, maxStartRow: 20, alternateScreen: true)

    #expect(decision == .forwardToPTY)
    #expect(controller.viewport.startRow == 0)
    #expect(controller.viewport.visualOffsetY == 0)
  }

  @Test func viewportControllerDrawsVisibleRowsWithOverscan() {
    let controller = ViewportController(
      viewport: TerminalViewport(startRow: 3, visualOffsetY: 4),
      visibleRowCount: 5,
      overscan: 1
    )

    #expect(controller.rowRange(totalRows: 20) == 2..<10)
  }

  @Test func cellRunBuilderMergesAdjacentCellsWithSameStyle() {
    let cells = Array(frame(rows: ["aaab"], cols: 4, cursorX: 0, cursorY: 0).cells)

    let runs = CellRunBuilder.runs(for: cells)

    #expect(runs.map(\.text) == ["aaab"])
    #expect(runs.map(\.range) == [0..<4])
  }

  @MainActor @Test func cellGridBackendCoalescesManyWritesIntoOneFlush() {
    let backend = GhosttyVTCellGridRendererBackend()

    backend.render(frame: frame(rows: ["one"], cols: 8, cursorX: 0, cursorY: 0))
    backend.render(frame: frame(rows: ["two"], cols: 8, cursorX: 0, cursorY: 0))
    backend.render(frame: frame(rows: ["tri"], cols: 8, cursorX: 0, cursorY: 0))

    #expect(backend.diagnostics.coalescedFrames == 2)
    backend.flushPendingFrame()
    #expect(backend.gridView.renderedText.hasPrefix("tri"))
  }

  @MainActor @Test func cellGridBackendDiagnosticsExposeDirtyAndAlternateScreenState() {
    let backend = GhosttyVTCellGridRendererBackend()
    var next = frame(rows: ["one", "two"], cols: 8, cursorX: 0, cursorY: 0)
    next.isAlternateScreen = true

    backend.render(frame: next)
    backend.flushPendingFrame()

    #expect(backend.diagnostics.backend == .ghosttyVTCellGrid)
    #expect(backend.diagnostics.dirtyRowCount == 2)
    #expect(backend.diagnostics.visibleRowCount == 2)
    #expect(backend.diagnostics.redrawMode == .full)
    #expect(backend.diagnostics.alternateScreenActive == true)
  }

  @MainActor @Test func cellGridBackendDiagnosticsExposeStyleCoverage() {
    let backend = GhosttyVTCellGridRendererBackend()
    let styled = GhosttyTerminalFrame(
      cols: 4,
      rows: 1,
      cursorVisible: true,
      cursorX: 0,
      cursorY: 0,
      cursorShape: .bar,
      cursorBlinking: false,
      isAlternateScreen: true,
      cells: [
        cell("a", foreground: .init(r: 220, g: 30, b: 40), usesDefaultForeground: false),
        cell("b", background: .init(r: 20, g: 80, b: 120), usesDefaultBackground: false),
        cell("c", bold: true, faint: true, underline: true),
        cell("d", inverse: true),
      ]
    )

    backend.render(frame: styled)
    backend.flushPendingFrame()

    #expect(backend.diagnostics.styleStats.explicitForegroundCells == 1)
    #expect(backend.diagnostics.styleStats.explicitBackgroundCells == 1)
    #expect(backend.diagnostics.styleStats.boldCells == 1)
    #expect(backend.diagnostics.styleStats.faintCells == 1)
    #expect(backend.diagnostics.styleStats.underlineCells == 1)
    #expect(backend.diagnostics.styleStats.inverseCells == 1)
    #expect(backend.diagnostics.debugSummary.contains("styleFg=1"))
    #expect(backend.diagnostics.debugSummary.contains("styleInverse=1"))
  }

  @MainActor @Test func cellGridBackendReportsCacheHitRateForUnchangedFrames() {
    let backend = GhosttyVTCellGridRendererBackend()
    let snapshot = frame(rows: ["same"], cols: 8, cursorX: 0, cursorY: 0)

    backend.render(frame: snapshot)
    backend.flushPendingFrame()
    backend.render(frame: snapshot)
    backend.flushPendingFrame()

    #expect(backend.diagnostics.cacheHitRate > 0)
    #expect(backend.diagnostics.redrawMode == .clean)
  }

  @MainActor @Test func cellGridBackendOnlyFullRedrawsWhenFocusActuallyChanges() {
    let backend = GhosttyVTCellGridRendererBackend()

    backend.setFocused(true)
    backend.render(frame: frame(rows: ["one", "two"], cols: 8, cursorX: 0, cursorY: 0))
    backend.flushPendingFrame()
    backend.setFocused(true)
    backend.render(frame: frame(rows: ["one", "twx"], cols: 8, cursorX: 0, cursorY: 0))
    backend.flushPendingFrame()

    #expect(backend.diagnostics.redrawMode == .dirty)
    #expect(backend.diagnostics.dirtyRowCount == 1)

    backend.setFocused(false)
    backend.render(frame: frame(rows: ["one", "twx"], cols: 8, cursorX: 0, cursorY: 0))
    backend.flushPendingFrame()

    #expect(backend.diagnostics.redrawMode == .full)
    #expect(backend.diagnostics.dirtyRowCount == 2)
  }

  @MainActor @Test func cellGridBackendMarksFullRedrawAfterThemeAndFontChanges() {
    let backend = GhosttyVTCellGridRendererBackend()
    let snapshot = frame(rows: ["one", "two"], cols: 8, cursorX: 0, cursorY: 0)

    backend.render(frame: snapshot)
    backend.flushPendingFrame()
    backend.applyPalette(.light)
    backend.render(frame: snapshot)
    backend.flushPendingFrame()

    #expect(backend.diagnostics.redrawMode == .full)
    #expect(backend.diagnostics.dirtyRowCount == 2)

    backend.applyFont(family: "Menlo", size: 16)
    backend.render(frame: snapshot)
    backend.flushPendingFrame()

    #expect(backend.diagnostics.redrawMode == .full)
    #expect(backend.diagnostics.dirtyRowCount == 2)
  }

  @MainActor @Test func cellGridViewTypeNameIsAvailableForBackendArchitecture() {
    let backend = GhosttyVTCellGridRendererBackend()

    #expect(backend.view is CellGridView)
  }

  @MainActor @Test func cellGridViewTracksSelectionRowsForDirtyInvalidation() {
    let view = CellGridView()
    view.render(frame(rows: ["one", "two", "three"], cols: 8, cursorX: 0, cursorY: 0), isFocused: true)

    view.testSetSelection(anchor: GridSelectionCoordinate(row: 0, col: 0), head: GridSelectionCoordinate(row: 2, col: 1))

    #expect(view.currentSelectionRowSet == [0, 1, 2])
  }

  private func frame(rows: [String], cols: Int, cursorX: Int, cursorY: Int) -> GhosttyTerminalFrame {
    let cells = rows.flatMap { row in
      let padded = row.padding(toLength: cols, withPad: " ", startingAt: 0)
      return padded.unicodeScalars.prefix(cols).map {
        GhosttyTerminalFrame.Cell(
          scalar: $0,
          foreground: GhosttyTerminalFrame.RGB(r: 255, g: 255, b: 255),
          background: GhosttyTerminalFrame.RGB(r: 0, g: 0, b: 0),
          bold: false,
          italic: false,
          faint: false,
          underline: false,
          inverse: false,
          usesDefaultForeground: true,
          usesDefaultBackground: true
        )
      }
    }
    return GhosttyTerminalFrame(
      cols: cols,
      rows: rows.count,
      cursorVisible: true,
      cursorX: cursorX,
      cursorY: cursorY,
      cursorShape: .bar,
      cursorBlinking: false,
      isAlternateScreen: false,
      cells: cells
    )
  }

  private func cell(
    _ scalar: UnicodeScalar,
    foreground: GhosttyTerminalFrame.RGB = .init(r: 255, g: 255, b: 255),
    background: GhosttyTerminalFrame.RGB = .init(r: 0, g: 0, b: 0),
    bold: Bool = false,
    italic: Bool = false,
    faint: Bool = false,
    underline: Bool = false,
    inverse: Bool = false,
    usesDefaultForeground: Bool = true,
    usesDefaultBackground: Bool = true
  ) -> GhosttyTerminalFrame.Cell {
    GhosttyTerminalFrame.Cell(
      scalar: scalar,
      foreground: foreground,
      background: background,
      bold: bold,
      italic: italic,
      faint: faint,
      underline: underline,
      inverse: inverse,
      usesDefaultForeground: usesDefaultForeground,
      usesDefaultBackground: usesDefaultBackground
    )
  }
}

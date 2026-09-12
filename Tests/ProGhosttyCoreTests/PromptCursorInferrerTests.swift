import Foundation
import Testing

@testable import ProGhosttyCore

@Suite("Prompt cursor inference")
struct PromptCursorInferrerTests {
  private func makeCell(
    scalar: UnicodeScalar,
    inverse: Bool = false,
    usesDefaultBackground: Bool = true
  ) -> GhosttyTerminalFrame.Cell {
    GhosttyTerminalFrame.Cell(
      scalar: scalar,
      foreground: .init(r: 255, g: 255, b: 255),
      background: .init(r: 0, g: 0, b: 0),
      bold: false, italic: false, faint: false, underline: false,
      inverse: inverse,
      usesDefaultForeground: true,
      usesDefaultBackground: usesDefaultBackground
    )
  }

  private func makeCells(
    _ text: String,
    cols: Int,
    inverse: Set<Int> = [],
    nonDefaultBackground: Set<Int> = []
  ) -> [GhosttyTerminalFrame.Cell] {
    let padded = text.padding(toLength: cols, withPad: " ", startingAt: 0)
    return padded.unicodeScalars.prefix(cols).enumerated().map { index, scalar in
      makeCell(
        scalar: scalar,
        inverse: inverse.contains(index),
        usesDefaultBackground: !nonDefaultBackground.contains(index)
      )
    }
  }

  private func makeFrame(
    rows: [String],
    cols: Int,
    cursorX: Int = 0,
    cursorY: Int = 0,
    cursorVisible: Bool = true
  ) -> GhosttyTerminalFrame {
    let cells = rows.flatMap { makeCells($0, cols: cols) }
    return GhosttyTerminalFrame(
      cols: cols, rows: rows.count, cursorVisible: cursorVisible,
      cursorX: cursorX, cursorY: cursorY, cells: cells
    )
  }

  private func makeFrame(
    cellsByRow: [[GhosttyTerminalFrame.Cell]],
    cols: Int,
    cursorX: Int = 0,
    cursorY: Int = 0,
    cursorVisible: Bool = true
  ) -> GhosttyTerminalFrame {
    GhosttyTerminalFrame(
      cols: cols, rows: cellsByRow.count, cursorVisible: cursorVisible,
      cursorX: cursorX, cursorY: cursorY, cells: cellsByRow.flatMap { $0 }
    )
  }

  private func makeGeometry(frame: GhosttyTerminalFrame) -> RenderedGridGeometry {
    RenderedGridGeometry(
      frame: frame,
      translationY: 0,
      cellSize: NSSize(width: 8, height: 16),
      inset: NSSize(width: 0, height: 0),
      clipRect: NSRect(x: 0, y: 0, width: 800, height: 600),
      absoluteBaseRow: 0
    )
  }

  @Test func hiddenLiveCursorOutranksContentHeuristics() {
    // A fullscreen TUI hides the cursor (DEC 25) and paints its own caret, but
    // reports a live position. That position wins over the content heuristics —
    // the old code dropped it whenever the app hid the cursor, and the heuristic
    // then anchored to whichever row happened to look like input.
    var frame = makeFrame(
      rows: ["output", "grill-with-docs, grilling", ""],
      cols: 30,
      cursorX: 0,
      cursorY: 1,
      cursorVisible: false
    )
    frame.cursorAppVisible = false
    frame.cursorPositionKnown = true
    #expect(PromptCursorInferrer.isLiveHiddenCursor(frame))
  }

  @Test func hiddenCursorParkedAtHomeIsNotALiveCaret() {
    // A presentation frame parks the hidden cursor at the top-left regardless of
    // where the input is: that carries no positional meaning, so the content
    // heuristics still get to run.
    var frame = makeFrame(
      rows: ["output", "> hello"],
      cols: 20,
      cursorX: 0,
      cursorY: 0,
      cursorVisible: false
    )
    frame.cursorAppVisible = false
    frame.cursorPositionKnown = true
    #expect(!PromptCursorInferrer.isLiveHiddenCursor(frame))
  }

  @Test func hiddenCursorWithUnknownPositionIsNotALiveCaret() {
    // The cursor row is outside the viewport, so the reported coordinates are
    // undefined and must not be trusted.
    var frame = makeFrame(
      rows: ["output", "> hello"],
      cols: 20,
      cursorX: 0,
      cursorY: 1,
      cursorVisible: false
    )
    frame.cursorAppVisible = false
    frame.cursorPositionKnown = false
    #expect(!PromptCursorInferrer.isLiveHiddenCursor(frame))
  }

  @Test func visibleParkedCursorIsNotALiveCaret() {
    // A shell that redraws its prompt leaves a *visible* cursor parked at column
    // 0 with the real caret at the end of the typed text — the original reason
    // the heuristics exist.
    let frame = makeFrame(rows: ["zpc@zpc % ls"], cols: 30, cursorX: 0, cursorY: 0)
    #expect(!PromptCursorInferrer.isLiveHiddenCursor(frame))
  }

  @Test func promptMarkerColumnFindsCommonMarkers() {
    let frame = makeFrame(rows: ["  ❯ echo hi"], cols: 20)
    let cells = PromptCursorInferrer.cells(inRow: 0, frame: frame)!
    #expect(PromptCursorInferrer.promptMarkerColumn(in: cells) == 2)
  }

  @Test func promptMarkerColumnNilForPlainOutput() {
    let frame = makeFrame(rows: ["compiling module"], cols: 20)
    let cells = PromptCursorInferrer.cells(inRow: 0, frame: frame)!
    #expect(PromptCursorInferrer.promptMarkerColumn(in: cells) == nil)
  }

  @Test func shouldInferWhenCursorParkedAtOrigin() {
    let frame = makeFrame(rows: ["hello", "world"], cols: 10, cursorX: 0, cursorY: 0)
    #expect(PromptCursorInferrer.shouldInferPromptCursor(for: frame, in: makeGeometry(frame: frame)))
  }

  @Test func shouldInferOnNonZeroCursorRowWithContent() {
    let promptFrame = makeFrame(rows: ["output", "❯ ls"], cols: 10, cursorX: 0, cursorY: 1)
    #expect(PromptCursorInferrer.shouldInferPromptCursor(for: promptFrame, in: makeGeometry(frame: promptFrame)))
    // No prompt marker required: any parked non-blank row can be the input row.
    let plainFrame = makeFrame(rows: ["output", "more out"], cols: 10, cursorX: 0, cursorY: 1)
    #expect(PromptCursorInferrer.shouldInferPromptCursor(for: plainFrame, in: makeGeometry(frame: plainFrame)))
    // A blank parked row carries nothing to anchor to.
    let blankFrame = makeFrame(rows: ["output", "         "], cols: 10, cursorX: 0, cursorY: 1)
    #expect(!PromptCursorInferrer.shouldInferPromptCursor(for: blankFrame, in: makeGeometry(frame: blankFrame)))
  }

  @Test func cursorRowInferencePlacesCursorAfterTypedText() {
    let frame = makeFrame(rows: ["❯ git st"], cols: 20, cursorX: 0, cursorY: 0)
    let coordinate = PromptCursorInferrer.inferredPromptCursorCoordinate(in: makeGeometry(frame: frame))
    // "❯ git st" — last text col 7, cursor lands one past it.
    #expect(coordinate == GridCoordinate(row: 0, col: 8))
  }

  @Test func viewportScanTracksLatestPromptRegion() {
    // The parked cursor sits on the bottom prompt's start (visible cursor).
    let frame = makeFrame(
      rows: ["❯ old command", "output line", "❯ new", ""],
      cols: 20,
      cursorX: 0, cursorY: 2
    )
    let coordinate = PromptCursorInferrer.inferredPromptCursorCoordinate(in: makeGeometry(frame: frame))
    // "❯ new" — last text col 4 → col 5.
    #expect(coordinate == GridCoordinate(row: 2, col: 5))
  }

  @Test func homeParkedFreshShellFindsTextEndOnRowZero() {
    // Reproduction: a fresh zsh window parks the visible cursor at home after
    // redrawing the prompt; the caret is the end of row 0's text. The prompt
    // has no marker (`%`), so this used to fall back to the parked (0,0).
    let frame = makeFrame(rows: ["zpc@zpc proghostty % pi"], cols: 40, cursorX: 0, cursorY: 0)
    let coordinate = PromptCursorInferrer.inferredPromptCursorCoordinate(in: makeGeometry(frame: frame))
    // "zpc@zpc proghostty % pi" — last text col 22 → caret col 23.
    #expect(coordinate == GridCoordinate(row: 0, col: 23))
  }

  @Test func parkedBottomPromptWithoutMarkerFindsTextEnd() {
    // A bottom prompt with no marker (plain `%`) parked at column 0: the
    // visible parked cursor sits on the input row; caret = row text end.
    let frame = makeFrame(rows: ["output line", "zpc@zpc % ls"], cols: 30, cursorX: 0, cursorY: 1)
    let coordinate = PromptCursorInferrer.inferredPromptCursorCoordinate(in: makeGeometry(frame: frame))
    // "zpc@zpc % ls" — last text col 11 → caret col 12.
    #expect(coordinate == GridCoordinate(row: 1, col: 12))
  }

  @Test func hiddenCursorParkedOnLastContentRowFindsTextEnd() {
    // Fresh-shell variant where the shell hides the cursor: the parked cursor
    // sits on the only content row (row 0), which is also the last non-blank
    // row — that row is the input even without a marker or caret cell.
    let frame = makeFrame(
      cellsByRow: [makeCells("zpc@zpc proghostty % pi", cols: 40)],
      cols: 40,
      cursorX: 0, cursorY: 0,
      cursorVisible: false
    )
    let coordinate = PromptCursorInferrer.inferredPromptCursorCoordinate(in: makeGeometry(frame: frame))
    #expect(coordinate == GridCoordinate(row: 0, col: 23))
  }

  @Test func hiddenCursorTuiPrefersLastPromptMarkerRow() {
    // pi-style: hidden cursor parked at home, input row at the bottom with a
    // `>` prompt and an isolated inverse caret cell. The anchor must be the
    // caret, not the parked home cell.
    let frame = makeFrame(
      cellsByRow: [
        makeCells("output line", cols: 20),
        makeCells("> hello ", cols: 20, inverse: [7]),
      ],
      cols: 20,
      cursorX: 0, cursorY: 0,
      cursorVisible: false
    )
    let coordinate = PromptCursorInferrer.inferredPromptCursorCoordinate(in: makeGeometry(frame: frame))
    // "> hello " — prompt at 0, caret (inverse space) at 7.
    #expect(coordinate == GridCoordinate(row: 1, col: 7))
  }

  @Test func styledRowRightEdgeIsNotMistakenForCaret() {
    // Bottom-right regression: a styled (non-default background) input row used
    // to match every cell, so the caret lost to the row's right edge. The caret
    // must win.
    let frame = makeFrame(
      cellsByRow: [
        makeCells("> hello ", cols: 20, inverse: [7], nonDefaultBackground: Set(8..<20)),
      ],
      cols: 20,
      cursorX: 0, cursorY: 0,
      cursorVisible: false
    )
    let coordinate = PromptCursorInferrer.inferredPromptCursorCoordinate(in: makeGeometry(frame: frame))
    #expect(coordinate == GridCoordinate(row: 0, col: 7))
  }

  @Test func rowClassifiersHandleBlankAndPromptRegion() {
    let frame = makeFrame(rows: ["❯ cmd", "", "text"], cols: 10)
    let geometry = makeGeometry(frame: frame)
    #expect(PromptCursorInferrer.rowIsBlank(1, in: geometry))
    #expect(!PromptCursorInferrer.rowIsBlank(2, in: geometry))
    // Every row at or below a prompt marker is in the prompt input region.
    #expect(PromptCursorInferrer.rowIsInPromptInputRegion(2, in: geometry))
  }

  @Test func isolatedInverseCellOnlyCountsAsCaret() {
    var cells = makeCells("> hello ", cols: 20)
    // The app-drawn caret is an isolated inverse cell.
    cells[7].inverse = true
    #expect(PromptCursorInferrer.isCaretCell(cells, at: 7))
    // Highlight runs are not carets: neither the middle nor the edges of an
    // inverse run qualify.
    cells[6].inverse = true
    cells[8].inverse = true
    #expect(!PromptCursorInferrer.isCaretCell(cells, at: 6))
    #expect(!PromptCursorInferrer.isCaretCell(cells, at: 7))
    #expect(!PromptCursorInferrer.isCaretCell(cells, at: 8))
    // A plain cell is not a caret.
    cells[7].inverse = false
    #expect(!PromptCursorInferrer.isCaretCell(cells, at: 7))
  }

  @Test func rectApproximateEqualityUsesHalfPointTolerance() {
    let base = NSRect(x: 10, y: 20, width: 8, height: 16)
    #expect(PromptCursorInferrer.rect(base, approximatelyEquals: base.offsetBy(dx: 0.4, dy: 0.4)))
    #expect(!PromptCursorInferrer.rect(base, approximatelyEquals: base.offsetBy(dx: 1.0, dy: 0)))
    #expect(!PromptCursorInferrer.rect(base, approximatelyEquals: nil))
  }
}

import Foundation

/// Pure prompt-cursor inference over an immutable rendered-frame geometry.
///
/// Extracted from `PTYGridView` (debt spec 4-1). Shells that redraw their
/// prompt leave the VT cursor parked at column 0, and TUI presentation frames
/// (main-screen apps rendered with overscan, or apps that hide the cursor)
/// often carry a meaningless cursor at the top-left. In those states the raw
/// cursor rect cannot anchor an IME composition; these heuristics locate the
/// visual input caret from the parked cursor's row, prompt markers, and cell
/// styling instead. Stateless: every function reads only the
/// `RenderedGridGeometry` snapshot passed in.
enum PromptCursorInferrer {
  /// Whether the VT cursor is a live caret the app maintains while hiding it:
  /// the app turned the cursor off (DEC 25), the viewport still knows where it
  /// is, and it is not parked at home.
  ///
  /// Ghostty's own IME point reads the cursor unconditionally, with no such
  /// condition. ProGhostty cannot: TUIs here transiently park a **visible**
  /// cursor at the start of a row while redrawing, and following it drags the
  /// composition anchor off the input line. The cached Codex CLI cases
  /// (`liveGridPreservesPromptCursorWhenCodexTransientCursorMovesToBlankRowStart`
  /// and friends) pin that behaviour. So the visibility intent is the
  /// discriminator: an app that hid the cursor far enough in advance to paint
  /// its own caret has left the VT cursor on the live caret, whereas a visible
  /// cursor sitting at a row start is mid-redraw and means nothing.
  static func isLiveHiddenCursor(_ frame: GhosttyTerminalFrame) -> Bool {
    !frame.cursorAppVisible
      && frame.cursorPositionKnown
      && !(frame.cursorX == 0 && frame.cursorY == 0)
  }

  /// Whether an input caret can be inferred: the VT cursor must be parked at
  /// column 0 (the redraw/presentation state where the raw cursor rect is
  /// meaningless) and the parked row must not be blank.
  static func shouldInferPromptCursor(
    for viewportFrame: GhosttyTerminalFrame,
    in geometry: RenderedGridGeometry
  ) -> Bool {
    guard viewportFrame.cursorX == 0 else { return false }
    if viewportFrame.cursorY == 0 {
      return true
    }
    return !rowIsBlank(viewportFrame.cursorY, in: geometry)
  }

  /// The inferred input caret when the VT cursor is parked at column 0.
  static func inferredPromptCursorCoordinate(in geometry: RenderedGridGeometry) -> GridCoordinate? {
    guard let regionStart = inputRegionStart(in: geometry) else { return nil }
    let regionEnd = inputRegionEnd(start: regionStart, in: geometry) ?? geometry.frame.rows
    return caretCoordinate(in: regionStart..<regionEnd, geometry: geometry)
  }

  /// The first row of the input region when the VT cursor is parked at column
  /// 0.
  ///
  /// Priority: a *visible* parked cursor sits on the input row (shell prompt
  /// redraws put the real cursor at the prompt start), so its row starts the
  /// region. A *hidden* cursor is ambiguous (TUI presentation frames park it at
  /// the top-left regardless of where the input is), so prompt-marker rows win
  /// first (TUIs keep their input at the bottom); otherwise a hidden cursor
  /// parked on the row where the content ends is the input (fresh shell: the
  /// parked cursor sits at the prompt start on the only content row). Only then
  /// does the content-based last non-blank row count — and only if it looks
  /// like an input row.
  static func inputRegionStart(in geometry: RenderedGridGeometry) -> Int? {
    let frame = geometry.frame
    guard frame.rows > 0 else { return nil }
    let cursorRow = (frame.cursorY >= 0 && frame.cursorY < frame.rows) ? frame.cursorY : nil
    if frame.cursorVisible, let cursorRow {
      return cursorRow
    }
    if let markerRow = lastPromptMarkerRow(in: geometry) {
      return markerRow
    }
    let lastRow = lastNonBlankRow(in: geometry)
    if let lastRow, let cursorRow, cursorRow == lastRow {
      return lastRow
    }
    guard let lastRow else { return nil }
    return rowLooksLikeInput(lastRow, in: geometry) ? lastRow : nil
  }

  /// The caret within an input region: the rightmost isolated inverse cell
  /// (a caret drawn by the app, e.g. pi's `\x1b[7m` block), else the column
  /// right after the last text cell of the region's last row. The last row of
  /// the region wins, so wrapped/continued input lines anchor at the visual
  /// caret even when the prompt marker sits on the first line.
  static func caretCoordinate(in region: Range<Int>, geometry: RenderedGridGeometry) -> GridCoordinate? {
    var bestCaret: GridCoordinate?
    var bestTextEnd: GridCoordinate?
    for row in region {
      guard geometry.clipRect.intersects(geometry.rowRect(row)) else { continue }
      guard let cells = cells(inRow: row, frame: geometry.frame), !cells.isEmpty else { continue }
      // The prompt marker only appears on the region's first row; continuation
      // rows are full-width text.
      let lowerBound = row == region.lowerBound ? (promptMarkerColumn(in: cells).map { $0 + 1 } ?? 0) : 0
      if let caretCol = cells.indices.last(where: { $0 >= lowerBound && isCaretCell(cells, at: $0) }) {
        bestCaret = GridCoordinate(row: row, col: caretCol)
      }
      if let lastTextCol = cells.indices.last(where: { $0 >= lowerBound && cells[$0].scalar != " " }) {
        bestTextEnd = GridCoordinate(row: row, col: min(lastTextCol + 1, geometry.frame.cols - 1))
      }
    }
    return bestCaret ?? bestTextEnd
  }

  static func rowContainsPromptMarker(_ row: Int, in geometry: RenderedGridGeometry) -> Bool {
    guard let cells = cells(inRow: row, frame: geometry.frame) else { return false }
    return promptMarkerColumn(in: cells) != nil
  }

  static func rowIsInPromptInputRegion(_ row: Int, in geometry: RenderedGridGeometry) -> Bool {
    guard row >= 0, row < geometry.frame.rows else { return false }
    for candidateRow in stride(from: row, through: 0, by: -1) {
      if rowContainsPromptMarker(candidateRow, in: geometry) {
        return true
      }
    }
    return false
  }

  static func rowIsBlank(_ row: Int, in geometry: RenderedGridGeometry) -> Bool {
    guard let cells = cells(inRow: row, frame: geometry.frame) else { return false }
    return cells.allSatisfy { $0.scalar == " " }
  }

  static func cells(inRow row: Int, frame: GhosttyTerminalFrame) -> [GhosttyTerminalFrame.Cell]? {
    let rowStart = row * frame.cols
    let rowEnd = min(rowStart + frame.cols, frame.cells.count)
    guard row >= 0, row < frame.rows, rowStart < rowEnd else {
      return nil
    }
    return Array(frame.cells[rowStart..<rowEnd])
  }

  static func rect(_ lhs: NSRect, approximatelyEquals rhs: NSRect?) -> Bool {
    guard let rhs else { return false }
    return abs(lhs.minX - rhs.minX) < 0.5
      && abs(lhs.minY - rhs.minY) < 0.5
      && abs(lhs.width - rhs.width) < 0.5
      && abs(lhs.height - rhs.height) < 0.5
  }

  static func promptMarkerColumn(in cells: [GhosttyTerminalFrame.Cell]) -> Int? {
    cells.indices.first { index in
      switch cells[index].scalar {
      case "›", "❯", ">", "$", "#":
        true
      default:
        false
      }
    }
  }

  /// A cell drawn as the app's caret: inverse and isolated from its neighbors,
  /// so a styled row's right edge or a highlight run is not mistaken for it.
  static func isCaretCell(_ cells: [GhosttyTerminalFrame.Cell], at index: Int) -> Bool {
    let cell = cells[index]
    guard cell.inverse else { return false }
    if index > 0, cells[index - 1].inverse { return false }
    if index + 1 < cells.count, cells[index + 1].inverse { return false }
    return true
  }

  // MARK: - Private helpers

  /// The last row of the input region: the start row through the last
  /// contiguous non-blank row (a blank row ends the input; continuation /
  /// wrapped lines stay in the region).
  private static func inputRegionEnd(start: Int, in geometry: RenderedGridGeometry) -> Int? {
    guard start >= 0, start < geometry.frame.rows else { return nil }
    var end = start
    while end < geometry.frame.rows, !rowIsBlank(end, in: geometry) {
      end += 1
    }
    return end
  }

  private static func lastPromptMarkerRow(in geometry: RenderedGridGeometry) -> Int? {
    (0..<geometry.frame.rows).reversed().first { row in
      guard geometry.clipRect.intersects(geometry.rowRect(row)) else { return false }
      return rowContainsPromptMarker(row, in: geometry)
    }
  }

  private static func lastNonBlankRow(in geometry: RenderedGridGeometry) -> Int? {
    (0..<geometry.frame.rows).reversed().first { row in
      guard geometry.clipRect.intersects(geometry.rowRect(row)) else { return false }
      return !rowIsBlank(row, in: geometry)
    }
  }

  private static func rowLooksLikeInput(_ row: Int, in geometry: RenderedGridGeometry) -> Bool {
    guard let cells = cells(inRow: row, frame: geometry.frame) else { return false }
    return promptMarkerColumn(in: cells) != nil
      || cells.indices.contains { isCaretCell(cells, at: $0) }
  }
}

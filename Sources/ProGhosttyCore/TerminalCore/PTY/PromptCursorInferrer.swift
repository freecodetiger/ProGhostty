import Foundation

/// Pure prompt-cursor inference over an immutable rendered-frame geometry.
///
/// Extracted from `PTYGridView` (debt spec 4-1). Shells that redraw the prompt
/// leave the VT cursor parked at column 0; these heuristics locate the visual
/// input cursor from prompt markers and cell styling instead. Stateless: every
/// function reads only the `RenderedGridGeometry` snapshot passed in. The view
/// keeps the orchestration that mixes this with live presentation state
/// (`inferredPromptCursorRect` and friends).
enum PromptCursorInferrer {
  static func shouldInferPromptCursor(
    for viewportFrame: GhosttyTerminalFrame,
    in geometry: RenderedGridGeometry
  ) -> Bool {
    if viewportFrame.cursorY == 0 {
      return true
    }
    let row = geometry.frame.cursorY
    let rowStart = row * geometry.frame.cols
    let rowEnd = min(rowStart + geometry.frame.cols, geometry.frame.cells.count)
    guard row >= 0, row < geometry.frame.rows, rowStart < rowEnd else {
      return false
    }
    let cells = Array(geometry.frame.cells[rowStart..<rowEnd])
    return promptMarkerColumn(in: cells) != nil
  }

  static func inferredPromptCursorCoordinateOnCursorRow(in geometry: RenderedGridGeometry) -> GridCoordinate? {
    let row = geometry.frame.cursorY
    let rowStart = row * geometry.frame.cols
    let rowEnd = min(rowStart + geometry.frame.cols, geometry.frame.cells.count)
    guard row >= 0, row < geometry.frame.rows, rowStart < rowEnd else {
      return nil
    }
    let cells = Array(geometry.frame.cells[rowStart..<rowEnd])
    guard let promptCol = promptMarkerColumn(in: cells) else {
      return nil
    }
    let lowerBound = promptCol + 1
    if let lastTextCol = cells.indices.last(where: { $0 >= lowerBound && cells[$0].scalar != " " }) {
      return GridCoordinate(row: row, col: min(lastTextCol + 1, geometry.frame.cols - 1))
    }
    if let cursorCol = cells.indices.last(where: { $0 >= lowerBound && isVisualInputCursorCell(cells[$0]) }) {
      return GridCoordinate(row: row, col: cursorCol)
    }
    return nil
  }

  static func inferredPromptCursorCoordinate(in geometry: RenderedGridGeometry) -> GridCoordinate? {
    var bestVisualCursor: GridCoordinate?
    var bestTextFallback: GridCoordinate?
    var inputRegionIsActive = false
    for row in 0..<geometry.frame.rows {
      guard geometry.clipRect.intersects(geometry.rowRect(row)) else { continue }
      let rowStart = row * geometry.frame.cols
      let rowEnd = min(rowStart + geometry.frame.cols, geometry.frame.cells.count)
      guard rowStart < rowEnd else { continue }
      let cells = Array(geometry.frame.cells[rowStart..<rowEnd])
      let lowerBound: Int
      if let promptCol = promptMarkerColumn(in: cells) {
        inputRegionIsActive = true
        bestVisualCursor = nil
        bestTextFallback = nil
        lowerBound = promptCol + 1
      } else if inputRegionIsActive {
        lowerBound = 0
      } else {
        continue
      }
      if let cursorCol = cells.indices.last(where: { $0 >= lowerBound && isVisualInputCursorCell(cells[$0]) }) {
        bestVisualCursor = GridCoordinate(row: row, col: cursorCol)
      }
      if let lastTextCol = cells.indices.last(where: { $0 >= lowerBound && cells[$0].scalar != " " }) {
        bestTextFallback = GridCoordinate(row: row, col: min(lastTextCol + 1, geometry.frame.cols - 1))
      }
    }
    return bestVisualCursor ?? bestTextFallback
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

  static func isVisualInputCursorCell(_ cell: GhosttyTerminalFrame.Cell) -> Bool {
    cell.scalar == " " && (cell.inverse || !cell.usesDefaultBackground)
  }
}

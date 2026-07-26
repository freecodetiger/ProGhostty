import AppKit

/// Immutable per-present geometry of the rendered grid: the frame being
/// drawn plus the metrics to convert between cell coordinates and view
/// points. Sole home of grid geometry math (debt spec 4-2).
struct RenderedGridGeometry: Equatable, Sendable {
  var frame: GhosttyTerminalFrame
  var translationY: CGFloat
  var cellSize: CGSize
  var inset: CGSize
  var clipRect: NSRect
  var absoluteBaseRow: Int

  init(
    frame: GhosttyTerminalFrame,
    translationY: CGFloat,
    cellSize: CGSize,
    inset: CGSize,
    clipRect: NSRect,
    absoluteBaseRow: Int
  ) {
    self.frame = frame
    self.translationY = translationY
    self.cellSize = cellSize
    self.inset = inset
    self.clipRect = clipRect
    self.absoluteBaseRow = absoluteBaseRow
  }

  func coordinate(at point: NSPoint) -> GridCoordinate? {
    let col = Int((point.x - inset.width) / cellSize.width)
    let row = Int((point.y - inset.height - translationY) / cellSize.height)
    guard row >= 0, row < frame.rows, col >= 0, col < frame.cols else { return nil }
    return GridCoordinate(row: row, col: col)
  }

  func selectionPoint(at point: NSPoint) -> GridSelectionPoint? {
    guard let coordinate = coordinate(at: point) else { return nil }
    return GridSelectionPoint(absoluteRow: absoluteBaseRow + coordinate.row, col: coordinate.col)
  }

  func rectForCell(row: Int, col: Int) -> NSRect {
    NSRect(
      x: inset.width + CGFloat(max(0, col)) * cellSize.width,
      y: inset.height + CGFloat(max(0, row)) * cellSize.height + translationY,
      width: cellSize.width,
      height: cellSize.height
    )
  }

  func rectForCellRange(row: Int, cols: Range<Int>) -> NSRect {
    let lower = max(0, cols.lowerBound)
    let upper = max(lower, cols.upperBound)
    return NSRect(
      x: inset.width + CGFloat(lower) * cellSize.width,
      y: inset.height + CGFloat(max(0, row)) * cellSize.height + translationY,
      width: CGFloat(upper - lower) * cellSize.width,
      height: cellSize.height
    )
  }

  func rowRect(_ row: Int) -> NSRect {
    NSRect(
      x: inset.width,
      y: inset.height + CGFloat(max(0, row)) * cellSize.height + translationY,
      width: CGFloat(frame.cols) * cellSize.width,
      height: cellSize.height
    )
  }
}

// MARK: Pure grid geometry (moved from PTYGridView statics; the view keeps
// same-signature public forwarders for tests and backend consumers).
extension RenderedGridGeometry {
  static func visualScrollTranslationY(for viewport: TerminalViewport) -> CGFloat {
    0
  }

  static func visualScrollTranslationY(
    for viewport: TerminalViewport,
    hasOverscanRows: Bool,
    cellHeight: CGFloat
  ) -> CGFloat {
    guard hasOverscanRows, cellHeight > 0 else { return 0 }
    return min(max(viewport.visualOffsetY, -cellHeight), cellHeight)
  }

  static func contentDirtyRect(forDrawing dirtyRect: NSRect, viewport: TerminalViewport) -> NSRect {
    dirtyRect.offsetBy(dx: 0, dy: -visualScrollTranslationY(for: viewport))
  }

  static func contentDirtyRect(
    forDrawing dirtyRect: NSRect,
    viewport: TerminalViewport,
    hasOverscanRows: Bool,
    cellHeight: CGFloat
  ) -> NSRect {
    dirtyRect.offsetBy(
      dx: 0,
      dy: -visualScrollTranslationY(
        for: viewport,
        hasOverscanRows: hasOverscanRows,
        cellHeight: cellHeight
      )
    )
  }

  static func terminalContentClipRect(
    cols: Int,
    rows: Int,
    cellSize: CGSize,
    inset: CGSize
  ) -> NSRect {
    NSRect(
      x: inset.width,
      y: inset.height,
      width: CGFloat(max(0, cols)) * cellSize.width,
      height: CGFloat(max(0, rows)) * cellSize.height
    )
  }

  static func textGlyphRects(
    for run: CellDrawRun,
    row: Int,
    cellSize: CGSize,
    inset: CGSize
  ) -> [NSRect] {
    let count = min(run.text.unicodeScalars.count, run.range.count)
    return (0..<count).map { offset in
      textGlyphRect(
        row: row,
        col: run.range.lowerBound + offset,
        cellSize: cellSize,
        inset: inset
      )
    }
  }

  static func textGlyphRect(row: Int, col: Int, cellSize: CGSize, inset: CGSize) -> NSRect {
    NSRect(
      x: inset.width + CGFloat(max(0, col)) * cellSize.width,
      y: inset.height + CGFloat(max(0, row)) * cellSize.height,
      width: cellSize.width,
      height: cellSize.height
    )
  }

  static func urlCursorRects(
    frame: GhosttyTerminalFrame,
    cellSize: CGSize,
    inset: CGSize,
    verticalOffsetY: CGFloat = 0,
    linkInteractionActive: Bool = true
  ) -> [NSRect] {
    guard linkInteractionActive else { return [] }
    return urlCursorRects(
      urlHitsByRow: urlHitsByRow(in: frame),
      cellSize: cellSize,
      inset: inset,
      verticalOffsetY: verticalOffsetY
    )
  }

  static func urlHitsByRow(
    in frame: GhosttyTerminalFrame,
    pathValidator: ((String) -> Bool)? = nil
  ) -> [Int: [TerminalLinkHit]] {
    guard frame.rows > 0, frame.cols > 0 else { return [:] }
    var hitsByRow: [Int: [TerminalLinkHit]] = [:]
    for row in 0..<frame.rows {
      let hits = TerminalLinkDetector.hits(inRow: row, frame: frame, pathValidator: pathValidator)
      if !hits.isEmpty {
        hitsByRow[row] = hits
      }
    }
    return hitsByRow
  }

  static func urlCursorRects(
    urlHitsByRow: [Int: [TerminalLinkHit]],
    cellSize: CGSize,
    inset: CGSize,
    verticalOffsetY: CGFloat = 0
  ) -> [NSRect] {
    urlHitsByRow.keys.sorted().flatMap { row in
      (urlHitsByRow[row] ?? []).map { hit in
        NSRect(
          x: inset.width + CGFloat(hit.range.lowerBound) * cellSize.width,
          y: inset.height + CGFloat(row) * cellSize.height + verticalOffsetY,
          width: CGFloat(hit.range.count) * cellSize.width,
          height: cellSize.height
        )
      }
    }
  }

  /// Splices overscan rows around the viewport into one extended frame.
  static func extendedFrame(from scrollFrame: GhosttyTerminalScrollFrame) -> GhosttyTerminalFrame {
    var frame = scrollFrame.viewport
    frame.rows = scrollFrame.overscanTop.count + scrollFrame.viewport.rows + scrollFrame.overscanBottom.count
    frame.cursorY += scrollFrame.overscanTop.count
    frame.cells = scrollFrame.overscanTop.flatMap(\.cells)
      + scrollFrame.viewport.cells
      + scrollFrame.overscanBottom.flatMap(\.cells)
    return frame
  }

  /// Absolute scrollback row of the extended frame's first row.
  static func absoluteBaseRow(for scrollFrame: GhosttyTerminalScrollFrame) -> Int {
    guard let viewportStartRow = scrollFrame.viewportStartRow else { return 0 }
    let cappedViewportStart = min(viewportStartRow, UInt64(Int.max))
    return max(0, Int(cappedViewportStart) - scrollFrame.overscanTop.count)
  }
}

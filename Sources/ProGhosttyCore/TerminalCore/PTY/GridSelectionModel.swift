import Foundation

/// A selection endpoint in absolute-row space (scrollback-stable), so an
/// active selection survives viewport scrolling.
struct GridSelectionPoint: Comparable {
  var absoluteRow: Int
  var col: Int

  static func < (lhs: GridSelectionPoint, rhs: GridSelectionPoint) -> Bool {
    if lhs.absoluteRow == rhs.absoluteRow {
      return lhs.col < rhs.col
    }
    return lhs.absoluteRow < rhs.absoluteRow
  }
}

/// Owner of the pane's selection endpoints plus their pure normalization into
/// viewport coordinates.
///
/// Extracted from `PTYGridView` (debt spec 4-3). The view still drives the
/// AppKit side (mouse events, dirty rects, auto-scroll timers) and converts
/// event points via `RenderedGridGeometry.selectionPoint(at:)`; this type owns
/// what the selection *is*.
struct GridSelectionModel {
  var anchor: GridSelectionPoint?
  var head: GridSelectionPoint?

  init(anchor: GridSelectionPoint? = nil, head: GridSelectionPoint? = nil) {
    self.anchor = anchor
    self.head = head
  }

  /// Anchors a fresh (initially zero-width) selection at the press point.
  mutating func begin(at point: GridSelectionPoint?) {
    anchor = point
    head = point
  }

  mutating func clear() {
    anchor = nil
    head = nil
  }

  /// Endpoints ordered ascending; nil while the selection is empty/zero-width.
  func normalizedPointRange() -> (lower: GridSelectionPoint, upper: GridSelectionPoint)? {
    guard let anchor, let head, anchor != head else { return nil }
    if anchor < head {
      return (anchor, head)
    }
    return (head, anchor)
  }

  /// Projects the absolute-row selection into the rendered frame's viewport
  /// rows, clamping endpoints that scrolled out of view to full rows.
  func normalizedRange(in geometry: RenderedGridGeometry) -> (lower: GridCoordinate, upper: GridCoordinate)? {
    guard let range = normalizedPointRange(), geometry.frame.rows > 0 else { return nil }
    let firstAbsoluteRow = geometry.absoluteBaseRow
    let lastAbsoluteRow = geometry.absoluteBaseRow + geometry.frame.rows - 1
    let lowerAbsoluteRow = max(range.lower.absoluteRow, firstAbsoluteRow)
    let upperAbsoluteRow = min(range.upper.absoluteRow, lastAbsoluteRow)
    guard lowerAbsoluteRow <= upperAbsoluteRow else { return nil }

    let lowerCol = lowerAbsoluteRow == range.lower.absoluteRow ? range.lower.col : 0
    let upperCol = upperAbsoluteRow == range.upper.absoluteRow ? range.upper.col : max(0, geometry.frame.cols - 1)
    guard lowerCol <= upperCol || lowerAbsoluteRow < upperAbsoluteRow else { return nil }
    return (
      GridCoordinate(row: lowerAbsoluteRow - geometry.absoluteBaseRow, col: lowerCol),
      GridCoordinate(row: upperAbsoluteRow - geometry.absoluteBaseRow, col: upperCol)
    )
  }

  static func isSelected(
    row: Int,
    col: Int,
    in range: (lower: GridCoordinate, upper: GridCoordinate)
  ) -> Bool {
    let coordinate = GridCoordinate(row: row, col: col)
    return coordinate >= range.lower && coordinate <= range.upper
  }
}

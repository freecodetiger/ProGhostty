import Foundation

/// Shared soft-wrap line reconstruction for link/URL detection.
///
/// A single terminal row is only part of the story: shells and TUIs soft-wrap a
/// long token (path or URL) across several physical rows without emitting a
/// newline. Detectors must match against the *logical* line — the physical rows
/// joined together — then map any hit back to the physical rows it covers.
///
/// This is intentionally pure (no AppKit / VT dependency) so both
/// `TerminalURLDetector` and `TerminalLinkDetector` share one definition of
/// "which rows form this logical line" and "how a joined-text range splits back
/// across rows". Keeping this in one place avoids the historical drift where
/// file paths spanned wrapped rows but URLs did not.
enum TerminalLogicalLine {
  /// One physical row inside a logical line, with its offset into the joined text.
  struct Row: Equatable {
    var row: Int
    var text: String
    var start: Int

    var end: Int { start + text.count }
  }

  /// A hit range mapped back onto a single physical row.
  struct RowRange: Equatable {
    var row: Int
    /// Range in that physical row's own column coordinates.
    var range: Range<Int>
  }

  /// The physical rows that form the logical line containing `row`, ordered top
  /// to bottom, each tagged with its start offset in the joined text.
  static func rows(around row: Int, frame: GhosttyTerminalFrame) -> [Row] {
    guard row >= 0, row < frame.rows, frame.cols > 0 else { return [] }

    var firstRow = row
    while firstRow > 0, maySoftWrapToNext(firstRow - 1, frame: frame) {
      firstRow -= 1
    }

    var lastRow = row
    while lastRow + 1 < frame.rows, maySoftWrapToNext(lastRow, frame: frame) {
      lastRow += 1
    }

    var offset = 0
    return (firstRow...lastRow).compactMap { current in
      guard let text = text(inRow: current, frame: frame) else { return nil }
      defer { offset += text.count }
      return Row(row: current, text: text, start: offset)
    }
  }

  /// Raw text of a single physical row with trailing space padding removed.
  ///
  /// Terminal rows are padded to `frame.cols` with space characters. Trimming
  /// the padding is essential: without it `maySoftWrapToNext` would see a
  /// trailing space and refuse to join rows, and URL/path regexes would stop
  /// matching at the first embedded run of spaces.
  static func text(inRow row: Int, frame: GhosttyTerminalFrame) -> String? {
    guard row >= 0, row < frame.rows, frame.cols > 0 else { return nil }
    let rowStart = row * frame.cols
    let rowEnd = min(rowStart + frame.cols, frame.cells.count)
    guard rowStart < rowEnd else { return nil }
    var end = rowEnd
    while end > rowStart, frame.cells[end - 1].scalar == " " { end -= 1 }
    guard end > rowStart else { return "" }
    return frame.cells[rowStart..<end].map { String($0.scalar) }.joined()
  }

  /// Heuristic soft-wrap: a row whose last cell is non-whitespace likely
  /// continues onto the next row. `libghostty-vt` does not currently surface an
  /// explicit wrap flag, so both detectors share this approximation.
  ///
  /// This checks the raw cell at `frame.cols - 1` rather than the trimmed text
  /// returned by `text(inRow:frame:)`, because trailing-space trimming would
  /// otherwise mask the padding that distinguishes a hard line break from a
  /// soft-wrap.
  static func maySoftWrapToNext(_ row: Int, frame: GhosttyTerminalFrame) -> Bool {
    guard row >= 0, row < frame.rows, frame.cols > 0 else { return false }
    let rowEnd = min((row + 1) * frame.cols, frame.cells.count)
    guard rowEnd > row * frame.cols else { return false }
    return frame.cells[rowEnd - 1].scalar != " "
  }

  /// Split a range expressed in joined-text coordinates into per-physical-row
  /// ranges (each in that row's own column coordinates).
  static func split(range: Range<Int>, across rows: [Row]) -> [RowRange] {
    rows.compactMap { row in
      let overlapLowerBound = Swift.max(range.lowerBound, row.start)
      let overlapUpperBound = Swift.min(range.upperBound, row.end)
      guard overlapLowerBound < overlapUpperBound else { return nil }
      return RowRange(
        row: row.row,
        range: (overlapLowerBound - row.start)..<(overlapUpperBound - row.start)
      )
    }
  }
}

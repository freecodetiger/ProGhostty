import Foundation

/// Pure, synchronous per-row matcher. It works over the *logical* character
/// sequence of a row — one element per non-spacer cell — so wide CJK glyphs
/// never contribute their trailing spacer cell (which carries a `' '` scalar)
/// to a spurious match. This is the same wide-char discipline as the copy path
/// (`PTYGridView.selectedText`).
public enum SearchMatcher {
  /// Cap on the number of matches a full-buffer search may return. Prevents a
  /// 10k-row scrollback with a one-char query from materializing an unbounded
  /// match list (and an unbounded highlight set).
  public static let maxMatches = 1000

  /// Column ranges (left-closed / right-open) of every occurrence of `query`
  /// in a single row. Returns `[]` for an empty query or a row with no logical
  /// characters.
  public static func hitRanges(
    in cells: [GhosttyTerminalFrame.Cell],
    query: String,
    caseSensitive: Bool
  ) -> [Range<Int>] {
    // Logical character sequence: skip spacer continuation cells. Track each
    // character's cell column and its display width so a match range covers the
    // full glyph span (a wide char occupies two cells; highlighting only the
    // head cell would leave its right half un-highlighted).
    var scalars: [UnicodeScalar] = []
    var cols: [Int] = []
    var widths: [Int] = []
    for (col, cell) in cells.enumerated() {
      if cell.width == .spacerTail || cell.width == .spacerHead { continue }
      scalars.append(cell.scalar)
      cols.append(col)
      widths.append(cell.width == .wide ? 2 : 1)
    }

    let needle = Array(query.unicodeScalars)
    guard !scalars.isEmpty, !needle.isEmpty, needle.count <= scalars.count else { return [] }

    var ranges: [Range<Int>] = []
    var i = 0
    let last = scalars.count - needle.count
    while i <= last {
      var matched = true
      for j in 0..<needle.count {
        if scalar(scalars[i + j], equals: needle[j], caseSensitive: caseSensitive) == false {
          matched = false
          break
        }
      }
      if matched {
        let startCol = cols[i]
        let lastIndex = i + needle.count - 1
        let endCol = cols[lastIndex] + widths[lastIndex]
        ranges.append(startCol..<endCol)
      }
      i += 1
    }
    return ranges
  }

  /// Fold two scalars for comparison. Only ASCII letters case-fold; everything
  /// else (CJK, symbols, digits) compares by identity. Good enough for plain
  /// substring find — regex / locale-aware folding is explicitly out of scope.
  private static func scalar(_ lhs: UnicodeScalar, equals rhs: UnicodeScalar, caseSensitive: Bool) -> Bool {
    if caseSensitive { return lhs == rhs }
    return asciiLowercased(lhs) == asciiLowercased(rhs)
  }

  private static func asciiLowercased(_ scalar: UnicodeScalar) -> UnicodeScalar {
    if scalar.value >= 0x41 && scalar.value <= 0x5A {
      return UnicodeScalar(scalar.value + 32) ?? scalar
    }
    return scalar
  }
}

/// Maps absolute-row matches onto expanded-frame cell ranges for highlighting.
/// Pure so the row-mapping invariant (§6 #2 of BUFFER_SEARCH_SPEC.md) is unit
/// testable in isolation from the surface registry.
public enum SearchHighlightMapper {
  public static func expandedCells(
    matches: [SearchMatch],
    absoluteBaseRow: Int,
    frameRows: Int,
    cols: Int
  ) -> [Int: [Range<Int>]] {
    var result: [Int: [Range<Int>]] = [:]
    for match in matches {
      let row = Int(match.absoluteRow) - absoluteBaseRow
      guard row >= 0, row < frameRows else { continue }
      let lower = max(0, match.startCol)
      let upper = min(max(lower, match.endCol), max(0, cols))
      guard lower < upper else { continue }
      result[row, default: []].append(lower..<upper)
    }
    return result
  }
}

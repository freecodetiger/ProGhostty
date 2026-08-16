import Foundation
import Testing

@testable import ProGhosttyCore

@Suite("Buffer search matcher")
struct SearchMatcherTests {
  private func cell(_ scalar: UnicodeScalar, width: TerminalCellWidth = .narrow) -> GhosttyTerminalFrame.Cell {
    GhosttyTerminalFrame.Cell(
      scalar: scalar,
      width: width,
      foreground: GhosttyTerminalFrame.RGB(r: 255, g: 255, b: 255),
      background: GhosttyTerminalFrame.RGB(r: 0, g: 0, b: 0),
      bold: false, italic: false, faint: false, underline: false, inverse: false,
      usesDefaultForeground: true, usesDefaultBackground: true
    )
  }

  private func row(_ text: String, cols: Int = 12) -> GhosttyTerminalCellRow {
    let cells = text.unicodeScalars.map { cell($0) }
    let padded = cells + Array(repeating: cell(" "), count: max(0, cols - cells.count))
    return GhosttyTerminalCellRow(cells: Array(padded.prefix(cols)))
  }

  @Test func basicSubstringHit() {
    let ranges = SearchMatcher.hitRanges(in: row("abcdef").cells, query: "bcd", caseSensitive: false)
    #expect(ranges == [1..<4])
  }

  @Test func caseSensitivity() {
    let cells = row("abcABC").cells
    #expect(SearchMatcher.hitRanges(in: cells, query: "abc", caseSensitive: true) == [0..<3])
    #expect(SearchMatcher.hitRanges(in: cells, query: "abc", caseSensitive: false) == [0..<3, 3..<6])
  }

  @Test func emptyQueryProducesNoHits() {
    #expect(SearchMatcher.hitRanges(in: row("abc").cells, query: "", caseSensitive: false).isEmpty)
  }

  @Test func noMatchProducesNoHits() {
    #expect(SearchMatcher.hitRanges(in: row("abc").cells, query: "z", caseSensitive: false).isEmpty)
  }

  @Test func wideCharacterSpacerCellsAreSkipped() {
    // "中文" as wide head + spacerTail continuation each. Matching must skip the
    // spacer cells (which carry a ' ' scalar), so the query "中文" hits once and
    // covers the full glyph span [0, 4) — not "中 " with a fake trailing space.
    let cells = [
      cell("中", width: .wide), cell(" ", width: .spacerTail),
      cell("文", width: .wide), cell(" ", width: .spacerTail),
      cell(" ", width: .narrow), cell(" ", width: .narrow),
    ]
    #expect(SearchMatcher.hitRanges(in: cells, query: "中文", caseSensitive: false) == [0..<4])
    // A query that would only match a spurious spacer space must not hit.
    #expect(SearchMatcher.hitRanges(in: cells, query: "中 ", caseSensitive: false).isEmpty)
    #expect(SearchMatcher.hitRanges(in: cells, query: " 文", caseSensitive: false).isEmpty)
  }

  @Test func searchStateNavigationWraps() {
    var state = SearchState(matches: (0..<3).map { SearchMatch(id: $0, absoluteRow: UInt64($0), startCol: 0, endCol: 1) })
    #expect(state.currentMatch == nil)
    state.next()
    #expect(state.currentMatch?.id == 0)
    state.next()
    #expect(state.currentMatch?.id == 1)
    state.next()
    #expect(state.currentMatch?.id == 2)
    state.next()
    #expect(state.currentMatch?.id == 0)  // wraps
    state.previous()
    #expect(state.currentMatch?.id == 2)  // wraps back
  }

  @Test func searchStateNavigationNoMatchesIsNoop() {
    var state = SearchState()
    state.next()
    state.previous()
    #expect(state.currentMatch == nil)
  }

  @Test func highlightMapperMapsAbsoluteRowsIntoExpandedFrame() {
    let matches = [
      SearchMatch(id: 0, absoluteRow: 10, startCol: 2, endCol: 5),
      SearchMatch(id: 1, absoluteRow: 11, startCol: 0, endCol: 2),
      SearchMatch(id: 2, absoluteRow: 9, startCol: 0, endCol: 1),  // below base → dropped
      SearchMatch(id: 3, absoluteRow: 13, startCol: 0, endCol: 1),  // above frame → dropped
    ]
    let cells = SearchHighlightMapper.expandedCells(
      matches: matches, absoluteBaseRow: 10, frameRows: 3, cols: 6
    )
    #expect(cells[0] == [2..<5])
    #expect(cells[1] == [0..<2])
    #expect(cells[2] == nil)
  }
}

@Suite("Buffer search driver")
struct SearchSessionDriverTests {
  private func row(_ text: String, cols: Int = 6) -> GhosttyTerminalCellRow {
    let cells = text.unicodeScalars.map {
      GhosttyTerminalFrame.Cell(
        scalar: $0,
        foreground: GhosttyTerminalFrame.RGB(r: 255, g: 255, b: 255),
        background: GhosttyTerminalFrame.RGB(r: 0, g: 0, b: 0),
        bold: false, italic: false, faint: false, underline: false, inverse: false,
        usesDefaultForeground: true, usesDefaultBackground: true
      )
    }
    return GhosttyTerminalCellRow(cells: cells)
  }

  private func provider(_ rows: [GhosttyTerminalCellRow], cols: Int) -> SearchSessionDriver.RowProvider {
    { start, count in
      let lower = Int(start)
      let upper = min(lower + count, rows.count)
      guard lower < upper else { return GhosttyTerminalRowWindow(startRow: start, total: 0, cols: cols, rows: []) }
      return GhosttyTerminalRowWindow(
        startRow: start,
        total: UInt64(rows.count),
        cols: cols,
        rows: Array(rows[lower..<upper])
      )
    }
  }

  @Test func aggregatesAcrossRowsAndAssignsSequentialIDs() async {
    let rows = [row("aa bb"), row("bb cc"), row("cc dd")]
    let result = await SearchSessionDriver().search(
      query: "bb", caseSensitive: false, rowProvider: provider(rows, cols: 6)
    )
    #expect(result.totalRows == 3)
    #expect(result.matches.count == 2)
    #expect(result.matches[0].absoluteRow == 0)
    #expect(result.matches[1].absoluteRow == 1)
    #expect(result.matches.map(\.id) == [0, 1])
  }

  @Test func emptyQueryReturnsEmptyResult() async {
    let result = await SearchSessionDriver().search(
      query: "", caseSensitive: false, rowProvider: provider([row("abc")], cols: 6)
    )
    #expect(result.matches.isEmpty)
    #expect(result.totalRows == 0)
  }

  @Test func truncatesAtMaxMatches() async {
    // One row with 2000 'a's → 2000 matches, truncated at maxMatches.
    let many = row(String(repeating: "a", count: 2000), cols: 2000)
    let result = await SearchSessionDriver().search(
      query: "a", caseSensitive: false, rowProvider: provider([many], cols: 2000)
    )
    #expect(result.matches.count == SearchMatcher.maxMatches)
    #expect(result.truncated)
  }
}

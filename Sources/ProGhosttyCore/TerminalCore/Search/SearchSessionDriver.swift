import Foundation

/// Runs a buffer search over the VT scrollback off the main actor, in bounded
/// row windows, cooperatively with `Task` cancellation. This is the only place
/// that touches `rows(at:)` for search; matching is the pure `SearchMatcher`.
///
/// Not actor-isolated: `search` suspends on the cooperative pool, so a search
/// over a 10k-row scrollback never blocks the main thread / render loop. The
/// `rowProvider` is `@Sendable` (it closes over the `@unchecked Sendable`
/// bridge); each window read locks the bridge only for that window.
public struct SearchSessionDriver: Sendable {
  public static let batchSize = 256

  public typealias RowProvider = @Sendable (UInt64, Int) throws -> GhosttyTerminalRowWindow

  public init() {}

  public func search(
    query: String,
    caseSensitive: Bool,
    rowProvider: @escaping RowProvider
  ) async -> SearchResult {
    guard !query.isEmpty else {
      return SearchResult(matches: [], truncated: false, totalRows: 0)
    }
    guard let probe = try? rowProvider(0, 1) else {
      return SearchResult(matches: [], truncated: false, totalRows: 0)
    }
    let totalRows = probe.total
    guard totalRows > 0 else {
      return SearchResult(matches: [], truncated: false, totalRows: 0)
    }

    var matches: [SearchMatch] = []
    var truncated = false
    var nextID = 0
    var cursor: UInt64 = 0

    while cursor < totalRows {
      if Task.isCancelled { break }
      let count = Int(min(UInt64(Self.batchSize), totalRows - cursor))
      guard let window = try? rowProvider(cursor, count), !window.rows.isEmpty else { break }

      for (offset, row) in window.rows.enumerated() {
        if Task.isCancelled { break }
        let absoluteRow = window.startRow + UInt64(offset)
        for range in SearchMatcher.hitRanges(in: row.cells, query: query, caseSensitive: caseSensitive) {
          if matches.count >= SearchMatcher.maxMatches {
            truncated = true
            break
          }
          matches.append(
            SearchMatch(id: nextID, absoluteRow: absoluteRow, startCol: range.lowerBound, endCol: range.upperBound)
          )
          nextID += 1
        }
        if truncated { break }
      }
      if truncated { break }

      let advanced = UInt64(window.rows.count)
      cursor = window.startRow + advanced
      if advanced == 0 { break }
    }

    return SearchResult(matches: matches, truncated: truncated, totalRows: totalRows)
  }
}

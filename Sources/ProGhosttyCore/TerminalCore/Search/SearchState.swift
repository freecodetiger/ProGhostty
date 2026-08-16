import Foundation

/// A single search match, addressed in the same absolute-row space as
/// `GhosttyVTBridge.rows(at:count:)` / `presentBrowseWindow`. Columns are cell
/// indices (left-closed / right-open), so highlighting lands on render cells
/// directly without any character↔cell conversion.
public struct SearchMatch: Sendable, Equatable, Identifiable {
  public let id: Int
  public let absoluteRow: UInt64
  public let startCol: Int
  public let endCol: Int

  public init(id: Int, absoluteRow: UInt64, startCol: Int, endCol: Int) {
    self.id = id
    self.absoluteRow = absoluteRow
    self.startCol = startCol
    self.endCol = endCol
  }
}

/// Result of one completed buffer search. `truncated` is set when the match
/// count hit the cap (see `SearchMatcher.maxMatches`), so callers can surface
/// "results truncated" instead of silently dropping the tail.
public struct SearchResult: Sendable, Equatable {
  public var matches: [SearchMatch]
  public var truncated: Bool
  public var totalRows: UInt64

  public init(matches: [SearchMatch], truncated: Bool, totalRows: UInt64) {
    self.matches = matches
    self.truncated = truncated
    self.totalRows = totalRows
  }
}

/// Owns the find-bar UI state and its pure navigation reducer. This is
/// ephemeral UI state, NOT terminal state — `libghostty-vt` remains the single
/// source of truth for the buffer; these are read-only derived results.
public struct SearchState: Sendable, Equatable {
  public var query: String
  public var caseSensitive: Bool
  public var matches: [SearchMatch]
  public var currentIndex: Int?
  public var truncated: Bool
  public var isSearching: Bool

  public init(
    query: String = "",
    caseSensitive: Bool = false,
    matches: [SearchMatch] = [],
    currentIndex: Int? = nil,
    truncated: Bool = false,
    isSearching: Bool = false
  ) {
    self.query = query
    self.caseSensitive = caseSensitive
    self.matches = matches
    self.currentIndex = currentIndex
    self.truncated = truncated
    self.isSearching = isSearching
  }

  public var currentMatch: SearchMatch? {
    guard let currentIndex, matches.indices.contains(currentIndex) else { return nil }
    return matches[currentIndex]
  }

  /// Advance the current match, wrapping; starts at the first match when none
  /// is selected. No-op when there are no matches.
  public mutating func next() {
    guard !matches.isEmpty else {
      currentIndex = nil
      return
    }
    currentIndex = ((currentIndex ?? -1) + 1) % matches.count
  }

  /// Retreat the current match, wrapping; starts at the last match when none is
  /// selected. No-op when there are no matches.
  public mutating func previous() {
    guard !matches.isEmpty else {
      currentIndex = nil
      return
    }
    currentIndex = ((currentIndex ?? 0) - 1 + matches.count) % matches.count
  }

  public mutating func resetMatches() {
    matches = []
    currentIndex = nil
    truncated = false
  }
}

import Foundation

/// A URL/link treated as **one Semantic Object**, not a set of rectangles, per
/// `URL_SEMANTIC_OBJECT_SPEC.md` §7.
///
/// A soft-wrapped link occupies several physical rows. Hovering *any* segment
/// must put the *whole* object into Hover, the halo must cover *all* segments
/// continuously, and the ↗ Action Hint appears *once* at the logical end. To do
/// that the engine needs a stable identity for the whole link plus its ordered
/// per-row segments — which is exactly this type.
public struct SemanticLinkObject: Equatable, Sendable, Identifiable {
  /// One physical-row slice of the object, in expanded-frame row/col space.
  public struct Segment: Equatable, Sendable {
    public var row: Int
    public var cols: Range<Int>

    public init(row: Int, cols: Range<Int>) {
      self.row = row
      self.cols = cols
    }
  }

  /// What the object resolves to (URL or file path), shared by all segments.
  public var target: TerminalLinkTarget
  /// The full visible link text.
  public var text: String
  /// Ordered top-to-bottom row segments.
  public var segments: [Segment]

  public init(target: TerminalLinkTarget, text: String, segments: [Segment]) {
    self.target = target
    self.text = text
    self.segments = segments
  }

  /// Stable identity: same target + same first segment position = same object,
  /// so it survives frame re-renders and pointer moves between its own segments.
  public var id: String {
    let anchor = segments.first.map { "\($0.row):\($0.cols.lowerBound)" } ?? "?"
    return "\(text)@\(anchor)"
  }

  /// The logical end of the object — the trailing cell of its last segment.
  /// This is where the ↗ Action Hint is anchored (§5).
  public var logicalEnd: Segment? {
    guard let last = segments.last, !last.cols.isEmpty else { return segments.last }
    return Segment(row: last.row, cols: (last.cols.upperBound - 1)..<last.cols.upperBound)
  }

  public func contains(row: Int, col: Int) -> Bool {
    segments.contains { $0.row == row && $0.cols.contains(col) }
  }
}

public enum SemanticLinkObjectResolver {
  /// The object under `(row, col)`, grouping every wrapped segment of that link.
  ///
  /// Uses `TerminalLinkDetector` to find the hit at the point, then collects all
  /// sibling hits sharing the same resolved target across the logical line's rows.
  public static func object(
    at row: Int,
    col: Int,
    in frame: GhosttyTerminalFrame,
    pathValidator: ((String) -> Bool)? = nil
  ) -> SemanticLinkObject? {
    guard let hit = TerminalLinkDetector.hitTest(row: row, col: col, in: frame, pathValidator: pathValidator) else { return nil }
    return object(for: hit, in: frame, pathValidator: pathValidator)
  }

  /// Group all segments belonging to the same link as `hit`.
  public static func object(
    for hit: TerminalLinkHit,
    in frame: GhosttyTerminalFrame,
    pathValidator: ((String) -> Bool)? = nil
  ) -> SemanticLinkObject {
    let logicalRows = TerminalLogicalLine.rows(around: hit.row, frame: frame)
    let rowNumbers = logicalRows.isEmpty ? [hit.row] : logicalRows.map(\.row)

    // Collect hits on every row of the logical line whose target matches, so a
    // wrapped link contributes one segment per row it spans.
    var segments: [SemanticLinkObject.Segment] = []
    for rowNumber in rowNumbers {
      for candidate in TerminalLinkDetector.hits(inRow: rowNumber, frame: frame, pathValidator: pathValidator)
      where sameTarget(candidate.target, hit.target) && candidate.text == hit.text {
        segments.append(SemanticLinkObject.Segment(row: candidate.row, cols: candidate.range))
      }
    }

    if segments.isEmpty {
      segments = [SemanticLinkObject.Segment(row: hit.row, cols: hit.range)]
    }
    segments.sort { lhs, rhs in
      lhs.row != rhs.row ? lhs.row < rhs.row : lhs.cols.lowerBound < rhs.cols.lowerBound
    }

    return SemanticLinkObject(target: hit.target, text: hit.text, segments: segments)
  }

  private static func sameTarget(_ lhs: TerminalLinkTarget, _ rhs: TerminalLinkTarget) -> Bool {
    switch (lhs, rhs) {
    case let (.url(a), .url(b)):
      return a == b
    case let (.filePath(a), .filePath(b)):
      return a == b
    default:
      return false
    }
  }
}

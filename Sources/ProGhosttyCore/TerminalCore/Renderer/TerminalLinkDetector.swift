import Foundation

public enum TerminalLinkTarget: Equatable, Sendable {
  case url(URL)
  case filePath(TerminalFilePathTarget)
}

public struct TerminalFilePathTarget: Equatable, Sendable {
  public var rawPath: String
  public var line: Int?
  public var column: Int?

  public init(rawPath: String, line: Int? = nil, column: Int? = nil) {
    self.rawPath = rawPath
    self.line = line
    self.column = column
  }

  public var requiresWorkingDirectory: Bool {
    !(rawPath.hasPrefix("/") || rawPath.hasPrefix("~/"))
  }
}

public struct TerminalLinkHit: Equatable, Sendable {
  public var target: TerminalLinkTarget
  public var row: Int
  public var range: Range<Int>
  public var text: String

  public init(target: TerminalLinkTarget, row: Int, range: Range<Int>, text: String) {
    self.target = target
    self.row = row
    self.range = range
    self.text = text
  }

  public func contains(row: Int, col: Int) -> Bool {
    self.row == row && range.contains(col)
  }
}

public enum TerminalLinkDetector {
  private struct LogicalRow {
    var row: Int
    var text: String
    var start: Int

    var end: Int {
      start + text.count
    }
  }

  private static let pathPattern =
    #"(?<![A-Za-z0-9_])((?:~\/|\.{1,2}\/|/)[^\s<>"']+|(?:[A-Za-z0-9._@%+=~-]+/)+[A-Za-z0-9._@%+=~-]+\.[A-Za-z0-9._@%+=~-]+(?::\d+){0,2})"#
  private static let trailingCharacters = CharacterSet(charactersIn: ".,;!?)]}")

  public static func hitTest(row: Int, col: Int, in frame: GhosttyTerminalFrame) -> TerminalLinkHit? {
    hits(inRow: row, frame: frame).first { $0.contains(row: row, col: col) }
  }

  public static func hits(inRow row: Int, frame: GhosttyTerminalFrame) -> [TerminalLinkHit] {
    guard row >= 0, row < frame.rows, frame.cols > 0 else { return [] }
    let urlHits = TerminalURLDetector.hits(inRow: row, frame: frame).map {
      TerminalLinkHit(target: .url($0.url), row: $0.row, range: $0.range, text: $0.text)
    }
    let pathHits = visiblePathHits(inRow: row, frame: frame).filter { pathHit in
      !urlHits.contains { rangesOverlap($0.range, pathHit.range) }
    }
    return urlHits + pathHits
  }

  private static func visiblePathHits(inRow row: Int, frame: GhosttyTerminalFrame) -> [TerminalLinkHit] {
    let rows = logicalRows(around: row, frame: frame)
    guard !rows.isEmpty else { return [] }
    let line = rows.map(\.text).joined()
    let nsLine = line as NSString
    let fullRange = NSRange(location: 0, length: nsLine.length)
    guard let regex = try? NSRegularExpression(pattern: pathPattern) else { return [] }
    return regex.matches(in: line, options: [], range: fullRange).flatMap { match in
      pathHits(from: nsLine.substring(with: match.range(at: 1)), range: match.range(at: 1), rows: rows)
    }.filter { hit in
      hit.row == row
    }
  }

  private static func logicalRows(around row: Int, frame: GhosttyTerminalFrame) -> [LogicalRow] {
    guard row >= 0, row < frame.rows, frame.cols > 0 else { return [] }
    var firstRow = row
    while firstRow > 0, rowMaySoftWrapToNext(firstRow - 1, frame: frame) {
      firstRow -= 1
    }

    var lastRow = row
    while lastRow + 1 < frame.rows, rowMaySoftWrapToNext(lastRow, frame: frame) {
      lastRow += 1
    }

    var offset = 0
    return (firstRow...lastRow).compactMap { row in
      guard let text = text(inRow: row, frame: frame) else { return nil }
      defer { offset += text.count }
      return LogicalRow(row: row, text: text, start: offset)
    }
  }

  private static func text(inRow row: Int, frame: GhosttyTerminalFrame) -> String? {
    guard row >= 0, row < frame.rows, frame.cols > 0 else { return nil }
    let rowStart = row * frame.cols
    let rowEnd = min(rowStart + frame.cols, frame.cells.count)
    guard rowStart < rowEnd else { return nil }
    return frame.cells[rowStart..<rowEnd].map { String($0.scalar) }.joined()
  }

  private static func rowMaySoftWrapToNext(_ row: Int, frame: GhosttyTerminalFrame) -> Bool {
    guard let text = text(inRow: row, frame: frame),
      let lastScalar = text.unicodeScalars.last
    else {
      return false
    }
    return !CharacterSet.whitespacesAndNewlines.contains(lastScalar)
  }

  private static func pathHits(from rawText: String, range rawRange: NSRange, rows: [LogicalRow]) -> [TerminalLinkHit] {
    let trimmed = trimmingTrailingCharacters(from: rawText)
    guard !trimmed.isEmpty else { return [] }
    let parsed = stripLineAndColumn(from: trimmed)
    let removedCharacterCount = rawText.count - parsed.visibleText.count
    let range = rawRange.location..<(rawRange.location + max(0, rawRange.length - removedCharacterCount))
    let target = TerminalLinkTarget.filePath(TerminalFilePathTarget(rawPath: parsed.path, line: parsed.line, column: parsed.column))
    return rows.compactMap { row in
      let overlapLowerBound = max(range.lowerBound, row.start)
      let overlapUpperBound = min(range.upperBound, row.end)
      guard overlapLowerBound < overlapUpperBound else { return nil }
      let overlap = overlapLowerBound..<overlapUpperBound
      return TerminalLinkHit(
        target: target,
        row: row.row,
        range: (overlap.lowerBound - row.start)..<(overlap.upperBound - row.start),
        text: parsed.visibleText
      )
    }
  }

  private static func trimmingTrailingCharacters(from text: String) -> String {
    var result = text
    while let scalar = result.unicodeScalars.last, trailingCharacters.contains(scalar) {
      result.removeLast()
    }
    return result
  }

  private static func stripLineAndColumn(from text: String) -> (path: String, line: Int?, column: Int?, visibleText: String) {
    let parts = text.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count >= 2, let line = Int(parts[parts.count - 1]) else {
      return (text, nil, nil, text)
    }

    if parts.count >= 3, let column = Int(parts[parts.count - 1]), let line = Int(parts[parts.count - 2]) {
      let path = parts.dropLast(2).joined(separator: ":")
      guard !path.isEmpty else { return (text, nil, nil, text) }
      return (path, line, column, text)
    }

    let path = parts.dropLast().joined(separator: ":")
    guard !path.isEmpty else { return (text, nil, nil, text) }
    return (path, line, nil, text)
  }

  private static func rangesOverlap(_ lhs: Range<Int>, _ rhs: Range<Int>) -> Bool {
    lhs.lowerBound < rhs.upperBound && rhs.lowerBound < lhs.upperBound
  }
}

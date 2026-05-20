import Foundation

public struct TerminalURLHit: Equatable, Sendable {
  public var url: URL
  public var row: Int
  public var range: Range<Int>
  public var text: String

  public init(url: URL, row: Int, range: Range<Int>, text: String) {
    self.url = url
    self.row = row
    self.range = range
    self.text = text
  }

  public func contains(row: Int, col: Int) -> Bool {
    self.row == row && range.contains(col)
  }
}

public enum TerminalURLDetector {
  private static let pattern = #"(?<![A-Za-z0-9_])((?:https?://)[^\s<>"']+|(?:localhost|127(?:\.\d{1,3}){3}|0\.0\.0\.0|\[::1\])(?::\d{1,5})(?:/[^\s<>"']*)?)"#
  private static let trailingCharacters = CharacterSet(charactersIn: ".,;:!?)]}")

  public static func hitTest(row: Int, col: Int, in frame: GhosttyTerminalFrame) -> TerminalURLHit? {
    hits(inRow: row, frame: frame).first { $0.contains(row: row, col: col) }
  }

  public static func hits(inRow row: Int, frame: GhosttyTerminalFrame) -> [TerminalURLHit] {
    guard row >= 0, row < frame.rows, frame.cols > 0 else { return [] }
    let rowStart = row * frame.cols
    let rowEnd = min(rowStart + frame.cols, frame.cells.count)
    guard rowStart < rowEnd else { return [] }

    let line = frame.cells[rowStart..<rowEnd].map { String($0.scalar) }.joined()
    let nsLine = line as NSString
    let fullRange = NSRange(location: 0, length: nsLine.length)
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
      return []
    }

    let hyperlinkHits = hyperlinkHits(inRow: row, frame: frame)
    let visibleURLHits = regex.matches(in: line, options: [], range: fullRange).compactMap { match in
      normalizedHit(
        from: nsLine.substring(with: match.range(at: 1)),
        range: match.range(at: 1),
        row: row
      )
    }.filter { hit in
      !hyperlinkHits.contains { rangesOverlap($0.range, hit.range) }
    }
    return hyperlinkHits + visibleURLHits
  }

  private static func hyperlinkHits(inRow row: Int, frame: GhosttyTerminalFrame) -> [TerminalURLHit] {
    var hits: [TerminalURLHit] = []
    var activeURI: String?
    var activeStart = 0

    func flush(end: Int) {
      guard let uri = activeURI, activeStart < end, let url = URL(string: uri), url.scheme != nil else { return }
      let rowStart = row * frame.cols
      let text = frame.cells[(rowStart + activeStart)..<(rowStart + end)].map { String($0.scalar) }.joined()
      hits.append(TerminalURLHit(url: url, row: row, range: activeStart..<end, text: text))
    }

    for col in 0..<frame.cols {
      let index = row * frame.cols + col
      guard index < frame.cells.count else { break }
      let uri = frame.cells[index].hyperlink
      if uri != activeURI {
        flush(end: col)
        activeURI = uri
        activeStart = col
      }
    }
    flush(end: frame.cols)
    return hits
  }

  private static func normalizedHit(from rawText: String, range rawRange: NSRange, row: Int) -> TerminalURLHit? {
    let trimmed = rawText.trimmingCharacters(in: trailingCharacters)
    guard !trimmed.isEmpty else { return nil }
    let removedCharacterCount = rawText.count - trimmed.count
    let range = rawRange.location..<(rawRange.location + max(0, rawRange.length - removedCharacterCount))
    guard let url = normalizedURL(from: trimmed) else { return nil }
    return TerminalURLHit(url: url, row: row, range: range, text: trimmed)
  }

  private static func normalizedURL(from text: String) -> URL? {
    let candidate = hasHTTPProtocol(text) ? text : "http://\(text)"
    guard let url = URL(string: candidate), let scheme = url.scheme?.lowercased() else {
      return nil
    }
    guard scheme == "http" || scheme == "https" else { return nil }
    return url
  }

  private static func hasHTTPProtocol(_ text: String) -> Bool {
    let lowercased = text.lowercased()
    return lowercased.hasPrefix("http://") || lowercased.hasPrefix("https://")
  }

  private static func rangesOverlap(_ lhs: Range<Int>, _ rhs: Range<Int>) -> Bool {
    lhs.lowerBound < rhs.upperBound && rhs.lowerBound < lhs.upperBound
  }
}

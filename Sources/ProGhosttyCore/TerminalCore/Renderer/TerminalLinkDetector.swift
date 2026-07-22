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
  private static let pathPattern =
    #"(?<![A-Za-z0-9_])((?:~\/|\.{1,2}\/|/)[^\s<>"']+|(?:[A-Za-z0-9._@%+=~-]+/)+[A-Za-z0-9._@%+=~-]+\.[A-Za-z0-9._@%+=~-]+(?::\d+){0,2})"#
  /// Compiled once — recompiling per row on every `mouseMoved` was a per-move stall.
  private static let pathRegex: NSRegularExpression? = try? NSRegularExpression(pattern: pathPattern)
  private static let trailingCharacters = CharacterSet(charactersIn: ".,;!?)]}")

  public static func hitTest(row: Int, col: Int, in frame: GhosttyTerminalFrame) -> TerminalLinkHit? {
    hitTest(row: row, col: col, in: frame, pathValidator: nil)
  }

  /// - Parameter pathValidator: optional predicate that returns true for a raw
  ///   token that resolves to an existing file/dir under the session cwd. When
  ///   provided, bare words (no `/`, no extension) that validate — e.g. `src`,
  ///   `dist` — also become clickable path hits.
  public static func hitTest(
    row: Int,
    col: Int,
    in frame: GhosttyTerminalFrame,
    pathValidator: ((String) -> Bool)?
  ) -> TerminalLinkHit? {
    if let hit = hits(inRow: row, frame: frame, pathValidator: pathValidator).first(where: { $0.contains(row: row, col: col) }) {
      return hit
    }
    return suffixAnchoredPathHit(row: row, col: col, frame: frame)
  }

  public static func hits(inRow row: Int, frame: GhosttyTerminalFrame) -> [TerminalLinkHit] {
    hits(inRow: row, frame: frame, pathValidator: nil)
  }

  public static func hits(
    inRow row: Int,
    frame: GhosttyTerminalFrame,
    pathValidator: ((String) -> Bool)?
  ) -> [TerminalLinkHit] {
    guard row >= 0, row < frame.rows, frame.cols > 0 else { return [] }
    let urlHits = TerminalURLDetector.hits(inRow: row, frame: frame).map {
      TerminalLinkHit(target: .url($0.url), row: $0.row, range: $0.range, text: $0.text)
    }
    let pathHits = visiblePathHits(inRow: row, frame: frame).map { pathHit in
      extendingPathHitWithSuffixContinuation(pathHit, frame: frame)
    }.filter { pathHit in
      !urlHits.contains { rangesOverlap($0.range, pathHit.range) }
    }
    let suffixPathHits = suffixAnchoredPathHits(inRow: row, frame: frame).filter { suffixHit in
      !urlHits.contains { rangesOverlap($0.range, suffixHit.range) }
        && !pathHits.contains { rangesOverlap($0.range, suffixHit.range) }
    }
    var result = urlHits + pathHits + suffixPathHits
    if let pathValidator {
      let existing = result
      let bareHits = bareWordPathHits(inRow: row, frame: frame, validator: pathValidator).filter { bare in
        !existing.contains { rangesOverlap($0.range, bare.range) }
      }
      result += bareHits
    }
    return result
  }

  /// Bare filename-like tokens (no `/`, no scheme) that the filesystem validator
  /// confirms exist under the cwd. Lets `dist`, `src`, `README` be clickable when
  /// they are real entries, without matching arbitrary prose (which won't exist).
  private static func bareWordPathHits(
    inRow row: Int,
    frame: GhosttyTerminalFrame,
    validator: (String) -> Bool
  ) -> [TerminalLinkHit] {
    guard let text = text(inRow: row, frame: frame) else { return [] }
    let characters = Array(text)
    var hits: [TerminalLinkHit] = []
    var index = 0
    let count = characters.count
    while index < count {
      // Skip delimiters.
      while index < count, isBareDelimiter(characters[index]) { index += 1 }
      guard index < count else { break }
      let start = index
      while index < count, !isBareDelimiter(characters[index]) { index += 1 }
      let token = String(characters[start..<index])
      guard isPlausibleBareName(token), validator(token) else { continue }
      hits.append(
        TerminalLinkHit(
          target: .filePath(TerminalFilePathTarget(rawPath: token)),
          row: row,
          range: start..<index,
          text: token
        )
      )
    }
    return hits
  }

  private static func isBareDelimiter(_ character: Character) -> Bool {
    guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1 else {
      return true
    }
    return CharacterSet.whitespacesAndNewlines.contains(scalar)
      || "\"'<>(){}[]|:;,".unicodeScalars.contains(scalar)
  }

  /// A conservative filter so we only fs-check tokens that look like a file or
  /// folder name (avoids validating every prose word and long junk).
  private static func isPlausibleBareName(_ token: String) -> Bool {
    guard token.count >= 2, token.count <= 64 else { return false }
    if token.hasPrefix("/") || token.hasPrefix("~") || token.hasPrefix(".") { return false }
    if token.contains("/") { return false } // handled by the path pattern already
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._+-")
    return token.unicodeScalars.allSatisfy { allowed.contains($0) }
      && token.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
  }

  private static func visiblePathHits(inRow row: Int, frame: GhosttyTerminalFrame) -> [TerminalLinkHit] {
    let rows = TerminalLogicalLine.rows(around: row, frame: frame)
    guard !rows.isEmpty else { return [] }
    let line = rows.map(\.text).joined()
    let nsLine = line as NSString
    let fullRange = NSRange(location: 0, length: nsLine.length)
    guard let regex = pathRegex else { return [] }
    return regex.matches(in: line, options: [], range: fullRange).flatMap { match in
      pathHits(from: nsLine.substring(with: match.range(at: 1)), range: match.range(at: 1), rows: rows)
    }.filter { hit in
      hit.row == row
    }
  }

  private static func text(inRow row: Int, frame: GhosttyTerminalFrame) -> String? {
    TerminalLogicalLine.text(inRow: row, frame: frame)
  }

  private static func pathHits(from rawText: String, range rawRange: NSRange, rows: [TerminalLogicalLine.Row]) -> [TerminalLinkHit] {
    let trimmed = trimmingTrailingCharacters(from: rawText)
    guard !trimmed.isEmpty else { return [] }
    let parsed = stripLineAndColumn(from: trimmed)
    let removedCharacterCount = rawText.count - parsed.visibleText.count
    let range = rawRange.location..<(rawRange.location + max(0, rawRange.length - removedCharacterCount))
    let target = TerminalLinkTarget.filePath(TerminalFilePathTarget(rawPath: parsed.path, line: parsed.line, column: parsed.column))
    return TerminalLogicalLine.split(range: range, across: rows).map { rowRange in
      TerminalLinkHit(
        target: target,
        row: rowRange.row,
        range: rowRange.range,
        text: parsed.visibleText
      )
    }
  }

  private static func suffixAnchoredPathHits(inRow row: Int, frame: GhosttyTerminalFrame) -> [TerminalLinkHit] {
    guard row >= 0, row < frame.rows, frame.cols > 0 else { return [] }
    var hits: [TerminalLinkHit] = []
    var seenKeys = Set<String>()
    for col in 0..<frame.cols {
      guard let hit = suffixAnchoredPathHit(row: row, col: col, frame: frame) else { continue }
      let key = "\(hit.row):\(hit.range.lowerBound):\(hit.range.upperBound):\(hit.text)"
      if seenKeys.insert(key).inserted {
        hits.append(hit)
      }
    }
    return hits
  }

  private static func extendingPathHitWithSuffixContinuation(_ hit: TerminalLinkHit, frame: GhosttyTerminalFrame) -> TerminalLinkHit {
    guard case .filePath(let target) = hit.target,
      target.line == nil,
      target.column == nil,
      hit.row + 1 < frame.rows,
      pathHitReachesLineEnd(hit, frame: frame),
      !lastPathComponentHasExtension(target.rawPath)
    else {
      return hit
    }

    guard let continuationHit = suffixAnchoredPathHits(inRow: hit.row + 1, frame: frame).first(where: { continuation in
      guard case .filePath(let continuationTarget) = continuation.target else { return false }
      return continuationTarget.rawPath.hasPrefix(target.rawPath)
    }) else {
      return hit
    }

    return TerminalLinkHit(
      target: continuationHit.target,
      row: hit.row,
      range: hit.range,
      text: continuationHit.text
    )
  }

  private static func pathHitReachesLineEnd(_ hit: TerminalLinkHit, frame: GhosttyTerminalFrame) -> Bool {
    guard let rowText = text(inRow: hit.row, frame: frame) else { return false }
    let trimmedText = rowText.trimmingCharacters(in: .whitespacesAndNewlines)
    return hit.range.upperBound >= trimmedText.count
  }

  private static func lastPathComponentHasExtension(_ path: String) -> Bool {
    guard let lastComponent = path.split(separator: "/", omittingEmptySubsequences: false).last else {
      return false
    }
    return lastComponent.contains(".")
  }

  private static func suffixAnchoredPathHit(row: Int, col: Int, frame: GhosttyTerminalFrame) -> TerminalLinkHit? {
    guard row >= 0, row < frame.rows, col >= 0, col < frame.cols,
      let rowText = text(inRow: row, frame: frame)
    else {
      return nil
    }

    let characters = Array(rowText)
    guard col < characters.count, isExtensionAnchorCharacter(characters[col]) else { return nil }

    let clickedPrefix = String(characters.prefix(col + 1))
    let suffixStart = tokenStart(in: clickedPrefix)
    let clickedSuffixPrefix = String(clickedPrefix.dropFirst(suffixStart))
    guard clickedSuffixPrefix.contains(".") else { return nil }

    let suffixEnd = extensionEnd(in: characters, from: col)
    let suffixFragment = String(characters[suffixStart..<suffixEnd])

    var candidate = suffixFragment
    let prefixBeforeSuffix = String(characters.prefix(suffixStart))
    let boundaryIsOnlyLeadingWhitespace = prefixBeforeSuffix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    var reachedTokenBoundary = suffixStart > 0 && !boundaryIsOnlyLeadingWhitespace

    if !reachedTokenBoundary, row > 0 {
      for previousRow in stride(from: row - 1, through: 0, by: -1) {
        guard let previousText = text(inRow: previousRow, frame: frame) else { break }
        let trimmedText = previousText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { break }

        let start = tokenStart(in: trimmedText)
        let fragment = String(trimmedText.dropFirst(start))
        guard !fragment.isEmpty else { break }

        candidate = fragment + candidate
        reachedTokenBoundary = start > 0 || previousRow == 0
        if reachedTokenBoundary {
          break
        }
      }
    }

    guard reachedTokenBoundary || row == 0 else { return nil }
    let trimmed = trimmingTrailingCharacters(from: candidate)
    guard !trimmed.isEmpty, isCompletePathCandidate(trimmed) else { return nil }

    let parsed = stripLineAndColumn(from: trimmed)
    return TerminalLinkHit(
      target: .filePath(TerminalFilePathTarget(rawPath: parsed.path, line: parsed.line, column: parsed.column)),
      row: row,
      range: suffixStart..<suffixEnd,
      text: parsed.visibleText
    )
  }

  private static func tokenStart(in text: String) -> Int {
    var start = 0
    for (index, character) in text.enumerated() where isTokenDelimiter(character) {
      start = index + 1
    }
    return start
  }

  private static func isTokenDelimiter(_ character: Character) -> Bool {
    guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1 else {
      return false
    }
    return CharacterSet.whitespacesAndNewlines.contains(scalar)
      || "\"'<>({[".unicodeScalars.contains(scalar)
  }

  private static func extensionEnd(in characters: [Character], from col: Int) -> Int {
    var end = col + 1
    while end < characters.count, isExtensionCharacter(characters[end]) {
      end += 1
    }
    return end
  }

  private static func isExtensionAnchorCharacter(_ character: Character) -> Bool {
    character == "." || isExtensionCharacter(character)
  }

  private static func isExtensionCharacter(_ character: Character) -> Bool {
    guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1 else {
      return false
    }
    return CharacterSet.alphanumerics.contains(scalar)
  }

  private static func isCompletePathCandidate(_ text: String) -> Bool {
    guard let regex = pathRegex else { return false }
    let nsText = text as NSString
    let fullRange = NSRange(location: 0, length: nsText.length)
    return regex.matches(in: text, options: [], range: fullRange).contains { match in
      match.range(at: 1).location == 0 && match.range(at: 1).length == nsText.length
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

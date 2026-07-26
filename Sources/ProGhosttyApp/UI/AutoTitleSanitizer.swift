import Foundation

/// Cleans titles reported by terminal programs (OSC 0/1/2) before they reach
/// the titlebar. Pure value logic — no AppKit.
enum AutoTitleSanitizer {
  static let maxLength = 256

  /// Returns nil when the title should be cleared (empty payload, or nothing
  /// visible after stripping control characters and whitespace).
  static func sanitize(_ raw: String) -> String? {
    let stripped = raw.unicodeScalars.filter { !isControl($0) }
    let trimmed = String(String.UnicodeScalarView(stripped))
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    guard trimmed.count > maxLength else { return trimmed }
    let keep = maxLength - 1
    let head = trimmed.prefix((keep + 1) / 2)
    let tail = trimmed.suffix(keep / 2)
    return "\(head)…\(tail)"
  }

  private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
    // C0 (0x00–0x1F), DEL, and C1 (0x80–0x9F) — keeps escape bytes out of the titlebar.
    scalar.value < 0x20 || (scalar.value >= 0x7F && scalar.value <= 0x9F)
  }
}

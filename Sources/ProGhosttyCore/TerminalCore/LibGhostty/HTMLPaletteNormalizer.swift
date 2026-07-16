import Foundation

/// Rewrites Ghostty VT HTML so palette colors are concrete `rgb(...)` values
/// instead of `<style>:root{--vt-palette-N: #hex;}</style>` + `var(--vt-palette-N)`
/// references.
///
/// This is pure string/regex work with no AppKit dependency, so it lives at the
/// VT layer next to the bridge rather than inside the AppKit rendering adapter.
/// It is idempotent: running it on already-normalized HTML is a no-op (there is
/// no `<style>` block or `var()` reference left to replace).
enum HTMLPaletteNormalizer {
  static func normalized(_ html: String) -> String {
    let fullRange = NSRange(location: 0, length: (html as NSString).length)
    guard
      let styleRegex = try? NSRegularExpression(
        pattern: #"<style>\s*:root\s*\{([^}]*)\}\s*</style>"#,
        options: [.caseInsensitive, .dotMatchesLineSeparators]
      ),
      let definitionRegex = try? NSRegularExpression(
        pattern: #"--vt-palette-(\d+):\s*#([0-9a-fA-F]{6});"#,
        options: []
      ),
      let variableRegex = try? NSRegularExpression(
        pattern: #"var\(--vt-palette-(\d+)\)"#,
        options: []
      )
    else {
      return html
    }

    var palette: [String: String] = [:]
    var normalized = html
    let styleMatches = styleRegex.matches(in: html, range: fullRange)
    for match in styleMatches {
      guard match.numberOfRanges > 1,
        let cssRange = Range(match.range(at: 1), in: html)
      else { continue }
      let css = String(html[cssRange])
      let cssNSString = css as NSString
      let fullCSSRange = NSRange(location: 0, length: cssNSString.length)
      for definition in definitionRegex.matches(in: css, range: fullCSSRange) {
        guard definition.numberOfRanges > 2 else { continue }
        let index = cssNSString.substring(with: definition.range(at: 1))
        let hex = cssNSString.substring(with: definition.range(at: 2))
        guard
          let red = UInt8(hex.prefix(2), radix: 16),
          let green = UInt8(hex.dropFirst(2).prefix(2), radix: 16),
          let blue = UInt8(hex.dropFirst(4).prefix(2), radix: 16)
        else { continue }
        palette[index] = "rgb(\(red), \(green), \(blue))"
      }
    }

    for match in styleMatches.reversed() {
      guard let range = Range(match.range, in: normalized) else { continue }
      normalized.removeSubrange(range)
    }

    let normalizedRange = NSRange(location: 0, length: (normalized as NSString).length)
    let variableMatches = variableRegex.matches(in: normalized, range: normalizedRange)
    for match in variableMatches.reversed() {
      guard match.numberOfRanges > 1 else { continue }
      let nsString = normalized as NSString
      let index = nsString.substring(with: match.range(at: 1))
      guard let replacement = palette[index],
        let range = Range(match.range, in: normalized)
      else { continue }
      normalized.replaceSubrange(range, with: replacement)
    }

    return normalized
  }
}

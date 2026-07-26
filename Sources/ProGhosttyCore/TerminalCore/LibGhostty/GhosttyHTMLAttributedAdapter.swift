import AppKit
import Foundation

public final class GhosttyHTMLAttributedAdapter {
  private struct StyleState: Equatable {
    var foreground: NSColor?
    var background: NSColor?
    var bold = false
    var italic = false
    var faint = false
    var underline = false
    var strikethrough = false
    var inverse = false
    var invisible = false
    var link: String?

    mutating func apply(css: String) {
      for declaration in css.split(separator: ";") {
        let parts = declaration.split(separator: ":", maxSplits: 1)
        guard parts.count == 2 else { continue }
        let property = parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch property {
        case "color":
          foreground = Self.color(from: value)
        case "background-color":
          background = Self.color(from: value)
        case "font-weight":
          bold = value.contains("bold")
        case "font-style":
          italic = value.contains("italic")
        case "opacity":
          faint = value == "0.5" || value == ".5"
        case "text-decoration-line":
          underline = value.contains("underline")
          strikethrough = value.contains("line-through")
        case "visibility":
          invisible = value.contains("hidden")
        case "filter":
          inverse = value.contains("invert")
        default:
          continue
        }
      }
    }

    private static func color(from value: String) -> NSColor? {
      if value.hasPrefix("#"), value.count == 7 {
        let hex = String(value.dropFirst())
        guard
          let red = UInt8(hex.prefix(2), radix: 16),
          let green = UInt8(hex.dropFirst(2).prefix(2), radix: 16),
          let blue = UInt8(hex.dropFirst(4).prefix(2), radix: 16)
        else { return nil }
        return NSColor(
          calibratedRed: CGFloat(red) / 255,
          green: CGFloat(green) / 255,
          blue: CGFloat(blue) / 255,
          alpha: 1
        )
      }

      guard value.hasPrefix("rgb("), value.hasSuffix(")") else { return nil }
      let body = value.dropFirst(4).dropLast()
      let components = body.split(separator: ",").map {
        $0.trimmingCharacters(in: .whitespacesAndNewlines)
      }
      guard components.count == 3,
        let red = Double(components[0]),
        let green = Double(components[1]),
        let blue = Double(components[2])
      else { return nil }
      return NSColor(
        calibratedRed: max(0, min(255, red)) / 255,
        green: max(0, min(255, green)) / 255,
        blue: max(0, min(255, blue)) / 255,
        alpha: 1
      )
    }
  }

  private let palette: TerminalSurfacePalette
  private let font: NSFont
  private let boldFont: NSFont
  private var cachedHTML: String?
  private var cachedFocus: Bool?
  private var cachedAttributedString: NSAttributedString?

  public init(
    palette: TerminalSurfacePalette,
    fontFamily: String = FontCatalog.defaultMonospacedFontName(),
    fontSize: CGFloat = 13
  ) {
    self.palette = palette
    font = Self.font(family: fontFamily, size: fontSize, weight: .regular)
    boldFont = Self.font(family: fontFamily, size: fontSize, weight: .semibold)
  }

  public func attributedString(fromHTML html: String, isFocused: Bool) throws -> NSAttributedString {
    if cachedHTML == html, cachedFocus == isFocused, let cachedAttributedString {
      return cachedAttributedString
    }

    let normalized = HTMLPaletteNormalizer.normalized(html)
    let output = NSMutableAttributedString()
    var stack = [StyleState()]
    var index = normalized.startIndex

    while index < normalized.endIndex {
      if normalized[index] == "<" {
        guard let close = normalized[index...].firstIndex(of: ">") else { break }
        let rawTag = String(normalized[normalized.index(after: index)..<close])
        handleTag(rawTag, stack: &stack)
        index = normalized.index(after: close)
        continue
      }

      if let decoded = Self.decodedHTMLEntity(at: index, in: normalized) {
        append(decoded.character, style: stack.last ?? StyleState(), isFocused: isFocused, to: output)
        index = decoded.endIndex
      } else {
        append(String(normalized[index]), style: stack.last ?? StyleState(), isFocused: isFocused, to: output)
        index = normalized.index(after: index)
      }
    }

    cachedHTML = html
    cachedFocus = isFocused
    cachedAttributedString = output
    return output
  }

  private func handleTag(_ rawTag: String, stack: inout [StyleState]) {
    let trimmed = rawTag.trimmingCharacters(in: .whitespacesAndNewlines)
    let lowered = trimmed.lowercased()
    if lowered.hasPrefix("/div") {
      if stack.count > 1 {
        _ = stack.popLast()
      }
      return
    }
    if lowered.hasPrefix("/a") {
      if stack.count > 1 {
        _ = stack.popLast()
      }
      return
    }
    guard lowered.hasPrefix("div") || lowered.hasPrefix("a") else { return }

    var next = stack.last ?? StyleState()
    if let style = styleAttribute(in: trimmed) {
      next.apply(css: style)
    }
    if lowered.hasPrefix("a"), let href = hrefAttribute(in: trimmed) {
      next.link = href
    }
    stack.append(next)
  }

  private func styleAttribute(in tag: String) -> String? {
    guard let range = tag.range(of: #"style\s*=\s*"([^"]*)""#, options: .regularExpression) else {
      return nil
    }
    let raw = String(tag[range])
    guard let firstQuote = raw.firstIndex(of: "\""), let lastQuote = raw.lastIndex(of: "\""), firstQuote < lastQuote else {
      return nil
    }
    return String(raw[raw.index(after: firstQuote)..<lastQuote])
  }

  private func hrefAttribute(in tag: String) -> String? {
    guard let range = tag.range(of: #"href\s*=\s*"([^"]*)""#, options: .regularExpression) else {
      return nil
    }
    let raw = String(tag[range])
    guard let firstQuote = raw.firstIndex(of: "\""), let lastQuote = raw.lastIndex(of: "\""), firstQuote < lastQuote else {
      return nil
    }
    return Self.decodedHTMLText(String(raw[raw.index(after: firstQuote)..<lastQuote]))
  }

  private func append(
    _ text: String,
    style: StyleState,
    isFocused: Bool,
    to output: NSMutableAttributedString
  ) {
    guard !text.isEmpty else { return }

    let foregroundBase = style.foreground ?? palette.foreground
    let backgroundBase = style.background ?? palette.background
    let usesDefaultForeground = style.foreground == nil

    let foreground: NSColor
    let background: NSColor
    if style.invisible {
      // Invisible text is intentionally the background color; contrast
      // correction must not force it back into visibility.
      background = backgroundBase
      foreground = style.inverse ? palette.foreground : backgroundBase
    } else {
      let resolved = TerminalColorResolver.resolvedColors(
        baseForeground: foregroundBase,
        baseBackground: backgroundBase,
        faint: style.faint,
        inverse: style.inverse,
        usesDefaultForeground: usesDefaultForeground,
        isFocused: isFocused,
        palette: palette
      )
      foreground = resolved.foreground
      background = resolved.background
    }

    var attributes: [NSAttributedString.Key: Any] = [
      .font: style.bold ? boldFont : font,
      .foregroundColor: foreground,
      .backgroundColor: background,
    ]
    if style.italic {
      attributes[.obliqueness] = 0.18
    }
    if style.underline {
      attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
    }
    if style.strikethrough {
      attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
    }
    if let link = style.link {
      attributes[.link] = link
    }

    output.append(NSAttributedString(string: text, attributes: attributes))
  }

  private static func decodedHTMLEntity(at index: String.Index, in html: String) -> (character: String, endIndex: String.Index)? {
    guard html[index] == "&", let semicolon = html[index...].firstIndex(of: ";") else { return nil }
    let entityStart = html.index(after: index)
    let entity = String(html[entityStart..<semicolon])
    let endIndex = html.index(after: semicolon)

    switch entity {
    case "amp": return ("&", endIndex)
    case "lt": return ("<", endIndex)
    case "gt": return (">", endIndex)
    case "quot": return ("\"", endIndex)
    case "apos": return ("'", endIndex)
    default:
      if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
        let hex = String(entity.dropFirst(2))
        if let value = UInt32(hex, radix: 16), let scalar = UnicodeScalar(value) {
          return (String(scalar), endIndex)
        }
      } else if entity.hasPrefix("#") {
        let decimal = String(entity.dropFirst())
        if let value = UInt32(decimal, radix: 10), let scalar = UnicodeScalar(value) {
          return (String(scalar), endIndex)
        }
      }
      return nil
    }
  }

  private static func decodedHTMLText(_ text: String) -> String {
    var output = ""
    var index = text.startIndex
    while index < text.endIndex {
      if let decoded = decodedHTMLEntity(at: index, in: text) {
        output += decoded.character
        index = decoded.endIndex
      } else {
        output.append(text[index])
        index = text.index(after: index)
      }
    }
    return output
  }

  private static func font(family: String, size: CGFloat, weight: NSFont.Weight) -> NSFont {
    if let named = NSFont(name: family, size: size) {
      if weight == .semibold {
        return NSFontManager.shared.convert(named, toHaveTrait: .boldFontMask)
      }
      return named
    }
    return NSFont.monospacedSystemFont(ofSize: size, weight: weight)
  }
}

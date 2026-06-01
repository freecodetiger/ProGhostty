import AppKit
import Foundation

extension NSAttributedString.Key {
  static let proGhosttyCursorShape = NSAttributedString.Key("ProGhosttyCursorShape")
  static let proGhosttyCursorColor = NSAttributedString.Key("ProGhosttyCursorColor")
}

public final class TerminalAttributedRenderer {
  private let font: NSFont
  private let boldFont: NSFont
  private let cjkFont: NSFont?
  private let cjkBoldFont: NSFont?
  private let cursorBackground: NSColor
  private let cursorForeground: NSColor
  private let palette: TerminalSurfacePalette
  private let isFocused: Bool

  public init(
    fontFamily: String = FontManager.defaultMonospacedFontName(),
    cjkFallbackFamily: String? = nil,
    fontSize: CGFloat = 13,
    palette: TerminalSurfacePalette = .dark,
    isFocused: Bool = true
  ) {
    font = Self.font(family: fontFamily, size: fontSize, weight: .regular)
    boldFont = Self.font(family: fontFamily, size: fontSize, weight: .semibold)
    let normalizedCJKFallback = Self.normalizedFontFamily(cjkFallbackFamily)
    cjkFont = normalizedCJKFallback.flatMap { Self.installedFont(family: $0, size: fontSize, weight: .regular) }
    cjkBoldFont = normalizedCJKFallback.flatMap { Self.installedFont(family: $0, size: fontSize, weight: .semibold) }
    self.palette = palette
    self.isFocused = isFocused
    cursorBackground = palette.cursorBackground
    cursorForeground = palette.cursorForeground
  }

  public func attributedString(for frame: GhosttyTerminalFrame) -> NSAttributedString {
    let output = NSMutableAttributedString()

    for row in 0..<frame.rows {
      for col in 0..<frame.cols {
        let index = row * frame.cols + col
        guard index < frame.cells.count else { continue }
        let cell = frame.cells[index]
        let isCursor = frame.cursorVisible && row == frame.cursorY && col == frame.cursorX

        let colors = TerminalColorResolver.resolvedColors(for: cell, palette: palette, isFocused: isFocused)

        var attributes: [NSAttributedString.Key: Any] = [
          .font: font(for: cell),
          .foregroundColor: colors.foreground,
        ]
        if cell.inverse || !cell.usesDefaultBackground {
          attributes[.backgroundColor] = colors.background
        }
        if isCursor {
          attributes[.proGhosttyCursorShape] = frame.cursorShape
          attributes[.proGhosttyCursorColor] = cursorBackground
        }
        if cell.italic {
          attributes[.obliqueness] = 0.18
        }
        if cell.underline {
          attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }

        output.append(NSAttributedString(string: String(cell.scalar), attributes: attributes))
      }
      if row < frame.rows - 1 {
        output.append(NSAttributedString(string: "\n", attributes: [.font: font]))
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

  private static func installedFont(family: String, size: CGFloat, weight: NSFont.Weight) -> NSFont? {
    guard let named = NSFont(name: family, size: size) else { return nil }
    if weight == .semibold {
      return NSFontManager.shared.convert(named, toHaveTrait: .boldFontMask)
    }
    return named
  }

  private func font(for cell: GhosttyTerminalFrame.Cell) -> NSFont {
    guard FontManager.containsCJK(String(cell.scalar)) else {
      return cell.bold ? boldFont : font
    }
    return (cell.bold ? cjkBoldFont : cjkFont) ?? (cell.bold ? boldFont : font)
  }

  private static func normalizedFontFamily(_ family: String?) -> String? {
    let trimmed = family?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? nil : trimmed
  }
}

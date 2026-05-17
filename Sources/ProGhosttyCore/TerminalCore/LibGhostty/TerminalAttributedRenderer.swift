import AppKit
import Foundation

extension NSAttributedString.Key {
  static let proGhosttyCursorShape = NSAttributedString.Key("ProGhosttyCursorShape")
  static let proGhosttyCursorColor = NSAttributedString.Key("ProGhosttyCursorColor")
}

public final class TerminalAttributedRenderer {
  private let font: NSFont
  private let boldFont: NSFont
  private let defaultBackground: NSColor
  private let defaultForeground: NSColor
  private let cursorBackground: NSColor
  private let cursorForeground: NSColor
  private let palette: TerminalSurfacePalette
  private let isFocused: Bool

  public init(
    fontFamily: String = FontManager.defaultMonospacedFontName(),
    fontSize: CGFloat = 13,
    palette: TerminalSurfacePalette = .dark,
    isFocused: Bool = true
  ) {
    font = Self.font(family: fontFamily, size: fontSize, weight: .regular)
    boldFont = Self.font(family: fontFamily, size: fontSize, weight: .semibold)
    self.palette = palette
    self.isFocused = isFocused
    defaultBackground = palette.background
    defaultForeground = palette.foreground
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

        let foregroundBase = color(cell.foreground, faint: cell.faint, fallback: cell.usesDefaultForeground ? defaultForeground : nil)
        let backgroundBase = color(cell.background, faint: false, fallback: cell.usesDefaultBackground ? defaultBackground : nil)
        let (foreground, background) = resolvedColors(
          foreground: foregroundBase,
          background: backgroundBase,
          inverse: cell.inverse
        )
        let displayForeground = adjustedForeground(foreground)

        var attributes: [NSAttributedString.Key: Any] = [
          .font: cell.bold ? boldFont : font,
          .foregroundColor: displayForeground,
        ]
        if cell.inverse || !cell.usesDefaultBackground {
          attributes[.backgroundColor] = background
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

  private func resolvedColors(
    foreground: NSColor,
    background: NSColor,
    inverse: Bool
  ) -> (NSColor, NSColor) {
    guard inverse else { return (foreground, background) }
    return (background, foreground)
  }

  private func color(_ rgb: GhosttyTerminalFrame.RGB, faint: Bool, fallback: NSColor? = nil) -> NSColor {
    let factor: CGFloat = faint ? 0.48 : 1.0
    if let fallback {
      let rgb = fallback.usingColorSpace(.deviceRGB) ?? fallback
      return NSColor(
        calibratedRed: rgb.redComponent * factor,
        green: rgb.greenComponent * factor,
        blue: rgb.blueComponent * factor,
        alpha: 1
      )
    }
    return NSColor(
      calibratedRed: CGFloat(rgb.r) / 255.0 * factor,
      green: CGFloat(rgb.g) / 255.0 * factor,
      blue: CGFloat(rgb.b) / 255.0 * factor,
      alpha: 1
    )
  }

  private func adjustedForeground(_ color: NSColor) -> NSColor {
    guard !isFocused else { return color }
    let rgb = color.usingColorSpace(.deviceRGB) ?? color
    let background = palette.background.usingColorSpace(.deviceRGB) ?? palette.background
    let amount = palette.inactiveForegroundBlend
    return NSColor(
      calibratedRed: rgb.redComponent + (background.redComponent - rgb.redComponent) * amount,
      green: rgb.greenComponent + (background.greenComponent - rgb.greenComponent) * amount,
      blue: rgb.blueComponent + (background.blueComponent - rgb.blueComponent) * amount,
      alpha: 1
    )
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

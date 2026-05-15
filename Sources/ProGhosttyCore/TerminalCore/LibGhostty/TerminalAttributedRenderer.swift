import AppKit
import Foundation

public final class TerminalAttributedRenderer {
  private let font: NSFont
  private let boldFont: NSFont
  private let defaultBackground: NSColor
  private let cursorBackground: NSColor
  private let cursorForeground: NSColor

  public init(fontSize: CGFloat = 13) {
    font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
    boldFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .semibold)
    defaultBackground = NSColor(calibratedWhite: 0.08, alpha: 1)
    cursorBackground = NSColor(calibratedWhite: 0.86, alpha: 1)
    cursorForeground = NSColor(calibratedWhite: 0.05, alpha: 1)
  }

  public func attributedString(for frame: GhosttyTerminalFrame) -> NSAttributedString {
    let output = NSMutableAttributedString()

    for row in 0..<frame.rows {
      for col in 0..<frame.cols {
        let index = row * frame.cols + col
        guard index < frame.cells.count else { continue }
        let cell = frame.cells[index]
        let isCursor = frame.cursorVisible && row == frame.cursorY && col == frame.cursorX

        let foregroundBase = color(cell.foreground, faint: cell.faint)
        let backgroundBase = color(cell.background, faint: false, fallback: defaultBackground)
        let (foreground, background) = resolvedColors(
          foreground: foregroundBase,
          background: backgroundBase,
          inverse: cell.inverse
        )

        var attributes: [NSAttributedString.Key: Any] = [
          .font: cell.bold ? boldFont : font,
          .foregroundColor: isCursor ? cursorForeground : foreground,
        ]
        if isCursor {
          attributes[.backgroundColor] = cursorBackground
        } else if cell.inverse || !isDefaultBackground(cell.background) {
          attributes[.backgroundColor] = background
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
    if rgb.r == 0, rgb.g == 0, rgb.b == 0, let fallback {
      return fallback
    }
    let factor: CGFloat = faint ? 0.48 : 1.0
    return NSColor(
      calibratedRed: CGFloat(rgb.r) / 255.0 * factor,
      green: CGFloat(rgb.g) / 255.0 * factor,
      blue: CGFloat(rgb.b) / 255.0 * factor,
      alpha: 1
    )
  }

  private func isDefaultBackground(_ rgb: GhosttyTerminalFrame.RGB) -> Bool {
    rgb.r == 0 && rgb.g == 0 && rgb.b == 0
  }
}

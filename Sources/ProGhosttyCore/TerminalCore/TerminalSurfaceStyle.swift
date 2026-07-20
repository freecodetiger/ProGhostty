import AppKit

public struct TerminalSurfacePalette: Equatable, Sendable {
  public var background: NSColor
  public var foreground: NSColor
  public var faintForeground: NSColor
  public var cursorBackground: NSColor
  public var cursorForeground: NSColor
  public var selectionForeground: NSColor
  public var inactiveForegroundBlend: CGFloat
  public var splitDivider: NSColor

  public init(
    background: NSColor,
    foreground: NSColor,
    faintForeground: NSColor,
    cursorBackground: NSColor,
    cursorForeground: NSColor,
    selectionForeground: NSColor,
    inactiveForegroundBlend: CGFloat,
    splitDivider: NSColor
  ) {
    self.background = background
    self.foreground = foreground
    self.faintForeground = faintForeground
    self.cursorBackground = cursorBackground
    self.cursorForeground = cursorForeground
    self.selectionForeground = selectionForeground
    self.inactiveForegroundBlend = inactiveForegroundBlend
    self.splitDivider = splitDivider
  }

  public static let dark = TerminalSurfacePalette(
    background: NSColor(calibratedWhite: 0.075, alpha: 1),
    foreground: NSColor(calibratedWhite: 0.86, alpha: 1),
    faintForeground: NSColor(calibratedWhite: 0.52, alpha: 1),
    cursorBackground: NSColor(calibratedWhite: 0.86, alpha: 1),
    cursorForeground: NSColor(calibratedWhite: 0.045, alpha: 1),
    selectionForeground: NSColor(calibratedWhite: 0.88, alpha: 1),
    inactiveForegroundBlend: 0.28,
    splitDivider: NSColor(calibratedWhite: 1, alpha: 0.10)
  )

  public static let light = TerminalSurfacePalette(
    background: NSColor(calibratedWhite: 0.955, alpha: 1),
    foreground: NSColor(calibratedWhite: 0.085, alpha: 1),
    faintForeground: NSColor(calibratedWhite: 0.48, alpha: 1),
    cursorBackground: NSColor(calibratedWhite: 0.16, alpha: 1),
    cursorForeground: NSColor(calibratedWhite: 0.98, alpha: 1),
    selectionForeground: NSColor(calibratedWhite: 0.12, alpha: 1),
    inactiveForegroundBlend: 0.32,
    splitDivider: NSColor(calibratedWhite: 0, alpha: 0.09)
  )

  /// Soft Dark — Ghostty / One Dark blue-black (`#23272E` lineage).
  public static let softDark = TerminalSurfacePalette(
    background: NSColor(calibratedRed: 0.137, green: 0.153, blue: 0.180, alpha: 1), // #23272E
    foreground: NSColor(calibratedRed: 0.671, green: 0.698, blue: 0.749, alpha: 1), // #ABB2BF
    faintForeground: NSColor(calibratedRed: 0.361, green: 0.388, blue: 0.439, alpha: 1), // #5C6370
    cursorBackground: NSColor(calibratedRed: 0.671, green: 0.698, blue: 0.749, alpha: 1),
    cursorForeground: NSColor(calibratedRed: 0.137, green: 0.153, blue: 0.180, alpha: 1),
    selectionForeground: NSColor(calibratedRed: 0.843, green: 0.855, blue: 0.878, alpha: 1), // #D7DAE0
    inactiveForegroundBlend: 0.28,
    splitDivider: NSColor(calibratedRed: 0.671, green: 0.698, blue: 0.749, alpha: 0.12)
  )

  /// Soft Light — warm Solarized cream bg, black body text (user preference).
  public static let softLight = TerminalSurfacePalette(
    background: NSColor(calibratedRed: 0.992, green: 0.965, blue: 0.890, alpha: 1), // #FDF6E3 base3
    foreground: NSColor(calibratedWhite: 0.0, alpha: 1), // black
    faintForeground: NSColor(calibratedRed: 0.396, green: 0.482, blue: 0.514, alpha: 1), // #657B83 base00
    cursorBackground: NSColor(calibratedWhite: 0.0, alpha: 1),
    cursorForeground: NSColor(calibratedRed: 0.992, green: 0.965, blue: 0.890, alpha: 1),
    selectionForeground: NSColor(calibratedWhite: 0.0, alpha: 1),
    inactiveForegroundBlend: 0.28,
    splitDivider: NSColor(calibratedRed: 0.345, green: 0.431, blue: 0.459, alpha: 0.22)
  )
}

public enum TerminalSurfaceStyle {
  @MainActor
  public static func configureScrollView(_ scrollView: NSScrollView, backgroundColor: NSColor) {
    scrollView.hasVerticalScroller = false
    scrollView.hasHorizontalScroller = false
    scrollView.verticalScroller = nil
    scrollView.horizontalScroller = nil
    scrollView.autohidesScrollers = true
    scrollView.drawsBackground = true
    scrollView.borderType = .noBorder
    scrollView.focusRingType = .none
    scrollView.scrollerStyle = .overlay
    scrollView.backgroundColor = backgroundColor
    scrollView.contentView.drawsBackground = true
    scrollView.contentView.backgroundColor = backgroundColor
  }

  @MainActor
  public static func configureTextView(_ textView: NSTextView, palette: TerminalSurfacePalette) {
    textView.focusRingType = .none
    textView.drawsBackground = true
    textView.selectedTextAttributes = [
      .backgroundColor: palette.cursorBackground.withAlphaComponent(0.18),
      .foregroundColor: palette.selectionForeground,
    ]
    textView.textColor = palette.foreground
    textView.backgroundColor = palette.background
    textView.insertionPointColor = palette.cursorBackground
  }
}

enum TerminalColorResolver {
  static func foreground(
    for cell: GhosttyTerminalFrame.Cell,
    palette: TerminalSurfacePalette,
    isFocused: Bool
  ) -> NSColor {
    let colors = resolvedColors(for: cell, palette: palette, isFocused: isFocused)
    return colors.foreground
  }

  static func background(for cell: GhosttyTerminalFrame.Cell, palette: TerminalSurfacePalette) -> NSColor {
    baseColor(cell.background, fallback: cell.usesDefaultBackground ? palette.background : nil)
  }

  static func resolvedColors(
    for cell: GhosttyTerminalFrame.Cell,
    palette: TerminalSurfacePalette,
    isFocused: Bool
  ) -> (foreground: NSColor, background: NSColor) {
    let baseBackground = background(for: cell, palette: palette)
    let baseForeground = baseColor(
      cell.foreground,
      fallback: cell.usesDefaultForeground ? palette.foreground : nil
    )

    return resolvedColors(
      baseForeground: baseForeground,
      baseBackground: baseBackground,
      faint: cell.faint,
      inverse: cell.inverse,
      usesDefaultForeground: cell.usesDefaultForeground,
      isFocused: isFocused,
      palette: palette
    )
  }

  /// Color-level resolver shared by the cell-grid renderer and the HTML
  /// fallback adapter. Applies faint dimming, inverse swap, WCAG minimum
  /// contrast, and inactive dimming so both presentation paths produce the
  /// same readable colors.
  static func resolvedColors(
    baseForeground: NSColor,
    baseBackground: NSColor,
    faint: Bool,
    inverse: Bool,
    usesDefaultForeground: Bool,
    isFocused: Bool,
    palette: TerminalSurfacePalette
  ) -> (foreground: NSColor, background: NSColor) {
    var foreground = faint
      ? faintColor(baseForeground, background: baseBackground, usesDefaultForeground: usesDefaultForeground, palette: palette)
      : baseForeground
    var background = baseBackground

    if inverse {
      swap(&foreground, &background)
    }

    let activeMinimumContrast: CGFloat = faint ? 2.0 : 3.0
    foreground = foreground.withMinimumContrast(activeMinimumContrast, against: background)

    if !isFocused {
      foreground = foreground.blended(toward: palette.background, amount: palette.inactiveForegroundBlend)
      let inactiveMinimumContrast: CGFloat = faint ? 1.8 : 2.4
      foreground = foreground.withMinimumContrast(inactiveMinimumContrast, against: background)
    }

    return (foreground, background)
  }

  private static func faintColor(
    _ foreground: NSColor,
    background: NSColor,
    usesDefaultForeground: Bool,
    palette: TerminalSurfacePalette
  ) -> NSColor {
    if usesDefaultForeground {
      return palette.faintForeground
    }
    return foreground.blended(toward: background, amount: 0.46)
  }

  private static func baseColor(_ rgb: GhosttyTerminalFrame.RGB, fallback: NSColor?) -> NSColor {
    if let fallback {
      return fallback
    }
    return NSColor(
      calibratedRed: CGFloat(rgb.r) / 255.0,
      green: CGFloat(rgb.g) / 255.0,
      blue: CGFloat(rgb.b) / 255.0,
      alpha: 1
    )
  }
}

private extension NSColor {
  func withMinimumContrast(_ minimumContrast: CGFloat, against background: NSColor) -> NSColor {
    guard contrastRatio(against: background) < minimumContrast else { return self }
    let backgroundIsLight = background.relativeLuminance >= 0.5
    let target = backgroundIsLight ? NSColor.black : NSColor.white

    var lower: CGFloat = 0
    var upper: CGFloat = 1
    var candidate = self
    for _ in 0..<14 {
      let midpoint = (lower + upper) / 2
      let next = blended(toward: target, amount: midpoint)
      if next.contrastRatio(against: background) >= minimumContrast {
        candidate = next
        upper = midpoint
      } else {
        lower = midpoint
      }
    }
    return candidate
  }

  func blended(toward target: NSColor, amount: CGFloat) -> NSColor {
    let lhs = usingColorSpace(.deviceRGB) ?? self
    let rhs = target.usingColorSpace(.deviceRGB) ?? target
    let amount = min(1, max(0, amount))
    return NSColor(
      calibratedRed: lhs.redComponent + (rhs.redComponent - lhs.redComponent) * amount,
      green: lhs.greenComponent + (rhs.greenComponent - lhs.greenComponent) * amount,
      blue: lhs.blueComponent + (rhs.blueComponent - lhs.blueComponent) * amount,
      alpha: lhs.alphaComponent + (rhs.alphaComponent - lhs.alphaComponent) * amount
    )
  }

  func contrastRatio(against other: NSColor) -> CGFloat {
    let lhs = relativeLuminance
    let rhs = other.relativeLuminance
    let lighter = max(lhs, rhs)
    let darker = min(lhs, rhs)
    return (lighter + 0.05) / (darker + 0.05)
  }

  var relativeLuminance: CGFloat {
    let rgb = usingColorSpace(.deviceRGB) ?? self
    func channel(_ value: CGFloat) -> CGFloat {
      value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * channel(rgb.redComponent)
      + 0.7152 * channel(rgb.greenComponent)
      + 0.0722 * channel(rgb.blueComponent)
  }
}

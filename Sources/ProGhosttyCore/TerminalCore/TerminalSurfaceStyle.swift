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

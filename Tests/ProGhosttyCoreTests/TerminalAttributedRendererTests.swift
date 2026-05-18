import AppKit
import Testing

@testable import ProGhosttyCore

@MainActor @Suite("Terminal attributed renderer")
struct TerminalAttributedRendererTests {
  @Test func rendersFaintCellsWithSubduedForeground() {
    let frame = makeFrame(
      cells: [
        .init(
          scalar: "a",
          foreground: .init(r: 200, g: 200, b: 200),
          background: .init(r: 10, g: 10, b: 10),
          bold: false,
          italic: false,
          faint: false,
          underline: false,
          inverse: false
        ),
        .init(
          scalar: "s",
          foreground: .init(r: 200, g: 200, b: 200),
          background: .init(r: 10, g: 10, b: 10),
          bold: false,
          italic: false,
          faint: true,
          underline: false,
          inverse: false
        ),
      ])

    let rendered = TerminalAttributedRenderer().attributedString(for: frame)

    let normal = rendered.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
    let faint = rendered.attribute(.foregroundColor, at: 1, effectiveRange: nil) as? NSColor
    #expect(normal?.redComponent ?? 0 > faint?.redComponent ?? 0)
  }

  @Test func rendersInverseCellsBySwappingForegroundAndBackground() {
    let frame = makeFrame(
      cells: [
        .init(
          scalar: "i",
          foreground: .init(r: 20, g: 30, b: 40),
          background: .init(r: 180, g: 190, b: 200),
          bold: false,
          italic: false,
          faint: false,
          underline: false,
          inverse: true
        )
      ])

    let rendered = TerminalAttributedRenderer().attributedString(for: frame)

    let foreground = rendered.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
    let background = rendered.attribute(.backgroundColor, at: 0, effectiveRange: nil) as? NSColor
    #expect(foreground?.redComponent.isApproximately(180.0 / 255.0) == true)
    #expect(background?.redComponent.isApproximately(20.0 / 255.0) == true)
  }

  @Test func rendersBlockCursorAsOverlayAttributeWithoutPaintingCellBackground() {
    let frame = makeFrame(
      cursorVisible: true,
      cursorX: 1,
      cursorY: 0,
      cursorShape: .block,
      cells: [
        .init(
          scalar: "a",
          foreground: .init(r: 200, g: 200, b: 200),
          background: .init(r: 10, g: 10, b: 10),
          bold: false,
          italic: false,
          faint: false,
          underline: false,
          inverse: false
        ),
        .init(
          scalar: "b",
          foreground: .init(r: 200, g: 200, b: 200),
          background: .init(r: 10, g: 10, b: 10),
          bold: false,
          italic: false,
          faint: false,
          underline: false,
          inverse: false
        ),
      ])

    let rendered = TerminalAttributedRenderer().attributedString(for: frame)

    let normalBackground = rendered.attribute(.backgroundColor, at: 0, effectiveRange: nil) as? NSColor
    let cursorBackground = rendered.attribute(.backgroundColor, at: 1, effectiveRange: nil) as? NSColor
    #expect(cursorBackground?.sameRGB(as: normalBackground) == true)
    #expect(rendered.attribute(.proGhosttyCursorShape, at: 1, effectiveRange: nil) as? TerminalCursorShape == .block)
  }

  @Test func rendersBarCursorAsOverlayAttributeWithoutPaintingCellBackground() {
    let frame = makeFrame(
      cursorVisible: true,
      cursorX: 0,
      cursorY: 0,
      cursorShape: .bar,
      cells: [
        .init(
          scalar: " ",
          foreground: .init(r: 200, g: 200, b: 200),
          background: .init(r: 10, g: 10, b: 10),
          bold: false,
          italic: false,
          faint: false,
          underline: false,
          inverse: false,
          usesDefaultForeground: true,
          usesDefaultBackground: true
        )
      ])

    let rendered = TerminalAttributedRenderer().attributedString(for: frame)

    #expect(rendered.attribute(.backgroundColor, at: 0, effectiveRange: nil) == nil)
    #expect(rendered.attribute(.proGhosttyCursorShape, at: 0, effectiveRange: nil) as? TerminalCursorShape == .bar)
  }

  @Test func rendersUnderlineCursorAsOverlayAttributeWithoutPaintingCellBackground() {
    let frame = makeFrame(
      cursorVisible: true,
      cursorX: 0,
      cursorY: 0,
      cursorShape: .underline,
      cells: [
        .init(
          scalar: " ",
          foreground: .init(r: 200, g: 200, b: 200),
          background: .init(r: 10, g: 10, b: 10),
          bold: false,
          italic: false,
          faint: false,
          underline: false,
          inverse: false,
          usesDefaultForeground: true,
          usesDefaultBackground: true
        )
      ])

    let rendered = TerminalAttributedRenderer().attributedString(for: frame)

    #expect(rendered.attribute(.backgroundColor, at: 0, effectiveRange: nil) == nil)
    #expect(rendered.attribute(.proGhosttyCursorShape, at: 0, effectiveRange: nil) as? TerminalCursorShape == .underline)
  }

  @Test func rendersHollowBlockCursorAsOverlayAttributeWithoutFillingCellBackground() {
    let frame = makeFrame(
      cursorVisible: true,
      cursorX: 0,
      cursorY: 0,
      cursorShape: .hollowBlock,
      cells: [
        .init(
          scalar: " ",
          foreground: .init(r: 200, g: 200, b: 200),
          background: .init(r: 10, g: 10, b: 10),
          bold: false,
          italic: false,
          faint: false,
          underline: false,
          inverse: false,
          usesDefaultForeground: true,
          usesDefaultBackground: true
        )
      ])

    let rendered = TerminalAttributedRenderer().attributedString(for: frame)

    #expect(rendered.attribute(.backgroundColor, at: 0, effectiveRange: nil) == nil)
    #expect(rendered.attribute(.proGhosttyCursorShape, at: 0, effectiveRange: nil) as? TerminalCursorShape == .hollowBlock)
  }

  @Test func hiddenCursorDoesNotEmitCursorOverlayAttribute() {
    let frame = makeFrame(
      cursorVisible: false,
      cursorX: 0,
      cursorY: 0,
      cursorShape: .bar,
      cells: [
        .init(
          scalar: "a",
          foreground: .init(r: 200, g: 200, b: 200),
          background: .init(r: 10, g: 10, b: 10),
          bold: false,
          italic: false,
          faint: false,
          underline: false,
          inverse: false
        )
      ])

    let rendered = TerminalAttributedRenderer().attributedString(for: frame)

    #expect(rendered.attribute(.proGhosttyCursorShape, at: 0, effectiveRange: nil) == nil)
  }

  @Test func defaultBackgroundDoesNotPaintEmptyCellRuns() {
    let frame = makeFrame(
      cells: [
        .init(
          scalar: " ",
          foreground: .init(r: 200, g: 200, b: 200),
          background: .init(r: 0, g: 0, b: 0),
          bold: false,
          italic: false,
          faint: false,
          underline: false,
          inverse: false,
          usesDefaultForeground: true,
          usesDefaultBackground: true
        )
      ])

    let rendered = TerminalAttributedRenderer().attributedString(for: frame)

    #expect(rendered.attribute(.backgroundColor, at: 0, effectiveRange: nil) == nil)
  }

  @Test func lightPaletteUsesDarkForegroundForDefaultForegroundCells() {
    let frame = makeFrame(
      cells: [
        .init(
          scalar: "a",
          foreground: .init(r: 220, g: 220, b: 220),
          background: .init(r: 0, g: 0, b: 0),
          bold: false,
          italic: false,
          faint: false,
          underline: false,
          inverse: false,
          usesDefaultForeground: true,
          usesDefaultBackground: true
        )
      ])

    let rendered = TerminalAttributedRenderer(palette: .light).attributedString(for: frame)

    let foreground = rendered.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
    #expect((foreground?.usingColorSpace(.deviceRGB)?.redComponent ?? 1) < 0.20)
  }

  @Test func lightPaletteAdjustsLowContrastExplicitForegrounds() {
    let frame = makeFrame(
      cells: [
        .init(
          scalar: "w",
          foreground: .init(r: 238, g: 238, b: 238),
          background: .init(r: 0, g: 0, b: 0),
          bold: false,
          italic: false,
          faint: false,
          underline: false,
          inverse: false,
          usesDefaultForeground: false,
          usesDefaultBackground: true
        )
      ])

    let rendered = TerminalAttributedRenderer(palette: .light).attributedString(for: frame)

    let foreground = rendered.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
    #expect(foreground?.contrastRatio(against: TerminalSurfacePalette.light.background) ?? 0 >= 3.0)
    #expect((foreground?.lightness ?? 1) < 0.70)
  }

  @Test func darkPaletteAdjustsLowContrastExplicitForegrounds() {
    let frame = makeFrame(
      cells: [
        .init(
          scalar: "d",
          foreground: .init(r: 22, g: 22, b: 22),
          background: .init(r: 0, g: 0, b: 0),
          bold: false,
          italic: false,
          faint: false,
          underline: false,
          inverse: false,
          usesDefaultForeground: false,
          usesDefaultBackground: true
        )
      ])

    let rendered = TerminalAttributedRenderer(palette: .dark).attributedString(for: frame)

    let foreground = rendered.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
    #expect(foreground?.contrastRatio(against: TerminalSurfacePalette.dark.background) ?? 0 >= 3.0)
    #expect((foreground?.lightness ?? 0) > 0.35)
  }

  @Test func lightPaletteFaintDefaultForegroundStaysMutedButReadable() {
    let frame = makeFrame(
      cells: [
        .init(
          scalar: "n",
          foreground: .init(r: 0, g: 0, b: 0),
          background: .init(r: 0, g: 0, b: 0),
          bold: false,
          italic: false,
          faint: false,
          underline: false,
          inverse: false,
          usesDefaultForeground: true,
          usesDefaultBackground: true
        ),
        .init(
          scalar: "f",
          foreground: .init(r: 0, g: 0, b: 0),
          background: .init(r: 0, g: 0, b: 0),
          bold: false,
          italic: false,
          faint: true,
          underline: false,
          inverse: false,
          usesDefaultForeground: true,
          usesDefaultBackground: true
        ),
      ])

    let rendered = TerminalAttributedRenderer(palette: .light).attributedString(for: frame)

    let normal = rendered.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
    let faint = rendered.attribute(.foregroundColor, at: 1, effectiveRange: nil) as? NSColor
    #expect((faint?.lightness ?? 0) > (normal?.lightness ?? 1))
    #expect(faint?.contrastRatio(against: TerminalSurfacePalette.light.background) ?? 0 >= 2.0)
  }

  @Test func inactiveRenderingDimsForegroundWithoutPaintingBackground() {
    let frame = makeFrame(
      cells: [
        .init(
          scalar: "a",
          foreground: .init(r: 20, g: 20, b: 20),
          background: .init(r: 0, g: 0, b: 0),
          bold: false,
          italic: false,
          faint: false,
          underline: false,
          inverse: false,
          usesDefaultForeground: true,
          usesDefaultBackground: true
        )
      ])

    let active = TerminalAttributedRenderer(palette: .light, isFocused: true).attributedString(for: frame)
    let inactive = TerminalAttributedRenderer(palette: .light, isFocused: false).attributedString(for: frame)

    let activeForeground = active.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
    let inactiveForeground = inactive.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
    #expect((inactiveForeground?.lightness ?? 0) > (activeForeground?.lightness ?? 1))
    #expect(inactive.attribute(.backgroundColor, at: 0, effectiveRange: nil) == nil)
  }

  @Test func inactiveRenderingDoesNotDimExplicitBackground() {
    let frame = makeFrame(
      cells: [
        .init(
          scalar: "i",
          foreground: .init(r: 10, g: 20, b: 30),
          background: .init(r: 210, g: 220, b: 230),
          bold: false,
          italic: false,
          faint: false,
          underline: false,
          inverse: true
        )
      ])

    let active = TerminalAttributedRenderer(palette: .light, isFocused: true).attributedString(for: frame)
    let inactive = TerminalAttributedRenderer(palette: .light, isFocused: false).attributedString(for: frame)

    let activeBackground = active.attribute(.backgroundColor, at: 0, effectiveRange: nil) as? NSColor
    let inactiveBackground = inactive.attribute(.backgroundColor, at: 0, effectiveRange: nil) as? NSColor
    #expect(inactiveBackground?.sameRGB(as: activeBackground) == true)
  }

  @Test func nonDefaultBackgroundStillRenders() {
    let frame = makeFrame(
      cells: [
        .init(
          scalar: " ",
          foreground: .init(r: 200, g: 200, b: 200),
          background: .init(r: 10, g: 20, b: 30),
          bold: false,
          italic: false,
          faint: false,
          underline: false,
          inverse: false
        )
      ])

    let rendered = TerminalAttributedRenderer().attributedString(for: frame)

    #expect(rendered.attribute(.backgroundColor, at: 0, effectiveRange: nil) != nil)
  }

  @Test func rendersItalicCellsWithObliqueness() {
    let frame = makeFrame(
      cells: [
        .init(
          scalar: "i",
          foreground: .init(r: 200, g: 200, b: 200),
          background: .init(r: 10, g: 10, b: 10),
          bold: false,
          italic: true,
          faint: false,
          underline: false,
          inverse: false
        )
      ])

    let rendered = TerminalAttributedRenderer().attributedString(for: frame)

    let obliqueness = rendered.attribute(.obliqueness, at: 0, effectiveRange: nil) as? CGFloat
    #expect((obliqueness ?? 0) > 0)
  }

  @Test func rendererUsesConfiguredFontSize() {
    let frame = makeFrame(
      cells: [
        .init(
          scalar: "f",
          foreground: .init(r: 200, g: 200, b: 200),
          background: .init(r: 10, g: 10, b: 10),
          bold: false,
          italic: false,
          faint: false,
          underline: false,
          inverse: false
        )
      ])

    let rendered = TerminalAttributedRenderer(fontFamily: "Menlo", fontSize: 19).attributedString(for: frame)

    let font = rendered.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
    #expect(font?.pointSize == 19)
  }

  private func makeFrame(
    cursorVisible: Bool = false,
    cursorX: Int = 0,
    cursorY: Int = 0,
    cursorShape: TerminalCursorShape = .block,
    cells: [GhosttyTerminalFrame.Cell]
  ) -> GhosttyTerminalFrame {
    GhosttyTerminalFrame(
      cols: cells.count,
      rows: 1,
      cursorVisible: cursorVisible,
      cursorX: cursorX,
      cursorY: cursorY,
      cursorShape: cursorShape,
      cells: cells
    )
  }
}

private extension CGFloat {
  func isApproximately(_ other: CGFloat) -> Bool {
    abs(self - other) < 0.01
  }
}

private extension NSColor {
  var lightness: CGFloat {
    guard let rgb = usingColorSpace(.deviceRGB) else { return 0 }
    return (rgb.redComponent + rgb.greenComponent + rgb.blueComponent) / 3
  }

  func sameRGB(as other: NSColor?) -> Bool {
    guard
      let lhs = usingColorSpace(.deviceRGB),
      let rhs = other?.usingColorSpace(.deviceRGB)
    else {
      return false
    }
    return abs(lhs.redComponent - rhs.redComponent) < 0.001
      && abs(lhs.greenComponent - rhs.greenComponent) < 0.001
      && abs(lhs.blueComponent - rhs.blueComponent) < 0.001
  }

  func contrastRatio(against other: NSColor) -> CGFloat {
    let lhs = relativeLuminance
    let rhs = other.relativeLuminance
    let lighter = max(lhs, rhs)
    let darker = min(lhs, rhs)
    return (lighter + 0.05) / (darker + 0.05)
  }

  private var relativeLuminance: CGFloat {
    guard let rgb = usingColorSpace(.deviceRGB) else { return 0 }
    func channel(_ value: CGFloat) -> CGFloat {
      value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * channel(rgb.redComponent)
      + 0.7152 * channel(rgb.greenComponent)
      + 0.0722 * channel(rgb.blueComponent)
  }
}

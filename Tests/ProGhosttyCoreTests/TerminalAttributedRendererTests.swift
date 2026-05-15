import AppKit
import Testing

@testable import ProGhosttyCore

@Suite("Terminal attributed renderer")
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

  @Test func rendersCursorCellWithDistinctForegroundAndBackground() {
    let frame = makeFrame(
      cursorVisible: true,
      cursorX: 1,
      cursorY: 0,
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
    #expect(cursorBackground != normalBackground)
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
          inverse: false
        )
      ])

    let rendered = TerminalAttributedRenderer().attributedString(for: frame)

    #expect(rendered.attribute(.backgroundColor, at: 0, effectiveRange: nil) == nil)
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

  private func makeFrame(
    cursorVisible: Bool = false,
    cursorX: Int = 0,
    cursorY: Int = 0,
    cells: [GhosttyTerminalFrame.Cell]
  ) -> GhosttyTerminalFrame {
    GhosttyTerminalFrame(
      cols: cells.count,
      rows: 1,
      cursorVisible: cursorVisible,
      cursorX: cursorX,
      cursorY: cursorY,
      cells: cells
    )
  }
}

private extension CGFloat {
  func isApproximately(_ other: CGFloat) -> Bool {
    abs(self - other) < 0.01
  }
}

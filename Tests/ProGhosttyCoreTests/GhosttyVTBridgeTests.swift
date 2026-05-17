import Foundation
import Testing

@testable import ProGhosttyCore

@Suite("Ghostty VT bridge")
struct GhosttyVTBridgeTests {
  @Test func writesVtBytesAndFormatsPlainText() throws {
    let bridge = try GhosttyVTBridge(cols: 40, rows: 5)
    bridge.write(Data("hello \u{1B}[1mghostty\u{1B}[0m\r\n".utf8))

    let text = try bridge.plainText()

    #expect(text.contains("hello ghostty"))
    #expect(!text.contains("\u{1B}[1m"))
  }

  @Test func formatsStyledTerminalStateAsHtml() throws {
    let bridge = try GhosttyVTBridge(cols: 40, rows: 5)
    bridge.write(Data("typed \u{1B}[2;90msuggestion\u{1B}[0m\r\n".utf8))

    let html = try bridge.htmlText()

    #expect(html.contains("typed"))
    #expect(html.contains("suggestion"))
    #expect(html.contains("style") || html.contains("class") || html.contains("span"))
  }

  @Test func formatsPaletteColorsAsConcreteRgbInHtml() throws {
    let bridge = try GhosttyVTBridge(cols: 40, rows: 5)
    bridge.write(Data("typed \u{1B}[38;5;8msuggestion\u{1B}[0m\r\n".utf8))

    let html = try bridge.htmlText()

    #expect(html.contains("rgb("))
    #expect(!html.contains("var(--vt-palette-8)"))
  }

  @Test func renderFramePreservesFaintStyleAndCursor() throws {
    let bridge = try GhosttyVTBridge(cols: 40, rows: 5)
    bridge.write(Data("typed \u{1B}[2;90msuggestion\u{1B}[0m".utf8))

    let frame = try bridge.frame()
    let text = frame.cells.map { String($0.scalar) }.joined()

    #expect(text.contains("typed suggestion"))
    #expect(frame.cells.contains { $0.scalar == "s" && $0.faint })
    #expect(frame.cursorVisible)
    #expect(frame.cursorX > 0)
  }

  @Test func renderFrameKeepsInverseAsStyleInsteadOfPreSwappingColors() throws {
    let bridge = try GhosttyVTBridge(cols: 10, rows: 2)
    bridge.write(Data("\u{1B}[38;2;200;10;20;7mX\u{1B}[0m".utf8))

    let cell = try #require(try bridge.frame().cells.first)

    #expect(cell.scalar == "X")
    #expect(cell.inverse)
    #expect(cell.foreground == GhosttyTerminalFrame.RGB(r: 200, g: 10, b: 20))
    #expect(cell.usesDefaultForeground == false)
    #expect(cell.usesDefaultBackground == true)
  }

  @Test func renderFramePreservesCursorVisualStyle() throws {
    let bridge = try GhosttyVTBridge(cols: 40, rows: 5)

    bridge.write(Data("\u{1B}[6 qbar".utf8))
    #expect(try bridge.frame().cursorShape == .bar)

    bridge.write(Data("\u{1B}[4 qunderline".utf8))
    #expect(try bridge.frame().cursorShape == .underline)

    bridge.write(Data("\u{1B}[2 qblock".utf8))
    #expect(try bridge.frame().cursorShape == .block)
  }

  @Test func renderFrameReportsAlternateScreenState() throws {
    let bridge = try GhosttyVTBridge(cols: 40, rows: 5)

    #expect(try bridge.frame().isAlternateScreen == false)

    bridge.write(Data("\u{1B}[?1049h".utf8))
    #expect(try bridge.frame().isAlternateScreen)

    bridge.write(Data("\u{1B}[?1049l".utf8))
    #expect(try bridge.frame().isAlternateScreen == false)
  }

  @Test func zshEndOfLineMarkerClearsWithCarriageReturnOverwrite() throws {
    let bridge = try GhosttyVTBridge(cols: 80, rows: 5)
    let clearLineRemainder = String(repeating: " ", count: 78)
    bridge.write(Data("\u{1B}[1m\u{1B}[7m%\u{1B}[27m\u{1B}[1m\u{1B}[0m\(clearLineRemainder)\r \rprompt % ".utf8))

    let frame = try bridge.frame()
    let firstLine = frame.cells.prefix(frame.cols).map { String($0.scalar) }.joined()

    #expect(firstLine.hasPrefix("prompt % "))
    #expect(!firstLine.hasPrefix("%"))
  }

  @Test func formatterIncludesScrollbackHistory() throws {
    let bridge = try GhosttyVTBridge(cols: 20, rows: 2, maxScrollback: 100)
    bridge.write(Data("hello".utf8))
    bridge.write(Data("\u{1B}D\u{1B}D\u{1B}D".utf8))

    let text = try bridge.plainText()
    let html = try bridge.htmlText()

    #expect(text.contains("hello"))
    #expect(html.contains("hello"))
  }

  @Test func cellGridFrameCanScrollLibGhosttyViewportIntoScrollback() throws {
    let bridge = try GhosttyVTBridge(cols: 20, rows: 2, maxScrollback: 100)
    bridge.write(Data("first\r\nsecond\r\nthird\r\nfourth".utf8))

    let bottom = try bridge.frame().cells.map { String($0.scalar) }.joined()
    bridge.scrollViewport(deltaRows: -2)
    let scrolled = try bridge.frame().cells.map { String($0.scalar) }.joined()

    #expect(bottom.contains("fourth"))
    #expect(scrolled.contains("first") || scrolled.contains("second"))
    #expect(try bridge.scrollbar().total >= bridge.scrollbar().length)
  }

  @Test func scrollFrameReportsVisibleAndOverscanRowsSeparately() throws {
    let bridge = try GhosttyVTBridge(cols: 20, rows: 4, maxScrollback: 100)
    bridge.write(Data("one\r\ntwo\r\nthree\r\nfour\r\nfive\r\nsix".utf8))

    let frame = try bridge.scrollFrame(overscanTop: 1, overscanBottom: 1)

    #expect(frame.viewport.cols == 20)
    #expect(frame.viewport.rows == 4)
    #expect(frame.overscanTop.count <= 1)
    #expect(frame.overscanBottom.count <= 1)
    #expect(frame.requestedOverscanTop == 1)
    #expect(frame.requestedOverscanBottom == 1)
  }

  @Test func scrollFrameCapabilityMatchesOverscanRows() throws {
    let bridge = try GhosttyVTBridge(cols: 20, rows: 3, maxScrollback: 100)
    bridge.write(Data("one\r\ntwo\r\nthree\r\nfour\r\nfive".utf8))
    bridge.scrollViewport(deltaRows: -1)

    let frame = try bridge.scrollFrame(overscanTop: 1, overscanBottom: 1)

    #expect(frame.overscanAvailable)
    #expect(frame.overscanTop.count == 1)
    #expect(frame.overscanBottom.count == 1)
    #expect(frame.overscanTop.first?.text(cols: frame.viewport.cols).contains("one") == true)
    #expect(frame.overscanBottom.first?.text(cols: frame.viewport.cols).contains("five") == true)
  }
}

private extension GhosttyTerminalCellRow {
  func text(cols: Int) -> String {
    cells.prefix(cols).map { String($0.scalar) }.joined()
  }
}

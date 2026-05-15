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
}

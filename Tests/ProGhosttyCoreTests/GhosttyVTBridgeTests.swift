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

  @Test func encodedPasteUsesBracketedPasteModeWhenTerminalRequestsIt() throws {
    let bridge = try GhosttyVTBridge(cols: 40, rows: 5)
    bridge.write(Data("\u{1B}[?2004h".utf8))

    let encoded = try bridge.encodedPaste("one\ntwo\u{1B}[201~three")
    let text = String(decoding: encoded, as: UTF8.self)

    #expect(text.hasPrefix("\u{1B}[200~"))
    #expect(text.hasSuffix("\u{1B}[201~"))
    #expect(text.contains("one\ntwo"))
    #expect(!String(text.dropFirst("\u{1B}[200~".count).dropLast("\u{1B}[201~".count)).contains("\u{1B}[201~"))
  }

  @Test func encodedPasteConvertsNewlinesToCarriageReturnsWithoutBracketedPasteMode() throws {
    let bridge = try GhosttyVTBridge(cols: 40, rows: 5)

    let encoded = try bridge.encodedPaste("one\ntwo")

    #expect(encoded == Data("one\rtwo".utf8))
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

  @Test func renderFramePreservesOSC8HyperlinkURI() throws {
    let bridge = try GhosttyVTBridge(cols: 20, rows: 2)
    bridge.write(Data("\u{1B}]8;;https://example.com/path\u{1B}\\link\u{1B}]8;;\u{1B}\\".utf8))

    let frame = try bridge.frame()
    let linkedCell = try #require(frame.cells.first { $0.scalar == "l" })

    #expect(linkedCell.hyperlink == "https://example.com/path")
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

  @Test func renderFramePreservesWideCellMetadataForCJKText() throws {
    let bridge = try GhosttyVTBridge(cols: 10, rows: 2)
    bridge.write(Data("界".utf8))

    let frame = try bridge.frame()

    #expect(frame.cells[0].scalar == "界")
    #expect(frame.cells[0].width == .wide)
    #expect(frame.cells[1].width == .spacerTail)
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

  @Test func scrollFrameClampsOverscanRowsToBridgeMaximum() throws {
    // Request more overscan than the C shim's hard cap
    // (PROGHOSTTY_VT_MAX_OVERSCAN_ROWS = 32) with ample scrollback above the
    // viewport, and confirm the shim never materializes more than the cap.
    let bridge = try GhosttyVTBridge(cols: 20, rows: 3, maxScrollback: 500)
    bridge.write(Data((1...200).map { "line-\($0)" }.joined(separator: "\r\n").utf8))
    bridge.scrollViewport(deltaRows: -100)

    let frame = try bridge.scrollFrame(overscanTop: 64, overscanBottom: 64)

    #expect(frame.overscanTop.count <= 32)
    #expect(frame.overscanBottom.count <= 32)
  }

  @Test func scrollFrameHonorsLargeOverscanRequestWithinCap() throws {
    // A request within the cap should be honored in full when enough history
    // exists on that side — this is the capacity R1 relies on to translate
    // many rows per frame without a synchronous VT commit.
    let bridge = try GhosttyVTBridge(cols: 20, rows: 3, maxScrollback: 500)
    bridge.write(Data((1...200).map { "line-\($0)" }.joined(separator: "\r\n").utf8))
    bridge.scrollViewport(deltaRows: -100)

    let frame = try bridge.scrollFrame(overscanTop: 24, overscanBottom: 24)

    #expect(frame.overscanTop.count == 24)
    #expect(frame.overscanBottom.count == 24)
  }

  @Test func seqLikeOutputAtBottomIncludesFinalLineAndPrompt() throws {
    let bridge = try GhosttyVTBridge(cols: 80, rows: 35, maxScrollback: 500)
    let output = (1...200).map(String.init).joined(separator: "\r\n") + "\r\nzpc@host ~ % "

    bridge.write(Data(output.utf8))

    let text = try bridge.frame().cells.map { String($0.scalar) }.joined()
    #expect(text.contains("200"))
    #expect(text.contains("zpc@host"))
  }

  @Test func concurrentOutputAndViewportReadsDoNotCorruptTerminalState() throws {
    let bridge = try GhosttyVTBridge(cols: 80, rows: 12, maxScrollback: 2_000)
    let iterations = 500
    let writers = 4
    let readers = 4
    let group = DispatchGroup()
    let queue = DispatchQueue(label: "dev.proghostty.tests.vt-race", attributes: .concurrent)

    for writer in 0..<writers {
      group.enter()
      queue.async {
        for index in 0..<iterations {
          bridge.write(Data("writer-\(writer)-line-\(index)\r\n".utf8))
        }
        group.leave()
      }
    }

    for _ in 0..<readers {
      group.enter()
      queue.async {
        for _ in 0..<iterations {
          _ = try? bridge.scrollbar()
          _ = try? bridge.frame()
          _ = try? bridge.scrollFrame(overscanTop: 2, overscanBottom: 2)
          bridge.scrollViewport(deltaRows: -1)
          bridge.scrollViewport(deltaRows: 1)
        }
        group.leave()
      }
    }

    #expect(group.wait(timeout: .now() + 10) == .success)
    let text = try bridge.frame().cells.map { String($0.scalar) }.joined()
    #expect(text.contains("writer-"))
  }

  // MARK: rows(at:count:) — pattern-2 absolute-row window primitive

  @Test func rowsAtReturnsRequestedWindowByAbsoluteRow() throws {
    let bridge = try GhosttyVTBridge(cols: 20, rows: 3, maxScrollback: 500)
    // 6 logical lines pushed into a 3-row screen leaves rows 0..2 in scrollback
    // history and rows 3..5 on screen, for a total of 6 absolute rows.
    bridge.write(Data("one\r\ntwo\r\nthree\r\nfour\r\nfive\r\nsix".utf8))

    let window = try bridge.rows(at: 0, count: 6)

    #expect(window.startRow == 0)
    #expect(window.total == 6)
    #expect(window.cols == 20)
    #expect(window.rows.count == 6)
    #expect(window.rows.first?.text(cols: window.cols).contains("one") == true)
    #expect(window.rows.last?.text(cols: window.cols).contains("six") == true)
  }

  @Test func rowsAtReadsAMidHistorySliceWithoutMovingViewport() throws {
    let bridge = try GhosttyVTBridge(cols: 20, rows: 3, maxScrollback: 500)
    bridge.write(Data("one\r\ntwo\r\nthree\r\nfour\r\nfive\r\nsix".utf8))

    // Fetch just the two history rows above the screen; the VT viewport must not
    // move (browsing is decoupled from the viewport in pattern 2).
    let before = try bridge.scrollbar()
    let window = try bridge.rows(at: 1, count: 2)
    let after = try bridge.scrollbar()

    #expect(window.startRow == 1)
    #expect(window.rows.count == 2)
    #expect(window.rows.first?.text(cols: window.cols).contains("two") == true)
    #expect(window.rows.last?.text(cols: window.cols).contains("three") == true)
    #expect(before.offset == after.offset)
  }

  @Test func rowsAtClampsWindowRunningPastEndOfScrollback() throws {
    let bridge = try GhosttyVTBridge(cols: 20, rows: 3, maxScrollback: 500)
    bridge.write(Data("one\r\ntwo\r\nthree\r\nfour\r\nfive\r\nsix".utf8))

    // Ask for more rows than remain from row 4; expect truncation to [4, total).
    let window = try bridge.rows(at: 4, count: 10)

    #expect(window.total == 6)
    #expect(window.startRow == 4)
    #expect(window.rows.count == 2)
    #expect(window.rows.first?.text(cols: window.cols).contains("five") == true)
  }

  @Test func rowsAtReturnsEmptyWindowForOutOfRangeStart() throws {
    let bridge = try GhosttyVTBridge(cols: 20, rows: 3, maxScrollback: 500)
    bridge.write(Data("one\r\ntwo\r\nthree\r\nfour\r\nfive\r\nsix".utf8))

    let window = try bridge.rows(at: 100, count: 4)

    #expect(window.total == 6)
    #expect(window.rows.isEmpty)
  }

  @Test func rowsAtReturnsEmptyForZeroCount() throws {
    let bridge = try GhosttyVTBridge(cols: 20, rows: 3, maxScrollback: 500)
    bridge.write(Data("one\r\ntwo\r\nthree".utf8))

    let window = try bridge.rows(at: 0, count: 0)

    #expect(window.rows.isEmpty)
  }
}

private extension GhosttyTerminalCellRow {
  func text(cols: Int) -> String {
    cells.prefix(cols).map { String($0.scalar) }.joined()
  }
}

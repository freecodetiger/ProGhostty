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

  @Test func specialKeysAllProduceNonEmptySequences() throws {
    let bridge = try GhosttyVTBridge(cols: 40, rows: 5)
    // macOS virtual keycodes: arrows, navigation/editing, F1–F12.
    let keyCodes: [UInt16] = [
      0x7E, 0x7D, 0x7B, 0x7C,                          // up down left right
      0x73, 0x77, 0x74, 0x79, 0x72, 0x75,              // home end pgup pgdn ins del
      0x7A, 0x78, 0x63, 0x76, 0x60, 0x61,              // F1..F6
      0x62, 0x64, 0x65, 0x6D, 0x67, 0x6F,              // F7..F12
    ]
    for code in keyCodes {
      #expect(!(try bridge.encodedKey(TerminalKeyEvent(keyCode: code, modifiers: [], text: nil, unshiftedCodepoint: 0)).isEmpty))
    }
  }

  @Test func arrowKeysRespectCursorApplicationMode() throws {
    let bridge = try GhosttyVTBridge(cols: 40, rows: 5)
    let up = TerminalKeyEvent(keyCode: 0x7E, modifiers: [], text: nil, unshiftedCodepoint: 0)
    // Normal mode emits CSI A; DECCKM (application cursor keys) emits SS3 A.
    #expect(try bridge.encodedKey(up) == Data("\u{1B}[A".utf8))
    bridge.write(Data("\u{1B}[?1h".utf8))
    #expect(try bridge.encodedKey(up) == Data("\u{1B}OA".utf8))
  }

  @Test func controlModifierEncodesModifiedArrow() throws {
    let bridge = try GhosttyVTBridge(cols: 40, rows: 5)
    let ctrlLeft = TerminalKeyEvent(keyCode: 0x7B, modifiers: .control, text: nil, unshiftedCodepoint: 0)
    #expect(try bridge.encodedKey(ctrlLeft) == Data("\u{1B}[1;5D".utf8))
  }

  @Test func controlPlusLetterEncodesControlByte() throws {
    let bridge = try GhosttyVTBridge(cols: 40, rows: 5)
    // Ctrl+A: keycode A + control mod + unshifted "a" → 0x01.
    let ctrlA = TerminalKeyEvent(keyCode: 0x00, modifiers: .control, text: "a", unshiftedCodepoint: 0x61)
    #expect(try bridge.encodedKey(ctrlA) == Data([0x01]))
  }

  @Test func optionModifiedArrowEncodesAltModifier() throws {
    let bridge = try GhosttyVTBridge(cols: 40, rows: 5)
    let altUp = TerminalKeyEvent(keyCode: 0x7E, modifiers: .alt, text: nil, unshiftedCodepoint: 0)
    #expect(try bridge.encodedKey(altUp) == Data("\u{1B}[1;3A".utf8))
  }

  @Test func focusReportingDefaultsOffAndEncodesInOut() throws {
    let bridge = try GhosttyVTBridge(cols: 40, rows: 5)
    #expect(!bridge.isFocusReportingActive())
    #expect(try bridge.encodedFocus(gained: true) == Data("\u{1B}[I".utf8))
    #expect(try bridge.encodedFocus(gained: false) == Data("\u{1B}[O".utf8))
    bridge.write(Data("\u{1B}[?1004h".utf8))
    #expect(bridge.isFocusReportingActive())
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

  @Test func primaryScreenWithoutMouseTrackingOwnsLocalScrollback() throws {
    let bridge = try GhosttyVTBridge(cols: 40, rows: 5)

    #expect(try bridge.scrollOwnership() == .localScrollback)
  }

  @Test func x10MouseTrackingIsRecognizedAndFiltersWheelEvents() throws {
    let bridge = try GhosttyVTBridge(cols: 40, rows: 5)
    bridge.write(Data("\u{1B}[?9h".utf8))

    #expect(bridge.isMouseReportingActive())
    #expect(try bridge.scrollOwnership() == .mouseReporting)
    let encoded = try bridge.encodedMouseInput(
      TerminalMouseInputEvent(action: .press, button: .wheelUp, x: 10, y: 10),
      geometry: mouseGeometry
    )
    #expect(encoded.isEmpty)
  }

  @Test func sgrMouseTrackingEncodesWheelButtonsAndCoordinates() throws {
    let bridge = try GhosttyVTBridge(cols: 80, rows: 24)
    bridge.write(Data("\u{1B}[?1002h\u{1B}[?1006h".utf8))

    let up = try bridge.encodedMouseInput(
      TerminalMouseInputEvent(action: .press, button: .wheelUp, x: 50, y: 40),
      geometry: mouseGeometry
    )
    let down = try bridge.encodedMouseInput(
      TerminalMouseInputEvent(
        action: .press,
        button: .wheelDown,
        shift: true,
        control: true,
        alt: true,
        x: 50,
        y: 40
      ),
      geometry: mouseGeometry
    )

    #expect(String(decoding: up, as: UTF8.self) == "\u{1B}[<64;6;3M")
    #expect(String(decoding: down, as: UTF8.self) == "\u{1B}[<93;6;3M")
  }

  @Test func sgrMouseTrackingEncodesButtonsReleaseAndMotion() throws {
    let bridge = try GhosttyVTBridge(cols: 80, rows: 24)
    bridge.write(Data("\u{1B}[?1003h\u{1B}[?1006h".utf8))

    let left = try bridge.encodedMouseInput(
      TerminalMouseInputEvent(action: .press, button: .left, anyButtonPressed: true, x: 50, y: 40),
      geometry: mouseGeometry
    )
    let rightRelease = try bridge.encodedMouseInput(
      TerminalMouseInputEvent(action: .release, button: .right, x: 50, y: 40),
      geometry: mouseGeometry
    )
    let middle = try bridge.encodedMouseInput(
      TerminalMouseInputEvent(action: .press, button: .middle, anyButtonPressed: true, x: 50, y: 40),
      geometry: mouseGeometry
    )
    let drag = try bridge.encodedMouseInput(
      TerminalMouseInputEvent(action: .motion, button: .left, anyButtonPressed: true, x: 50, y: 40),
      geometry: mouseGeometry
    )
    let hover = try bridge.encodedMouseInput(
      TerminalMouseInputEvent(action: .motion, x: 50, y: 40),
      geometry: mouseGeometry
    )

    #expect(String(decoding: left, as: UTF8.self) == "\u{1B}[<0;6;3M")
    #expect(String(decoding: rightRelease, as: UTF8.self) == "\u{1B}[<2;6;3m")
    #expect(String(decoding: middle, as: UTF8.self) == "\u{1B}[<1;6;3M")
    #expect(String(decoding: drag, as: UTF8.self) == "\u{1B}[<32;6;3M")
    #expect(String(decoding: hover, as: UTF8.self) == "\u{1B}[<35;6;3M")
  }

  @Test func mouseTrackingFiltersMotionByRequestedMode() throws {
    let bridge = try GhosttyVTBridge(cols: 80, rows: 24)
    bridge.write(Data("\u{1B}[?1000h\u{1B}[?1006h".utf8))

    let normalMotion = try bridge.encodedMouseInput(
      TerminalMouseInputEvent(action: .motion, button: .left, anyButtonPressed: true, x: 50, y: 40),
      geometry: mouseGeometry
    )
    bridge.write(Data("\u{1B}[?1000l\u{1B}[?1002h".utf8))
    let buttonHover = try bridge.encodedMouseInput(
      TerminalMouseInputEvent(action: .motion, x: 50, y: 40),
      geometry: mouseGeometry
    )
    let buttonDrag = try bridge.encodedMouseInput(
      TerminalMouseInputEvent(action: .motion, button: .left, anyButtonPressed: true, x: 50, y: 40),
      geometry: mouseGeometry
    )

    #expect(normalMotion.isEmpty)
    #expect(buttonHover.isEmpty)
    #expect(String(decoding: buttonDrag, as: UTF8.self) == "\u{1B}[<32;6;3M")
  }

  @Test func sgrMouseTrackingEncodesHorizontalWheelButtons() throws {
    let bridge = try GhosttyVTBridge(cols: 80, rows: 24)
    bridge.write(Data("\u{1B}[?1002h\u{1B}[?1006h".utf8))

    let right = try bridge.encodedMouseInput(
      TerminalMouseInputEvent(action: .press, button: .wheelRight, x: 50, y: 40),
      geometry: mouseGeometry
    )
    let left = try bridge.encodedMouseInput(
      TerminalMouseInputEvent(action: .press, button: .wheelLeft, x: 50, y: 40),
      geometry: mouseGeometry
    )

    #expect(String(decoding: right, as: UTF8.self) == "\u{1B}[<66;6;3M")
    #expect(String(decoding: left, as: UTF8.self) == "\u{1B}[<67;6;3M")
  }

  @Test func mouseEncoderSupportsLegacyAndPixelFormats() throws {
    let bridge = try GhosttyVTBridge(cols: 400, rows: 100)
    let largeGeometry = TerminalMouseGeometry(
      screenWidth: 4_000,
      screenHeight: 2_000,
      cellWidth: 10,
      cellHeight: 20,
      paddingTop: 20,
      paddingBottom: 20,
      paddingRight: 10,
      paddingLeft: 10
    )

    bridge.write(Data("\u{1B}[?1002h\u{1B}[?1005h".utf8))
    let utf8 = try bridge.encodedMouseInput(
      TerminalMouseInputEvent(action: .press, button: .left, x: 3_000, y: 40),
      geometry: largeGeometry
    )
    bridge.write(Data("\u{1B}[?1005l\u{1B}[?1015h".utf8))
    let urxvt = try bridge.encodedMouseInput(
      TerminalMouseInputEvent(action: .press, button: .wheelUp, x: 50, y: 40),
      geometry: largeGeometry
    )
    bridge.write(Data("\u{1B}[?1015l\u{1B}[?1016h".utf8))
    let pixels = try bridge.encodedMouseInput(
      TerminalMouseInputEvent(action: .press, button: .left, x: 50, y: 40),
      geometry: largeGeometry
    )

    #expect(utf8.starts(with: Data([0x1B, 0x5B, 0x4D, 0x20])))
    #expect(String(decoding: urxvt, as: UTF8.self) == "\u{1B}[96;5;2M")
    #expect(String(decoding: pixels, as: UTF8.self) == "\u{1B}[<0;40;20M")
  }

  @Test func alternateScreenWithoutTrackingEncodesCursorKeys() throws {
    let bridge = try GhosttyVTBridge(cols: 40, rows: 5)
    bridge.write(Data("\u{1B}[?1049h".utf8))

    #expect(try bridge.scrollOwnership() == .alternateCursorKeys(applicationMode: false))
    #expect(
      String(decoding: try bridge.encodedAlternateScroll(wheelUp: true, count: 2), as: UTF8.self)
        == "\u{1B}[A\u{1B}[A"
    )

    bridge.write(Data("\u{1B}[?1h".utf8))
    #expect(try bridge.scrollOwnership() == .alternateCursorKeys(applicationMode: true))
    #expect(
      String(decoding: try bridge.encodedAlternateScroll(wheelUp: false, count: 2), as: UTF8.self)
        == "\u{1B}OB\u{1B}OB"
    )
  }

  @Test func alternateScreenWithAlternateScrollDisabledConsumesWheel() throws {
    let bridge = try GhosttyVTBridge(cols: 40, rows: 5)
    bridge.write(Data("\u{1B}[?1049h\u{1B}[?1007l".utf8))

    #expect(try bridge.scrollOwnership() == .consumed)
    #expect(try bridge.encodedAlternateScroll(wheelUp: true, count: 1).isEmpty)
  }

  private var mouseGeometry: TerminalMouseGeometry {
    TerminalMouseGeometry(
      screenWidth: 800,
      screenHeight: 600,
      cellWidth: 10,
      cellHeight: 20,
      paddingTop: 0,
      paddingBottom: 0,
      paddingRight: 0,
      paddingLeft: 0
    )
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

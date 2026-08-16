import AppKit
import Foundation
import Testing

@testable import ProGhosttyCore

@Suite("Terminal surface", .serialized)
struct TerminalSurfaceTests {
  @MainActor @Test func liveGridRoutesDiscreteMouseReportingWheelToPTYInput() throws {
    let gridView = PTYGridView()
    gridView.terminalScrollOwnershipHandler = { .mouseReporting }
    gridView.terminalMouseEncodeHandler = { _, _ in Data("m".utf8) }
    var emitted = Data()
    gridView.inputHandler = { emitted.append($0) }

    gridView.scrollWheel(with: try scrollEvent(deltaY: 1))

    #expect(emitted == Data("mmm".utf8))
  }

  @MainActor @Test func liveGridRoutesAlternateWheelToCursorKeyEncoder() throws {
    let gridView = PTYGridView()
    gridView.terminalScrollOwnershipHandler = { .alternateCursorKeys(applicationMode: false) }
    var request: (wheelUp: Bool, count: Int)?
    gridView.terminalAlternateScrollEncodeHandler = { wheelUp, count in
      request = (wheelUp, count)
      return Data("cursor".utf8)
    }
    var emitted = Data()
    gridView.inputHandler = { emitted.append($0) }

    gridView.scrollWheel(with: try scrollEvent(deltaY: -1))

    #expect(request?.wheelUp == false)
    #expect(request?.count == 3)
    #expect(emitted == Data("cursor".utf8))
  }

  @MainActor @Test func liveGridConsumesDisabledAlternateScrollWithoutPTYInput() throws {
    let gridView = PTYGridView()
    gridView.terminalScrollOwnershipHandler = { .consumed }
    var encoded = false
    gridView.terminalMouseEncodeHandler = { _, _ in
      encoded = true
      return Data("unexpected".utf8)
    }
    var emitted = Data()
    gridView.inputHandler = { emitted.append($0) }

    gridView.scrollWheel(with: try scrollEvent(deltaY: 1))

    #expect(!encoded)
    #expect(emitted.isEmpty)
  }

  @MainActor @Test func liveGridRoutesCapturedMousePressAndRelease() throws {
    let gridView = PTYGridView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    gridView.terminalScrollOwnershipHandler = { .mouseReporting }
    var events: [TerminalMouseInputEvent] = []
    gridView.terminalMouseEncodeHandler = { event, _ in
      events.append(event)
      return Data([UInt8(events.count)])
    }
    var emitted = Data()
    gridView.inputHandler = { emitted.append($0) }

    gridView.mouseDown(with: try mouseEvent(.leftMouseDown, viewPoint: NSPoint(x: 50, y: 40), in: gridView))
    gridView.mouseUp(with: try mouseEvent(.leftMouseUp, viewPoint: NSPoint(x: 50, y: 40), in: gridView))

    #expect(events.map(\.action) == [.press, .release])
    #expect(events.map(\.button) == [.left, .left])
    #expect(events[0].anyButtonPressed)
    #expect(!events[1].anyButtonPressed)
    #expect(emitted == Data([1, 2]))
  }

  @MainActor @Test func capturedMouseReleaseUsesPressOwnershipDecision() throws {
    let gridView = PTYGridView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    var ownership: TerminalScrollOwnership? = .mouseReporting
    gridView.terminalScrollOwnershipHandler = { ownership }
    var actions: [TerminalMouseAction] = []
    gridView.terminalMouseEncodeHandler = { event, _ in
      actions.append(event.action)
      return Data("m".utf8)
    }

    gridView.mouseDown(with: try mouseEvent(.leftMouseDown, viewPoint: NSPoint(x: 50, y: 40), in: gridView))
    ownership = .localScrollback
    gridView.mouseUp(with: try mouseEvent(.leftMouseUp, viewPoint: NSPoint(x: 50, y: 40), in: gridView))

    #expect(actions == [.press, .release])
  }

  @MainActor @Test func liveGridRoutesCapturedRightButtonWithoutOpeningLocalMenu() throws {
    let gridView = PTYGridView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    gridView.terminalScrollOwnershipHandler = { .mouseReporting }
    var buttons: [TerminalMouseButton?] = []
    gridView.terminalMouseEncodeHandler = { event, _ in
      buttons.append(event.button)
      return Data("r".utf8)
    }
    var emitted = Data()
    gridView.inputHandler = { emitted.append($0) }

    gridView.rightMouseDown(with: try mouseEvent(.rightMouseDown, viewPoint: NSPoint(x: 50, y: 40), in: gridView))
    gridView.rightMouseUp(with: try mouseEvent(.rightMouseUp, viewPoint: NSPoint(x: 50, y: 40), in: gridView))

    #expect(buttons == [.right, .right])
    #expect(emitted == Data("rr".utf8))
  }

  @MainActor @Test func shiftLeftDragRemainsLocalDuringMouseReporting() throws {
    let gridView = PTYGridView()
    let frame = frameWithText(rows: ["abcdef"], cols: 12, cursorX: 0, cursorY: 0)
    let cellSize = gridView.terminalCellSize
    let inset = gridView.terminalContentInset
    gridView.frame = NSRect(
      x: 0,
      y: 0,
      width: inset.width * 2 + CGFloat(frame.cols) * cellSize.width,
      height: inset.height * 2 + CGFloat(frame.rows) * cellSize.height
    )
    gridView.render(frame, isFocused: true)
    gridView.terminalScrollOwnershipHandler = { .mouseReporting }
    var encoded = 0
    gridView.terminalMouseEncodeHandler = { _, _ in
      encoded += 1
      return Data("m".utf8)
    }
    let start = PTYGridView.textGlyphRect(row: 0, col: 1, cellSize: cellSize, inset: inset)
    let end = PTYGridView.textGlyphRect(row: 0, col: 3, cellSize: cellSize, inset: inset)

    gridView.mouseDown(with: try mouseEvent(
      .leftMouseDown,
      viewPoint: NSPoint(x: start.midX, y: start.midY),
      in: gridView,
      modifierFlags: .shift
    ))
    gridView.mouseDragged(with: try mouseEvent(
      .leftMouseDragged,
      viewPoint: NSPoint(x: end.midX, y: end.midY),
      in: gridView,
      modifierFlags: .shift
    ))
    gridView.mouseUp(with: try mouseEvent(
      .leftMouseUp,
      viewPoint: NSPoint(x: end.midX, y: end.midY),
      in: gridView,
      modifierFlags: .shift
    ))

    #expect(encoded == 0)
    #expect(gridView.selectedText == "bcd")
  }

  @MainActor @Test func capturedMousePressClearsExistingLocalSelection() throws {
    let gridView = PTYGridView()
    let frame = frameWithText(rows: ["abcdef"], cols: 12, cursorX: 0, cursorY: 0)
    let cellSize = gridView.terminalCellSize
    let inset = gridView.terminalContentInset
    gridView.frame = NSRect(
      x: 0,
      y: 0,
      width: inset.width * 2 + CGFloat(frame.cols) * cellSize.width,
      height: inset.height * 2 + CGFloat(frame.rows) * cellSize.height
    )
    gridView.render(frame, isFocused: true)
    let start = PTYGridView.textGlyphRect(row: 0, col: 1, cellSize: cellSize, inset: inset)
    let end = PTYGridView.textGlyphRect(row: 0, col: 3, cellSize: cellSize, inset: inset)
    gridView.mouseDown(with: try mouseEvent(.leftMouseDown, viewPoint: NSPoint(x: start.midX, y: start.midY), in: gridView))
    gridView.mouseDragged(with: try mouseEvent(.leftMouseDragged, viewPoint: NSPoint(x: end.midX, y: end.midY), in: gridView))
    gridView.mouseUp(with: try mouseEvent(.leftMouseUp, viewPoint: NSPoint(x: end.midX, y: end.midY), in: gridView))
    #expect(gridView.selectedText == "bcd")

    gridView.terminalScrollOwnershipHandler = { .mouseReporting }
    gridView.terminalMouseEncodeHandler = { _, _ in Data("m".utf8) }
    gridView.mouseDown(with: try mouseEvent(.leftMouseDown, viewPoint: NSPoint(x: start.midX, y: start.midY), in: gridView))

    #expect(gridView.selectedText == nil)
  }

  @MainActor @Test func copySelectionSkipsWideCharacterSpacerCells() throws {
    let gridView = PTYGridView()
    func wideCell(_ scalar: UnicodeScalar, _ width: TerminalCellWidth) -> GhosttyTerminalFrame.Cell {
      GhosttyTerminalFrame.Cell(
        scalar: scalar,
        width: width,
        foreground: GhosttyTerminalFrame.RGB(r: 255, g: 255, b: 255),
        background: GhosttyTerminalFrame.RGB(r: 0, g: 0, b: 0),
        bold: false, italic: false, faint: false, underline: false, inverse: false,
        usesDefaultForeground: true, usesDefaultBackground: true
      )
    }
    // "中文": each CJK glyph is a wide head followed by a spacerTail continuation.
    let cells: [GhosttyTerminalFrame.Cell] = [
      wideCell("中", .wide), wideCell(" ", .spacerTail),
      wideCell("文", .wide), wideCell(" ", .spacerTail),
      wideCell(" ", .narrow), wideCell(" ", .narrow),
    ]
    let frame = GhosttyTerminalFrame(
      cols: 6, rows: 1,
      cursorVisible: true, cursorX: 0, cursorY: 0,
      cursorShape: .bar, cursorBlinking: false, isAlternateScreen: true,
      cells: cells
    )
    let cellSize = gridView.terminalCellSize
    let inset = gridView.terminalContentInset
    gridView.frame = NSRect(
      x: 0, y: 0,
      width: inset.width * 2 + CGFloat(frame.cols) * cellSize.width,
      height: inset.height * 2 + CGFloat(frame.rows) * cellSize.height
    )
    gridView.render(frame, isFocused: true)

    let start = PTYGridView.textGlyphRect(row: 0, col: 0, cellSize: cellSize, inset: inset)
    let end = PTYGridView.textGlyphRect(row: 0, col: 5, cellSize: cellSize, inset: inset)
    gridView.mouseDown(with: try mouseEvent(.leftMouseDown, viewPoint: NSPoint(x: start.midX, y: start.midY), in: gridView))
    gridView.mouseDragged(with: try mouseEvent(.leftMouseDragged, viewPoint: NSPoint(x: end.midX, y: end.midY), in: gridView))
    gridView.mouseUp(with: try mouseEvent(.leftMouseUp, viewPoint: NSPoint(x: end.midX, y: end.midY), in: gridView))

    #expect(gridView.selectedText == "中文")
  }

  @MainActor @Test func liveGridCoalescesCapturedMouseMotion() throws {
    let gridView = PTYGridView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    gridView.terminalScrollOwnershipHandler = { .mouseReporting }
    var events: [TerminalMouseInputEvent] = []
    gridView.terminalMouseEncodeHandler = { event, _ in
      events.append(event)
      return Data("m".utf8)
    }
    var emitted = Data()
    gridView.inputHandler = { emitted.append($0) }

    gridView.mouseMoved(with: try mouseEvent(.mouseMoved, viewPoint: NSPoint(x: 10, y: 20), in: gridView))
    gridView.mouseMoved(with: try mouseEvent(.mouseMoved, viewPoint: NSPoint(x: 30, y: 40), in: gridView))
    gridView.flushPendingTerminalMouseMotionForTests()

    #expect(events.count == 1)
    #expect(events[0].action == .motion)
    #expect(events[0].button == nil)
    #expect(events[0].x == 30)
    #expect(events[0].y == 40)
    #expect(emitted == Data("m".utf8))
  }

  @MainActor @Test func capturedMouseDragReportsPressedButtonMotion() throws {
    let gridView = PTYGridView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    gridView.terminalScrollOwnershipHandler = { .mouseReporting }
    var events: [TerminalMouseInputEvent] = []
    gridView.terminalMouseEncodeHandler = { event, _ in
      events.append(event)
      return Data("m".utf8)
    }

    gridView.mouseDown(with: try mouseEvent(.leftMouseDown, viewPoint: NSPoint(x: 10, y: 20), in: gridView))
    gridView.mouseDragged(with: try mouseEvent(.leftMouseDragged, viewPoint: NSPoint(x: 30, y: 40), in: gridView))
    gridView.flushPendingTerminalMouseMotionForTests()
    gridView.mouseUp(with: try mouseEvent(.leftMouseUp, viewPoint: NSPoint(x: 30, y: 40), in: gridView))

    #expect(events.map(\.action) == [.press, .motion, .release])
    #expect(events.map(\.button) == [.left, .left, .left])
    #expect(events[1].anyButtonPressed)
  }

  @MainActor @Test func focusLossReleasesCapturedMouseButtons() throws {
    let gridView = PTYGridView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    gridView.terminalScrollOwnershipHandler = { .mouseReporting }
    var actions: [TerminalMouseAction] = []
    gridView.terminalMouseEncodeHandler = { event, _ in
      actions.append(event.action)
      return Data("m".utf8)
    }

    gridView.mouseDown(with: try mouseEvent(.leftMouseDown, viewPoint: NSPoint(x: 10, y: 20), in: gridView))
    _ = gridView.resignFirstResponder()

    #expect(actions == [.press, .release])
  }

  @MainActor @Test func localPressDoesNotCreateTerminalReleaseAfterModeChange() throws {
    let gridView = PTYGridView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    var ownership: TerminalScrollOwnership? = .localScrollback
    gridView.terminalScrollOwnershipHandler = { ownership }
    var actions: [TerminalMouseAction] = []
    gridView.terminalMouseEncodeHandler = { event, _ in
      actions.append(event.action)
      return Data("m".utf8)
    }

    gridView.mouseDown(with: try mouseEvent(.leftMouseDown, viewPoint: NSPoint(x: 10, y: 20), in: gridView))
    ownership = .mouseReporting
    gridView.mouseUp(with: try mouseEvent(.leftMouseUp, viewPoint: NSPoint(x: 10, y: 20), in: gridView))

    #expect(actions.isEmpty)
  }

  @MainActor @Test func ownershipQueryFailureUsesLastSuccessfulRoute() throws {
    let gridView = PTYGridView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    var ownership: TerminalScrollOwnership? = .mouseReporting
    gridView.terminalScrollOwnershipHandler = { ownership }
    gridView.terminalMouseEncodeHandler = { _, _ in Data("m".utf8) }
    var emitted = Data()
    gridView.inputHandler = { emitted.append($0) }

    gridView.scrollWheel(with: try scrollEvent(deltaY: 1))
    ownership = nil
    gridView.scrollWheel(with: try scrollEvent(deltaY: 1))

    #expect(emitted == Data("mmmmmm".utf8))
  }

  @MainActor @Test func liveGridRoutesHorizontalWheelToMouseButtonsSixAndSeven() throws {
    let gridView = PTYGridView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    gridView.terminalScrollOwnershipHandler = { .mouseReporting }
    var buttons: [TerminalMouseButton?] = []
    gridView.terminalMouseEncodeHandler = { event, _ in
      buttons.append(event.button)
      return Data("h".utf8)
    }
    var emitted = Data()
    gridView.inputHandler = { emitted.append($0) }

    gridView.scrollWheel(with: try scrollEvent(deltaY: 0, deltaX: 1))
    gridView.scrollWheel(with: try scrollEvent(deltaY: 0, deltaX: -1))

    #expect(buttons == [.wheelRight, .wheelLeft])
    #expect(emitted == Data("hhhhhh".utf8))
  }

  @Test func builtInPalettesUseDistinctReadableGrays() {
    let light = TerminalSurfacePalette.light
    let dark = TerminalSurfacePalette.dark

    #expect(light.background.lightness > 0.90)
    #expect(light.foreground.lightness < 0.20)
    #expect(dark.background.lightness < 0.12)
    #expect(dark.foreground.lightness > 0.80)
    #expect(light.inactiveForegroundBlend > 0.20)
    #expect(light.inactiveForegroundBlend < 0.40)
    #expect(dark.inactiveForegroundBlend > 0.20)
    #expect(dark.inactiveForegroundBlend < 0.40)
  }

  private func scrollEvent(deltaY: Int32, deltaX: Int32 = 0) throws -> NSEvent {
    let cgEvent = try #require(CGEvent(
      scrollWheelEvent2Source: nil,
      units: .line,
      wheelCount: 2,
      wheel1: deltaY,
      wheel2: deltaX,
      wheel3: 0
    ))
    return try #require(NSEvent(cgEvent: cgEvent))
  }

  @MainActor @Test func mockSurfaceDoesNotExposeNativeScrollers() throws {
    let engine = MockTerminalEngine()
    let session = try engine.createSession(config: TerminalSessionConfig(
      shellPath: "/bin/sh",
      workingDirectory: FileManager.default.currentDirectoryPath,
      environment: [:],
      rows: 24,
      cols: 80
    ))

    let scrollView = try #require(engine.viewForSession(session) as? NSScrollView)

    #expect(scrollView.hasVerticalScroller == false)
    #expect(scrollView.hasHorizontalScroller == false)
    #expect(scrollView.verticalScroller == nil || scrollView.verticalScroller?.isHidden == true)
    #expect(scrollView.horizontalScroller == nil || scrollView.horizontalScroller?.isHidden == true)
  }

  @MainActor @Test func ptySurfaceUsesTerminalBackgroundAcrossNativeLayers() throws {
    let registry = PTYTerminalSurfaceRegistry()
    let session = TerminalSessionID()
    registry.createSurface(session: session)
    registry.applyPalette(.light)

    let scrollView = try scrollView(in: #require(registry.viewForSession(session)))
    let textView = try #require(scrollView.documentView as? NSTextView)

    #expect(scrollView.backgroundColor.sameRGB(as: TerminalSurfacePalette.light.background))
    #expect(scrollView.contentView.drawsBackground == true)
    #expect(scrollView.contentView.backgroundColor.sameRGB(as: TerminalSurfacePalette.light.background))
    #expect(textView.backgroundColor.sameRGB(as: TerminalSurfacePalette.light.background))
    #expect(scrollView.focusRingType == .none)
    #expect(textView.focusRingType == .none)
  }

  @MainActor @Test func ptySurfaceAppliesCurrentPaletteToNewLiveRenderer() {
    let renderer = PaletteRecordingLiveRendererBackend()
    let registry = PTYTerminalSurfaceRegistry(
      isMetalDirectAvailable: true,
      makeDirectRenderer: { _ in renderer }
    )
    let session = TerminalSessionID()
    registry.applyPalette(.light)

    registry.createSurface(session: session)

    #expect(renderer.appliedPalettes == [.light])
  }

  @MainActor @Test func ptySurfaceAllowsVisibleNativeTextSelection() throws {
    let registry = PTYTerminalSurfaceRegistry()
    let session = TerminalSessionID()
    registry.createSurface(session: session)

    let scrollView = try scrollView(in: #require(registry.viewForSession(session)))
    let textView = try #require(scrollView.documentView as? NSTextView)
    let selectionBackground = textView.selectedTextAttributes[.backgroundColor] as? NSColor

    #expect(textView.isEditable == false)
    #expect(textView.isSelectable == true)
    #expect(selectionBackground?.alphaComponent ?? 0 > 0)
  }

  @MainActor @Test func ptySurfaceAppliesConfiguredFont() throws {
    let registry = PTYTerminalSurfaceRegistry()
    let session = TerminalSessionID()
    registry.createSurface(session: session)

    registry.applyFont(family: "Menlo", size: 21)

    let scrollView = try scrollView(in: #require(registry.viewForSession(session)))
    let textView = try #require(scrollView.documentView as? NSTextView)
    #expect(textView.font?.pointSize == 21)
    #expect(textView.font?.familyName == "Menlo")
  }

  @MainActor @Test func ptySurfaceAppliesPendingKeyboardFocusWhenAttachedToWindow() throws {
    let registry = PTYTerminalSurfaceRegistry()
    let session = TerminalSessionID()
    registry.createSurface(session: session)
    registry.focusSessionView(session)

    let surfaceView = try #require(registry.viewForSession(session) as? PTYTerminalSurfaceView)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 420), styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = surfaceView

    #expect(window.firstResponder === surfaceView.scrollView.documentView || window.firstResponder === surfaceView.liveGridView)
  }

  @MainActor @Test func ptySurfaceRendersScrollableScrollbackDocument() throws {
    let registry = PTYTerminalSurfaceRegistry()
    registry.applyRendererOptions(TerminalRendererOptions(mode: .ghosttyVTTextFallback))
    let session = TerminalSessionID()
    registry.createSurface(session: session)
    let bridge = try GhosttyVTBridge(cols: 20, rows: 2, maxScrollback: 100)

    bridge.write(Data("hello".utf8))
    bridge.write(Data("\u{1B}D\u{1B}D\u{1B}D".utf8))
    registry.render(bridge, session: session)
    registry.flushPendingRenderers()

    let scrollView = try scrollView(in: #require(registry.viewForSession(session)))
    let textView = try #require(scrollView.documentView as? NSTextView)

    #expect(textView.string.contains("hello"))
    #expect(textView.isVerticallyResizable)
    #expect(textView.textContainer?.heightTracksTextView == false)
  }

  @MainActor @Test func ptySurfaceRendersAlternateScreenLiveViewportFromCellGrid() throws {
    let registry = PTYTerminalSurfaceRegistry()
    let session = TerminalSessionID()
    registry.createSurface(session: session)
    let bridge = try GhosttyVTBridge(cols: 8, rows: 2, maxScrollback: 100)

    bridge.write(Data("\u{1B}[?1049h".utf8))
    bridge.write(Data("x".utf8))
    registry.render(bridge, session: session)
    registry.flushPendingRenderers()

    let gridView = try gridView(in: #require(registry.viewForSession(session)))
    let firstLine = gridView.renderedText.components(separatedBy: "\n").first ?? ""

    #expect(firstLine.hasPrefix("x"))
    #expect((firstLine as NSString).length == 8)
  }

  @MainActor @Test func ptySurfacePinnedStateReflectsPostAltScreenExitWhenScrolledUp() throws {
    let registry = PTYTerminalSurfaceRegistry()
    let session = TerminalSessionID()
    registry.createSurface(session: session)
    let bridge = try GhosttyVTBridge(cols: 20, rows: 3, maxScrollback: 100)

    // Fill main screen scrollback with enough content to allow scrolling up.
    let history = (1...30).map { "line\($0)" }.joined(separator: "\r\n") + "\r\nprompt % "
    bridge.write(Data(history.utf8))
    registry.render(bridge, session: session)
    registry.flushPendingRenderers()

    // Simulate user scrolling up to read history (not pinned to bottom).
    bridge.scrollViewport(deltaRows: -10)
    guard let scrollbarBefore = try? bridge.scrollbar() else {
      Issue.record("scrollbar unavailable before alt screen")
      return
    }
    #expect(scrollbarBefore.offset + scrollbarBefore.length < scrollbarBefore.total,
            "viewport should NOT be at bottom after user scrolls up")

    // Enter alternate screen (alt screen has no scrollback, always "at bottom").
    bridge.write(Data("\u{1B}[?1049h".utf8))

    // Exit alt screen and append new content in a single write — the exact
    // pattern that triggered the scroll-freeze bug when wasPinnedToBottom
    // was captured before bridge.write(data).
    let exitAndOutput = "\u{1B}[?1049l\r\nnew-output-after-alt-exit"
    bridge.write(Data(exitAndOutput.utf8))

    // After the write, viewportIsPinnedToBottom must reflect the main screen
    // state (user was scrolled up → not pinned), NOT the alt screen's false
    // "always at bottom" state.
    guard let scrollbarAfter = try? bridge.scrollbar() else {
      Issue.record("scrollbar unavailable after alt screen exit")
      return
    }
    let isPinnedAfterExit = scrollbarAfter.offset + scrollbarAfter.length >= scrollbarAfter.total
    #expect(!isPinnedAfterExit,
            "wasPinnedToBottom should be false after exiting alt screen when user was scrolled up")
  }

  @MainActor @Test func liveCellGridUsesFixedGridViewInsteadOfTextKitDocument() throws {
    let registry = PTYTerminalSurfaceRegistry()
    let session = TerminalSessionID()
    registry.createSurface(session: session)
    let bridge = try GhosttyVTBridge(cols: 8, rows: 2, maxScrollback: 100)

    bridge.write(Data("\u{1B}[?1049h".utf8))
    bridge.write(Data("x".utf8))
    registry.render(bridge, session: session)
    registry.flushPendingRenderers()

    let surfaceView = try #require(registry.viewForSession(session) as? PTYTerminalSurfaceView)

    #expect(surfaceView.isShowingLiveGrid)
    #expect(surfaceView.liveGridView.renderedText.hasPrefix("x"))
    #expect(surfaceView.scrollView.isHidden)
    #expect(surfaceView.liveGridView.isHidden == false)
  }

  @MainActor @Test func autoRendererUsesDirectBackendForOrdinaryPromptFrames() throws {
    let registry = PTYTerminalSurfaceRegistry()
    let session = TerminalSessionID()
    registry.createSurface(session: session)
    let bridge = try GhosttyVTBridge(cols: 20, rows: 2, maxScrollback: 100)

    bridge.write(Data("prompt % ".utf8))
    registry.render(bridge, session: session)
    registry.flushPendingRenderers()

    let surfaceView = try #require(registry.viewForSession(session) as? PTYTerminalSurfaceView)
    let diagnostics = try #require(registry.rendererDiagnostics(for: session))

    #expect(surfaceView.isShowingLiveGrid)
    #expect(surfaceView.liveGridView is MetalDirectRendererView)
    #expect(surfaceView.liveGridView.renderedText.contains("prompt"))
    #expect(diagnostics.backend == .metalDirect)
    #expect(diagnostics.requestedBackend == nil)
  }

  @MainActor @Test func liveCellGridUserInputDoesNotPreRenderWhenAlreadyAtLiveBottom() throws {
    let registry = PTYTerminalSurfaceRegistry()
    let session = TerminalSessionID()
    registry.createSurface(session: session)
    let bridge = try codexLikeBridge(suggestions: [
      "/resume       resume a previous session",
      "/review       review current changes",
    ])

    registry.render(bridge, session: session)
    registry.flushPendingRenderers()

    let shouldRenderInputSnapshot = registry.prepareForUserInput(session: session)

    #expect(!shouldRenderInputSnapshot)
  }

  @MainActor @Test func liveCellGridOutputWhileDraggingSelectionDoesNotReplaceVisibleRows() throws {
    let registry = PTYTerminalSurfaceRegistry()
    let session = TerminalSessionID()
    registry.createSurface(session: session)
    let bridge = try GhosttyVTBridge(cols: 24, rows: 3, maxScrollback: 100)

    bridge.write(Data("first\r\nsecond\r\nthird".utf8))
    registry.render(bridge, session: session)
    registry.flushPendingRenderers()
    let surfaceView = try #require(registry.viewForSession(session) as? PTYTerminalSurfaceView)
    let originalText = surfaceView.liveGridView.renderedText
    let start = PTYGridView.textGlyphRect(
      row: 1,
      col: 1,
      cellSize: surfaceView.liveGridView.terminalCellSize,
      inset: surfaceView.liveGridView.terminalContentInset
    )

    surfaceView.liveGridView.mouseDown(with: try mouseEvent(.leftMouseDown, viewPoint: NSPoint(x: start.midX, y: start.midY), in: surfaceView.liveGridView))

    bridge.write(Data("\r\ncodex streaming update".utf8))
    let snapshot = ResizeRenderSnapshot.capture(from: bridge)
    registry.renderOutput(snapshot, bridge: bridge, session: session, wasPinnedToBottom: true)
    registry.flushPendingRenderers()

    #expect(surfaceView.liveGridView.renderedText == originalText)
  }

  @MainActor @Test func liveCellGridResizeWhilePinnedKeepsFinalLineAndPromptVisible() throws {
    let registry = PTYTerminalSurfaceRegistry()
    let session = TerminalSessionID()
    registry.createSurface(session: session)
    let bridge = try GhosttyVTBridge(cols: 28, rows: 5, maxScrollback: 500)

    let output = (1...200).map(String.init).joined(separator: "\r\n") + "\r\nzpc@host ~ % "
    bridge.write(Data(output.utf8))
    registry.render(bridge, session: session)
    registry.flushPendingRenderers()
    let surfaceView = try #require(registry.viewForSession(session) as? PTYTerminalSurfaceView)

    let wasPinned = try #require(registry.viewportIsPinnedToBottom(session) as Bool?)
    bridge.resize(cols: 28, rows: 7)
    registry.prepareForPinnedOutput(session: session, wasPinnedToBottom: wasPinned)
    registry.render(bridge, session: session)
    registry.flushPendingRenderers()

    #expect(surfaceView.liveGridView.renderedText.contains("200"))
    #expect(surfaceView.liveGridView.renderedText.contains("zpc@host ~ %"))
  }

  @MainActor @Test func rendererDiagnosticsReportBridgeSnapshotTimingsAndCellCount() throws {
    let registry = PTYTerminalSurfaceRegistry()
    registry.applyRendererOptions(TerminalRendererOptions(mode: .ghosttyVTCellGrid))
    let session = TerminalSessionID()
    registry.createSurface(session: session)
    let bridge = try GhosttyVTBridge(cols: 20, rows: 2, maxScrollback: 100)

    bridge.write(Data("first\r\nsecond\r\nthird\r\nfourth".utf8))
    registry.render(bridge, session: session)
    registry.flushPendingRenderers()

    let diagnostics = try #require(registry.rendererDiagnostics(for: session))
    #expect(diagnostics.bridgeFrameSnapshotDuration >= 0)
    #expect(diagnostics.bridgeScrollFrameSnapshotDuration >= 0)
    #expect(diagnostics.bridgeSnapshotCellCount >= 40)
    #expect(diagnostics.debugSummary.contains("bridgeFrameSnapshotMs="))
    #expect(diagnostics.debugSummary.contains("bridgeScrollFrameSnapshotMs="))
    #expect(diagnostics.debugSummary.contains("bridgeSnapshotCells="))
  }

  @MainActor @Test func surfaceRegistryExposesCellGridRendererDiagnostics() throws {
    let registry = PTYTerminalSurfaceRegistry()
    registry.applyRendererOptions(TerminalRendererOptions(mode: .ghosttyVTCellGrid))
    let session = TerminalSessionID()
    registry.createSurface(session: session)
    let bridge = try GhosttyVTBridge(cols: 20, rows: 2, maxScrollback: 100)

    bridge.write(Data("prompt % ".utf8))
    registry.render(bridge, session: session)
    registry.flushPendingRenderers()

    let diagnostics = try #require(registry.rendererDiagnostics(for: session))

    #expect(diagnostics.backend == .ghosttyVTCellGrid)
    #expect(diagnostics.visibleRowCount == 2)
  }

  @MainActor @Test func autoRendererFallsBackToCellGridWhenDirectMetalUnavailable() throws {
    let registry = PTYTerminalSurfaceRegistry(isMetalDirectAvailable: false)
    registry.applyRendererOptions(TerminalRendererOptions(mode: .auto))
    let session = TerminalSessionID()
    registry.createSurface(session: session)
    let bridge = try GhosttyVTBridge(cols: 12, rows: 2, maxScrollback: 100)

    bridge.write(Data("prompt".utf8))
    registry.render(bridge, session: session)
    registry.flushPendingRenderers()

    let surfaceView = try #require(registry.viewForSession(session) as? PTYTerminalSurfaceView)
    let diagnostics = try #require(registry.rendererDiagnostics(for: session))
    #expect(surfaceView.liveGridView is MetalDirectRendererView == false)
    #expect(diagnostics.backend == .ghosttyVTCellGrid)
  }

  @MainActor @Test func metalDirectRendererModeUsesDirectBackendWhenAvailable() throws {
    let registry = PTYTerminalSurfaceRegistry(isMetalDirectAvailable: true)
    registry.applyRendererOptions(TerminalRendererOptions(mode: .metalDirect))
    let session = TerminalSessionID()
    registry.createSurface(session: session)
    let bridge = try GhosttyVTBridge(cols: 12, rows: 2, maxScrollback: 100)

    bridge.write(Data("prompt".utf8))
    registry.render(bridge, session: session)
    registry.flushPendingRenderers()

    let surfaceView = try #require(registry.viewForSession(session) as? PTYTerminalSurfaceView)
    let diagnostics = try #require(registry.rendererDiagnostics(for: session))

    #expect(surfaceView.liveGridView is MetalDirectRendererView)
    #expect(diagnostics.backend == .metalDirect)
    #expect(diagnostics.requestedBackend == .metalDirect)
    #expect(diagnostics.backendFallbackReason == nil)
    #expect(diagnostics.usesBitmapCapture == false)
  }

  @MainActor @Test func metalDirectRendererModeFallsBackToCellGridWhenPipelineIsUnavailable() throws {
    let registry = PTYTerminalSurfaceRegistry(
      isMetalDirectAvailable: true,
      makeDirectRenderer: { _ in PipelineFailingDirectRendererBackend() }
    )
    registry.applyRendererOptions(TerminalRendererOptions(mode: .metalDirect))
    let session = TerminalSessionID()
    registry.createSurface(session: session)
    let bridge = try GhosttyVTBridge(cols: 12, rows: 2, maxScrollback: 100)

    bridge.write(Data("prompt".utf8))
    registry.render(bridge, session: session)
    registry.flushPendingRenderers()

    let diagnostics = try #require(registry.rendererDiagnostics(for: session))

    #expect(diagnostics.backend == .ghosttyVTCellGrid)
    #expect(diagnostics.requestedBackend == .metalDirect)
    #expect(diagnostics.backendFallbackReason == TerminalRendererDiagnostics.metalDirectUnavailableFallbackReason)
  }

  @MainActor @Test func metalDirectRendererFallsBackToCellGridWhenRenderFailsAtRuntime() throws {
    let registry = PTYTerminalSurfaceRegistry(
      isMetalDirectAvailable: true,
      makeDirectRenderer: { options in
        MetalDirectRendererBackend(options: options) { _ in
          RuntimeFailingMetalDirectRenderingEngine()
        }
      }
    )
    registry.applyRendererOptions(TerminalRendererOptions(mode: .metalDirect))
    let session = TerminalSessionID()
    registry.createSurface(session: session)
    let bridge = try GhosttyVTBridge(cols: 12, rows: 2, maxScrollback: 100)

    bridge.write(Data("prompt".utf8))
    registry.render(bridge, session: session)
    registry.flushPendingRenderers()

    let surfaceView = try #require(registry.viewForSession(session) as? PTYTerminalSurfaceView)
    let diagnostics = try #require(registry.rendererDiagnostics(for: session))

    #expect(surfaceView.liveGridView is MetalDirectRendererView == false)
    #expect(surfaceView.liveGridView.renderedText.contains("prompt"))
    #expect(diagnostics.backend == .ghosttyVTCellGrid)
    #expect(diagnostics.requestedBackend == .metalDirect)
    #expect(diagnostics.backendFallbackReason == TerminalRendererDiagnostics.metalDirectRenderFailedFallbackReason)
  }

  @MainActor @Test func ptySurfaceUsesBarCursorOverlayWithoutPaintingBlankCellBackground() throws {
    let registry = PTYTerminalSurfaceRegistry()
    let session = TerminalSessionID()
    registry.createSurface(session: session)
    let bridge = try GhosttyVTBridge(cols: 8, rows: 2, maxScrollback: 100)

    bridge.write(Data("\u{1B}[6 q".utf8))
    registry.render(bridge, session: session)
    registry.flushPendingRenderers()

    let surfaceView = try #require(registry.viewForSession(session) as? PTYTerminalSurfaceView)

    #expect(surfaceView.isShowingLiveGrid)
    #expect(surfaceView.liveGridView.cursorCellRect != nil)
    #expect(surfaceView.liveGridView.renderedText.hasPrefix(" "))
  }

  @MainActor @Test func textFallbackSurfaceDimsInactiveSessionText() throws {
    let registry = PTYTerminalSurfaceRegistry()
    registry.applyRendererOptions(TerminalRendererOptions(mode: .ghosttyVTTextFallback))
    let activeSession = TerminalSessionID()
    let inactiveSession = TerminalSessionID()
    registry.createSurface(session: activeSession)
    registry.createSurface(session: inactiveSession)

    let activeBridge = try GhosttyVTBridge(cols: 20, rows: 2, maxScrollback: 100)
    let inactiveBridge = try GhosttyVTBridge(cols: 20, rows: 2, maxScrollback: 100)
    activeBridge.write(Data("active".utf8))
    inactiveBridge.write(Data("inactive".utf8))
    registry.render(activeBridge, session: activeSession)
    registry.flushPendingRenderers()
    registry.render(inactiveBridge, session: inactiveSession)
    registry.flushPendingRenderers()

    registry.setFocusedSession(activeSession)

    let activeTextView = try textView(in: #require(registry.viewForSession(activeSession)))
    let inactiveTextView = try textView(in: #require(registry.viewForSession(inactiveSession)))
    let activeColor = try #require(activeTextView.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
    let inactiveColor = try #require(inactiveTextView.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)

    #expect(inactiveColor.lightness < activeColor.lightness)
  }

  @MainActor @Test func metalDirectFocusChangeRepaintsImmediately() throws {
    let registry = PTYTerminalSurfaceRegistry()
    registry.applyRendererOptions(TerminalRendererOptions(mode: .metalDirect))
    let activeSession = TerminalSessionID()
    let inactiveSession = TerminalSessionID()
    registry.createSurface(session: activeSession)
    registry.createSurface(session: inactiveSession)

    let activeBridge = try GhosttyVTBridge(cols: 20, rows: 2, maxScrollback: 100)
    let inactiveBridge = try GhosttyVTBridge(cols: 20, rows: 2, maxScrollback: 100)
    activeBridge.write(Data("active".utf8))
    inactiveBridge.write(Data("inactive".utf8))
    registry.render(activeBridge, session: activeSession)
    registry.render(inactiveBridge, session: inactiveSession)
    registry.flushPendingRenderers()

    registry.setFocusedSession(activeSession)

    let inactiveDiagnostics = try #require(registry.rendererDiagnostics(for: inactiveSession))
    #expect(inactiveDiagnostics.backend == .metalDirect)
    #expect(inactiveDiagnostics.redrawMode == .full)
    #expect(inactiveDiagnostics.metalDirect.drawnRowCount == 2)
  }

  @MainActor @Test func textFallbackSurfacePreservesFaintSuggestionStyle() throws {
    let registry = PTYTerminalSurfaceRegistry()
    registry.applyRendererOptions(TerminalRendererOptions(mode: .ghosttyVTTextFallback))
    let session = TerminalSessionID()
    registry.createSurface(session: session)
    let bridge = try GhosttyVTBridge(cols: 40, rows: 2, maxScrollback: 100)

    bridge.write(Data("typed \u{1B}[2msuggestion\u{1B}[0m".utf8))
    registry.render(bridge, session: session)
    registry.flushPendingRenderers()

    let textView = try textView(in: #require(registry.viewForSession(session)))
    let text = textView.string as NSString
    let normalIndex = text.range(of: "typed").location
    let suggestionIndex = text.range(of: "suggestion").location
    let normalColor = try #require(textView.textStorage?.attribute(.foregroundColor, at: normalIndex, effectiveRange: nil) as? NSColor)
    let suggestionColor = try #require(textView.textStorage?.attribute(.foregroundColor, at: suggestionIndex, effectiveRange: nil) as? NSColor)

    #expect(suggestionColor.lightness < normalColor.lightness)
  }

  @MainActor @Test func textFallbackSurfacePreservesPaletteSuggestionStyle() throws {
    let registry = PTYTerminalSurfaceRegistry()
    registry.applyRendererOptions(TerminalRendererOptions(mode: .ghosttyVTTextFallback))
    let session = TerminalSessionID()
    registry.createSurface(session: session)
    let bridge = try GhosttyVTBridge(cols: 40, rows: 2, maxScrollback: 100)

    bridge.write(Data("typed \u{1B}[38;5;8msuggestion\u{1B}[0m".utf8))
    registry.render(bridge, session: session)
    registry.flushPendingRenderers()

    let textView = try textView(in: #require(registry.viewForSession(session)))
    let text = textView.string as NSString
    let normalIndex = text.range(of: "typed").location
    let suggestionIndex = text.range(of: "suggestion").location
    let normalColor = try #require(textView.textStorage?.attribute(.foregroundColor, at: normalIndex, effectiveRange: nil) as? NSColor)
    let suggestionColor = try #require(textView.textStorage?.attribute(.foregroundColor, at: suggestionIndex, effectiveRange: nil) as? NSColor)

    #expect(suggestionColor.lightness < normalColor.lightness)
  }

  @MainActor @Test func textFallbackSurfaceShowsCursorFromGhosttyFrame() throws {
    let registry = PTYTerminalSurfaceRegistry()
    registry.applyRendererOptions(TerminalRendererOptions(mode: .ghosttyVTTextFallback))
    let session = TerminalSessionID()
    registry.createSurface(session: session)
    let bridge = try GhosttyVTBridge(cols: 40, rows: 2, maxScrollback: 100)

    bridge.write(Data("prompt % ".utf8))
    registry.render(bridge, session: session)
    registry.flushPendingRenderers()

    let textView = try textView(in: #require(registry.viewForSession(session)))
    let cursorIndex = (textView.string as NSString).length - 1
    let cursorShape = textView.textStorage?.attribute(.proGhosttyCursorShape, at: cursorIndex, effectiveRange: nil) as? TerminalCursorShape
    let cursorBackground = textView.textStorage?.attribute(.backgroundColor, at: cursorIndex, effectiveRange: nil) as? NSColor

    #expect((textView.string as NSString).substring(with: NSRange(location: cursorIndex, length: 1)) == " ")
    #expect(cursorShape == .block)
    #expect(cursorBackground?.sameRGB(as: TerminalSurfacePalette.dark.cursorBackground) != true)
  }

  @MainActor @Test func textFallbackSurfaceShowsCursorAtBlankLineEnd() throws {
    let registry = PTYTerminalSurfaceRegistry()
    registry.applyRendererOptions(TerminalRendererOptions(mode: .ghosttyVTTextFallback))
    let session = TerminalSessionID()
    registry.createSurface(session: session)
    let bridge = try GhosttyVTBridge(cols: 40, rows: 2, maxScrollback: 100)

    bridge.write(Data("prompt % \r\n".utf8))
    registry.render(bridge, session: session)
    registry.flushPendingRenderers()

    let textView = try textView(in: #require(registry.viewForSession(session)))
    let text = textView.string as NSString
    let cursorIndex = text.length - 1
    let cursorShape = textView.textStorage?.attribute(.proGhosttyCursorShape, at: cursorIndex, effectiveRange: nil) as? TerminalCursorShape
    let cursorBackground = textView.textStorage?.attribute(.backgroundColor, at: cursorIndex, effectiveRange: nil) as? NSColor

    #expect(text.substring(with: NSRange(location: cursorIndex, length: 1)) == " ")
    #expect(cursorShape == .block)
    #expect(cursorBackground?.sameRGB(as: TerminalSurfacePalette.dark.cursorBackground) != true)
  }

  @MainActor @Test func textFallbackSurfaceKeepsCursorOnTrimmedViewportBlankLine() throws {
    let registry = PTYTerminalSurfaceRegistry()
    registry.applyRendererOptions(TerminalRendererOptions(mode: .ghosttyVTTextFallback))
    let session = TerminalSessionID()
    registry.createSurface(session: session)
    let bridge = try GhosttyVTBridge(cols: 40, rows: 4, maxScrollback: 100)

    bridge.write(Data("first\r\nsecond\r\n".utf8))
    registry.render(bridge, session: session)
    registry.flushPendingRenderers()

    let textView = try textView(in: #require(registry.viewForSession(session)))
    let text = textView.string as NSString
    let cursorIndex = text.length - 1
    let cursorShape = textView.textStorage?.attribute(.proGhosttyCursorShape, at: cursorIndex, effectiveRange: nil) as? TerminalCursorShape

    #expect(text.range(of: "second\n ").location != NSNotFound)
    #expect(text.substring(with: NSRange(location: cursorIndex, length: 1)) == " ")
    #expect(cursorShape == .block)
  }

  @MainActor @Test func textFallbackSurfaceKeepsCursorOnTrimmedBlankLineAfterHistory() throws {
    let registry = PTYTerminalSurfaceRegistry()
    registry.applyRendererOptions(TerminalRendererOptions(mode: .ghosttyVTTextFallback))
    let session = TerminalSessionID()
    registry.createSurface(session: session)
    let bridge = try GhosttyVTBridge(cols: 40, rows: 4, maxScrollback: 100)

    bridge.write(Data("one\r\ntwo\r\nthree\r\nfour\r\nfive\r\nsix\r\n".utf8))
    registry.render(bridge, session: session)
    registry.flushPendingRenderers()

    let textView = try textView(in: #require(registry.viewForSession(session)))
    let text = textView.string as NSString
    let cursorIndex = text.length - 1
    let cursorShape = textView.textStorage?.attribute(.proGhosttyCursorShape, at: cursorIndex, effectiveRange: nil) as? TerminalCursorShape

    #expect(text.range(of: "six\n ").location != NSNotFound)
    #expect(text.substring(with: NSRange(location: cursorIndex, length: 1)) == " ")
    #expect(cursorShape == .block)
  }

  @MainActor @Test func textFallbackSurfaceKeepsCursorOnLatestPromptAfterScrollback() throws {
    let registry = PTYTerminalSurfaceRegistry()
    registry.applyRendererOptions(TerminalRendererOptions(mode: .ghosttyVTTextFallback))
    let session = TerminalSessionID()
    registry.createSurface(session: session)
    let bridge = try GhosttyVTBridge(cols: 40, rows: 2, maxScrollback: 100)

    bridge.write(Data("first\r\nsecond\r\nlatest % ".utf8))
    registry.render(bridge, session: session)
    registry.flushPendingRenderers()

    let textView = try textView(in: #require(registry.viewForSession(session)))
    let text = textView.string as NSString
    let latestPrompt = text.range(of: "latest %")
    let cursorIndex = text.length - 1
    let cursorShape = textView.textStorage?.attribute(.proGhosttyCursorShape, at: cursorIndex, effectiveRange: nil) as? TerminalCursorShape

    #expect(latestPrompt.location != NSNotFound)
    #expect(cursorIndex > latestPrompt.location)
    #expect(text.substring(with: NSRange(location: cursorIndex, length: 1)) == " ")
    #expect(cursorShape == .block)
  }

  @MainActor @Test func liveScreenRenderKeepsCursorVisuallyAnchoredWhenSuggestionsResize() throws {
    let registry = PTYTerminalSurfaceRegistry()
    let session = TerminalSessionID()
    registry.createSurface(session: session)
    let surfaceView = try #require(registry.viewForSession(session) as? PTYTerminalSurfaceView)
    surfaceView.frame = NSRect(x: 0, y: 0, width: 720, height: 170)

    let expandedSuggestions = try codexLikeBridge(suggestions: [
      "/model        choose what model and reasoning effort to use",
      "/fast         toggle Fast mode",
      "/ide          include current selection",
      "/permissions  choose what Codex is allowed to do",
    ])
    registry.render(expandedSuggestions, session: session)
    registry.flushPendingRenderers()
    let expandedCursorY = try #require(surfaceView.liveGridView.cursorCellRect?.minY)
    let expandedLineCount = surfaceView.liveGridView.renderedText.components(separatedBy: "\n").count

    let collapsedSuggestions = try codexLikeBridge(suggestions: [
      "/model        choose what model and reasoning effort to use",
    ])
    registry.render(collapsedSuggestions, session: session)
    registry.flushPendingRenderers()
    let collapsedCursorY = try #require(surfaceView.liveGridView.cursorCellRect?.minY)
    let collapsedLineCount = surfaceView.liveGridView.renderedText.components(separatedBy: "\n").count

    #expect(abs(expandedCursorY - collapsedCursorY) < 0.5)
    #expect(expandedLineCount == 12)
    #expect(collapsedLineCount == 12)
  }

  @MainActor @Test func liveScreenRenderDoesNotBounceToHtmlWhenSuggestionsTemporarilyDisappear() throws {
    let registry = PTYTerminalSurfaceRegistry()
    let session = TerminalSessionID()
    registry.createSurface(session: session)

    registry.render(try codexLikeBridge(suggestions: [
      "/model        choose what model and reasoning effort to use",
      "/permissions  choose what Codex is allowed to do",
    ]), session: session)
    registry.flushPendingRenderers()
    registry.render(try codexLikeBridge(suggestions: []), session: session)
    registry.flushPendingRenderers()

    let gridView = try gridView(in: #require(registry.viewForSession(session)))

    #expect(gridView.renderedText.components(separatedBy: "\n").count == 12)
  }

  @MainActor @Test func liveCellGridStaysMountedAcrossCodexLikeRefreshes() throws {
    let registry = PTYTerminalSurfaceRegistry()
    let session = TerminalSessionID()
    registry.createSurface(session: session)
    let surfaceView = try #require(registry.viewForSession(session) as? PTYTerminalSurfaceView)

    registry.render(try codexLikeBridge(suggestions: [
      "/model        choose what model and reasoning effort to use",
      "/permissions  choose what Codex is allowed to do",
    ]), session: session)
    registry.flushPendingRenderers()
    let mountedGridView = surfaceView.liveGridView

    registry.render(try codexLikeBridge(suggestions: [
      "/resume       resume a previous session",
      "/review       review current changes",
    ]), session: session)
    registry.flushPendingRenderers()

    #expect(surfaceView.isShowingLiveGrid)
    #expect(surfaceView.liveGridView === mountedGridView)
  }

  @MainActor @Test func liveCellGridStaysActiveAcrossRepeatedCodexLikeAnsiRefreshes() throws {
    let registry = PTYTerminalSurfaceRegistry()
    registry.applyRendererOptions(TerminalRendererOptions(mode: .ghosttyVTCellGrid))
    let session = TerminalSessionID()
    registry.createSurface(session: session)
    let bridge = try GhosttyVTBridge(cols: 96, rows: 12, maxScrollback: 200)

    bridge.write(Data((1...12).map { "history \($0)" }.joined(separator: "\r\n").utf8))
    for query in ["", "r", "re", "res", "resu"] {
      let suggestions = [
        "/resume       resume a previous session",
        "/review       review current changes",
        "/reset        reset conversation state",
      ].filter { query.isEmpty || $0.contains(query) }
      bridge.write(Data("\u{1B}[10;1H> /\(query)\u{1B}[11;1H\u{1B}[J\(suggestions.joined(separator: "\r\n"))\u{1B}[10;\(4 + query.count)H".utf8))
      registry.render(bridge, session: session)
      registry.flushPendingRenderers()

      let surfaceView = try #require(registry.viewForSession(session) as? PTYTerminalSurfaceView)
      #expect(surfaceView.isShowingLiveGrid)
      #expect(registry.rendererDiagnostics(for: session)?.backend == .ghosttyVTCellGrid)
      #expect(surfaceView.liveGridView.renderedText.components(separatedBy: "\n").count == 12)
    }
  }

  @MainActor @Test func liveCellGridCoalescesTransientCodexCursorMovesBeforePresentingOutput() async throws {
    let registry = PTYTerminalSurfaceRegistry()
    registry.applyRendererOptions(TerminalRendererOptions(mode: .ghosttyVTCellGrid))
    let session = TerminalSessionID()
    registry.createSurface(session: session)
    let bridge = try codexLikeBridge(suggestions: [
      "/resume       resume a previous session",
      "/review       review current changes",
    ])
    registry.render(bridge, session: session)
    registry.flushPendingRenderers()
    let surfaceView = try #require(registry.viewForSession(session) as? PTYTerminalSurfaceView)
    let initialCursor = try #require(surfaceView.liveGridView.cursorCellRect)

    bridge.write(Data("\u{1B}[8;1H".utf8))
    let transientSnapshot = ResizeRenderSnapshot.capture(from: bridge)
    registry.renderOutput(transientSnapshot, bridge: bridge, session: session, wasPinnedToBottom: true)

    #expect(surfaceView.liveGridView.cursorCellRect == initialCursor)

    bridge.write(Data("\u{1B}[10;1H> /r\u{1B}[11;1H\u{1B}[J/resume       resume a previous session\u{1B}[10;5H".utf8))
    let finalSnapshot = ResizeRenderSnapshot.capture(from: bridge)
    registry.renderOutput(finalSnapshot, bridge: bridge, session: session, wasPinnedToBottom: true)
    registry.flushPendingRenderers()

    #expect(surfaceView.liveGridView.cursorCellRect == PTYGridView.textGlyphRect(
      row: 9,
      col: 4,
      cellSize: surfaceView.liveGridView.terminalCellSize,
      inset: surfaceView.liveGridView.terminalContentInset
    ))
  }

  @MainActor @Test func liveGridInfersPromptCursorWhenCodexTransientCursorMovesToPromptLineStart() throws {
    let registry = PTYTerminalSurfaceRegistry()
    registry.applyRendererOptions(TerminalRendererOptions(mode: .ghosttyVTCellGrid))
    let session = TerminalSessionID()
    registry.createSurface(session: session)
    let bridge = try codexLikeBridge(suggestions: [
      "/resume       resume a previous session",
      "/review       review current changes",
    ])
    registry.render(bridge, session: session)
    registry.flushPendingRenderers()
    let surfaceView = try #require(registry.viewForSession(session) as? PTYTerminalSurfaceView)
    let initialCursor = try #require(surfaceView.liveGridView.cursorCellRect)

    bridge.write(Data("\u{1B}[10;1H".utf8))
    registry.render(bridge, session: session)
    registry.flushPendingRenderers()

    #expect(surfaceView.liveGridView.cursorCellRect == initialCursor)
  }

  @MainActor @Test func liveGridPreservesPromptCursorWhenCodexTransientCursorMovesToBlankRowStart() throws {
    let gridView = PTYGridView()
    let rows = [
      "",
      "",
      "",
      "",
      "",
      "",
      "",
      "",
      "",
      "",
      "› /res",
      "",
    ]
    let cellSize = gridView.terminalCellSize
    let inset = gridView.terminalContentInset
    gridView.frame = NSRect(
      x: 0,
      y: 0,
      width: inset.width * 2 + CGFloat(43) * cellSize.width,
      height: inset.height * 2 + CGFloat(rows.count) * cellSize.height
    )
    let initialFrame = frameWithText(rows: rows, cols: 43, cursorX: 6, cursorY: 10)
    let initialScrollFrame = GhosttyTerminalScrollFrame(
      viewport: initialFrame,
      overscanTop: [
        cellRow(text: "history 1", cols: initialFrame.cols),
        cellRow(text: "history 2", cols: initialFrame.cols),
      ],
      overscanBottom: [],
      requestedOverscanTop: 2,
      requestedOverscanBottom: 0,
      viewportStartRow: 12
    )
    gridView.render(initialScrollFrame, isFocused: true, dirty: CellGridDirtyResult(mode: .full, rows: Set(0..<rows.count)))
    let stableCursor = try #require(gridView.cursorCellRect)

    let transientFrame = frameWithText(rows: rows, cols: 43, cursorX: 0, cursorY: 8)
    let transientScrollFrame = GhosttyTerminalScrollFrame(
      viewport: transientFrame,
      overscanTop: initialScrollFrame.overscanTop,
      overscanBottom: [],
      requestedOverscanTop: 2,
      requestedOverscanBottom: 0,
      viewportStartRow: 12
    )
    gridView.render(transientScrollFrame, isFocused: true, dirty: CellGridDirtyResult(mode: .full, rows: Set(0..<rows.count)))

    #expect(gridView.cursorCellRect == stableCursor)
  }

  @MainActor @Test func liveGridPreservesPromptCursorWhenCodexTransientCursorMovesToStyledBlankRowStart() throws {
    let gridView = PTYGridView()
    let rows = [
      "",
      "",
      "",
      "",
      "",
      "",
      "",
      "",
      "",
      "",
      "› /res",
      "",
    ]
    let cellSize = gridView.terminalCellSize
    let inset = gridView.terminalContentInset
    gridView.frame = NSRect(
      x: 0,
      y: 0,
      width: inset.width * 2 + CGFloat(43) * cellSize.width,
      height: inset.height * 2 + CGFloat(rows.count) * cellSize.height
    )
    let initialFrame = frameWithText(rows: rows, cols: 43, cursorX: 6, cursorY: 10)
    let initialScrollFrame = GhosttyTerminalScrollFrame(
      viewport: initialFrame,
      overscanTop: [
        cellRow(text: "history 1", cols: initialFrame.cols),
        cellRow(text: "history 2", cols: initialFrame.cols),
      ],
      overscanBottom: [],
      requestedOverscanTop: 2,
      requestedOverscanBottom: 0,
      viewportStartRow: 12
    )
    gridView.render(initialScrollFrame, isFocused: true, dirty: CellGridDirtyResult(mode: .full, rows: Set(0..<rows.count)))
    let stableCursor = try #require(gridView.cursorCellRect)

    var transientFrame = frameWithText(rows: rows, cols: 43, cursorX: 0, cursorY: 8)
    for index in (8 * transientFrame.cols)..<((8 + 1) * transientFrame.cols) {
      transientFrame.cells[index].usesDefaultBackground = false
      transientFrame.cells[index].background = GhosttyTerminalFrame.RGB(r: 8, g: 24, b: 40)
    }
    let transientScrollFrame = GhosttyTerminalScrollFrame(
      viewport: transientFrame,
      overscanTop: initialScrollFrame.overscanTop,
      overscanBottom: [],
      requestedOverscanTop: 2,
      requestedOverscanBottom: 0,
      viewportStartRow: 12
    )
    gridView.render(transientScrollFrame, isFocused: true, dirty: CellGridDirtyResult(mode: .full, rows: Set(0..<rows.count)))

    #expect(gridView.cursorCellRect == stableCursor)
  }

  @MainActor @Test func liveGridPreservesPromptCursorWhenCodexTransientFrameErasesPromptRow() throws {
    let gridView = PTYGridView()
    let stableRows = [
      "",
      "",
      "",
      "",
      "",
      "",
      "",
      "",
      "",
      "",
      "› /res",
      "",
    ]
    let transientRows = Array(repeating: "", count: stableRows.count)
    let cellSize = gridView.terminalCellSize
    let inset = gridView.terminalContentInset
    gridView.frame = NSRect(
      x: 0,
      y: 0,
      width: inset.width * 2 + CGFloat(43) * cellSize.width,
      height: inset.height * 2 + CGFloat(stableRows.count) * cellSize.height
    )
    let initialFrame = frameWithText(rows: stableRows, cols: 43, cursorX: 6, cursorY: 10)
    let initialScrollFrame = GhosttyTerminalScrollFrame(
      viewport: initialFrame,
      overscanTop: [
        cellRow(text: "history 1", cols: initialFrame.cols),
        cellRow(text: "history 2", cols: initialFrame.cols),
      ],
      overscanBottom: [],
      requestedOverscanTop: 2,
      requestedOverscanBottom: 0,
      viewportStartRow: 12
    )
    gridView.render(initialScrollFrame, isFocused: true, dirty: CellGridDirtyResult(mode: .full, rows: Set(0..<stableRows.count)))
    let stableCursor = try #require(gridView.cursorCellRect)

    let transientFrame = frameWithText(rows: transientRows, cols: 43, cursorX: 0, cursorY: 8)
    let transientScrollFrame = GhosttyTerminalScrollFrame(
      viewport: transientFrame,
      overscanTop: initialScrollFrame.overscanTop,
      overscanBottom: [],
      requestedOverscanTop: 2,
      requestedOverscanBottom: 0,
      viewportStartRow: 12
    )
    gridView.render(transientScrollFrame, isFocused: true, dirty: CellGridDirtyResult(mode: .full, rows: Set(0..<stableRows.count)))

    #expect(gridView.cursorCellRect == stableCursor)
  }

  @MainActor @Test func liveGridPreservesContinuationCursorWhenCodexTransientMovesToBlankRowStart() throws {
    let gridView = PTYGridView()
    let stableRows = [
      "",
      "",
      "",
      "",
      "",
      "",
      "",
      "",
      "",
      "",
      "› long input fills the first prompt line",
      "  continuation text near wrap edge",
    ]
    let transientRows = Array(repeating: "", count: stableRows.count)
    let cellSize = gridView.terminalCellSize
    let inset = gridView.terminalContentInset
    gridView.frame = NSRect(
      x: 0,
      y: 0,
      width: inset.width * 2 + CGFloat(43) * cellSize.width,
      height: inset.height * 2 + CGFloat(stableRows.count) * cellSize.height
    )
    let initialFrame = frameWithText(rows: stableRows, cols: 43, cursorX: 35, cursorY: 11)
    let initialScrollFrame = GhosttyTerminalScrollFrame(
      viewport: initialFrame,
      overscanTop: [
        cellRow(text: "history 1", cols: initialFrame.cols),
        cellRow(text: "history 2", cols: initialFrame.cols),
      ],
      overscanBottom: [],
      requestedOverscanTop: 2,
      requestedOverscanBottom: 0,
      viewportStartRow: 12
    )
    gridView.render(initialScrollFrame, isFocused: true, dirty: CellGridDirtyResult(mode: .full, rows: Set(0..<stableRows.count)))
    let stableCursor = try #require(gridView.cursorCellRect)

    let transientFrame = frameWithText(rows: transientRows, cols: 43, cursorX: 0, cursorY: 8)
    let transientScrollFrame = GhosttyTerminalScrollFrame(
      viewport: transientFrame,
      overscanTop: initialScrollFrame.overscanTop,
      overscanBottom: [],
      requestedOverscanTop: 2,
      requestedOverscanBottom: 0,
      viewportStartRow: 12
    )
    gridView.render(transientScrollFrame, isFocused: true, dirty: CellGridDirtyResult(mode: .full, rows: Set(0..<stableRows.count)))

    #expect(gridView.cursorCellRect == stableCursor)
  }

  @MainActor @Test func terminalOutputCoordinatorKeepsLatestSnapshotDuringCoalescingWindow() async throws {
    let session = TerminalSessionID()
    let bridge = try GhosttyVTBridge(cols: 12, rows: 2, maxScrollback: 100)
    var deliveredCursorPositions: [GridCoordinate] = []
    let coordinator = TerminalOutputCoordinator(coalescingDelayNanoseconds: 8_000_000) { snapshot, _, _, _ in
      if let frame = snapshot.frame {
        deliveredCursorPositions.append(GridCoordinate(row: frame.cursorY, col: frame.cursorX))
      }
    }

    bridge.write(Data("one".utf8))
    let firstSnapshot = ResizeRenderSnapshot.capture(from: bridge)
    bridge.write(Data("\r\nabc".utf8))
    let secondSnapshot = ResizeRenderSnapshot.capture(from: bridge)

    coordinator.scheduleRender(
      snapshot: firstSnapshot,
      bridge: bridge,
      session: session,
      wasPinnedToBottom: true
    )
    coordinator.scheduleRender(
      snapshot: secondSnapshot,
      bridge: bridge,
      session: session,
      wasPinnedToBottom: true
    )

    coordinator.flush(session: session)

    #expect(deliveredCursorPositions == [GridCoordinate(row: 1, col: 3)])
  }

  @MainActor @Test func terminalOutputCoordinatorDeliversInteractiveOutputImmediately() async throws {
    let session = TerminalSessionID()
    let bridge = try GhosttyVTBridge(cols: 12, rows: 2, maxScrollback: 100)
    var deliveredCursorPositions: [GridCoordinate] = []
    let coordinator = TerminalOutputCoordinator(coalescingDelayNanoseconds: 50_000_000) { snapshot, _, _, _ in
      if let frame = snapshot.frame {
        deliveredCursorPositions.append(GridCoordinate(row: frame.cursorY, col: frame.cursorX))
      }
    }

    bridge.write(Data("one".utf8))
    let firstSnapshot = ResizeRenderSnapshot.capture(from: bridge)
    bridge.write(Data("x".utf8))
    let interactiveSnapshot = ResizeRenderSnapshot.capture(from: bridge)

    coordinator.scheduleRender(
      snapshot: firstSnapshot,
      bridge: bridge,
      session: session,
      wasPinnedToBottom: true
    )
    coordinator.scheduleRender(
      snapshot: interactiveSnapshot,
      bridge: bridge,
      session: session,
      wasPinnedToBottom: true,
      delivery: .immediate
    )

    #expect(deliveredCursorPositions == [GridCoordinate(row: 0, col: 4)])

    try await Task.sleep(nanoseconds: 70_000_000)

    #expect(deliveredCursorPositions == [GridCoordinate(row: 0, col: 4)])
  }

  @MainActor @Test func terminalOutputBatchCoordinatorCombinesBulkOutputIntoOneRender() async throws {
    let session = TerminalSessionID()
    var delivered: [String] = []
    let coordinator = TerminalOutputBatchCoordinator(coalescingDelayNanoseconds: 50_000_000) { data, _, _ in
      delivered.append(String(decoding: data, as: UTF8.self))
    }

    coordinator.receive(Data("one".utf8), session: session, delivery: .coalesced)
    coordinator.receive(Data("two".utf8), session: session, delivery: .coalesced)
    coordinator.flush(session: session)

    #expect(delivered == ["onetwo"])
  }

  @MainActor @Test func terminalOutputBatchCoordinatorFlushesBulkBeforeInteractiveOutput() async throws {
    let session = TerminalSessionID()
    var delivered: [(text: String, immediate: Bool)] = []
    let coordinator = TerminalOutputBatchCoordinator(coalescingDelayNanoseconds: 50_000_000) { data, _, delivery in
      delivered.append((String(decoding: data, as: UTF8.self), delivery == .immediate))
    }

    coordinator.receive(Data("bulk".utf8), session: session, delivery: .coalesced)
    coordinator.receive(Data("x".utf8), session: session, delivery: .immediate)

    try await Task.sleep(nanoseconds: 70_000_000)

    #expect(delivered.map(\.text) == ["bulk", "x"])
    #expect(delivered.map(\.immediate) == [false, true])
  }

  @Test func ptySessionManagerTreatsRecentSmallOutputAsInteractiveEcho() {
    #expect(PTYTerminalSessionManager.isInteractiveEchoOutput(
      Data("a".utf8),
      secondsSinceLastInput: 0.01
    ))
    #expect(PTYTerminalSessionManager.isInteractiveEchoOutput(
      Data("中文".utf8),
      secondsSinceLastInput: 0.01
    ))
    #expect(PTYTerminalSessionManager.isInteractiveEchoOutput(
      Data("\u{1B}[?2004h% 中文".utf8),
      secondsSinceLastInput: 0.12
    ))
  }

  @Test func ptySessionManagerDoesNotTreatStaleOrLargeOutputAsInteractiveEcho() {
    #expect(!PTYTerminalSessionManager.isInteractiveEchoOutput(
      Data("a".utf8),
      secondsSinceLastInput: 0.20
    ))
    #expect(!PTYTerminalSessionManager.isInteractiveEchoOutput(
      Data(repeating: 65, count: 128),
      secondsSinceLastInput: 0.01
    ))
    #expect(!PTYTerminalSessionManager.isInteractiveEchoOutput(
      Data(repeating: 65, count: 384),
      secondsSinceLastInput: 0.01
    ))
  }

  @Test func scrollAnchorPreservesCursorScreenPositionWhenLiveDocumentHeightChanges() {
    let origin = TerminalScrollAnchor.replacementOrigin(
      previousOriginY: 100,
      previousCursorDocumentMinY: 220,
      nextCursorDocumentMinY: 180,
      maxOriginY: 300
    )

    #expect(origin == 60)
  }

  @Test func attributedDiffScopesEqualLengthLiveGridUpdatesToChangedRuns() {
    let old = NSAttributedString(string: "abc\ndef", attributes: [.foregroundColor: NSColor.white])
    let new = NSAttributedString(string: "abc\ndex", attributes: [.foregroundColor: NSColor.white])

    let ranges = TerminalAttributedDiff.changedRanges(from: old, to: new)

    #expect(ranges == [NSRange(location: 6, length: 1)])
  }

  @Test func attributedDiffFallsBackToWholeDocumentWhenLengthChanges() {
    let old = NSAttributedString(string: "abc")
    let new = NSAttributedString(string: "abcd")

    let ranges = TerminalAttributedDiff.changedRanges(from: old, to: new)

    #expect(ranges == [NSRange(location: 0, length: 4)])
  }

  @MainActor @Test func liveGridDirtyRectsScopeCodexLikeUpdatesToDirtyRowsAndCursorRows() {
    let old = frameWithText(rows: [
      "> /",
      "/model",
      "/permissions",
    ], cols: 16, cursorX: 3, cursorY: 0)
    let new = frameWithText(rows: [
      "> /r",
      "/resume",
      "/review",
    ], cols: 16, cursorX: 4, cursorY: 0)

    let rects = PTYGridView.dirtyRects(
      from: old,
      to: new,
      cellSize: CGSize(width: 8, height: 16),
      inset: CGSize(width: 14, height: 12)
    )

    #expect(rects == [
      NSRect(x: 14, y: 12, width: 16 * 8, height: 16),
      NSRect(x: 14, y: 12 + 16, width: 16 * 8, height: 16),
      NSRect(x: 14, y: 12 + 2 * 16, width: 16 * 8, height: 16),
    ])
  }

  @MainActor @Test func textFallbackSurfaceDoesNotShowStrongCursorWhenUnfocused() throws {
    let registry = PTYTerminalSurfaceRegistry()
    registry.applyRendererOptions(TerminalRendererOptions(mode: .ghosttyVTTextFallback))
    let activeSession = TerminalSessionID()
    let inactiveSession = TerminalSessionID()
    registry.createSurface(session: activeSession)
    registry.createSurface(session: inactiveSession)
    let activeBridge = try GhosttyVTBridge(cols: 40, rows: 2, maxScrollback: 100)
    let inactiveBridge = try GhosttyVTBridge(cols: 40, rows: 2, maxScrollback: 100)

    activeBridge.write(Data("active % ".utf8))
    inactiveBridge.write(Data("inactive % ".utf8))
    registry.render(activeBridge, session: activeSession)
    registry.flushPendingRenderers()
    registry.render(inactiveBridge, session: inactiveSession)
    registry.flushPendingRenderers()
    registry.setFocusedSession(activeSession)

    let inactiveTextView = try textView(in: #require(registry.viewForSession(inactiveSession)))
    let text = inactiveTextView.string as NSString
    let cursorIndex = text.length - 1

    #expect(text.substring(with: NSRange(location: cursorIndex, length: 1)) == " ")
    #expect(inactiveTextView.textStorage?.attribute(.proGhosttyCursorShape, at: cursorIndex, effectiveRange: nil) == nil)
  }

  @MainActor @Test func ptyTextSelectionHitTestingIgnoresBlankTerminalBackground() throws {
    let textView = PTYTextView()
    textView.frame = NSRect(x: 0, y: 0, width: 320, height: 180)
    textView.textContainerInset = NSSize(width: 14, height: 12)
    textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    textView.string = "abc\n\nz"

    let layoutManager = try #require(textView.layoutManager)
    let textContainer = try #require(textView.textContainer)
    layoutManager.ensureLayout(for: textContainer)

    let textOrigin = textView.textContainerOrigin
    let firstGlyphRect = layoutManager.boundingRect(
      forGlyphRange: NSRange(location: 0, length: 1),
      in: textContainer
    )
    let lastGlyphRect = layoutManager.boundingRect(
      forGlyphRange: NSRange(location: layoutManager.numberOfGlyphs - 1, length: 1),
      in: textContainer
    )
    let visibleTextPoint = NSPoint(
      x: textOrigin.x + firstGlyphRect.midX,
      y: textOrigin.y + firstGlyphRect.midY
    )
    let blankLinePoint = NSPoint(
      x: textOrigin.x + firstGlyphRect.midX,
      y: textOrigin.y + (firstGlyphRect.midY + lastGlyphRect.midY) / 2
    )
    let backgroundPoint = NSPoint(x: textView.bounds.maxX - 8, y: textView.bounds.maxY - 8)

    #expect(textView.isSelectableTextPoint(visibleTextPoint) == true)
    #expect(textView.isSelectableTextPoint(blankLinePoint) == false)
    #expect(textView.isSelectableTextPoint(backgroundPoint) == false)
  }

  @MainActor @Test func ptyTextBackgroundClickClearsExistingSelection() throws {
    let textView = PTYTextView()
    textView.frame = NSRect(x: 0, y: 0, width: 320, height: 180)
    textView.textContainerInset = NSSize(width: 14, height: 12)
    textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    textView.string = "selected text"
    textView.setSelectedRange(NSRange(location: 0, length: 8))

    let backgroundPoint = NSPoint(x: textView.bounds.maxX - 8, y: textView.bounds.maxY - 8)
    let event = try #require(NSEvent.mouseEvent(
      with: .leftMouseDown,
      location: backgroundPoint,
      modifierFlags: [],
      timestamp: 0,
      windowNumber: 0,
      context: nil,
      eventNumber: 1,
      clickCount: 1,
      pressure: 1
    ))

    textView.mouseDown(with: event)

    #expect(textView.selectedRange().length == 0)
  }

  @MainActor @Test func ptyTextCanDragSelectFromBackgroundIntoText() throws {
    let textView = PTYTextView()
    textView.frame = NSRect(x: 0, y: 0, width: 320, height: 180)
    textView.textContainerInset = NSSize(width: 14, height: 12)
    textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    textView.string = "top\nmiddle\nbottom"

    let layoutManager = try #require(textView.layoutManager)
    let textContainer = try #require(textView.textContainer)
    layoutManager.ensureLayout(for: textContainer)

    let textOrigin = textView.textContainerOrigin
    let firstGlyphRect = layoutManager.boundingRect(
      forGlyphRange: NSRange(location: 0, length: 1),
      in: textContainer
    )
    let startPoint = NSPoint(x: textView.bounds.maxX - 8, y: textView.bounds.maxY - 8)
    let dragPoint = NSPoint(
      x: textOrigin.x + firstGlyphRect.midX,
      y: textOrigin.y + firstGlyphRect.midY
    )
    let mouseDown = try #require(NSEvent.mouseEvent(
      with: .leftMouseDown,
      location: startPoint,
      modifierFlags: [],
      timestamp: 0,
      windowNumber: 0,
      context: nil,
      eventNumber: 1,
      clickCount: 1,
      pressure: 1
    ))
    let mouseDrag = try #require(NSEvent.mouseEvent(
      with: .leftMouseDragged,
      location: dragPoint,
      modifierFlags: [],
      timestamp: 0.1,
      windowNumber: 0,
      context: nil,
      eventNumber: 2,
      clickCount: 1,
      pressure: 1
    ))

    textView.mouseDown(with: mouseDown)
    textView.mouseDragged(with: mouseDrag)

    #expect(textView.selectedRange().length > 0)
  }

  @MainActor @Test func ptyTextCopyWritesSelectedTextToPasteboard() throws {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("proghostty.copy.test.\(UUID().uuidString)"))
    pasteboard.clearContents()
    let textView = PTYTextView()
    textView.pasteboard = pasteboard
    textView.string = "copy this text"
    textView.setSelectedRange(NSRange(location: 5, length: 4))

    textView.copy(nil)

    #expect(pasteboard.string(forType: .string) == "this")
  }

  @MainActor @Test func ptyTextCopyPreservesDocumentSelectionTextExactly() throws {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("proghostty.copy.exact.test.\(UUID().uuidString)"))
    pasteboard.clearContents()
    let textView = PTYTextView()
    textView.pasteboard = pasteboard
    textView.string = "first line  \n中文 é 😀"
    textView.setSelectedRange(NSRange(location: 0, length: (textView.string as NSString).length))

    textView.copy(nil)

    #expect(pasteboard.string(forType: .string) == "first line  \n中文 é 😀")
  }

  @MainActor @Test func ptyTextPasteWritesPasteboardTextToPasteHandler() throws {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("proghostty.paste.test.\(UUID().uuidString)"))
    pasteboard.clearContents()
    pasteboard.setString("echo hello\npwd", forType: .string)
    var written: Data?
    var pasted: String?
    let textView = PTYTextView()
    textView.pasteboard = pasteboard
    textView.inputHandler = { written = $0 }
    textView.pasteHandler = { pasted = $0 }

    textView.paste(nil)

    #expect(pasted == "echo hello\npwd")
    #expect(written == nil)
  }

  @MainActor @Test func ptyGridPasteWritesPasteboardTextToPasteHandler() throws {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("proghostty.grid.paste.test.\(UUID().uuidString)"))
    pasteboard.clearContents()
    pasteboard.setString("{\n  \"key\": \"value\"\n}", forType: .string)
    var written: Data?
    var pasted: String?
    let gridView = PTYGridView()
    gridView.pasteboard = pasteboard
    gridView.inputHandler = { written = $0 }
    gridView.pasteHandler = { pasted = $0 }

    gridView.paste(nil)

    #expect(pasted == "{\n  \"key\": \"value\"\n}")
    #expect(written == nil)
  }

  @MainActor @Test func ptyTextInputClientWritesCommittedChineseTextToInputHandler() {
    var written: Data?
    let textView = PTYTextView()
    textView.inputHandler = { written = $0 }

    textView.insertText("中文", replacementRange: NSRange(location: NSNotFound, length: 0))

    #expect(written == Data("中文".utf8))
  }

  @MainActor @Test func ptyGridInputClientWritesCommittedChineseTextToInputHandler() {
    var written: Data?
    let gridView = PTYGridView()
    gridView.inputHandler = { written = $0 }

    gridView.insertText("中文", replacementRange: NSRange(location: NSNotFound, length: 0))

    #expect(written == Data("中文".utf8))
  }

  @MainActor @Test func ptyGridPrintableKeyEventsUseTextInputPipeline() throws {
    var written: Data?
    let gridView = PTYGridView()
    gridView.inputHandler = { written = $0 }
    let event = try #require(NSEvent.keyEvent(
      with: .keyDown,
      location: .zero,
      modifierFlags: [],
      timestamp: 0,
      windowNumber: 0,
      context: nil,
      characters: "a",
      charactersIgnoringModifiers: "a",
      isARepeat: false,
      keyCode: 0
    ))

    gridView.keyDown(with: event)

    #expect(written == Data("a".utf8))
  }

  @MainActor @Test func ptyGridControlCWritesInterruptByte() throws {
    var written: Data?
    let gridView = PTYGridView()
    gridView.inputHandler = { written = $0 }
    let event = try #require(NSEvent.keyEvent(
      with: .keyDown,
      location: .zero,
      modifierFlags: [.control],
      timestamp: 0,
      windowNumber: 0,
      context: nil,
      characters: "\u{3}",
      charactersIgnoringModifiers: "c",
      isARepeat: false,
      keyCode: 8
    ))

    gridView.keyDown(with: event)

    #expect(written == Data([0x03]))
  }

  @MainActor @Test func ptyGridEscapeWritesEscapeByte() throws {
    var written: Data?
    let gridView = PTYGridView()
    gridView.inputHandler = { written = $0 }
    let event = try #require(NSEvent.keyEvent(
      with: .keyDown,
      location: .zero,
      modifierFlags: [],
      timestamp: 0,
      windowNumber: 0,
      context: nil,
      characters: "\u{1B}",
      charactersIgnoringModifiers: "\u{1B}",
      isARepeat: false,
      keyCode: 53
    ))

    gridView.keyDown(with: event)

    #expect(written == Data([0x1B]))
  }

  @MainActor @Test func ptyTextControlCWritesInterruptByte() throws {
    var written: Data?
    let textView = PTYTextView()
    textView.inputHandler = { written = $0 }
    let event = try #require(NSEvent.keyEvent(
      with: .keyDown,
      location: .zero,
      modifierFlags: [.control],
      timestamp: 0,
      windowNumber: 0,
      context: nil,
      characters: "\u{3}",
      charactersIgnoringModifiers: "c",
      isARepeat: false,
      keyCode: 8
    ))

    textView.keyDown(with: event)

    #expect(written == Data([0x03]))
  }

  @MainActor @Test func ptyGridMarkedTextBackspaceDoesNotWriteDeleteToPTY() {
    var writes: [Data] = []
    let gridView = PTYGridView()
    gridView.inputHandler = { writes.append($0) }

    gridView.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
    gridView.doCommand(by: #selector(NSResponder.deleteBackward(_:)))

    #expect(writes.isEmpty)
    #expect(gridView.hasMarkedText())
  }

  @MainActor @Test func ptyGridMarkedTextTracksIMESelectedRange() {
    let gridView = PTYGridView()

    gridView.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))

    #expect(gridView.selectedRange() == NSRange(location: 5, length: 0))
  }

  @MainActor @Test func ptyGridFirstRectUsesMarkedTextCaretOffset() {
    let gridView = PTYGridView()
    let frame = frameWithText(rows: ["            "], cols: 12, cursorX: 1, cursorY: 0)
    let cellSize = gridView.terminalCellSize
    let inset = gridView.terminalContentInset
    gridView.frame = NSRect(
      x: 0,
      y: 0,
      width: inset.width * 2 + CGFloat(frame.cols) * cellSize.width,
      height: inset.height * 2 + CGFloat(frame.rows) * cellSize.height
    )
    let window = NSWindow(contentRect: gridView.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = gridView
    gridView.render(frame, isFocused: true)
    gridView.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))

    let startRect = gridView.firstRect(forCharacterRange: NSRange(location: 0, length: 0), actualRange: nil)
    let endRect = gridView.firstRect(forCharacterRange: NSRange(location: 5, length: 0), actualRange: nil)

    #expect(endRect.minX > startRect.minX)
  }

  @MainActor @Test func ptyGridInvalidatesIMECharacterCoordinatesForMarkedTextChanges() {
    let gridView = InputCoordinateTrackingGridView()
    let frame = frameWithText(rows: ["      "], cols: 6, cursorX: 0, cursorY: 0)

    gridView.render(frame, isFocused: true)
    gridView.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
    gridView.unmarkText()

    #expect(gridView.trackingInputContext.invalidationCount == 3)
  }

  @MainActor @Test func ptyGridEmptyMarkedTextRestoresBackspaceToPTY() throws {
    var writes: [Data] = []
    let gridView = PTYGridView()
    gridView.inputHandler = { writes.append($0) }
    gridView.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
    gridView.setMarkedText("", selectedRange: NSRange(location: 0, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))

    let event = try #require(NSEvent.keyEvent(
      with: .keyDown,
      location: .zero,
      modifierFlags: [],
      timestamp: 0,
      windowNumber: 0,
      context: nil,
      characters: "\u{8}",
      charactersIgnoringModifiers: "\u{8}",
      isARepeat: false,
      keyCode: 51
    ))

    gridView.keyDown(with: event)

    #expect(writes == [Data([0x7F])])
    #expect(!gridView.isComposingMarkedText)
  }

  @MainActor @Test func ptyGridDrawsMarkedTextAtCursorBeforeCommit() throws {
    let backend = GhosttyVTCellGridRendererBackend()
    let gridView = backend.gridView
    let frame = frameWithText(rows: ["      "], cols: 6, cursorX: 2, cursorY: 0)
    let cellSize = gridView.terminalCellSize
    let inset = gridView.terminalContentInset
    gridView.frame = NSRect(
      x: 0,
      y: 0,
      width: inset.width * 2 + CGFloat(frame.cols) * cellSize.width,
      height: inset.height * 2 + CGFloat(frame.rows) * cellSize.height
    )
    backend.render(frame: frame)
    backend.flushPendingFrame()
    gridView.display()
    let measuredViewRect =
      PTYGridView.textGlyphRect(row: 0, col: 2, cellSize: cellSize, inset: inset)
        .union(PTYGridView.textGlyphRect(row: 0, col: 4, cellSize: cellSize, inset: inset))
    let baselineImage = try #require(bitmapImage(drawing: gridView))
    let baselinePixels = nonBackgroundPixelCount(
      in: bitmapRect(measuredViewRect, imageHeight: baselineImage.pixelsHigh),
      image: baselineImage,
      background: TerminalSurfacePalette.dark.background
    )

    gridView.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
    gridView.display()

    let image = try #require(bitmapImage(drawing: gridView))

    #expect(
      nonBackgroundPixelCount(
        in: bitmapRect(measuredViewRect, imageHeight: image.pixelsHigh),
        image: image,
        background: TerminalSurfacePalette.dark.background
      ) > baselinePixels
    )
  }

  @MainActor @Test func ptyGridExposesMarkedTextOverlayAtCursor() {
    let gridView = PTYGridView()
    let frame = frameWithText(rows: ["      "], cols: 6, cursorX: 2, cursorY: 0)
    gridView.render(frame, isFocused: true)

    gridView.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))

    let overlay = gridView.currentMarkedTextOverlay
    #expect(overlay?.row == 0)
    #expect(overlay?.col == 2)
    #expect((overlay?.width ?? 0) >= gridView.terminalCellSize.width)
    #expect(gridView.currentMarkedTextString == "zhong")

    gridView.unmarkText()

    #expect(gridView.currentMarkedTextOverlay == nil)
    #expect(gridView.currentMarkedTextString == nil)
  }

  @MainActor @Test func ptyGridInfersMarkedTextAnchorFromVisualPromptCursorWhenVtCursorIsHome() throws {
    let gridView = PTYGridView()
    var frame = frameWithText(rows: [
      "Claude Code",
      "------------",
      "› hello     "
    ], cols: 12, cursorX: 0, cursorY: 0)
    let promptCursorIndex = 2 * frame.cols + 7
    frame.cells[promptCursorIndex].scalar = " "
    frame.cells[promptCursorIndex].inverse = true
    frame.cells[promptCursorIndex].usesDefaultBackground = false

    gridView.render(frame, isFocused: true)
    gridView.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))

    let overlay = try #require(gridView.currentMarkedTextOverlay)
    #expect(overlay.row == 2)
    #expect(overlay.col == 7)
    #expect(gridView.cursorCellRect == nil)
  }

  @MainActor @Test func ptyGridInfersMarkedTextAnchorFromLatestVisualPromptCursorWhenVtCursorIsHome() throws {
    let gridView = PTYGridView()
    var frame = frameWithText(rows: [
      "› old       ",
      "history     ",
      "› current   "
    ], cols: 12, cursorX: 0, cursorY: 0)
    let staleCursorIndex = 0 * frame.cols + 2
    frame.cells[staleCursorIndex].scalar = " "
    frame.cells[staleCursorIndex].inverse = true
    frame.cells[staleCursorIndex].usesDefaultBackground = false
    let liveCursorIndex = 2 * frame.cols + 9
    frame.cells[liveCursorIndex].scalar = " "
    frame.cells[liveCursorIndex].inverse = true
    frame.cells[liveCursorIndex].usesDefaultBackground = false

    gridView.render(frame, isFocused: true)
    gridView.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))

    let overlay = try #require(gridView.currentMarkedTextOverlay)
    #expect(overlay.row == 2)
    #expect(overlay.col == 9)
    #expect(gridView.currentIMECompositionCursorOverlay?.row == 2)
    #expect(gridView.currentIMECompositionCursorOverlay?.col == 9)
    #expect(gridView.cursorCellRect == nil)
  }

  @MainActor @Test func ptyGridInfersMarkedTextAnchorFromPromptContinuationCursorWhenVtCursorIsHome() throws {
    let gridView = PTYGridView()
    var frame = frameWithText(rows: [
      "› long input",
      "continues   ",
      "here        "
    ], cols: 12, cursorX: 0, cursorY: 0)
    let firstLineEndIndex = 0 * frame.cols + 11
    frame.cells[firstLineEndIndex].scalar = " "
    frame.cells[firstLineEndIndex].inverse = true
    frame.cells[firstLineEndIndex].usesDefaultBackground = false
    let continuationCursorIndex = 2 * frame.cols + 4
    frame.cells[continuationCursorIndex].scalar = " "
    frame.cells[continuationCursorIndex].inverse = true
    frame.cells[continuationCursorIndex].usesDefaultBackground = false

    gridView.render(frame, isFocused: true)
    gridView.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))

    let overlay = try #require(gridView.currentMarkedTextOverlay)
    #expect(overlay.row == 2)
    #expect(overlay.col == 4)
    #expect(gridView.currentIMECompositionCursorOverlay?.row == 2)
    #expect(gridView.currentIMECompositionCursorOverlay?.col == 4)
    #expect(gridView.cursorCellRect == nil)
  }

  @MainActor @Test func ptyGridInfersMarkedTextAnchorFromRightmostVisualPromptCursorWhenVtCursorIsHome() throws {
    let gridView = PTYGridView()
    var frame = frameWithText(rows: [
      "› current   "
    ], cols: 12, cursorX: 0, cursorY: 0)
    let promptAdjacentIndex = 0 * frame.cols + 2
    frame.cells[promptAdjacentIndex].scalar = " "
    frame.cells[promptAdjacentIndex].inverse = true
    frame.cells[promptAdjacentIndex].usesDefaultBackground = false
    let liveCursorIndex = 0 * frame.cols + 9
    frame.cells[liveCursorIndex].scalar = " "
    frame.cells[liveCursorIndex].inverse = true
    frame.cells[liveCursorIndex].usesDefaultBackground = false

    gridView.render(frame, isFocused: true)
    gridView.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))

    let overlay = try #require(gridView.currentMarkedTextOverlay)
    #expect(overlay.row == 0)
    #expect(overlay.col == 9)
    #expect(gridView.currentIMECompositionCursorOverlay?.row == 0)
    #expect(gridView.currentIMECompositionCursorOverlay?.col == 9)
    #expect(gridView.cursorCellRect == nil)
  }

  @MainActor @Test func ptyGridMarkedTextHidesTerminalCursorDuringComposition() throws {
    let gridView = PTYGridView()
    let frame = frameWithText(rows: ["x     "], cols: 6, cursorX: 0, cursorY: 0)
    let cellSize = gridView.terminalCellSize
    let inset = gridView.terminalContentInset
    gridView.frame = NSRect(
      x: 0,
      y: 0,
      width: inset.width * 2 + CGFloat(frame.cols) * cellSize.width,
      height: inset.height * 2 + CGFloat(frame.rows) * cellSize.height
    )
    gridView.render(frame, isFocused: true)

    let cursorImage = try #require(bitmapImage(drawing: gridView))
    let cellRect = bitmapRect(PTYGridView.textGlyphRect(row: 0, col: 0, cellSize: cellSize, inset: inset), imageHeight: cursorImage.pixelsHigh)
    let cursorFillPixels = similarPixelCount(
      to: TerminalSurfacePalette.dark.cursorBackground,
      in: cellRect,
      image: cursorImage
    )
    #expect(cursorFillPixels > 0)

    gridView.setMarkedText("z", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
    let composingImage = try #require(bitmapImage(drawing: gridView))
    let composingCursorFillPixels = similarPixelCount(
      to: TerminalSurfacePalette.dark.cursorBackground,
      in: bitmapRect(PTYGridView.textGlyphRect(row: 0, col: 0, cellSize: cellSize, inset: inset), imageHeight: composingImage.pixelsHigh),
      image: composingImage
    )
    let composingPixels = nonBackgroundPixelCount(
      in: bitmapRect(PTYGridView.textGlyphRect(row: 0, col: 0, cellSize: cellSize, inset: inset), imageHeight: cursorImage.pixelsHigh),
      image: composingImage,
      background: TerminalSurfacePalette.dark.background
    )

    #expect(composingPixels > 0)
    #expect(composingCursorFillPixels < cursorFillPixels)
  }

  @MainActor @Test func ptyGridEmptyMarkedTextRestoresCursorWithoutExplicitUnmarkText() throws {
    let gridView = PTYGridView()
    let frame = frameWithText(rows: ["x     "], cols: 6, cursorX: 0, cursorY: 0)
    let cellSize = gridView.terminalCellSize
    let inset = gridView.terminalContentInset
    gridView.frame = NSRect(
      x: 0,
      y: 0,
      width: inset.width * 2 + CGFloat(frame.cols) * cellSize.width,
      height: inset.height * 2 + CGFloat(frame.rows) * cellSize.height
    )
    gridView.render(frame, isFocused: true)

    let cursorImage = try #require(bitmapImage(drawing: gridView))
    let cellRect = bitmapRect(PTYGridView.textGlyphRect(row: 0, col: 0, cellSize: cellSize, inset: inset), imageHeight: cursorImage.pixelsHigh)
    let cursorFillPixels = similarPixelCount(
      to: TerminalSurfacePalette.dark.cursorBackground,
      in: cellRect,
      image: cursorImage
    )

    gridView.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
    gridView.setMarkedText("", selectedRange: NSRange(location: 0, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))

    let emptyImage = try #require(bitmapImage(drawing: gridView))
    let emptyCursorFillPixels = similarPixelCount(
      to: TerminalSurfacePalette.dark.cursorBackground,
      in: bitmapRect(PTYGridView.textGlyphRect(row: 0, col: 0, cellSize: cellSize, inset: inset), imageHeight: emptyImage.pixelsHigh),
      image: emptyImage
    )

    #expect(emptyCursorFillPixels >= cursorFillPixels)
    #expect(!gridView.isComposingMarkedText)
  }

  @MainActor @Test func ptyGridCommandClickOpensVisibleURL() throws {
    let gridView = PTYGridView()
    let frame = frameWithText(rows: ["open http://localhost:5173 now"], cols: 36, cursorX: 0, cursorY: 0)
    let cellSize = gridView.terminalCellSize
    let inset = gridView.terminalContentInset
    gridView.frame = NSRect(
      x: 0,
      y: 0,
      width: inset.width * 2 + CGFloat(frame.cols) * cellSize.width,
      height: inset.height * 2 + CGFloat(frame.rows) * cellSize.height
    )
    gridView.render(frame, isFocused: true)
    gridView.terminalScrollOwnershipHandler = { .mouseReporting }
    var encodedMouse = false
    gridView.terminalMouseEncodeHandler = { _, _ in
      encodedMouse = true
      return Data("unexpected".utf8)
    }
    var openedURL: URL?
    gridView.openURLHandler = { openedURL = $0 }
    let rect = PTYGridView.textGlyphRect(row: 0, col: 9, cellSize: cellSize, inset: inset)
    let point = NSPoint(x: rect.midX, y: rect.midY)
    let event = try #require(NSEvent.mouseEvent(
      with: .leftMouseDown,
      location: point,
      modifierFlags: [.command],
      timestamp: 0,
      windowNumber: 0,
      context: nil,
      eventNumber: 1,
      clickCount: 1,
      pressure: 1
    ))

    gridView.mouseDown(with: event)

    #expect(openedURL?.absoluteString == "http://localhost:5173")
    #expect(!encodedMouse)
  }

  @MainActor @Test func ptyGridPlainClickOnURLDoesNotOpenURL() throws {
    let gridView = PTYGridView()
    let frame = frameWithText(rows: ["open http://localhost:5173 now"], cols: 36, cursorX: 0, cursorY: 0)
    let cellSize = gridView.terminalCellSize
    let inset = gridView.terminalContentInset
    gridView.frame = NSRect(
      x: 0,
      y: 0,
      width: inset.width * 2 + CGFloat(frame.cols) * cellSize.width,
      height: inset.height * 2 + CGFloat(frame.rows) * cellSize.height
    )
    gridView.render(frame, isFocused: true)
    var openedURL: URL?
    gridView.openURLHandler = { openedURL = $0 }
    let rect = PTYGridView.textGlyphRect(row: 0, col: 9, cellSize: cellSize, inset: inset)
    let point = NSPoint(x: rect.midX, y: rect.midY)
    let event = try #require(NSEvent.mouseEvent(
      with: .leftMouseDown,
      location: point,
      modifierFlags: [],
      timestamp: 0,
      windowNumber: 0,
      context: nil,
      eventNumber: 1,
      clickCount: 1,
      pressure: 1
    ))

    gridView.mouseDown(with: event)

    #expect(openedURL == nil)
  }

  @MainActor @Test func ptyGridCommandClickOpensFilePathTarget() throws {
    let gridView = PTYGridView()
    let frame = frameWithText(rows: ["edit Sources/App.swift"], cols: 32, cursorX: 0, cursorY: 0)
    let cellSize = gridView.terminalCellSize
    let inset = gridView.terminalContentInset
    gridView.frame = NSRect(
      x: 0,
      y: 0,
      width: inset.width * 2 + CGFloat(frame.cols) * cellSize.width,
      height: inset.height * 2 + CGFloat(frame.rows) * cellSize.height
    )
    gridView.render(frame, isFocused: true)
    var openedTarget: TerminalLinkTarget?
    gridView.openLinkTargetHandler = { openedTarget = $0 }
    let rect = PTYGridView.textGlyphRect(row: 0, col: 8, cellSize: cellSize, inset: inset)
    let event = try #require(NSEvent.mouseEvent(
      with: .leftMouseDown,
      location: NSPoint(x: rect.midX, y: rect.midY),
      modifierFlags: [.command],
      timestamp: 0,
      windowNumber: 0,
      context: nil,
      eventNumber: 1,
      clickCount: 1,
      pressure: 1
    ))

    gridView.mouseDown(with: event)

    #expect(openedTarget == .filePath(TerminalFilePathTarget(rawPath: "Sources/App.swift")))
  }

  @MainActor @Test func ptyGridPlainClickOnFilePathDoesNotOpenTarget() throws {
    let gridView = PTYGridView()
    let frame = frameWithText(rows: ["edit Sources/App.swift"], cols: 32, cursorX: 0, cursorY: 0)
    let cellSize = gridView.terminalCellSize
    let inset = gridView.terminalContentInset
    gridView.frame = NSRect(
      x: 0,
      y: 0,
      width: inset.width * 2 + CGFloat(frame.cols) * cellSize.width,
      height: inset.height * 2 + CGFloat(frame.rows) * cellSize.height
    )
    gridView.render(frame, isFocused: true)
    var openedTarget: TerminalLinkTarget?
    gridView.openLinkTargetHandler = { openedTarget = $0 }
    let rect = PTYGridView.textGlyphRect(row: 0, col: 8, cellSize: cellSize, inset: inset)
    let event = try #require(NSEvent.mouseEvent(
      with: .leftMouseDown,
      location: NSPoint(x: rect.midX, y: rect.midY),
      modifierFlags: [],
      timestamp: 0,
      windowNumber: 0,
      context: nil,
      eventNumber: 1,
      clickCount: 1,
      pressure: 1
    ))

    gridView.mouseDown(with: event)

    #expect(openedTarget == nil)
  }

  @MainActor @Test func ptyGridDragStartingOnLinkSelectsOnlyDraggedSpanNotStaleAnchor() throws {
    let gridView = PTYGridView()
    let frame = frameWithText(rows: ["edit Sources/App.swift here"], cols: 32, cursorX: 0, cursorY: 0)
    let cellSize = gridView.terminalCellSize
    let inset = gridView.terminalContentInset
    gridView.frame = NSRect(
      x: 0,
      y: 0,
      width: inset.width * 2 + CGFloat(frame.cols) * cellSize.width,
      height: inset.height * 2 + CGFloat(frame.rows) * cellSize.height
    )
    gridView.render(frame, isFocused: true)
    var openedTarget: TerminalLinkTarget?
    gridView.openLinkTargetHandler = { openedTarget = $0 }

    // Press on the link (col 8, inside "Sources/App.swift") and drag a few cells.
    let start = PTYGridView.textGlyphRect(row: 0, col: 8, cellSize: cellSize, inset: inset)
    let end = PTYGridView.textGlyphRect(row: 0, col: 12, cellSize: cellSize, inset: inset)
    gridView.mouseDown(with: try mouseEvent(.leftMouseDown, viewPoint: NSPoint(x: start.midX, y: start.midY), in: gridView))
    gridView.mouseDragged(with: try mouseEvent(.leftMouseDragged, viewPoint: NSPoint(x: end.midX, y: end.midY), in: gridView))
    gridView.mouseUp(with: try mouseEvent(.leftMouseUp, viewPoint: NSPoint(x: end.midX, y: end.midY), in: gridView))

    // Anchor was set at the press point (not a stale one), so the selection is the
    // small dragged span — and dragging cancelled the pending click, so nothing opened.
    #expect(gridView.selectedText == "rces/")
    #expect(openedTarget == nil)
  }

  @MainActor @Test func ptyGridPlainClickOnLinkLeavesNoSelection() throws {
    let gridView = PTYGridView()
    let frame = frameWithText(rows: ["edit Sources/App.swift"], cols: 32, cursorX: 0, cursorY: 0)
    let cellSize = gridView.terminalCellSize
    let inset = gridView.terminalContentInset
    gridView.frame = NSRect(
      x: 0,
      y: 0,
      width: inset.width * 2 + CGFloat(frame.cols) * cellSize.width,
      height: inset.height * 2 + CGFloat(frame.rows) * cellSize.height
    )
    gridView.render(frame, isFocused: true)

    // A single click that never drags: mouseDown sets an empty anchor, mouseUp
    // clears it (and would open the popover if a window were attached).
    let rect = PTYGridView.textGlyphRect(row: 0, col: 8, cellSize: cellSize, inset: inset)
    gridView.mouseDown(with: try mouseEvent(.leftMouseDown, viewPoint: NSPoint(x: rect.midX, y: rect.midY), in: gridView))
    gridView.mouseUp(with: try mouseEvent(.leftMouseUp, viewPoint: NSPoint(x: rect.midX, y: rect.midY), in: gridView))

    #expect(gridView.selectedText == nil)
  }

  @MainActor @Test func ptyGridCommandClickOpensOSC8HyperlinkMetadata() throws {
    let gridView = PTYGridView()
    var frame = frameWithText(rows: ["project docs"], cols: 24, cursorX: 0, cursorY: 0)
    for col in 0..<7 {
      frame.cells[col].hyperlink = "https://docs.example/project"
    }
    let cellSize = gridView.terminalCellSize
    let inset = gridView.terminalContentInset
    gridView.frame = NSRect(
      x: 0,
      y: 0,
      width: inset.width * 2 + CGFloat(frame.cols) * cellSize.width,
      height: inset.height * 2 + CGFloat(frame.rows) * cellSize.height
    )
    gridView.render(frame, isFocused: true)
    var openedURL: URL?
    gridView.openURLHandler = { openedURL = $0 }
    let rect = PTYGridView.textGlyphRect(row: 0, col: 2, cellSize: cellSize, inset: inset)
    let point = NSPoint(x: rect.midX, y: rect.midY)
    let event = try #require(NSEvent.mouseEvent(
      with: .leftMouseDown,
      location: point,
      modifierFlags: [.command],
      timestamp: 0,
      windowNumber: 0,
      context: nil,
      eventNumber: 1,
      clickCount: 1,
      pressure: 1
    ))

    gridView.mouseDown(with: event)

    #expect(openedURL?.absoluteString == "https://docs.example/project")
  }

  @MainActor @Test func ptyGridExposesURLCursorRectsForVisibleLinks() {
    let frame = frameWithText(rows: ["open http://localhost:5173 now"], cols: 36, cursorX: 0, cursorY: 0)
    let cellSize = CGSize(width: 8, height: 16)
    let inset = CGSize(width: 14, height: 12)

    let rects = PTYGridView.urlCursorRects(frame: frame, cellSize: cellSize, inset: inset, linkInteractionActive: true)

    #expect(rects == [
      NSRect(x: 14 + 5 * 8, y: 12, width: 21 * 8, height: 16),
    ])
  }

  @MainActor @Test func ptyGridExposesCursorRectsForSuffixPathHits() {
    let frame = frameWithText(
      rows: ["- main: /Users/zpc/projects/DB/database_r", "eview.html"],
      cols: 48,
      cursorX: 0,
      cursorY: 0
    )
    let cellSize = CGSize(width: 8, height: 16)
    let inset = CGSize(width: 14, height: 12)

    let rects = PTYGridView.urlCursorRects(frame: frame, cellSize: cellSize, inset: inset, linkInteractionActive: true)

    #expect(rects.contains(NSRect(x: 14, y: 12 + 16, width: 10 * 8, height: 16)))
  }

  @MainActor @Test func ptyGridDoesNotExposeURLCursorRectsWithoutCommandLinkMode() {
    let frame = frameWithText(rows: ["open http://localhost:5173 now"], cols: 36, cursorX: 0, cursorY: 0)
    let cellSize = CGSize(width: 8, height: 16)
    let inset = CGSize(width: 14, height: 12)

    let rects = PTYGridView.urlCursorRects(frame: frame, cellSize: cellSize, inset: inset, linkInteractionActive: false)

    #expect(rects.isEmpty)
  }

  @MainActor @Test func ptyGridSelectionDragAboveTopUsesBrowsePresentWhenPattern2Ready() throws {
    let gridView = PTYGridView()
    var frame = frameWithText(rows: ["first visible", "second visible"], cols: 24, cursorX: 0, cursorY: 0)
    frame.isAlternateScreen = false
    let cellSize = gridView.terminalCellSize
    let inset = gridView.terminalContentInset
    gridView.frame = NSRect(
      x: 0,
      y: 0,
      width: inset.width * 2 + CGFloat(frame.cols) * cellSize.width,
      height: inset.height * 2 + CGFloat(frame.rows) * cellSize.height
    )
    gridView.applyRendererOptions(TerminalRendererOptions(smoothPixelScrollingEnabled: true))
    gridView.render(frame, isFocused: true)

    var presented: [(top: UInt64, visible: Int)] = []
    var followed = false
    // total 100, visible 2 → liveBottom max(98, 76) = 98
    gridView.browseScrollMetricsHandler = { (total: 100, topAbsoluteRow: 76) }
    gridView.browsePresentHandler = { top, visible in
      presented.append((top, visible))
    }
    gridView.browseFollowResumeHandler = { followed = true }

    let start = PTYGridView.textGlyphRect(row: 1, col: 2, cellSize: cellSize, inset: inset)
    gridView.mouseDown(with: try mouseEvent(.leftMouseDown, viewPoint: NSPoint(x: start.midX, y: start.midY), in: gridView))
    gridView.mouseDragged(with: try mouseEvent(.leftMouseDragged, viewPoint: NSPoint(x: start.midX, y: inset.height - 8), in: gridView))

    #expect(followed == false)
    #expect(presented.count == 1)
    #expect(presented[0].top == 97)
    #expect(presented[0].visible == 2)
    #expect(gridView.browseTopAbsoluteRow == 97)
  }

  @MainActor @Test func ptyGridURLCursorRectsCanFollowPixelScrollOffset() {
    let frame = frameWithText(rows: ["open http://localhost:5173 now"], cols: 36, cursorX: 0, cursorY: 0)
    let cellSize = CGSize(width: 8, height: 16)
    let inset = CGSize(width: 14, height: 12)

    let rects = PTYGridView.urlCursorRects(
      frame: frame,
      cellSize: cellSize,
      inset: inset,
      verticalOffsetY: 6,
      linkInteractionActive: true
    )

    #expect(rects == [
      NSRect(x: 14 + 5 * 8, y: 18, width: 21 * 8, height: 16),
    ])
  }

  @MainActor @Test func ptyGridReportsLinkHoverHintWithoutOpeningURL() throws {
    let gridView = PTYGridView()
    let frame = frameWithText(rows: ["open http://localhost:5173 now"], cols: 36, cursorX: 0, cursorY: 0)
    let cellSize = gridView.terminalCellSize
    let inset = gridView.terminalContentInset
    gridView.frame = NSRect(
      x: 0,
      y: 0,
      width: inset.width * 2 + CGFloat(frame.cols) * cellSize.width,
      height: inset.height * 2 + CGFloat(frame.rows) * cellSize.height
    )
    gridView.render(frame, isFocused: true)
    var hoverStates: [Bool] = []
    gridView.linkHoverHandler = { hoverStates.append($0) }
    let urlRect = PTYGridView.textGlyphRect(row: 0, col: 9, cellSize: cellSize, inset: inset)
    let plainRect = PTYGridView.textGlyphRect(row: 0, col: 0, cellSize: cellSize, inset: inset)

    // Dwell model: the hover *signal* (lightweight open-link toast) fires as soon
    // as the pointer is over the URL object and drops when it moves to plain text.
    // (The *visual* weight reveal is separately dwell-gated.) The signal never
    // opens the URL.
    gridView.mouseMoved(with: try mouseEvent(.mouseMoved, viewPoint: NSPoint(x: urlRect.midX, y: urlRect.midY), in: gridView))
    gridView.mouseMoved(with: try mouseEvent(.mouseMoved, viewPoint: NSPoint(x: plainRect.midX, y: plainRect.midY), in: gridView))

    #expect(hoverStates.first == true)
    #expect(hoverStates.last == false)
  }

  @MainActor @Test func ptyGridExposesHoveredLinkCellRange() throws {
    let gridView = PTYGridView()
    let frame = frameWithText(rows: ["open http://localhost:5173 now"], cols: 36, cursorX: 0, cursorY: 0)
    let cellSize = gridView.terminalCellSize
    let inset = gridView.terminalContentInset
    gridView.frame = NSRect(
      x: 0,
      y: 0,
      width: inset.width * 2 + CGFloat(frame.cols) * cellSize.width,
      height: inset.height * 2 + CGFloat(frame.rows) * cellSize.height
    )
    gridView.render(frame, isFocused: true)
    let urlRect = PTYGridView.textGlyphRect(row: 0, col: 9, cellSize: cellSize, inset: inset)
    let plainRect = PTYGridView.textGlyphRect(row: 0, col: 0, cellSize: cellSize, inset: inset)

    gridView.mouseMoved(with: try mouseEvent(.mouseMoved, viewPoint: NSPoint(x: urlRect.midX, y: urlRect.midY), in: gridView))

    #expect(gridView.currentLinkHoverCellRanges == [
      GridSelectionCellRange(row: 0, cols: 5..<26),
    ])

    gridView.mouseMoved(with: try mouseEvent(.mouseMoved, viewPoint: NSPoint(x: plainRect.midX, y: plainRect.midY), in: gridView))

    #expect(gridView.currentLinkHoverCellRanges == [])
  }

  @MainActor @Test func ptyTextCommandCAndVUseCopyPasteActions() throws {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("proghostty.shortcuts.test.\(UUID().uuidString)"))
    pasteboard.clearContents()
    var written: Data?
    let textView = PTYTextView()
    textView.pasteboard = pasteboard
    textView.string = "selected"
    textView.setSelectedRange(NSRange(location: 0, length: 8))
    textView.inputHandler = { written = $0 }

    let copyEvent = try #require(NSEvent.keyEvent(
      with: .keyDown,
      location: .zero,
      modifierFlags: [.command],
      timestamp: 0,
      windowNumber: 0,
      context: nil,
      characters: "c",
      charactersIgnoringModifiers: "c",
      isARepeat: false,
      keyCode: 8
    ))
    #expect(textView.performKeyEquivalent(with: copyEvent))
    #expect(pasteboard.string(forType: .string) == "selected")

    pasteboard.clearContents()
    pasteboard.setString("pwd", forType: .string)
    let pasteEvent = try #require(NSEvent.keyEvent(
      with: .keyDown,
      location: .zero,
      modifierFlags: [.command],
      timestamp: 0,
      windowNumber: 0,
      context: nil,
      characters: "v",
      charactersIgnoringModifiers: "v",
      isARepeat: false,
      keyCode: 9
    ))
    var pasted: String?
    textView.pasteHandler = { pasted = $0 }

    #expect(textView.performKeyEquivalent(with: pasteEvent))
    #expect(pasted == "pwd")
    #expect(written == nil)
  }

  @MainActor @Test func nonFocusedGridViewDoesNotConsumeCommandV() throws {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("proghostty.grid.shortcuts.focus.test.\(UUID().uuidString)"))
    pasteboard.clearContents()
    pasteboard.setString("target text", forType: .string)
    let first = PTYGridView()
    let second = PTYGridView()
    first.pasteboard = pasteboard
    second.pasteboard = pasteboard
    var firstPaste: String?
    var secondPaste: String?
    first.pasteHandler = { firstPaste = $0 }
    second.pasteHandler = { secondPaste = $0 }

    let container = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 240))
    first.frame = NSRect(x: 0, y: 0, width: 320, height: 240)
    second.frame = NSRect(x: 320, y: 0, width: 320, height: 240)
    container.addSubview(first)
    container.addSubview(second)
    let window = NSWindow(contentRect: container.bounds, styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = container
    #expect(window.makeFirstResponder(second))
    let pasteEvent = try #require(NSEvent.keyEvent(
      with: .keyDown,
      location: .zero,
      modifierFlags: [.command],
      timestamp: 0,
      windowNumber: window.windowNumber,
      context: nil,
      characters: "v",
      charactersIgnoringModifiers: "v",
      isARepeat: false,
      keyCode: 9
    ))

    #expect(first.performKeyEquivalent(with: pasteEvent) == false)
    #expect(firstPaste == nil)
    #expect(second.performKeyEquivalent(with: pasteEvent))
    #expect(secondPaste == "target text")
  }

  private func codexLikeBridge(suggestions: [String]) throws -> GhosttyVTBridge {
    let bridge = try GhosttyVTBridge(cols: 96, rows: 12, maxScrollback: 200)
    let history = (1...12).map { "history \($0)" }.joined(separator: "\r\n")
    let renderedSuggestions = suggestions.joined(separator: "\r\n")
    bridge.write(Data("\(history)\r\n".utf8))
    bridge.write(Data("\u{1B}[10;1H> /\u{1B}[11;1H\(renderedSuggestions)\u{1B}[10;4H".utf8))
    return bridge
  }

  private func cursorCharacterIndex(in textStorage: NSTextStorage) -> Int? {
    var cursorIndex: Int?
    let range = NSRange(location: 0, length: textStorage.length)
    textStorage.enumerateAttribute(.proGhosttyCursorShape, in: range) { value, attributeRange, stop in
      guard value is TerminalCursorShape else { return }
      cursorIndex = attributeRange.location
      stop.pointee = true
    }
    return cursorIndex
  }

  private func nonBackgroundPixelCount(
    in rect: NSRect,
    image: NSBitmapImageRep,
    background: NSColor
  ) -> Int {
    let backgroundRGB = background.usingColorSpace(.deviceRGB) ?? background
    let minX = max(0, Int(floor(rect.minX)))
    let maxX = min(image.pixelsWide - 1, Int(ceil(rect.maxX)))
    let minY = max(0, Int(floor(rect.minY)))
    let maxY = min(image.pixelsHigh - 1, Int(ceil(rect.maxY)))
    guard minX <= maxX, minY <= maxY else { return 0 }

    var count = 0
    for x in minX...maxX {
      for y in minY...maxY {
        guard let color = image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
        let distance = abs(color.redComponent - backgroundRGB.redComponent)
          + abs(color.greenComponent - backgroundRGB.greenComponent)
          + abs(color.blueComponent - backgroundRGB.blueComponent)
        if distance > 0.08 {
          count += 1
        }
      }
    }
    return count
  }

  private func similarPixelCount(
    to target: NSColor,
    in rect: NSRect,
    image: NSBitmapImageRep
  ) -> Int {
    let targetRGB = target.usingColorSpace(.deviceRGB) ?? target
    let minX = max(0, Int(floor(rect.minX)))
    let maxX = min(image.pixelsWide - 1, Int(ceil(rect.maxX)))
    let minY = max(0, Int(floor(rect.minY)))
    let maxY = min(image.pixelsHigh - 1, Int(ceil(rect.maxY)))
    guard minX <= maxX, minY <= maxY else { return 0 }

    var count = 0
    for x in minX...maxX {
      for y in minY...maxY {
        guard let color = image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
        let distance = abs(color.redComponent - targetRGB.redComponent)
          + abs(color.greenComponent - targetRGB.greenComponent)
          + abs(color.blueComponent - targetRGB.blueComponent)
        if distance < 0.08 {
          count += 1
        }
      }
    }
    return count
  }

  private func bitmapRect(_ viewRect: NSRect, imageHeight: Int) -> NSRect {
    NSRect(
      x: viewRect.minX,
      y: CGFloat(imageHeight) - viewRect.maxY,
      width: viewRect.width,
      height: viewRect.height
    )
  }

  @MainActor private func bitmapImage(drawing view: NSView) -> NSBitmapImageRep? {
    guard let image = NSBitmapImageRep(
      bitmapDataPlanes: nil,
      pixelsWide: max(1, Int(ceil(view.bounds.width))),
      pixelsHigh: max(1, Int(ceil(view.bounds.height))),
      bitsPerSample: 8,
      samplesPerPixel: 4,
      hasAlpha: true,
      isPlanar: false,
      colorSpaceName: .deviceRGB,
      bytesPerRow: 0,
      bitsPerPixel: 0
    ) else {
      return nil
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: image)
    view.draw(view.bounds)
    NSGraphicsContext.restoreGraphicsState()
    return image
  }

  private func frameWithText(rows: [String], cols: Int, cursorX: Int, cursorY: Int) -> GhosttyTerminalFrame {
    let cells = rows.flatMap { row in
      let padded = row.padding(toLength: cols, withPad: " ", startingAt: 0)
      return padded.unicodeScalars.prefix(cols).map {
        GhosttyTerminalFrame.Cell(
          scalar: $0,
          foreground: GhosttyTerminalFrame.RGB(r: 255, g: 255, b: 255),
          background: GhosttyTerminalFrame.RGB(r: 0, g: 0, b: 0),
          bold: false,
          italic: false,
          faint: false,
          underline: false,
          inverse: false,
          usesDefaultForeground: true,
          usesDefaultBackground: true
        )
      }
    }
    return GhosttyTerminalFrame(
      cols: cols,
      rows: rows.count,
      cursorVisible: true,
      cursorX: cursorX,
      cursorY: cursorY,
      cursorShape: .bar,
      cursorBlinking: false,
      isAlternateScreen: true,
      cells: cells
    )
  }

  private func cellRow(text: String, cols: Int) -> GhosttyTerminalCellRow {
    let frame = frameWithText(rows: [text], cols: cols, cursorX: 0, cursorY: 0)
    return GhosttyTerminalCellRow(cells: frame.cells)
  }

  @MainActor private func mouseEvent(
    _ type: NSEvent.EventType,
    viewPoint: NSPoint,
    in view: NSView,
    modifierFlags: NSEvent.ModifierFlags = []
  ) throws -> NSEvent {
    let windowPoint = NSPoint(x: viewPoint.x, y: view.bounds.height - viewPoint.y)
    return try #require(NSEvent.mouseEvent(
      with: type,
      location: windowPoint,
      modifierFlags: modifierFlags,
      timestamp: 0,
      windowNumber: 0,
      context: nil,
      eventNumber: 1,
      clickCount: 1,
      pressure: 1
    ))
  }

  @MainActor private func scrollView(in view: NSView) throws -> NSScrollView {
    if let scrollView = view as? NSScrollView {
      return scrollView
    }
    if let surfaceView = view as? PTYTerminalSurfaceView {
      return surfaceView.scrollView
    }
    for subview in view.subviews {
      if let scrollView = try? scrollView(in: subview) {
        return scrollView
      }
    }
    throw SurfaceLookupError.notFound("NSScrollView")
  }

  @MainActor private func textView(in view: NSView) throws -> NSTextView {
    let scrollView = try scrollView(in: view)
    guard let textView = scrollView.documentView as? NSTextView else {
      throw SurfaceLookupError.notFound("NSTextView")
    }
    return textView
  }

  @MainActor private func gridView(in view: NSView) throws -> PTYGridView {
    if let gridView = view as? PTYGridView {
      return gridView
    }
    if let surfaceView = view as? PTYTerminalSurfaceView {
      return surfaceView.liveGridView
    }
    for subview in view.subviews {
      if let gridView = try? gridView(in: subview) {
        return gridView
      }
    }
    throw SurfaceLookupError.notFound("PTYGridView")
  }

  private func scrollBridgeToBottom(_ bridge: GhosttyVTBridge) {
    guard let scrollbar = try? bridge.scrollbar(), scrollbar.offset + scrollbar.length < scrollbar.total else {
      return
    }
    let rowsToBottom = scrollbar.total - (scrollbar.offset + scrollbar.length)
    bridge.scrollViewport(deltaRows: Int(min(UInt64(Int.max), rowsToBottom)))
  }

  private enum SurfaceLookupError: Error {
    case notFound(String)
  }
}

private final class InputCoordinateTrackingGridView: PTYGridView {
  let trackingInputContext = TrackingTextInputContext(client: DummyTextInputClient())

  override var inputContext: NSTextInputContext? {
    trackingInputContext
  }
}

private final class TrackingTextInputContext: NSTextInputContext {
  private(set) var invalidationCount = 0

  override func invalidateCharacterCoordinates() {
    invalidationCount += 1
  }
}

private final class DummyTextInputClient: NSObject, NSTextInputClient {
  func insertText(_ string: Any, replacementRange: NSRange) {}
  func doCommand(by selector: Selector) {}
  func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {}
  func unmarkText() {}
  func selectedRange() -> NSRange { NSRange(location: 0, length: 0) }
  func markedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
  func hasMarkedText() -> Bool { false }
  func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
  func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
  func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect { .zero }
  func characterIndex(for point: NSPoint) -> Int { 0 }
}

@MainActor
private final class PaletteRecordingLiveRendererBackend: TerminalLiveRendererBackend {
  private let wrapped = GhosttyVTCellGridRendererBackend()
  var appliedPalettes: [TerminalSurfacePalette] = []
  var renderFrameCount = 0
  var flushCount = 0

  var gridView: PTYGridView { wrapped.gridView }
  var view: NSView { wrapped.view }
  var diagnostics: TerminalRendererDiagnostics {
    var diagnostics = wrapped.diagnostics
    diagnostics.backend = .metalDirect
    diagnostics.requestedBackend = .metalDirect
    diagnostics.metalDirect.pipelineReady = true
    return diagnostics
  }
  var selectedText: String? { wrapped.selectedText }

  func setInputHandler(_ handler: ((Data) -> Void)?) { wrapped.setInputHandler(handler) }
  func setActivationHandler(_ handler: (() -> Void)?) { wrapped.setActivationHandler(handler) }
  func applyPalette(_ palette: TerminalSurfacePalette) {
    appliedPalettes.append(palette)
    wrapped.applyPalette(palette)
  }
  func applyFont(family: String, size: CGFloat, cjkFallbackFamily: String?) {
    wrapped.applyFont(family: family, size: size, cjkFallbackFamily: cjkFallbackFamily)
  }
  func setFocused(_ isFocused: Bool) { wrapped.setFocused(isFocused) }
  func render(frame: GhosttyTerminalFrame) { wrapped.render(frame: frame) }
  func focus() { wrapped.focus() }

  func applyOptions(_ options: TerminalRendererOptions) { wrapped.applyOptions(options) }
  func render(_ renderFrame: TerminalRenderFrame) {
    renderFrameCount += 1
    wrapped.render(renderFrame)
  }
  func flushPendingFrame() {
    flushCount += 1
    wrapped.flushPendingFrame()
  }
  func updateOverscanDiagnostics(topRows: Int, bottomRows: Int) {
    wrapped.updateOverscanDiagnostics(topRows: topRows, bottomRows: bottomRows)
  }
  func markResizePending() { wrapped.markResizePending() }
  func applyResizeDiagnostics(_ diagnostics: TerminalResizeDiagnostics) { wrapped.applyResizeDiagnostics(diagnostics) }
  func resetViewportStartRowKeepingVisualOffset() { wrapped.resetViewportStartRowKeepingVisualOffset() }
  func resetPixelScroll(suppressMomentum: Bool) { wrapped.resetPixelScroll(suppressMomentum: suppressMomentum) }
}

@MainActor
private final class PipelineFailingDirectRendererBackend: TerminalLiveRendererBackend {
  let gridView = PTYGridView()
  private let diagnosticsState = TerminalRendererDiagnostics(
    backend: .metalDirect,
    requestedBackend: .metalDirect,
    backendFallbackReason: TerminalRendererDiagnostics.metalDirectUnavailableFallbackReason,
    usesBitmapCapture: false,
    dirtyRowCount: 0,
    visibleRowCount: 0,
    cacheHitRate: 0,
    averageDrawTime: 0,
    maxDrawTime: 0,
    redrawMode: .clean,
    smoothScrollOffset: 0,
    coalescedFrames: 0,
    droppedFrames: 0,
    alternateScreenActive: false,
    resizeSensitiveScreen: false,
    scrollMode: .rowBased,
    overscanTopRows: 0,
    overscanBottomRows: 0,
    pixelSmoothScroll: .unavailable,
    pixelSmoothScrollReason: TerminalRendererDiagnostics.missingOverscanRowsReason,
    pixelRemainderY: 0,
    committedRowDelta: 0,
    pendingScrollRowDelta: 0,
    pendingScrollWheelEvents: 0,
    lastScrollCommitDuration: 0,
    lastScrollRenderDuration: 0,
    lastResizeTotalDuration: 0,
    lastResizeVTDuration: 0,
    lastResizeSnapshotDuration: 0,
    pendingResize: false,
    styleStats: TerminalCellStyleStats()
  )

  var view: NSView { gridView }
  var diagnostics: TerminalRendererDiagnostics { diagnosticsState }
  var selectedText: String? { nil }

  func setInputHandler(_ handler: ((Data) -> Void)?) {}
  func setActivationHandler(_ handler: (() -> Void)?) {}
  func applyPalette(_ palette: TerminalSurfacePalette) {}
  func applyFont(family: String, size: CGFloat, cjkFallbackFamily: String?) {}
  func setFocused(_ isFocused: Bool) {}
  func render(frame: GhosttyTerminalFrame) {}
  func focus() {}

  func applyOptions(_ options: TerminalRendererOptions) {}
  func render(_ renderFrame: TerminalRenderFrame) {}
  func flushPendingFrame() {}
  func updateOverscanDiagnostics(topRows: Int, bottomRows: Int) {}
  func markResizePending() {}
  func applyResizeDiagnostics(_ diagnostics: TerminalResizeDiagnostics) {}
  func resetViewportStartRowKeepingVisualOffset() {}
  func resetPixelScroll(suppressMomentum: Bool) {}
}

@MainActor
private final class RuntimeFailingMetalDirectRenderingEngine: MetalDirectRenderingEngine {
  let drawPassCount = 0
  let presentedFrameCount = 0
  let latestSubmittedGeneration = 0
  let latestPresentedGeneration = 0
  let pipelineReady = true
  var prefersAsyncPresent = false
  let lastRenderedRowCount = 0
  let lastRenderedCellCount = 0
  let lastRenderedRunCount = 0
  let lastRenderPassLoadPolicy = MetalDirectRenderPassLoadPolicy.clear
  let lastWaitedForCompletion = false
  let lastGPUWaitReason = "none"
  let lastGlyphTextureHitCount = 0
  let lastGlyphTextureMissCount = 0
  let staleCompletionCount = 0

  func resetTextureCache() {}

  func clearToBackground(
    view: MetalDirectRendererView,
    palette: TerminalSurfacePalette
  ) -> Bool {
    false
  }

  func render(
    renderFrame: TerminalRenderFrame,
    plan: MetalTerminalRenderPlan,
    view: MetalDirectRendererView,
    palette: TerminalSurfacePalette,
    glyphAtlas: MetalGlyphAtlas
  ) -> Bool {
    false
  }
}

private extension NSColor {
  var lightness: CGFloat {
    guard let rgb = usingColorSpace(.deviceRGB) else { return 0 }
    return (rgb.redComponent + rgb.greenComponent + rgb.blueComponent) / 3
  }

  func sameRGB(as other: NSColor) -> Bool {
    guard let lhs = usingColorSpace(.deviceRGB), let rhs = other.usingColorSpace(.deviceRGB) else {
      return false
    }
    return abs(lhs.redComponent - rhs.redComponent) < 0.001
      && abs(lhs.greenComponent - rhs.greenComponent) < 0.001
      && abs(lhs.blueComponent - rhs.blueComponent) < 0.001
  }
}

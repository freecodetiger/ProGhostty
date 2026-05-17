import AppKit
import Foundation
import Testing

@testable import ProGhosttyCore

@Suite("Terminal surface", .serialized)
struct TerminalSurfaceTests {
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

  @MainActor @Test func autoRendererUsesCellGridForOrdinaryPromptFrames() throws {
    let registry = PTYTerminalSurfaceRegistry()
    let session = TerminalSessionID()
    registry.createSurface(session: session)
    let bridge = try GhosttyVTBridge(cols: 20, rows: 2, maxScrollback: 100)

    bridge.write(Data("prompt % ".utf8))
    registry.render(bridge, session: session)
    registry.flushPendingRenderers()

    let surfaceView = try #require(registry.viewForSession(session) as? PTYTerminalSurfaceView)

    #expect(surfaceView.isShowingLiveGrid)
    #expect(surfaceView.liveGridView.renderedText.contains("prompt"))
  }

  @MainActor @Test func liveCellGridScrollsLibGhosttyViewportForScrollbackHistory() throws {
    let registry = PTYTerminalSurfaceRegistry()
    let session = TerminalSessionID()
    registry.createSurface(session: session)
    let bridge = try GhosttyVTBridge(cols: 20, rows: 2, maxScrollback: 100)

    bridge.write(Data("first\r\nsecond\r\nthird\r\nfourth".utf8))
    registry.render(bridge, session: session)
    registry.flushPendingRenderers()
    let surfaceView = try #require(registry.viewForSession(session) as? PTYTerminalSurfaceView)
    #expect(surfaceView.liveGridView.renderedText.contains("fourth"))

    surfaceView.liveGridView.testScrollViewportRows(2)
    registry.flushPendingRenderers()

    #expect(surfaceView.isShowingLiveGrid)
    #expect(surfaceView.liveGridView.renderedText.contains("first") || surfaceView.liveGridView.renderedText.contains("second"))
    #expect(registry.rendererDiagnostics(for: session)?.backend == .ghosttyVTCellGrid)
  }

  @MainActor @Test func liveCellGridWheelScrollReachesLibGhosttyScrollbackWhenFrameHasNoExtraRows() throws {
    let registry = PTYTerminalSurfaceRegistry()
    let session = TerminalSessionID()
    registry.createSurface(session: session)
    let bridge = try GhosttyVTBridge(cols: 20, rows: 2, maxScrollback: 100)

    bridge.write(Data("first\r\nsecond\r\nthird\r\nfourth".utf8))
    registry.render(bridge, session: session)
    registry.flushPendingRenderers()
    let surfaceView = try #require(registry.viewForSession(session) as? PTYTerminalSurfaceView)
    #expect(surfaceView.liveGridView.renderedText.contains("fourth"))

    surfaceView.liveGridView.testScrollWheelDeltaY(37)
    registry.flushPendingRenderers()

    #expect(surfaceView.liveGridView.renderedText.contains("first") || surfaceView.liveGridView.renderedText.contains("second"))
  }

  @MainActor @Test func liveCellGridWheelScrollDoesNotExposeTransientLocalPixelOffset() throws {
    let registry = PTYTerminalSurfaceRegistry()
    let session = TerminalSessionID()
    registry.createSurface(session: session)
    let bridge = try GhosttyVTBridge(cols: 20, rows: 2, maxScrollback: 100)

    bridge.write(Data("first\r\nsecond\r\nthird\r\nfourth".utf8))
    registry.render(bridge, session: session)
    registry.flushPendingRenderers()
    let surfaceView = try #require(registry.viewForSession(session) as? PTYTerminalSurfaceView)
    let bottomText = surfaceView.liveGridView.renderedText

    surfaceView.liveGridView.testScrollWheelDeltaY(5)
    registry.flushPendingRenderers()

    #expect(surfaceView.liveGridView.renderedText == bottomText)
    #expect(surfaceView.liveGridView.viewport == TerminalViewport())

    surfaceView.liveGridView.testScrollWheelDeltaY(37)
    registry.flushPendingRenderers()

    #expect(surfaceView.liveGridView.renderedText.contains("first") || surfaceView.liveGridView.renderedText.contains("second"))
    #expect(surfaceView.liveGridView.viewport == TerminalViewport())
  }

  @MainActor @Test func liveCellGridWheelScrollReturnsToBottomAndIgnoresPastTopEdge() throws {
    let registry = PTYTerminalSurfaceRegistry()
    let session = TerminalSessionID()
    registry.createSurface(session: session)
    let bridge = try GhosttyVTBridge(cols: 20, rows: 2, maxScrollback: 100)

    bridge.write(Data("first\r\nsecond\r\nthird\r\nfourth".utf8))
    registry.render(bridge, session: session)
    registry.flushPendingRenderers()
    let surfaceView = try #require(registry.viewForSession(session) as? PTYTerminalSurfaceView)

    surfaceView.liveGridView.testScrollWheelDeltaY(37)
    registry.flushPendingRenderers()
    let topText = surfaceView.liveGridView.renderedText

    surfaceView.liveGridView.testScrollWheelDeltaY(5)
    registry.flushPendingRenderers()

    #expect(surfaceView.liveGridView.renderedText == topText)
    #expect(surfaceView.liveGridView.viewport == TerminalViewport())

    surfaceView.liveGridView.testScrollWheelDeltaY(37)
    registry.flushPendingRenderers()

    #expect(surfaceView.liveGridView.renderedText == topText)
    #expect(surfaceView.liveGridView.viewport == TerminalViewport())

    surfaceView.liveGridView.testScrollWheelDeltaY(-37)
    registry.flushPendingRenderers()

    #expect(surfaceView.liveGridView.renderedText.contains("fourth"))
  }

  @MainActor @Test func surfaceRegistryExposesCellGridRendererDiagnostics() throws {
    let registry = PTYTerminalSurfaceRegistry()
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

  @MainActor @Test func ptyTextPasteWritesPasteboardTextToInputHandler() throws {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("proghostty.paste.test.\(UUID().uuidString)"))
    pasteboard.clearContents()
    pasteboard.setString("echo hello", forType: .string)
    var written: Data?
    let textView = PTYTextView()
    textView.pasteboard = pasteboard
    textView.inputHandler = { written = $0 }

    textView.paste(nil)

    #expect(written == Data("echo hello".utf8))
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
    #expect(textView.performKeyEquivalent(with: pasteEvent))
    #expect(written == Data("pwd".utf8))
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

  private enum SurfaceLookupError: Error {
    case notFound(String)
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

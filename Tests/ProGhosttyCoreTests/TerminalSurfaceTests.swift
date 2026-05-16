import AppKit
import Foundation
import Testing

@testable import ProGhosttyCore

@Suite("Terminal surface")
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

    let scrollView = try #require(registry.viewForSession(session) as? NSScrollView)
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

    let scrollView = try #require(registry.viewForSession(session) as? NSScrollView)
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

    let scrollView = try #require(registry.viewForSession(session) as? NSScrollView)
    let textView = try #require(scrollView.documentView as? NSTextView)
    #expect(textView.font?.pointSize == 21)
    #expect(textView.font?.familyName == "Menlo")
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

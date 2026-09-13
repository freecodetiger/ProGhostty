import AppKit
import Testing

@testable import ProGhosttyApp
@testable import ProGhosttyCore

@MainActor
struct MarkdownPreviewKeyRoutingTests {
  @Test func dismissedPreviewPreservesTerminalCopyAcrossSplitPointerPositions() throws {
    let root = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 600))
    let window = NSWindow(contentRect: root.bounds, styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = root
    let left = PTYGridView(frame: NSRect(x: 0, y: 0, width: 500, height: 600))
    let right = PTYGridView(frame: NSRect(x: 500, y: 0, width: 500, height: 600))
    root.addSubview(left)
    root.addSubview(right)
    let overlay = MarkdownPreviewFloatContainerView(frame: root.bounds)
    root.addSubview(overlay)
    overlay.configure(body: nil, isPresented: false, containerSize: root.bounds.size,
                      frame: CGRect(x: 520, y: 260, width: 460, height: 320))
    let preview = try #require(overlay.subviews.compactMap { $0 as? MarkdownPreviewFloatView }.first)
    let bridge = try GhosttyVTBridge(cols: 40, rows: 10)
    bridge.write(Data("selected terminal text".utf8))
    right.render(try bridge.frame(), isFocused: true)
    let cell = right.terminalCellSize
    let inset = right.terminalContentInset
    let point = right.convert(NSPoint(x: inset.width + cell.width / 2, y: inset.height + cell.height / 2), to: nil)
    let click = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point,
      modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
      eventNumber: 1, clickCount: 1, pressure: 1))
    right.mouseDown(with: click)
    let end = right.convert(NSPoint(x: inset.width + cell.width * 21.5, y: inset.height + cell.height / 2), to: nil)
    for type in [NSEvent.EventType.leftMouseDragged, .leftMouseUp] {
      let drag = try #require(NSEvent.mouseEvent(with: type, location: end,
        modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
        eventNumber: 2, clickCount: 1, pressure: 1))
      if type == .leftMouseDragged { right.mouseDragged(with: drag) }
      else { right.mouseUp(with: drag) }
    }
    let selection = try #require(right.selectedText)
    #expect(selection.contains("selected terminal text"))
    #expect(window.firstResponder === right)
    let board = NSPasteboard(name: .init("proghostty.preview-routing.\(UUID().uuidString)"))
    defer { board.releaseGlobally() }
    right.pasteboard = board
    let event = try keyEvent(window: window, key: "c", code: 8, modifiers: .command)
    for pointer in [NSPoint(x: 250, y: 450), NSPoint(x: 750, y: 100), NSPoint(x: 750, y: 450)] {
      board.clearContents()
      board.setString("old clipboard", forType: .string)
      if let routed = preview.routeHoveredKeyEvent(event, mouseLocationInWindow: pointer) {
        #expect(!left.performKeyEquivalent(with: routed))
        #expect(right.performKeyEquivalent(with: routed))
      }
      #expect(board.string(forType: .string) == selection, "pointer=\(pointer)")
      #expect(right.selectedText == selection)
    }
  }

  @Test func previewRoutesKeysOnlyWhilePresentedAndHovered() throws {
    let root = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 600))
    let window = NSWindow(contentRect: root.bounds, styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = root
    let preview = MarkdownPreviewFloatView(frame: NSRect(x: 500, y: 200, width: 460, height: 320))
    root.addSubview(preview)
    var dismissals = 0
    preview.onDismiss = { dismissals += 1 }
    let escape = try keyEvent(window: window, key: "\u{1b}", code: 53, modifiers: [])
    let inside = NSPoint(x: 700, y: 400)
    #expect(preview.routeHoveredKeyEvent(escape, mouseLocationInWindow: .zero) != nil)
    #expect(preview.routeHoveredKeyEvent(escape, mouseLocationInWindow: inside) == nil)
    #expect(dismissals == 1)
    preview.setPresented(false)
    #expect(preview.routeHoveredKeyEvent(escape, mouseLocationInWindow: inside) != nil)
    #expect(dismissals == 1)
    preview.setPresented(true)
    #expect(preview.routeHoveredKeyEvent(escape, mouseLocationInWindow: inside) == nil)
    #expect(dismissals == 2)
  }

  private func keyEvent(window: NSWindow, key: String, code: UInt16, modifiers: NSEvent.ModifierFlags) throws -> NSEvent {
    try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
      timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: key,
      charactersIgnoringModifiers: key, isARepeat: false, keyCode: code))
  }
}

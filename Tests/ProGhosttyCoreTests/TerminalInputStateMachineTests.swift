import AppKit
import Testing

@testable import ProGhosttyCore

@MainActor
@Suite("Terminal input state machine")
struct TerminalInputStateMachineTests {
  private func cursor(_ row: Int, _ col: Int) -> NSRect {
    PTYGridView.textGlyphRect(
      row: row,
      col: col,
      cellSize: CGSize(width: 8, height: 16),
      inset: CGSize(width: 14, height: 12)
    )
  }

  @Test func compositionStartsFromStableCursor() {
    let machine = TerminalInputStateMachine()
    machine.ingestRenderSnapshot(.init(generation: 1, cursorRect: cursor(2, 6), isFocused: true, hasMarkedText: false))

    let snapshot = machine.handle(.setMarkedText("nihao", selectedRange: .init(location: 5, length: 0)))

    #expect(snapshot.compositionAnchorRect == cursor(2, 6))
    #expect(snapshot.cursorSuppressed)
  }

  @Test func transientHomeCursorDoesNotMoveActiveAnchor() {
    let machine = TerminalInputStateMachine()
    machine.ingestRenderSnapshot(.init(generation: 1, cursorRect: cursor(2, 6), isFocused: true, hasMarkedText: false))
    machine.handle(.keyDown(isCompositionMethod: true))
    machine.ingestRenderSnapshot(.init(generation: 2, cursorRect: cursor(0, 0), isFocused: true, hasMarkedText: false))

    let snapshot = machine.handle(.setMarkedText("nihao", selectedRange: .init(location: 5, length: 0)))

    #expect(snapshot.compositionAnchorRect == cursor(2, 6))
  }

  @Test func unmarkClearsSuppression() {
    let machine = TerminalInputStateMachine()
    machine.handle(.setMarkedText("ni", selectedRange: .init(location: 2, length: 0)))

    let snapshot = machine.handle(.unmarkText)

    #expect(snapshot.cursorSuppressed == false)
    #expect(snapshot.markedText == nil)
  }
}

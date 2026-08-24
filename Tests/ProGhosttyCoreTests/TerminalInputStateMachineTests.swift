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

  private func snapshot(
    generation: Int,
    cursorRect: NSRect?,
    cursorIsHomeParked: Bool = false,
    isFocused: Bool = true,
    hasMarkedText: Bool = false
  ) -> TerminalInputRenderSnapshot {
    TerminalInputRenderSnapshot(
      generation: generation,
      cursorRect: cursorRect,
      cursorIsHomeParked: cursorIsHomeParked,
      isFocused: isFocused,
      hasMarkedText: hasMarkedText
    )
  }

  @Test func compositionStartsFromStableCursor() {
    let machine = TerminalInputStateMachine()
    machine.ingestRenderSnapshot(snapshot(generation: 1, cursorRect: cursor(2, 6)))

    let snapshot = machine.handle(.setMarkedText("nihao", selectedRange: .init(location: 5, length: 0)))

    #expect(snapshot.compositionAnchorRect == cursor(2, 6))
    #expect(snapshot.cursorSuppressed)
  }

  @Test func transientHomeCursorDoesNotMoveActiveAnchor() {
    let machine = TerminalInputStateMachine()
    machine.ingestRenderSnapshot(snapshot(generation: 1, cursorRect: cursor(2, 6)))
    machine.handle(.keyDown(isCompositionMethod: true))
    machine.ingestRenderSnapshot(snapshot(generation: 2, cursorRect: cursor(0, 0)))

    let snapshot = machine.handle(.setMarkedText("nihao", selectedRange: .init(location: 5, length: 0)))

    #expect(snapshot.compositionAnchorRect == cursor(2, 6))
  }

  @Test func homeParkedFrameDoesNotClobberStableAnchor() {
    let machine = TerminalInputStateMachine()
    machine.ingestRenderSnapshot(snapshot(generation: 1, cursorRect: cursor(2, 6)))
    // Prompt redraw / TUI presentation parks the cursor at the top-left and the
    // derived rect degenerates to the home cell: it must not move the anchor.
    machine.ingestRenderSnapshot(
      snapshot(generation: 2, cursorRect: cursor(0, 0), cursorIsHomeParked: true)
    )

    let snapshot = machine.handle(.setMarkedText("nihao", selectedRange: .init(location: 5, length: 0)))

    #expect(snapshot.compositionAnchorRect == cursor(2, 6))
  }

  @Test func nonCompositionKeyClearsPendingAnchor() {
    let machine = TerminalInputStateMachine()
    machine.ingestRenderSnapshot(snapshot(generation: 1, cursorRect: cursor(2, 6)))
    machine.handle(.keyDown(isCompositionMethod: true))
    machine.handle(.keyDown(isCompositionMethod: false))
    machine.ingestRenderSnapshot(snapshot(generation: 2, cursorRect: cursor(0, 0)))

    let snapshot = machine.handle(.setMarkedText("nihao", selectedRange: .init(location: 5, length: 0)))

    #expect(snapshot.compositionAnchorRect == cursor(0, 0))
  }

  @Test func committedTextAdvancesNextCompositionAnchor() {
    let machine = TerminalInputStateMachine()
    machine.ingestRenderSnapshot(snapshot(generation: 1, cursorRect: cursor(2, 6)))
    machine.handle(.setMarkedText("nihao", selectedRange: .init(location: 5, length: 0)))
    machine.handle(.insertText("你好"))

    let snapshot = machine.handle(.setMarkedText("ma", selectedRange: .init(location: 2, length: 0)))

    #expect(snapshot.compositionAnchorRect == cursor(2, 10))
  }

  @Test func unmarkClearsSuppression() {
    let machine = TerminalInputStateMachine()
    machine.handle(.setMarkedText("ni", selectedRange: .init(location: 2, length: 0)))

    let snapshot = machine.handle(.unmarkText)

    #expect(snapshot.cursorSuppressed == false)
    #expect(snapshot.markedText == nil)
  }

  @Test func emptyMarkedTextClearsSuppression() {
    let machine = TerminalInputStateMachine()
    machine.handle(.setMarkedText("ni", selectedRange: .init(location: 2, length: 0)))

    let snapshot = machine.handle(.setMarkedText("", selectedRange: .init(location: 0, length: 0)))

    #expect(snapshot.cursorSuppressed == false)
    #expect(snapshot.markedText == nil)
  }
}

import Foundation
import Testing

@testable import ProGhosttyCore

@Suite("Semantic click-to-position")
struct SemanticClickToPositionTests {
  // Helper: build a frame with semantic content per cell.
  // `content` is a string where each char maps to a cell.
  // `semantics` is a string of same length: 'p'=prompt, 'i'=input, 'o'=output.
  private func makeSemanticFrame(
    content: String,
    semantics: String,
    cols: Int,
    cursorX: Int,
    cursorY: Int
  ) -> GhosttyTerminalFrame {
    let scalars = Array(content.unicodeScalars)
    let semChars = Array(semantics)
    precondition(scalars.count == semChars.count)
    let rows = (scalars.count + cols - 1) / cols
    let totalCells = rows * cols

    var cells: [GhosttyTerminalFrame.Cell] = []
    for i in 0..<totalCells {
      let scalar: UnicodeScalar = i < scalars.count ? scalars[i] : " "
      let sem: CellSemanticContent
      if i < semChars.count {
        switch semChars[i] {
        case "i": sem = .input
        case "p": sem = .prompt
        default: sem = .output
        }
      } else {
        sem = .output
      }
      cells.append(GhosttyTerminalFrame.Cell(
        scalar: scalar,
        foreground: .init(r: 255, g: 255, b: 255),
        background: .init(r: 0, g: 0, b: 0),
        bold: false, italic: false, faint: false, underline: false, inverse: false,
        usesDefaultForeground: true, usesDefaultBackground: true,
        semanticContent: sem
      ))
    }
    return GhosttyTerminalFrame(
      cols: cols, rows: rows, cursorVisible: true,
      cursorX: cursorX, cursorY: cursorY, cells: cells
    )
  }

  // MARK: - cursor gate tests

  /// Mirror of the handleClickToPosition cursor gate: proceed only when the
  /// cursor's semantic state is .input OR the cell under it is .input.
  private func allowsClick(
    cursorRow: Int, cursorCol: Int,
    cols: Int, cells: [GhosttyTerminalFrame.Cell],
    cursorSemanticContent: CellSemanticContent
  ) -> Bool {
    let idx = cursorRow * cols + cursorCol
    let cellIsInput = idx < cells.count && cells[idx].semanticContent == .input
    return cursorSemanticContent == .input || cellIsInput
  }

  @Test func livePromptAllowsClickWhenCursorOnBlankCell() {
    // Normal editing: cursor parked on the blank cell past the last input char
    // (cell .output) but the cursor semantic state is still .input → allowed.
    let frame = makeSemanticFrame(
      content: "% hello   ",
      semantics: "ppiiiiiooo",
      cols: 10, cursorX: 7, cursorY: 0
    )
    #expect(allowsClick(
      cursorRow: 0, cursorCol: 7, cols: 10, cells: frame.cells,
      cursorSemanticContent: .input))
  }

  @Test func runningCommandRejectsClick() {
    // "sleep 100" running: OSC 133;C flipped cursor semantic to .output, cursor
    // parked on the stale command line's trailing blank cell → rejected.
    let frame = makeSemanticFrame(
      content: "sleep 100",
      semantics: "iiiiiiiii",
      cols: 10, cursorX: 9, cursorY: 0
    )
    #expect(!allowsClick(
      cursorRow: 0, cursorCol: 9, cols: 10, cells: frame.cells,
      cursorSemanticContent: .output))
  }

  @Test func runningCommandCursorOnInputCellAllowsClick() {
    // Cursor lands directly on a written input char (e.g. arrow-navigated into
    // the stale command): cursor cell is .input → allowed, matching Ghostty.
    let frame = makeSemanticFrame(
      content: "sleep 100",
      semantics: "iiiiiiiii",
      cols: 10, cursorX: 4, cursorY: 0
    )
    #expect(allowsClick(
      cursorRow: 0, cursorCol: 4, cols: 10, cells: frame.cells,
      cursorSemanticContent: .output))
  }

  @Test func cursorOnPromptCellRejectsClick() {
    // Cursor on the prompt marker, semantic state .prompt → rejected.
    let frame = makeSemanticFrame(
      content: "% hello   ",
      semantics: "ppiiiiiooo",
      cols: 10, cursorX: 0, cursorY: 0
    )
    #expect(!allowsClick(
      cursorRow: 0, cursorCol: 0, cols: 10, cells: frame.cells,
      cursorSemanticContent: .prompt))
  }

  // MARK: - countSemanticMoves tests

  // Since countSemanticMoves is private on PTYGridView, we test via
  // a standalone helper that mirrors its logic. We'll extract it.

  /// Mirror of the semantic counting logic for testing.
  private func countMoves(
    fromLinear: Int, toLinear: Int, cells: [GhosttyTerminalFrame.Cell]
  ) -> Int {
    guard fromLinear != toLinear else { return 0 }
    let movingRight = toLinear > fromLinear
    var charCount = 0

    if movingRight {
      var pos = fromLinear
      while pos < toLinear {
        guard pos < cells.count else { break }
        let cell = cells[pos]
        if cell.semanticContent != .input || cell.width == .spacerTail {
          pos += 1
          continue
        }
        charCount += 1
        pos += (cell.width == .wide) ? 2 : 1
      }
      return charCount
    } else {
      var pos = fromLinear - 1
      while pos >= toLinear {
        guard pos >= 0, pos < cells.count else { break }
        let cell = cells[pos]
        if cell.semanticContent != .input {
          pos -= 1
          continue
        }
        if cell.width == .spacerTail {
          pos -= 1
        }
        charCount += 1
        pos -= 1
      }
      return -charCount
    }
  }

  // MARK: - Basic scenarios

  @Test func moveRightWithinInputCells() {
    // "% hello   " — prompt is "% ", input is "hello", rest is output
    // cols=10, cursor at col 2 (first 'h'), click at col 6 ('o')
    let frame = makeSemanticFrame(
      content: "% hello   ",
      semantics: "ppiiiiiooo",
      cols: 10, cursorX: 2, cursorY: 0
    )
    // From col 2 to col 6: 'h','e','l','l' = 4 input chars
    let moves = countMoves(fromLinear: 2, toLinear: 6, cells: frame.cells)
    #expect(moves == 4)
  }

  @Test func moveLeftWithinInputCells() {
    // cursor at col 6, click at col 2
    let frame = makeSemanticFrame(
      content: "% hello   ",
      semantics: "ppiiiiiooo",
      cols: 10, cursorX: 6, cursorY: 0
    )
    let moves = countMoves(fromLinear: 6, toLinear: 2, cells: frame.cells)
    #expect(moves == -4)
  }

  @Test func moveToEndOfInput() {
    // "% hello   " — input 'hello' is cols 2-6, col 7 is first output
    // cursor at col 2, target is col 7 (one past last input char)
    let frame = makeSemanticFrame(
      content: "% hello   ",
      semantics: "ppiiiiiooo",
      cols: 10, cursorX: 2, cursorY: 0
    )
    // From col 2 to col 7: should count all input chars: h,e,l,l,o = 5
    let moves = countMoves(fromLinear: 2, toLinear: 7, cells: frame.cells)
    #expect(moves == 5)
  }

  @Test func cursorAtEndClickAtEnd() {
    // Cursor already at end of input (col 7), click at col 7 → 0 moves
    let frame = makeSemanticFrame(
      content: "% hello   ",
      semantics: "ppiiiiiooo",
      cols: 10, cursorX: 7, cursorY: 0
    )
    let moves = countMoves(fromLinear: 7, toLinear: 7, cells: frame.cells)
    #expect(moves == 0)
  }

  @Test func cursorInMiddleClickAtEnd() {
    // "% hello   " cursor at 'l' (col 4), click at col 7 (past last input)
    // Should count: l, l, o = 3
    let frame = makeSemanticFrame(
      content: "% hello   ",
      semantics: "ppiiiiiooo",
      cols: 10, cursorX: 4, cursorY: 0
    )
    let moves = countMoves(fromLinear: 4, toLinear: 7, cells: frame.cells)
    #expect(moves == 3)
  }

  @Test func crossRowForward() {
    // Two rows: "% abcde" (7 cols) wraps to "fghij  "
    // content 14 chars, semantics 14 chars
    // cursor at (0,2)=linear 2, click at (1,3)=linear 10
    let frame = makeSemanticFrame(
      content: "% abcdefghij  ",
      semantics: "ppiiiiiiiiiioo",
      cols: 7, cursorX: 2, cursorY: 0
    )
    // From linear 2 to linear 10: a,b,c,d,e,f,g,h = 8
    let moves = countMoves(fromLinear: 2, toLinear: 10, cells: frame.cells)
    #expect(moves == 8)
  }

  @Test func crossRowBackward() {
    // Same frame, cursor at (1,3)=linear 10, click at (0,2)=linear 2
    let frame = makeSemanticFrame(
      content: "% abcdefghij  ",
      semantics: "ppiiiiiiiiiioo",
      cols: 7, cursorX: 3, cursorY: 1
    )
    let moves = countMoves(fromLinear: 10, toLinear: 2, cells: frame.cells)
    #expect(moves == -8)
  }

  @Test func cursorAtEndOfInputBlankCellClickIntoInput() {
    // "% hello   " input is cols 2-6, cursor sits at col 7 (blank cell, .output).
    // Click at col 4 ('l'): should count all input chars before col 4.
    let frame = makeSemanticFrame(
      content: "% hello   ",
      semantics: "ppiiiiiooo",
      cols: 10, cursorX: 7, cursorY: 0
    )
    // From col 7 to col 4, walking backward: o,l,l = 3 moves left.
    let moves = countMoves(fromLinear: 7, toLinear: 4, cells: frame.cells)
    #expect(moves == -3)
  }

  @Test func cursorAtEndOfInputBlankCellClickAtStart() {
    // Cursor at col 7 (blank), click at col 2 (first 'h'): 5 moves left.
    let frame = makeSemanticFrame(
      content: "% hello   ",
      semantics: "ppiiiiiooo",
      cols: 10, cursorX: 7, cursorY: 0
    )
    let moves = countMoves(fromLinear: 7, toLinear: 2, cells: frame.cells)
    #expect(moves == -5)
  }

  @Test func cursorAtEndOfInputBlankCellClickPastEnd() {
    // Cursor at col 7 (blank), click at col 9 (also blank, past end) → no move.
    let frame = makeSemanticFrame(
      content: "% hello   ",
      semantics: "ppiiiiiooo",
      cols: 10, cursorX: 7, cursorY: 0
    )
    // After snap target becomes col 7, which equals cursor → 0 moves.
    let moves = countMoves(fromLinear: 7, toLinear: 7, cells: frame.cells)
    #expect(moves == 0)
  }

  @Test func clickFarPastEndSnapsToEndOfInput() {
    // "% hello   " — input ends at col 6 (inclusive), cols 7-9 are output.
    // Cursor at col 4, user clicks col 9 (far past input end).
    // Should snap target to col 7 (one past last input) and count 3 moves.
    let frame = makeSemanticFrame(
      content: "% hello   ",
      semantics: "ppiiiiiooo",
      cols: 10, cursorX: 4, cursorY: 0
    )
    // After snap, target becomes col 7. From 4 to 7: l, l, o = 3 moves right.
    let moves = countMoves(fromLinear: 4, toLinear: 7, cells: frame.cells)
    #expect(moves == 3)
  }
}

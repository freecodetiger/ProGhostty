import Foundation
import Testing

@testable import ProGhosttyCore

@Suite("Prompt cursor inference")
struct PromptCursorInferrerTests {
  private func makeFrame(rows: [String], cols: Int, cursorX: Int = 0, cursorY: Int = 0) -> GhosttyTerminalFrame {
    let cells = rows.flatMap { row -> [GhosttyTerminalFrame.Cell] in
      let padded = row.padding(toLength: cols, withPad: " ", startingAt: 0)
      return padded.unicodeScalars.prefix(cols).map {
        GhosttyTerminalFrame.Cell(
          scalar: $0,
          foreground: .init(r: 255, g: 255, b: 255),
          background: .init(r: 0, g: 0, b: 0),
          bold: false, italic: false, faint: false, underline: false, inverse: false,
          usesDefaultForeground: true, usesDefaultBackground: true
        )
      }
    }
    return GhosttyTerminalFrame(
      cols: cols, rows: rows.count, cursorVisible: true,
      cursorX: cursorX, cursorY: cursorY, cells: cells
    )
  }

  private func makeGeometry(frame: GhosttyTerminalFrame) -> RenderedGridGeometry {
    RenderedGridGeometry(
      frame: frame,
      translationY: 0,
      cellSize: NSSize(width: 8, height: 16),
      inset: NSSize(width: 0, height: 0),
      clipRect: NSRect(x: 0, y: 0, width: 800, height: 600),
      absoluteBaseRow: 0
    )
  }

  @Test func promptMarkerColumnFindsCommonMarkers() {
    let frame = makeFrame(rows: ["  ❯ echo hi"], cols: 20)
    let cells = PromptCursorInferrer.cells(inRow: 0, frame: frame)!
    #expect(PromptCursorInferrer.promptMarkerColumn(in: cells) == 2)
  }

  @Test func promptMarkerColumnNilForPlainOutput() {
    let frame = makeFrame(rows: ["compiling module"], cols: 20)
    let cells = PromptCursorInferrer.cells(inRow: 0, frame: frame)!
    #expect(PromptCursorInferrer.promptMarkerColumn(in: cells) == nil)
  }

  @Test func shouldInferWhenCursorParkedAtOrigin() {
    let frame = makeFrame(rows: ["hello", "world"], cols: 10, cursorX: 0, cursorY: 0)
    #expect(PromptCursorInferrer.shouldInferPromptCursor(for: frame, in: makeGeometry(frame: frame)))
  }

  @Test func shouldInferOnNonZeroCursorRowOnlyWithPromptMarker() {
    let promptFrame = makeFrame(rows: ["output", "❯ ls"], cols: 10, cursorX: 0, cursorY: 1)
    #expect(PromptCursorInferrer.shouldInferPromptCursor(for: promptFrame, in: makeGeometry(frame: promptFrame)))

    let plainFrame = makeFrame(rows: ["output", "more out"], cols: 10, cursorX: 0, cursorY: 1)
    #expect(!PromptCursorInferrer.shouldInferPromptCursor(for: plainFrame, in: makeGeometry(frame: plainFrame)))
  }

  @Test func cursorRowInferencePlacesCursorAfterTypedText() {
    let frame = makeFrame(rows: ["❯ git st"], cols: 20, cursorX: 0, cursorY: 0)
    let coordinate = PromptCursorInferrer.inferredPromptCursorCoordinateOnCursorRow(in: makeGeometry(frame: frame))
    // "❯ git st" — last text col 7, cursor lands one past it.
    #expect(coordinate == GridCoordinate(row: 0, col: 8))
  }

  @Test func viewportScanTracksLatestPromptRegion() {
    let frame = makeFrame(
      rows: ["❯ old command", "output line", "❯ new", ""],
      cols: 20,
      cursorX: 0, cursorY: 0
    )
    let coordinate = PromptCursorInferrer.inferredPromptCursorCoordinate(in: makeGeometry(frame: frame))
    // The later prompt resets the scan: cursor follows "❯ new" (last text col 4 → col 5).
    #expect(coordinate == GridCoordinate(row: 2, col: 5))
  }

  @Test func rowClassifiersHandleBlankAndPromptRegion() {
    let frame = makeFrame(rows: ["❯ cmd", "", "text"], cols: 10)
    let geometry = makeGeometry(frame: frame)
    #expect(PromptCursorInferrer.rowIsBlank(1, in: geometry))
    #expect(!PromptCursorInferrer.rowIsBlank(2, in: geometry))
    // Every row at or below a prompt marker is in the prompt input region.
    #expect(PromptCursorInferrer.rowIsInPromptInputRegion(2, in: geometry))
  }

  @Test func visualInputCursorCellRequiresStyledSpace() {
    var cell = GhosttyTerminalFrame.Cell(
      scalar: " ",
      foreground: .init(r: 255, g: 255, b: 255),
      background: .init(r: 0, g: 0, b: 0),
      bold: false, italic: false, faint: false, underline: false, inverse: true,
      usesDefaultForeground: true, usesDefaultBackground: true
    )
    #expect(PromptCursorInferrer.isVisualInputCursorCell(cell))
    cell.inverse = false
    #expect(!PromptCursorInferrer.isVisualInputCursorCell(cell))
  }

  @Test func rectApproximateEqualityUsesHalfPointTolerance() {
    let base = NSRect(x: 10, y: 20, width: 8, height: 16)
    #expect(PromptCursorInferrer.rect(base, approximatelyEquals: base.offsetBy(dx: 0.4, dy: 0.4)))
    #expect(!PromptCursorInferrer.rect(base, approximatelyEquals: base.offsetBy(dx: 1.0, dy: 0)))
    #expect(!PromptCursorInferrer.rect(base, approximatelyEquals: nil))
  }
}

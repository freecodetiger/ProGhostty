import Foundation
import Testing

@testable import ProGhosttyCore

@Suite("Grid selection model")
struct GridSelectionModelTests {
  private func makeGeometry(rows: Int, cols: Int, absoluteBaseRow: Int) -> RenderedGridGeometry {
    let cells = (0..<(rows * cols)).map { _ in
      GhosttyTerminalFrame.Cell(
        scalar: " ",
        foreground: .init(r: 255, g: 255, b: 255),
        background: .init(r: 0, g: 0, b: 0),
        bold: false, italic: false, faint: false, underline: false, inverse: false,
        usesDefaultForeground: true, usesDefaultBackground: true
      )
    }
    let frame = GhosttyTerminalFrame(
      cols: cols, rows: rows, cursorVisible: true,
      cursorX: 0, cursorY: 0, cells: cells
    )
    return RenderedGridGeometry(
      frame: frame,
      translationY: 0,
      cellSize: NSSize(width: 8, height: 16),
      inset: NSSize(width: 0, height: 0),
      clipRect: NSRect(x: 0, y: 0, width: 800, height: 600),
      absoluteBaseRow: absoluteBaseRow
    )
  }

  @Test func zeroWidthSelectionNormalizesToNil() {
    var selection = GridSelectionModel()
    selection.begin(at: GridSelectionPoint(absoluteRow: 3, col: 5))
    #expect(selection.normalizedPointRange() == nil)
  }

  @Test func normalizationOrdersReversedDrag() throws {
    let selection = GridSelectionModel(
      anchor: GridSelectionPoint(absoluteRow: 7, col: 2),
      head: GridSelectionPoint(absoluteRow: 4, col: 9)
    )
    let range = try #require(selection.normalizedPointRange())
    #expect(range.lower == GridSelectionPoint(absoluteRow: 4, col: 9))
    #expect(range.upper == GridSelectionPoint(absoluteRow: 7, col: 2))
  }

  @Test func viewportProjectionClampsOffscreenEndpointsToFullRows() throws {
    // Selection spans absolute rows 8...25; viewport shows rows 10...19 (base 10).
    let selection = GridSelectionModel(
      anchor: GridSelectionPoint(absoluteRow: 8, col: 4),
      head: GridSelectionPoint(absoluteRow: 25, col: 3)
    )
    let geometry = makeGeometry(rows: 10, cols: 80, absoluteBaseRow: 10)
    let range = try #require(selection.normalizedRange(in: geometry))
    // Both endpoints scrolled out: the visible span covers full rows edge to edge.
    #expect(range.lower == GridCoordinate(row: 0, col: 0))
    #expect(range.upper == GridCoordinate(row: 9, col: 79))
  }

  @Test func viewportProjectionKeepsInViewEndpointColumns() throws {
    let selection = GridSelectionModel(
      anchor: GridSelectionPoint(absoluteRow: 12, col: 4),
      head: GridSelectionPoint(absoluteRow: 14, col: 30)
    )
    let geometry = makeGeometry(rows: 10, cols: 80, absoluteBaseRow: 10)
    let range = try #require(selection.normalizedRange(in: geometry))
    #expect(range.lower == GridCoordinate(row: 2, col: 4))
    #expect(range.upper == GridCoordinate(row: 4, col: 30))
  }

  @Test func selectionFullyAboveViewportProjectsToNil() {
    let selection = GridSelectionModel(
      anchor: GridSelectionPoint(absoluteRow: 2, col: 0),
      head: GridSelectionPoint(absoluteRow: 5, col: 10)
    )
    let geometry = makeGeometry(rows: 10, cols: 80, absoluteBaseRow: 10)
    #expect(selection.normalizedRange(in: geometry) == nil)
  }

  @Test func isSelectedHonorsRangeBoundsInclusive() {
    let range = (lower: GridCoordinate(row: 1, col: 5), upper: GridCoordinate(row: 3, col: 2))
    #expect(GridSelectionModel.isSelected(row: 1, col: 5, in: range))
    #expect(GridSelectionModel.isSelected(row: 2, col: 0, in: range))
    #expect(GridSelectionModel.isSelected(row: 3, col: 2, in: range))
    #expect(!GridSelectionModel.isSelected(row: 1, col: 4, in: range))
    #expect(!GridSelectionModel.isSelected(row: 3, col: 3, in: range))
  }

  @Test func clearEmptiesBothEndpoints() {
    var selection = GridSelectionModel(
      anchor: GridSelectionPoint(absoluteRow: 1, col: 1),
      head: GridSelectionPoint(absoluteRow: 2, col: 2)
    )
    selection.clear()
    #expect(selection.anchor == nil)
    #expect(selection.head == nil)
  }
}

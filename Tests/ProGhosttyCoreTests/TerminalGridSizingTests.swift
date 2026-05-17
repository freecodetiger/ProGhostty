import CoreGraphics
import Testing

@testable import ProGhosttyCore

@Suite("Terminal grid sizing")
struct TerminalGridSizingTests {
  @Test func smallPixelWidthChangesInsideSameCellKeepSameGridSize() {
    let cellSize = CGSize(width: 9, height: 17)
    let inset = CGSize(width: 14, height: 12)
    let first = TerminalGridSizer.gridSize(
      for: CGSize(width: 972, height: 648),
      cellSize: cellSize,
      inset: inset,
      scale: 2
    )
    let second = TerminalGridSizer.gridSize(
      for: CGSize(width: 971, height: 648),
      cellSize: cellSize,
      inset: inset,
      scale: 2
    )

    #expect(first == second)
  }

  @Test func widthChangesThatCrossCellBoundaryProduceNewColumnCount() {
    let cellSize = CGSize(width: 9, height: 17)
    let inset = CGSize(width: 14, height: 12)
    let first = TerminalGridSizer.gridSize(
      for: CGSize(width: 972, height: 648),
      cellSize: cellSize,
      inset: inset,
      scale: 2
    )
    let second = TerminalGridSizer.gridSize(
      for: CGSize(width: 981, height: 648),
      cellSize: cellSize,
      inset: inset,
      scale: 2
    )

    #expect(second.cols == first.cols + 1)
    #expect(second.rows == first.rows)
  }
}

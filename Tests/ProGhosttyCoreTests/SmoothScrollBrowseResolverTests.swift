import CoreGraphics
import Foundation
import Testing

@testable import ProGhosttyCore

@Suite("Smooth scroll browse resolver")
struct SmoothScrollBrowseResolverTests {
  private let cellHeight: CGFloat = 22

  @Test func zeroPositionSitsOnAnchorWithNoOffset() {
    let r = SmoothScrollBrowseResolver.resolve(
      position: 0, cellHeight: cellHeight, anchorRow: 100, total: 500, visibleRows: 24)
    #expect(r.topAbsoluteRow == 100)
    #expect(r.pixelOffset == 0)
    #expect(!r.atTopEdge)
    #expect(!r.atBottomEdge)
  }

  @Test func positivePositionClimbsIntoHistory() {
    // 2.5 rows up from anchor 100 → top row 97 (anchor - 3 whole rows) with the
    // floor remainder revealing the bottom slice of row 96.
    let r = SmoothScrollBrowseResolver.resolve(
      position: 2.5 * cellHeight, cellHeight: cellHeight, anchorRow: 100, total: 500, visibleRows: 24)
    // floor(2.5) = 2 rows; top = 100 - 2 = 98, remainder 0.5*cellHeight.
    #expect(r.topAbsoluteRow == 98)
    #expect(abs(r.pixelOffset - 0.5 * cellHeight) < 0.001)
    #expect(!r.atTopEdge)
    #expect(!r.atBottomEdge)
  }

  @Test func pixelOffsetIsAlwaysNonNegativeAndSubRow() {
    for position in stride(from: -200.0, through: 200.0, by: 7.0) {
      let r = SmoothScrollBrowseResolver.resolve(
        position: position, cellHeight: cellHeight, anchorRow: 250, total: 500, visibleRows: 24)
      #expect(r.pixelOffset >= 0)
      #expect(r.pixelOffset < cellHeight)
    }
  }

  @Test func negativePositionMovesTowardBottom() {
    // Anchor mid-history, scroll DOWN 3 rows → top row increases by 3.
    let r = SmoothScrollBrowseResolver.resolve(
      position: -3 * cellHeight, cellHeight: cellHeight, anchorRow: 100, total: 500, visibleRows: 24)
    #expect(r.topAbsoluteRow == 103)
    #expect(r.pixelOffset == 0)
  }

  @Test func clampsAtTopEdgeAndDropsUpwardPeek() {
    // Anchor near top, scroll up well past row 0.
    let r = SmoothScrollBrowseResolver.resolve(
      position: 10 * cellHeight, cellHeight: cellHeight, anchorRow: 3, total: 500, visibleRows: 24)
    #expect(r.topAbsoluteRow == 0)
    #expect(r.pixelOffset == 0)
    #expect(r.atTopEdge)
    #expect(!r.atBottomEdge)
  }

  @Test func clampsAtBottomEdgeToLastPage() {
    // total 500, visible 24 → maxTop = 476. Anchor at 470, scroll down 20 rows.
    let r = SmoothScrollBrowseResolver.resolve(
      position: -20 * cellHeight, cellHeight: cellHeight, anchorRow: 470, total: 500, visibleRows: 24)
    #expect(r.topAbsoluteRow == 476)
    #expect(r.pixelOffset == 0)
    #expect(r.atBottomEdge)
    #expect(!r.atTopEdge)
  }

  @Test func topRowZeroWithSubRowPeekIsAllowedWhenNotClampedPastEdge() {
    // Anchor at row 1, scroll up just under one row: rawTop stays 0 with a peek
    // would push above 0, so it clamps to the top edge (row 0, no peek).
    let r = SmoothScrollBrowseResolver.resolve(
      position: 0.5 * cellHeight, cellHeight: cellHeight, anchorRow: 1, total: 500, visibleRows: 24)
    // floor(0.5) = 0 → top = 1, remainder 0.5 row. Row 1 with peek of row 0. Fine.
    #expect(r.topAbsoluteRow == 1)
    #expect(abs(r.pixelOffset - 0.5 * cellHeight) < 0.001)
    #expect(!r.atTopEdge)
  }

  @Test func degenerateInputsAreSafe() {
    let zeroCell = SmoothScrollBrowseResolver.resolve(
      position: 100, cellHeight: 0, anchorRow: 5, total: 500, visibleRows: 24)
    #expect(zeroCell.topAbsoluteRow == 5)
    #expect(zeroCell.pixelOffset == 0)

    let empty = SmoothScrollBrowseResolver.resolve(
      position: 100, cellHeight: cellHeight, anchorRow: 0, total: 0, visibleRows: 24)
    #expect(empty.topAbsoluteRow == 0)
  }

  @Test func shortScrollbackShorterThanViewportPinsToZero() {
    // total 10 rows, viewport 24 → maxTop clamps to 0; any scroll stays at 0.
    let r = SmoothScrollBrowseResolver.resolve(
      position: -5 * cellHeight, cellHeight: cellHeight, anchorRow: 0, total: 10, visibleRows: 24)
    #expect(r.topAbsoluteRow == 0)
    #expect(r.atBottomEdge)
  }
}

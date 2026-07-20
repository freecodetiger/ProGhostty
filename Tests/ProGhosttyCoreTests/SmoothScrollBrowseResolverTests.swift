import CoreGraphics
import Foundation
import Testing

@testable import ProGhosttyCore

@Suite("Smooth scroll browse resolver")
struct SmoothScrollBrowseResolverTests {
  private let cellHeight: CGFloat = 22

  @Test func zeroPositionSitsAtAnchorAndReportsBottom() {
    // position == 0 means "at the anchor". When the caller anchored at the live
    // tail, that is the bottom → atBottomEdge signals resume-follow.
    let r = SmoothScrollBrowseResolver.resolve(
      position: 0, cellHeight: cellHeight, anchorRow: 100, total: 500, visibleRows: 24)
    #expect(r.topAbsoluteRow == 100)
    #expect(r.pixelOffset == 0)
    #expect(!r.atTopEdge)
    #expect(r.atBottomEdge)
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

  @Test func negativePositionIsBottomFollow() {
    // Any position ≤ 0 means the user scrolled back to/below the anchor. When
    // anchored at the live tail this is "at bottom" → resume follow, top pinned
    // to the anchor (clamped to the last page).
    let r = SmoothScrollBrowseResolver.resolve(
      position: -3 * cellHeight, cellHeight: cellHeight, anchorRow: 100, total: 500, visibleRows: 24)
    #expect(r.topAbsoluteRow == 100)
    #expect(r.pixelOffset == 0)
    #expect(r.atBottomEdge)
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

  @Test func negativePositionClampsToLastPageAndFollows() {
    // Scroll down (position < 0) with anchor already near the tail: report the
    // anchor clamped to the last page, atBottomEdge (follow), decoupled from total.
    let r = SmoothScrollBrowseResolver.resolve(
      position: -20 * cellHeight, cellHeight: cellHeight, anchorRow: 470, total: 500, visibleRows: 24)
    #expect(r.topAbsoluteRow == 470)
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

  @Test func returnToBottomReachableUnderGrowingTail() {
    // Regression: anchored at the live tail, the user scrolls up into history
    // while a flood of output grows `total` far past the anchor. Scrolling back
    // down (position → 0) must still report atBottomEdge (follow) — the old
    // total-derived bottom test made this unreachable and stranded the view in
    // history with the live cursor off-screen.
    let anchor: UInt64 = 1976  // total 2000 - visible 24 at gesture start
    // Up into history:
    let up = SmoothScrollBrowseResolver.resolve(
      position: 30 * cellHeight, cellHeight: cellHeight, anchorRow: anchor, total: 5000, visibleRows: 24)
    #expect(!up.atBottomEdge)
    #expect(up.topAbsoluteRow == anchor - 30)
    // Back down to the anchor, even though total ballooned to 5000:
    let down = SmoothScrollBrowseResolver.resolve(
      position: -1, cellHeight: cellHeight, anchorRow: anchor, total: 5000, visibleRows: 24)
    #expect(down.atBottomEdge)
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

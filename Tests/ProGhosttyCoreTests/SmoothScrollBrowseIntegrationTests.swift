import AppKit
import CoreGraphics
import Foundation
import Testing

@testable import ProGhosttyCore

/// Integration coverage for the pattern-2 display-link browse seam: a gesture
/// starts browsing, and each manual tick resolves a top absolute row + sub-row
/// offset and drives the present handler, WITHOUT moving any VT viewport.
@Suite("Pattern-2 smooth scroll browse")
@MainActor
struct SmoothScrollBrowseIntegrationTests {
  private func makeView() -> MetalDirectRendererView {
    let view = MetalDirectRendererView(device: nil)
    view.applyRendererOptions(TerminalRendererOptions(smoothPixelScrollingEnabled: true))
    // Seed a viewport frame so cellSize/rows are meaningful.
    view.render(
      frame(rows: Array(repeating: "hello", count: 24), cols: 8, cursorY: 0),
      isFocused: true
    )
    return view
  }

  private func frame(rows: [String], cols: Int, cursorY: Int) -> GhosttyTerminalFrame {
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
      cursorX: 0, cursorY: cursorY, cells: cells
    )
  }

  @Test func tickDrivesPresentWithResolvedTopRowAndSetsSubRowOffset() {
    let view = makeView()
    // Following the live tail: total 1000, visible 24 → anchor at bottom page 976.
    view.browseScrollMetricsHandler = { (total: 1000, topAbsoluteRow: 976) }
    var presented: [(top: UInt64, visible: Int)] = []
    view.browsePresentHandler = { top, visible in presented.append((top, visible)) }

    // Scroll UP into history.
    view.testBeginSmoothScroll(delta: 40, time: 0)
    #expect(view.testIsSmoothScrollBrowsing)

    var t = 0.0
    for _ in 0..<30 { t += 1.0 / 120.0; view.testTickSmoothScroll(now: t) }

    #expect(!presented.isEmpty)
    // Climbing into history moves the top row below the bottom-page anchor (976).
    #expect(presented.last!.top < 976)
    #expect(presented.last!.visible == 24)
    // The sub-row offset the tick set is in [0, cellHeight).
    #expect(view.viewport.visualOffsetY >= 0)
    #expect(view.viewport.visualOffsetY < view.terminalCellSize.height)
  }

  @Test func scrollActivityHandlerFlipsAroundGesture() {
    let view = makeView()
    view.browseScrollMetricsHandler = { (total: 1000, topAbsoluteRow: 200) }
    view.browsePresentHandler = { _, _ in }
    var activity: [Bool] = []
    view.scrollActivityHandler = { activity.append($0) }

    view.testBeginSmoothScroll(delta: 40, time: 0)
    #expect(activity.first == true)

    // Build a little velocity, release, then coast to rest.
    var t = 0.0
    for _ in 0..<5 { t += 1.0 / 120.0; view.testTickSmoothScroll(now: t) }
    view.testEndSmoothScroll(time: t)

    var ticks = 0
    while view.testIsSmoothScrollBrowsing, ticks < 3000 {
      t += 1.0 / 120.0
      view.testTickSmoothScrollWithStop(now: t)
      ticks += 1
    }
    #expect(ticks < 3000)
    #expect(!view.testIsSmoothScrollBrowsing)
    #expect(activity.last == false)
  }

  @Test func scrollingDownAtBottomResumesFollowInsteadOfPresentingHistory() {
    let view = makeView()
    // total 30, visible 24 → already following near the tail. Scroll DOWN.
    view.browseScrollMetricsHandler = { (total: 30, topAbsoluteRow: 6) }
    var presentedHistory = false
    var resumedFollow = false
    view.browsePresentHandler = { _, _ in presentedHistory = true }
    view.browseFollowResumeHandler = { resumedFollow = true }

    view.testBeginSmoothScroll(delta: -80, time: 0)
    var t = 0.0
    for _ in 0..<10 { t += 1.0 / 120.0; view.testTickSmoothScroll(now: t) }

    // Scrolling down at the tail resumes follow (renders live frame), never
    // strands the view in a history window.
    #expect(resumedFollow)
    #expect(!presentedHistory)
    #expect(view.testBrowseTopRow == nil)
  }

  @Test func settledHistoryPositionPersistsAndKeepsViewingHistory() {
    let view = makeView()
    view.browseScrollMetricsHandler = { (total: 1000, topAbsoluteRow: 976) }
    view.browsePresentHandler = { _, _ in }

    // Scroll up well into history and settle.
    view.testBeginSmoothScroll(delta: 200, time: 0)
    var t = 0.0
    for _ in 0..<40 { t += 1.0 / 120.0; view.testTickSmoothScroll(now: t) }

    #expect(view.testBrowseTopRow != nil)
    #expect(view.testBrowseTopRow! < 976)
    // Persisted browse row keeps the surface "viewing history" even if the
    // sub-row offset happens to be ~0.
    #expect(view.isViewingHistory)
  }

  @Test func reachingBottomClearsBrowsePositionToFollow() {
    let view = makeView()
    // Start already settled in history at row 100.
    view.browseScrollMetricsHandler = { (total: 200, topAbsoluteRow: 176) }
    view.browsePresentHandler = { _, _ in }
    view.testBeginSmoothScroll(delta: 100, time: 0)
    var t = 0.0
    for _ in 0..<30 { t += 1.0 / 120.0; view.testTickSmoothScroll(now: t) }
    #expect(view.testBrowseTopRow != nil)

    // Now scroll hard toward the bottom; reaching the last page resumes follow.
    view.testBeginSmoothScroll(delta: -400, time: t)
    for _ in 0..<30 { t += 1.0 / 120.0; view.testTickSmoothScroll(now: t) }
    #expect(view.testBrowseTopRow == nil)
    #expect(!view.isViewingHistory)
  }

  @Test func scrollingDownThroughHistoryReachesLiveBottomNotFalseFloor() {
    // Mid-history park must still be able to walk the remaining rows down to
    // the live page. A frozen/underestimated maxTop used to stop early with
    // content still below.
    let view = makeView()
    view.browseScrollMetricsHandler = { (total: 1000, topAbsoluteRow: 976) }
    var presented: [UInt64] = []
    var resumedFollow = false
    view.browsePresentHandler = { top, _ in presented.append(top) }
    view.browseFollowResumeHandler = { resumedFollow = true }

    // Climb into history and settle somewhere above the live page.
    view.testBeginSmoothScroll(delta: 800, time: 0)
    var t = 0.0
    for _ in 0..<80 { t += 1.0 / 120.0; view.testTickSmoothScroll(now: t) }
    let parked = view.testBrowseTopRow
    #expect(parked != nil)
    #expect(parked! < 976)

    // Strong downward scroll should walk remaining history and resume follow —
    // not freeze on a false floor above the live page.
    resumedFollow = false
    presented.removeAll()
    view.testBeginSmoothScroll(delta: -3000, time: t)
    for _ in 0..<120 { t += 1.0 / 120.0; view.testTickSmoothScroll(now: t) }

    #expect(resumedFollow)
    #expect(view.testBrowseTopRow == nil)
  }

  @Test func smallDownwardFlickFromParkedHistoryDoesNotSnapToBottom() {
    // Regression: parked history used to re-anchor at the parked row with
    // position reset to 0, so ANY downward delta made position ≤ 0 and
    // snapped to live follow. Seed distance-from-bottom instead.
    let view = makeView()
    view.browseScrollMetricsHandler = { (total: 1000, topAbsoluteRow: 976) }
    view.browsePresentHandler = { _, _ in }
    var resumedFollow = false
    view.browseFollowResumeHandler = { resumedFollow = true }

    // Climb well into history and settle.
    view.testBeginSmoothScroll(delta: 400, time: 0)
    var t = 0.0
    for _ in 0..<50 { t += 1.0 / 120.0; view.testTickSmoothScroll(now: t) }
    let parked = view.testBrowseTopRow
    #expect(parked != nil)
    #expect(parked! < 976)

    // Small downward flick — far less than the distance back to the live tail.
    resumedFollow = false
    view.testBeginSmoothScroll(delta: -20, time: t)
    for _ in 0..<20 { t += 1.0 / 120.0; view.testTickSmoothScroll(now: t) }

    #expect(!resumedFollow)
    #expect(view.testBrowseTopRow != nil)
    // Still above the live bottom page; may have moved a bit toward it.
    #expect(view.testBrowseTopRow! < 976)
    #expect(view.isViewingHistory)
  }

  @Test func resetPixelScrollReturnsToFollow() {
    let view = makeView()
    view.browseScrollMetricsHandler = { (total: 1000, topAbsoluteRow: 976) }
    view.browsePresentHandler = { _, _ in }
    view.testBeginSmoothScroll(delta: 200, time: 0)
    var t = 0.0
    for _ in 0..<20 { t += 1.0 / 120.0; view.testTickSmoothScroll(now: t) }
    #expect(view.testBrowseTopRow != nil)

    view.resetPixelScroll()
    #expect(view.testBrowseTopRow == nil)
    #expect(!view.isViewingHistory)
    #expect(!view.testIsSmoothScrollBrowsing)
  }

  // MARK: Hit-testing red line

  /// A browse present builds a scroll frame with one overscan row above
  /// `topAbsoluteRow` and `viewportStartRow == topAbsoluteRow`. The geometry the
  /// view reports for hit-testing must place absolute row `topAbsoluteRow` at
  /// viewport row 0 and shift it down by the sub-row offset P — the same
  /// `(topAbsoluteRow, P)` the renderer draws.
  @Test func geometryMatchesBrowsePresentTopRowAndOffset() {
    let view = makeView()
    let cols = 8
    let topAbsoluteRow: UInt64 = 300
    let visible = 24
    let pixelOffset: CGFloat = 7

    // Mirror presentBrowseWindow's scroll-frame shape: 1 overscan row above
    // (absolute topAbsoluteRow-1), visible viewport rows, 1 overscan below.
    let scrollFrame = GhosttyTerminalScrollFrame(
      viewport: frame(rows: Array(repeating: "row", count: visible), cols: cols, cursorY: 0),
      overscanTop: [cellRow("above", cols: cols)],
      overscanBottom: [cellRow("below", cols: cols)],
      requestedOverscanTop: 1,
      requestedOverscanBottom: 1,
      viewportStartRow: topAbsoluteRow
    )
    // The display-link tick sets the sub-row offset before the present lands.
    view.testSetViewportOffsetForTests(pixelOffset)
    view.render(scrollFrame, isFocused: true, dirty: CellGridDirtyResult(mode: .full, rows: Set(0..<visible)))

    guard let geo = view.testRenderedGeometry() else {
      Issue.record("no geometry")
      return
    }
    // absoluteBaseRow is the overscan row (topAbsoluteRow - 1).
    #expect(geo.absoluteBaseRow == Int(topAbsoluteRow) - 1)
    // Viewport row 0 (first visible row, after the overscan row) is topAbsoluteRow.
    #expect(view.testAbsoluteRow(forViewportRow: 0) == Int(topAbsoluteRow))
    #expect(view.testAbsoluteRow(forViewportRow: 5) == Int(topAbsoluteRow) + 5)
    // Translation = -overscanTop(1)*cellH + P (the same the renderer applies).
    let expected = -view.terminalCellSize.height + pixelOffset
    #expect(abs(geo.translationY - expected) < 0.001)
  }

  private func cellRow(_ text: String, cols: Int) -> GhosttyTerminalCellRow {
    let padded = text.padding(toLength: cols, withPad: " ", startingAt: 0)
    return GhosttyTerminalCellRow(cells: padded.unicodeScalars.prefix(cols).map {
      GhosttyTerminalFrame.Cell(
        scalar: $0,
        foreground: .init(r: 255, g: 255, b: 255),
        background: .init(r: 0, g: 0, b: 0),
        bold: false, italic: false, faint: false, underline: false, inverse: false,
        usesDefaultForeground: true, usesDefaultBackground: true
      )
    })
  }
}

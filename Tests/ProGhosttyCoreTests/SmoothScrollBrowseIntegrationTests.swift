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
    // Anchor mid-history at row 200, plenty of scrollback below and above.
    view.browseScrollMetricsHandler = { (total: 1000, topAbsoluteRow: 200) }
    var presented: [(top: UInt64, visible: Int)] = []
    view.browsePresentHandler = { top, visible in presented.append((top, visible)) }

    // Scroll UP into history.
    view.testBeginSmoothScroll(delta: 40, time: 0)
    #expect(view.testIsSmoothScrollBrowsing)

    var t = 0.0
    for _ in 0..<30 { t += 1.0 / 120.0; view.testTickSmoothScroll(now: t) }

    #expect(!presented.isEmpty)
    // Climbing into history moves the top row below the anchor (200).
    #expect(presented.last!.top < 200)
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

  @Test func bottomEdgeClampDoesNotOvershoot() {
    let view = makeView()
    // total 30, visible 24 → maxTop 6. Anchor at 6 (already bottom), scroll down.
    view.browseScrollMetricsHandler = { (total: 30, topAbsoluteRow: 6) }
    var lastTop: UInt64 = .max
    view.browsePresentHandler = { top, _ in lastTop = top }

    view.testBeginSmoothScroll(delta: -80, time: 0)
    var t = 0.0
    for _ in 0..<10 { t += 1.0 / 120.0; view.testTickSmoothScroll(now: t) }

    // Never past the last page.
    #expect(lastTop <= 6)
  }
}

import Foundation
import Testing

@testable import ProGhosttyCore

@Suite("Markdown preview float layout")
struct MarkdownPreviewLayoutTests {
  @Test func initialFrameSitsAtTopRightInsideContainer() {
    let frame = MarkdownPreviewLayout.initialFrame(in: CGSize(width: 1200, height: 800))
    #expect(frame.maxX <= 1200)
    #expect(frame.minX >= 0)
    #expect(frame.maxY <= 800)
    #expect(frame.minY >= 0)
    // Top-right placement: right edge near the container's right edge, top near the top.
    #expect(frame.maxX > 1000)
    #expect(frame.maxY > 700)
    // Reading-measure width.
    #expect(frame.width == MarkdownPreviewLayout.defaultWidth)
  }

  @Test func initialFrameDoesNotReachBottomInputArea() {
    // Top-right placement leaves the bottom of the container clear, so the
    // float never covers the bottom input rows (~40pt ≈ 2–3 terminal rows).
    let frame = MarkdownPreviewLayout.initialFrame(in: CGSize(width: 1200, height: 800))
    #expect(frame.minY >= 40)
  }

  @Test func initialFrameAnchorsToPaneTopRight() {
    let pane = CGRect(x: 0, y: 0, width: 600, height: 800)
    let frame = MarkdownPreviewLayout.initialFrame(in: CGSize(width: 1200, height: 800), anchoredTo: pane)
    // Anchored to the pane's top-right (y-up): right edge at pane.maxX, top at pane.maxY.
    #expect(abs(frame.maxX - pane.maxX) < 0.001)
    #expect(abs(frame.maxY - pane.maxY) < 0.001)
  }

  @Test func clampsFullyOutsideContainer() {
    let frame = CGRect(x: -100, y: -100, width: 400, height: 300)
    let clamped = MarkdownPreviewLayout.clamped(frame, in: CGSize(width: 800, height: 600))
    #expect(clamped.minX >= 0)
    #expect(clamped.minY >= 0)
    #expect(clamped.maxX <= 800)
    #expect(clamped.maxY <= 600)
    #expect(clamped.width == 400)
    #expect(clamped.height == 300)
  }

  @Test func clampsOversizedFrameToContainerSize() {
    let frame = CGRect(x: 100, y: 100, width: 2000, height: 2000)
    let clamped = MarkdownPreviewLayout.clamped(frame, in: CGSize(width: 800, height: 600))
    #expect(clamped.width == 800)
    #expect(clamped.height == 600)
    #expect(clamped.minX == 0)
    #expect(clamped.minY == 0)
  }

  @Test func movedStaysInsideContainer() {
    let frame = CGRect(x: 700, y: 500, width: 300, height: 200)
    let moved = MarkdownPreviewLayout.moved(frame, by: CGSize(width: 100, height: 100), in: CGSize(width: 800, height: 600))
    #expect(moved.maxX == 800)
    #expect(moved.maxY == 600)
  }

  @Test func resizeBottomRightAnchorsTopLeftAndEnforcesMinimum() {
    // Bottom-right corner drag: left edge (minX) and top edge (maxY) stay
    // fixed; maxX / minY follow the mouse. Over-shrink clamps to the minimum
    // by pushing the moving edges outward.
    let frame = CGRect(x: 100, y: 100, width: 300, height: 200) // maxX=400, maxY=300
    let resized = MarkdownPreviewLayout.resized(
      frame,
      by: CGSize(width: -500, height: 50),
      from: .bottomRight,
      minimumSize: CGSize(width: 200, height: 150),
      in: CGSize(width: 800, height: 600)
    )
    #expect(resized.minX == 100) // left edge fixed
    #expect(resized.maxY == 300) // top edge fixed
    #expect(resized.width == 200) // clamped to minimum (maxX pushed back to 300)
    #expect(resized.height == 150) // minY moved 100 → 150, min height held
    #expect(resized.minY == 150)
  }

  @Test func resizeRightEdgeMovesOnlyTheRightEdge() {
    let frame = CGRect(x: 100, y: 100, width: 300, height: 200)
    let resized = MarkdownPreviewLayout.resized(
      frame,
      by: CGSize(width: 50, height: 0),
      from: .right,
      minimumSize: CGSize(width: 200, height: 150),
      in: CGSize(width: 800, height: 600)
    )
    #expect(resized == CGRect(x: 100, y: 100, width: 350, height: 200))
  }

  @Test func resizeTopLeftMovesTopAndLeftEdges() {
    // Top-left corner drag: bottom (minY) and right (maxX) edges stay fixed;
    // minX / maxY follow the mouse.
    let frame = CGRect(x: 100, y: 100, width: 300, height: 200) // maxX=400, maxY=300
    let resized = MarkdownPreviewLayout.resized(
      frame,
      by: CGSize(width: 30, height: 40),
      from: .topLeft,
      minimumSize: CGSize(width: 200, height: 150),
      in: CGSize(width: 800, height: 600)
    )
    #expect(resized.minX == 130)
    #expect(resized.maxX == 400) // right edge fixed
    #expect(resized.minY == 100) // bottom edge fixed
    #expect(resized.maxY == 340)
    #expect(resized.width == 270)
    #expect(resized.height == 240)
  }

  @Test func miniCardIsCenteredOnGrabPointAndInsideContainer() {
    let card = MarkdownPreviewLayout.miniCardFrame(grabbedAt: CGPoint(x: 600, y: 400), container: CGSize(width: 1200, height: 800))
    // Centered on the grab point.
    #expect(abs(card.midX - 600) < 0.001)
    #expect(abs(card.midY - 400) < 0.001)
    // Fully inside the container.
    #expect(card.minX >= 0)
    #expect(card.maxX <= 1200)
    #expect(card.minY >= 0)
    #expect(card.maxY <= 800)
  }

  @Test func miniCardSizeIsCompact() {
    let card = MarkdownPreviewLayout.miniCardFrame(grabbedAt: CGPoint(x: 600, y: 400), container: CGSize(width: 1200, height: 800))
    #expect(card.width <= 320)
    #expect(card.height <= 250)
  }

  @Test func miniCardClampsNearContainerEdge() {
    // Grab at the top-left corner: the card is pushed fully inside.
    let card = MarkdownPreviewLayout.miniCardFrame(grabbedAt: CGPoint(x: 0, y: 800), container: CGSize(width: 1200, height: 800))
    #expect(card.minX >= 0)
    #expect(card.maxY <= 800)
  }

  @Test func miniCardTopAnchorKeepsCursorOnTheHandle() {
    // A handle grab anchors the card's grab handle (which sits handleGrabOffset
    // below the top edge) to the cursor, so the mouse rests on the three dots —
    // not on the top edge (a resize zone).
    let card = MarkdownPreviewLayout.miniCardFrame(
      grabbedAt: CGPoint(x: 600, y: 600),
      container: CGSize(width: 1200, height: 800),
      anchor: .top
    )
    #expect(abs((card.maxY - MarkdownPreviewLayout.handleGrabOffset) - 600) < 0.001) // handle under the cursor
    #expect(abs(card.midX - 600) < 0.001) // centered horizontally
    #expect(card.minY >= 0) // inside the container
  }

  @Test func snapTargetFindsPanelContainingFloatCenter() {
    let panels = [
      CGRect(x: 0, y: 0, width: 500, height: 600),
      CGRect(x: 500, y: 0, width: 500, height: 600),
    ]
    // Float's center inside the right panel → dock there.
    let float = CGRect(x: 620, y: 200, width: 280, height: 180)
    #expect(MarkdownPreviewLayout.snapTarget(for: float, panels: panels) == 1)
  }

  @Test func snapTargetAppliesThresholdNearPanelEdge() {
    let panels = [
      CGRect(x: 0, y: 0, width: 500, height: 600),
      CGRect(x: 500, y: 0, width: 500, height: 600),
    ]
    // Float center just outside the right panel (within threshold) → still snaps.
    let nearEdge = CGRect(x: 492, y: 200, width: 280, height: 180) // center x=632
    #expect(MarkdownPreviewLayout.snapTarget(for: nearEdge, panels: panels) == 1)
  }

  @Test func snapTargetReturnsNilWhenNotOverAnyPanel() {
    let panels = [CGRect(x: 0, y: 0, width: 500, height: 600)]
    // Float center far from the panel (beyond threshold) → no target.
    let far = CGRect(x: 3000, y: 3000, width: 280, height: 180)
    #expect(MarkdownPreviewLayout.snapTarget(for: far, panels: panels) == nil)
  }

  @Test func snapTargetRequiresAtLeastTwoPanels() {
    // Single panel: docking would cover the whole terminal — never a target.
    let panel = CGRect(x: 0, y: 0, width: 1200, height: 800)
    let float = CGRect(x: 460, y: 310, width: 280, height: 180) // center well inside
    #expect(MarkdownPreviewLayout.snapTarget(for: float, panels: [panel]) == nil)
  }

  @Test func dockedFrameMatchesPanelSlightlyInset() {
    let panel = CGRect(x: 500, y: 100, width: 500, height: 600)
    let docked = MarkdownPreviewLayout.dockedFrame(for: panel)
    #expect(docked == panel.insetBy(dx: 1, dy: 1))
  }
}

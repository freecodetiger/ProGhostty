import AppKit
import Testing

@testable import ProGhosttyApp
import ProGhosttyCore

@MainActor
@Suite("Pane split availability")
struct PaneSplitAvailabilityControllerTests {
  @Test func unknownPaneDefaultsToSplittable() {
    let controller = PaneSplitAvailabilityController()
    #expect(controller.canSplit(UUID(), axis: .horizontal))
    #expect(controller.canSplit(UUID(), axis: .vertical))
  }

  @Test func updateGatesSplitPerAxis() {
    let controller = PaneSplitAvailabilityController()
    let pane = UUID()
    controller.update(pane, size: NSSize(width: 900, height: 500), canSplitRight: true, canSplitDown: false)
    #expect(controller.canSplit(pane, axis: .horizontal))
    #expect(!controller.canSplit(pane, axis: .vertical))
  }

  @Test func removeRestoresDefaultSplittable() {
    let controller = PaneSplitAvailabilityController()
    let pane = UUID()
    controller.update(pane, size: NSSize(width: 10, height: 10), canSplitRight: false, canSplitDown: false)
    controller.remove(paneID: pane)
    #expect(controller.canSplit(pane, axis: .horizontal))
  }

  @Test func childPaneSizesSplitHorizontallyShareWidthMinusDivider() throws {
    let sizes = try #require(
      PaneSplitAvailabilityController.childPaneSizesAfterSplit(
        size: NSSize(width: 801, height: 400),
        axis: .horizontal
      )
    )
    #expect(sizes.first.height == 400)
    #expect(sizes.second.height == 400)
    #expect(sizes.first.width + sizes.second.width == 800)
  }

  @Test func childPaneSizesSplitVerticallyShareHeightMinusDivider() throws {
    let sizes = try #require(
      PaneSplitAvailabilityController.childPaneSizesAfterSplit(
        size: NSSize(width: 640, height: 481),
        axis: .vertical
      )
    )
    #expect(sizes.first.width == 640)
    #expect(sizes.second.width == 640)
    #expect(sizes.first.height + sizes.second.height == 480)
  }

  @Test func seedAfterSplitProjectsBothChildren() {
    let controller = PaneSplitAvailabilityController()
    let original = UUID()
    let child = UUID()
    controller.update(original, size: NSSize(width: 1200, height: 800), canSplitRight: true, canSplitDown: true)
    controller.seedAfterSplit(originalPaneID: original, newPaneID: child, axis: .horizontal)
    // Both halves of a 1200pt-wide pane remain comfortably splittable.
    #expect(controller.canSplit(original, axis: .horizontal))
    #expect(controller.canSplit(child, axis: .horizontal))
  }
}

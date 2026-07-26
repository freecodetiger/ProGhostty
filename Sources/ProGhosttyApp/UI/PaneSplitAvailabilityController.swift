import AppKit
import ProGhosttyCore

/// Sole owner of per-pane split-availability state and its geometry.
///
/// Extracted from `AppModel` (debt spec 3-3). Panes report their measured
/// bounds via `update`; split gating asks `canSplit`; after a split the two
/// child sizes are projected with `SplitRatioLayout` so gating stays accurate
/// before the next layout pass reports real bounds.
@MainActor
final class PaneSplitAvailabilityController {
  struct Availability: Equatable {
    var size: NSSize
    var canSplitRight: Bool
    var canSplitDown: Bool

    func allows(axis: TerminalSplitAxis) -> Bool {
      switch axis {
      case .horizontal:
        canSplitRight
      case .vertical:
        canSplitDown
      }
    }
  }

  private var availabilityByPane: [UUID: Availability] = [:]

  func update(_ paneID: UUID, size: NSSize, canSplitRight: Bool, canSplitDown: Bool) {
    let availability = Availability(size: size, canSplitRight: canSplitRight, canSplitDown: canSplitDown)
    guard availabilityByPane[paneID] != availability else { return }
    availabilityByPane[paneID] = availability
    DebugLog.write("pane split availability pane=\(paneID) size=\(size) right=\(canSplitRight) down=\(canSplitDown)")
  }

  /// Unknown panes default to splittable; the first layout pass reports real bounds.
  func canSplit(_ paneID: UUID, axis: TerminalSplitAxis) -> Bool {
    guard let availability = availabilityByPane[paneID] else { return true }
    return availability.allows(axis: axis)
  }

  func seedAfterSplit(originalPaneID: UUID, newPaneID: UUID, axis: TerminalSplitAxis) {
    guard
      let previous = availabilityByPane[originalPaneID],
      let sizes = Self.childPaneSizesAfterSplit(size: previous.size, axis: axis)
    else {
      return
    }
    availabilityByPane[originalPaneID] = Self.availability(for: sizes.first)
    availabilityByPane[newPaneID] = Self.availability(for: sizes.second)
    DebugLog.write("pane split availability seeded original=\(originalPaneID) new=\(newPaneID) axis=\(axis)")
  }

  func remove(paneID: UUID) {
    availabilityByPane[paneID] = nil
  }

  func remove(for panes: [TerminalPane]) {
    for pane in panes {
      availabilityByPane[pane.paneId] = nil
    }
  }

  // MARK: Pure geometry

  static func childPaneSizesAfterSplit(
    size: NSSize,
    axis: TerminalSplitAxis
  ) -> (first: NSSize, second: NSSize)? {
    let dividerThickness = 1.0
    switch axis {
    case .horizontal:
      guard let firstWidth = SplitRatioLayout.safeFirstLength(
        totalLength: Double(size.width),
        dividerThickness: dividerThickness,
        ratio: 0.5
      ) else {
        return nil
      }
      let secondWidth = max(0, Double(size.width) - dividerThickness - firstWidth)
      return (
        NSSize(width: firstWidth, height: Double(size.height)),
        NSSize(width: secondWidth, height: Double(size.height))
      )
    case .vertical:
      guard let firstHeight = SplitRatioLayout.safeFirstLength(
        totalLength: Double(size.height),
        dividerThickness: dividerThickness,
        ratio: 0.5
      ) else {
        return nil
      }
      let secondHeight = max(0, Double(size.height) - dividerThickness - firstHeight)
      return (
        NSSize(width: Double(size.width), height: firstHeight),
        NSSize(width: Double(size.width), height: secondHeight)
      )
    }
  }

  static func availability(for size: NSSize) -> Availability {
    Availability(
      size: size,
      canSplitRight: SplitRatioLayout.canSplit(totalLength: Double(size.width), dividerThickness: 1),
      canSplitDown: SplitRatioLayout.canSplit(totalLength: Double(size.height), dividerThickness: 1)
    )
  }
}

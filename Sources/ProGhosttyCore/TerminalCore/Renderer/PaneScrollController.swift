import CoreGraphics
import Foundation

/// Single owner of pixel-scroll decision state for one pane.
///
/// Wraps the two value-type coordinators — `PaneScrollCoordinator` (wheel→row
/// physics + sub-row pixel remainder) and `ScrollCommitCoordinator` (row-commit
/// coalescing) — plus the pure judgments and commit timing that used to live
/// scattered across `PTYGridView`. The view still owns the `TerminalViewport`
/// (it drives drawing, the Metal accessor, and NSView invalidation side
/// effects) and applies the effects this type reports; this type owns *whether*
/// and *what* to scroll/commit, not the display state.
public struct PaneScrollController: Sendable {
  /// Row commits are coalesced and flushed at ~120 Hz.
  public static let commitInterval: TimeInterval = 1.0 / 120.0

  private var physics: PaneScrollCoordinator
  private var commit: ScrollCommitCoordinator

  public init(
    physics: PaneScrollCoordinator = PaneScrollCoordinator(),
    commit: ScrollCommitCoordinator = ScrollCommitCoordinator()
  ) {
    self.physics = physics
    self.commit = commit
  }

  // MARK: Diagnostics reads

  public var pixelRemainderY: CGFloat { physics.pixelRemainderY }
  public var lastCommittedRowDelta: Int { physics.lastCommittedRowDelta }
  public var coalescedWheelEvents: Int { physics.coalescedWheelEvents }
  public var isPixelScrollActive: Bool { physics.isPixelScrollActive }
  public var lastDisabledReason: String { physics.lastDisabledReason }
  public var pendingRowDelta: Int { commit.pendingRowDelta }
  public var pendingWheelEvents: Int { commit.pendingWheelEvents }
  public var hasPendingCommit: Bool { commit.hasPendingCommit }

  // MARK: Physics

  @discardableResult
  public mutating func scroll(
    deltaY: CGFloat,
    cellHeight: CGFloat,
    alternateScreen: Bool,
    smoothPixelScrollingEnabled: Bool,
    hasOverscanRowsForProjectedRemainder: Bool
  ) -> PaneScrollDecision {
    physics.scroll(
      deltaY: deltaY,
      cellHeight: cellHeight,
      alternateScreen: alternateScreen,
      smoothPixelScrollingEnabled: smoothPixelScrollingEnabled,
      hasOverscanRowsForProjectedRemainder: hasOverscanRowsForProjectedRemainder
    )
  }

  public mutating func resetPhysics(reason: String) {
    physics.reset(reason: reason)
  }

  public mutating func resetAll() {
    physics.reset()
    commit.reset()
  }

  // MARK: Commit coalescing

  /// A single accumulated row (after coalescing more than one wheel event) is
  /// committed immediately rather than waiting for the next flush, so slow
  /// deliberate scrolling stays responsive.
  public func shouldCommitAccumulatedRowImmediately(rowDelta: Int) -> Bool {
    !commit.hasPendingCommit && abs(rowDelta) == 1 && physics.coalescedWheelEvents > 1
  }

  /// Enqueues a row commit; returns true when a flush should be scheduled.
  @discardableResult
  public mutating func enqueueCommit(rowDelta: Int) -> Bool {
    commit.enqueue(rowDelta: rowDelta)
  }

  public mutating func drainCommit() -> ScrollCommitBatch? {
    commit.drain()
  }
}

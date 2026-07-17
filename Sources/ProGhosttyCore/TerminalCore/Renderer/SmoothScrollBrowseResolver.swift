import CoreGraphics
import Foundation

/// Pure mapping from a continuous smooth-scroll position to a pattern-2 browse
/// window `(topAbsoluteRow, pixelOffset)`.
///
/// This is the heart of pattern 2's "no cache, no VT commit" model: given where
/// the physics engine currently sits (`position`, points, measured from the
/// anchor row the gesture started on), it computes which absolute scrollback row
/// belongs at the top of the viewport and the sub-row pixel remainder to shift
/// by — with edge clamping. It owns NO state and touches no AppKit/VT, so the
/// whole browse mapping is unit-testable in isolation.
///
/// Sign convention matches `SmoothScrollEngine`/`visualOffsetY`: a POSITIVE
/// position means the user is looking UP into history, so `topAbsoluteRow`
/// decreases from the anchor.
///
/// `pixelOffset` is normalized to `[0, cellHeight)` using floor semantics, so it
/// maps directly onto the renderer's existing presentation: present a window
/// with ONE overscan row above `topAbsoluteRow` and set `viewport.visualOffsetY
/// = pixelOffset`. The engine then draws `topAbsoluteRow` shifted DOWN by
/// `pixelOffset`, with the bottom `pixelOffset` pixels of `topAbsoluteRow - 1`
/// peeking in at the top — for both scroll directions.
public enum SmoothScrollBrowseResolver {
  public struct Resolved: Equatable, Sendable {
    /// Absolute scrollback row that should sit at the top of the viewport.
    public let topAbsoluteRow: UInt64
    /// Sub-row pixel remainder in [0, cellHeight).
    public let pixelOffset: CGFloat
    /// True when the user tried to scroll above row 0 (cannot go further up).
    public let atTopEdge: Bool
    /// True when the user tried to scroll past the last page (cannot go down).
    public let atBottomEdge: Bool

    public init(topAbsoluteRow: UInt64, pixelOffset: CGFloat, atTopEdge: Bool, atBottomEdge: Bool) {
      self.topAbsoluteRow = topAbsoluteRow
      self.pixelOffset = pixelOffset
      self.atTopEdge = atTopEdge
      self.atBottomEdge = atBottomEdge
    }
  }

  /// - Parameters:
  ///   - position: continuous scroll position in points (engine.position).
  ///   - cellHeight: row height in points (> 0).
  ///   - anchorRow: absolute row that sat at the viewport top when the gesture
  ///     began (position == 0 maps here).
  ///   - total: total rows currently in scrollback (history + screen).
  ///   - visibleRows: number of rows the viewport shows.
  public static func resolve(
    position: CGFloat,
    cellHeight: CGFloat,
    anchorRow: UInt64,
    total: UInt64,
    visibleRows: Int
  ) -> Resolved {
    guard cellHeight > 0, visibleRows > 0, total > 0 else {
      return Resolved(topAbsoluteRow: anchorRow, pixelOffset: 0, atTopEdge: true, atBottomEdge: true)
    }

    // Floor semantics: rowDelta whole rows climbed into history, pixelOffset the
    // fractional remainder always in [0, cellHeight). Positive position climbs
    // into history (fewer absolute rows), so subtract rowDelta from the anchor.
    let rowDelta = (position / cellHeight).rounded(.down)
    var pixelOffset = position - rowDelta * cellHeight  // in [0, cellHeight)

    // Top row cannot exceed the last full page (bottom row pinned to the floor).
    let maxTop = max(0, Int64(total) - Int64(visibleRows))
    let rawTop = Int64(anchorRow) - Int64(rowDelta)

    var atTopEdge = false
    var atBottomEdge = false
    var topRow = rawTop

    if rawTop < 0 || (rawTop == 0 && pixelOffset > 0) {
      // At/above the very top: pin to row 0, drop the upward sub-row peek (no
      // row above 0 to reveal).
      atTopEdge = true
      topRow = 0
      pixelOffset = 0
    } else if rawTop > maxTop {
      // Below the last page: pin to the last page, no further downward travel.
      atBottomEdge = true
      topRow = maxTop
      pixelOffset = 0
    }

    return Resolved(
      topAbsoluteRow: UInt64(max(0, topRow)),
      pixelOffset: pixelOffset,
      atTopEdge: atTopEdge,
      atBottomEdge: atBottomEdge
    )
  }
}

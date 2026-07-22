import CoreGraphics
import Foundation

/// Pure geometry helper: distance from a point to a semantic object's rect.
///
/// The old proximity/"flashlight" reveal (strength as a function of distance) was
/// removed in favor of the dwell model ([[SemanticDwell]]) — the terminal reacts
/// to the pointer *resting* on an object, not merely being near it. All that
/// remains here is the point→rect distance used to anchor the magnetic cursor puck.
public enum LinkProximity {
  /// Euclidean distance from a point to a rectangle (0 if inside).
  public static func distance(from point: CGPoint, to rect: CGRect) -> CGFloat {
    let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
    let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
    return (dx * dx + dy * dy).squareRoot()
  }
}

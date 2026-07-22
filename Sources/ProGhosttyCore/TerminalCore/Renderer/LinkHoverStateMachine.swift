import CoreGraphics
import Foundation

/// Dwell-gated interaction state for a hovered URL, per
/// `URL_SEMANTIC_OBJECT_SPEC.md` §2 / §9.
///
/// > React to intention, not motion.
///
/// This is the pure heart of "quiet by default": pointer motion alone changes
/// nothing. Only sustained dwell on the *same* semantic object advances state.
/// The engine feeds it `(now, objectID)` updates and a clock; it never touches
/// AppKit, timers, or rendering.
///
/// State ladder (cumulative dwell on one object identity):
///   Rest ──200ms──▶ Hover ──400ms total──▶ ActionHint
/// Moving within the same object (including its wrapped segments) keeps the
/// timer running; leaving the object (objectID == nil or a different id) resets
/// to Rest immediately.
public struct LinkHoverStateMachine: Equatable, Sendable {
  public struct Thresholds: Equatable, Sendable {
    /// Dwell before Hover reveals luminance lift + halo.
    public var hover: TimeInterval
    /// Dwell before the trailing ↗ Action Hint fades in.
    public var actionHint: TimeInterval

    public init(hover: TimeInterval = 0.20, actionHint: TimeInterval = 0.40) {
      self.hover = hover
      self.actionHint = actionHint
    }

    public static let `default` = Thresholds()
  }

  public enum Stage: Equatable, Sendable {
    case rest
    case hover
    case actionHint
  }

  public let thresholds: Thresholds

  /// The object the pointer is currently dwelling on, and when dwell began.
  /// Identity is the object's stable string id (`SemanticLinkObject.id`).
  private var currentObject: String?
  private var dwellStart: TimeInterval?
  private(set) public var stage: Stage = .rest

  public init(thresholds: Thresholds = .default) {
    self.thresholds = thresholds
  }

  /// The object currently being dwelled on (nil at Rest / off any link).
  public var hoveredObjectID: String? { currentObject }

  /// Feed a pointer sample. `objectID` is the semantic object under the pointer,
  /// or nil if the pointer is not over any link. Returns true if `stage` changed.
  @discardableResult
  public mutating func update(objectID: String?, now: TimeInterval) -> Bool {
    guard let objectID else {
      return reset()
    }

    if currentObject != objectID {
      // Entered a new object (or moved from empty space) — start its dwell clock.
      currentObject = objectID
      dwellStart = now
      return setStage(.rest)
    }

    // Same object: advance by cumulative dwell. Motion within it does not reset.
    let elapsed = now - (dwellStart ?? now)
    let target: Stage
    if elapsed >= thresholds.actionHint {
      target = .actionHint
    } else if elapsed >= thresholds.hover {
      target = .hover
    } else {
      target = .rest
    }
    return setStage(target)
  }

  /// Advance time without a new pointer sample (display-link tick). Lets dwell
  /// cross a threshold while the pointer holds still. Returns true if changed.
  @discardableResult
  public mutating func tick(now: TimeInterval) -> Bool {
    guard let currentObject else { return false }
    return update(objectID: currentObject, now: now)
  }

  /// Pointer left every link (or interaction cancelled). Returns true if changed.
  @discardableResult
  public mutating func reset() -> Bool {
    currentObject = nil
    dwellStart = nil
    return setStage(.rest)
  }

  /// The next dwell threshold the machine is waiting to cross from `now`, or nil
  /// if already at the terminal stage / at rest. Lets the driver decide whether
  /// it still needs to tick.
  public func nextDeadline(now: TimeInterval) -> TimeInterval? {
    guard let dwellStart else { return nil }
    let elapsed = now - dwellStart
    if elapsed < thresholds.hover { return dwellStart + thresholds.hover }
    if elapsed < thresholds.actionHint { return dwellStart + thresholds.actionHint }
    return nil
  }

  @discardableResult
  private mutating func setStage(_ newStage: Stage) -> Bool {
    guard stage != newStage else { return false }
    stage = newStage
    return true
  }
}

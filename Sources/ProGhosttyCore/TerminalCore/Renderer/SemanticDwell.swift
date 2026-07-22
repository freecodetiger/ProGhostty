import CoreGraphics
import Foundation

/// Dwell-gated reveal state for a Semantic Object (spec: URL_TYPOGRAPHIC_DWELL_SPEC).
///
/// The one intent signal is **dwell**: the pointer stayed on the same object, on
/// purpose. There is no proximity, no motion reaction. This pure value type owns
/// the timing ladder only — the view feeds it "which object is under the pointer,
/// and when," and asks for the current phase; the renderer turns the phase into a
/// weight boost. All wall-clock reasoning lives here so it stays testable.
///
///   Rest ──300ms──► Awake ──500ms──► ActionHint
///     ▲                                   │
///     └──────── object changes / leaves ──┘
///
/// The dwell clock resets **only** when the object identity actually changes, so
/// moving the pointer *within* one object (including across its wrapped rows)
/// never restarts the timer.
public struct SemanticDwell: Equatable, Sendable {
  public struct Tuning: Equatable, Sendable {
    /// Dwell before the object wakes (weight gain begins).
    public var awakeDelay: TimeInterval
    /// Dwell before the trailing `↗` action hint appears (after Awake).
    public var actionHintDelay: TimeInterval

    public init(awakeDelay: TimeInterval = 0.06, actionHintDelay: TimeInterval = 0.26) {
      self.awakeDelay = awakeDelay
      self.actionHintDelay = actionHintDelay
    }

    public static let `default` = Tuning()
  }

  public enum Phase: Int, Equatable, Sendable, Comparable {
    case rest = 0
    case awake = 1
    case actionHint = 2

    public static func < (lhs: Phase, rhs: Phase) -> Bool { lhs.rawValue < rhs.rawValue }
  }

  public private(set) var tuning: Tuning
  /// Identity of the object currently under the pointer (nil = none).
  public private(set) var objectID: String?
  /// When the current object first came under the pointer.
  public private(set) var since: TimeInterval?

  public init(tuning: Tuning = .default) {
    self.tuning = tuning
  }

  /// Report which object is under the pointer at `now`. Resets the dwell clock
  /// only when the identity changes; a repeat of the same id keeps it running.
  public mutating func setObject(_ id: String?, at now: TimeInterval) {
    guard id != objectID else { return }
    objectID = id
    since = id == nil ? nil : now
  }

  /// The reveal phase at time `now`. Rest whenever there is no object.
  public func phase(at now: TimeInterval) -> Phase {
    guard objectID != nil, let since else { return .rest }
    let elapsed = now - since
    if elapsed >= tuning.actionHintDelay { return .actionHint }
    if elapsed >= tuning.awakeDelay { return .awake }
    return .rest
  }

  /// Seconds until the phase would next change on its own (dwell crossing a
  /// threshold), or nil if no further transition is pending. The view uses this
  /// to schedule a single wake-up instead of polling every frame.
  public func timeUntilNextTransition(at now: TimeInterval) -> TimeInterval? {
    guard objectID != nil, let since else { return nil }
    let elapsed = now - since
    if elapsed < tuning.awakeDelay { return tuning.awakeDelay - elapsed }
    if elapsed < tuning.actionHintDelay { return tuning.actionHintDelay - elapsed }
    return nil
  }
}

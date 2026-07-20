import CoreGraphics
import Foundation

/// Continuous, display-link-paced smooth-scroll physics for one pane.
///
/// This is the sole owner of "how the scroll position evolves over time". It is
/// a pure value type with no AppKit/Metal/VT dependencies so it can be unit
/// tested in isolation — the long-standing pain with the old event-driven code
/// was that scroll behavior could only be verified by hand.
///
/// Model: a continuous scroll position measured in POINTS along the history
/// axis, using the same sign convention as `NSEvent.scrollingDeltaY` and the
/// legacy `PaneScrollCoordinator` (positive delta = content moves one way,
/// negative the other; the caller maps sign to VT direction). Wheel input moves
/// a `target`; each display-link `tick` advances `position` toward `target`
/// (gesture phase) or coasts under self-authored inertia (post-gesture),
/// producing a smooth per-refresh position rather than one jump per input event.
///
/// The engine knows nothing about rows, cell commits, or overscan. Callers map
/// `position` to a (topRow, sub-row pixel offset) pair via `resolve(cellHeight:)`.
public struct SmoothScrollEngine: Sendable {
  /// Tuning parameters. Defaults are starting points to be hand-tuned on-device.
  public struct Config: Sendable, Equatable {
    /// Fraction of the remaining (target - position) gap closed per second while
    /// a gesture is active. Higher = snappier tracking of the finger.
    public var trackingResponse: CGFloat
    /// Velocity decay per second during inertia (exponential friction). Lower =
    /// longer glide. e.g. 0.001 means velocity drops to 0.1% after 1s.
    public var inertiaDecayPerSecond: CGFloat
    /// Below this |velocity| (points/sec) inertia stops and the engine settles.
    public var minInertiaVelocity: CGFloat
    /// Multiplies raw wheel delta into position points (1 = 1:1 with deltaY).
    public var wheelScale: CGFloat

    public init(
      trackingResponse: CGFloat = 22,
      inertiaDecayPerSecond: CGFloat = 0.0015,
      minInertiaVelocity: CGFloat = 6,
      wheelScale: CGFloat = 1
    ) {
      self.trackingResponse = trackingResponse
      self.inertiaDecayPerSecond = inertiaDecayPerSecond
      self.minInertiaVelocity = minInertiaVelocity
      self.wheelScale = wheelScale
    }
  }

  public enum Phase: Sendable, Equatable {
    case idle
    case tracking   // finger down / active gesture
    case settling   // gesture ended with negligible velocity; easing to rest
    case inertia    // coasting after release
  }

  /// Where a continuous position lands on the row grid.
  public struct Resolved: Sendable, Equatable {
    /// Whole rows of travel from origin (sign per scroll convention).
    public let rowDelta: Int
    /// Sub-row pixel remainder in [0, cellHeight) magnitude, carrying position's sign.
    public let offsetY: CGFloat
  }

  public private(set) var position: CGFloat = 0
  public private(set) var target: CGFloat = 0
  public private(set) var velocity: CGFloat = 0
  public private(set) var phase: Phase = .idle
  private let config: Config
  private var lastTickTime: TimeInterval?
  /// Rolling window of the most recent per-tick velocities during tracking. The
  /// fling is seeded from the PEAK of this window, not the single last tick — a
  /// gesture often ends with one slow settling tick whose velocity is near zero,
  /// which would otherwise kill inertia instantly (best-practices review).
  private var recentVelocities: [CGFloat] = []
  private static let velocityWindow = 4

  public init(config: Config = Config()) {
    self.config = config
  }

  public var isActive: Bool { phase != .idle }

  // MARK: Input

  /// Feed a wheel delta (points), with its gesture phase and event time.
  /// `began`/`changed` drive tracking; `ended` starts inertia using the velocity
  /// accumulated during tracking. Momentum events from the OS are NOT fed here —
  /// inertia is synthesized by the engine (see WheelPhase).
  public mutating func addWheelInput(delta: CGFloat, phase inputPhase: WheelPhase, time: TimeInterval) {
    switch inputPhase {
    case .began:
      phase = .tracking
      lastTickTime = time
      recentVelocities.removeAll(keepingCapacity: true)
      target += delta * config.wheelScale
    case .changed, .discrete:
      if phase != .tracking {
        phase = .tracking
        lastTickTime = time
      }
      target += delta * config.wheelScale
    case .ended:
      // Seed the fling from the fastest of the last few tracking ticks, not the
      // single most recent one (a gesture often ends with a near-still tick).
      let seed = seedVelocity()
      velocity = seed
      phase = seed.magnitude >= config.minInertiaVelocity ? .inertia : .settling
    }
  }

  /// The inertia seed: the signed velocity with the largest magnitude across the
  /// recent tracking window, falling back to the current `velocity`.
  private func seedVelocity() -> CGFloat {
    guard let peak = recentVelocities.max(by: { $0.magnitude < $1.magnitude }) else {
      return velocity
    }
    return peak.magnitude >= velocity.magnitude ? peak : velocity
  }

  /// A discrete wheel scroll (mouse wheel, no gesture phases): nudge target and
  /// let tick ease toward it.
  public mutating func addDiscreteScroll(delta: CGFloat, time: TimeInterval) {
    addWheelInput(delta: delta, phase: .discrete, time: time)
  }

  // MARK: Clock

  /// Advance the physics to `now`. Returns the (possibly unchanged) position.
  /// Callers should stop the display link when `isActive` becomes false.
  @discardableResult
  public mutating func tick(now: TimeInterval) -> CGFloat {
    guard phase != .idle else { lastTickTime = now; return position }
    let dt = lastTickTime.map { max(0, now - $0) } ?? 0
    lastTickTime = now
    guard dt > 0 else { return position }

    switch phase {
    case .idle:
      break
    case .tracking, .settling:
      let previous = position
      // Critically-damped-ish exponential approach toward target.
      let alpha = 1 - exp(-config.trackingResponse * CGFloat(dt))
      position += (target - position) * alpha
      velocity = CGFloat(dt) > 0 ? (position - previous) / CGFloat(dt) : 0
      if phase == .tracking {
        recentVelocities.append(velocity)
        if recentVelocities.count > Self.velocityWindow {
          recentVelocities.removeFirst(recentVelocities.count - Self.velocityWindow)
        }
      }
      if phase == .settling, (target - position).magnitude < 0.5 {
        position = target
        velocity = 0
        phase = .idle
      }
    case .inertia:
      // Exponential friction: v *= decay^dt ; position += v*dt.
      let decay = pow(config.inertiaDecayPerSecond, CGFloat(dt))
      position += velocity * CGFloat(dt)
      velocity *= decay
      target = position
      if velocity.magnitude < config.minInertiaVelocity {
        velocity = 0
        phase = .idle
      }
    }
    return position
  }

  // MARK: Mapping

  /// Map the continuous position to whole-row + sub-row pixel offset.
  public func resolve(cellHeight: CGFloat) -> Resolved {
    guard cellHeight > 0 else { return Resolved(rowDelta: 0, offsetY: 0) }
    let rows = (position / cellHeight).rounded(.towardZero)
    let remainder = position - rows * cellHeight
    return Resolved(rowDelta: Int(rows), offsetY: remainder)
  }

  // MARK: Reset

  /// Snap everything to rest. Pass `position` to seed a continuous offset (e.g.
  /// distance-from-bottom when resuming a parked history browse) so the next
  /// gesture continues from the visible row instead of jumping to 0/follow.
  public mutating func reset(to position: CGFloat = 0) {
    self.position = position
    self.target = position
    velocity = 0
    phase = .idle
    lastTickTime = nil
    recentVelocities.removeAll(keepingCapacity: true)
  }

  /// Shift the continuous coordinate without killing velocity/phase. Used when
  /// the live-bottom anchor moves mid-gesture (scrollback growth/prune) so the
  /// absolute history row under the viewport stays put.
  public mutating func offsetPosition(by delta: CGFloat) {
    guard delta != 0 else { return }
    position += delta
    target += delta
  }
}

public enum WheelPhase: Sendable, Equatable {
  case began
  case changed
  case ended
  case discrete
}

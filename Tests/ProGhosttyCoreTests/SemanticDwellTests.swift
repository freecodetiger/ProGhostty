import Testing
@testable import ProGhosttyCore

struct SemanticDwellTests {
  @Test func restWhenNoObject() {
    var dwell = SemanticDwell()
    dwell.setObject(nil, at: 10)
    #expect(dwell.phase(at: 10) == .rest)
    #expect(dwell.phase(at: 100) == .rest)
    #expect(dwell.timeUntilNextTransition(at: 10) == nil)
  }

  // Threshold behavior is tested with explicit tuning so it stays stable across
  // default-timing tweaks; the defaults themselves are pinned once, below.
  private static let t = SemanticDwell.Tuning(awakeDelay: 0.10, actionHintDelay: 0.30)

  @Test func staysRestBeforeAwakeDelay() {
    var dwell = SemanticDwell(tuning: Self.t)
    dwell.setObject("a", at: 0)
    #expect(dwell.phase(at: 0) == .rest)
    #expect(dwell.phase(at: 0.09) == .rest)
  }

  @Test func wakesAtAwakeDelay() {
    var dwell = SemanticDwell(tuning: Self.t)
    dwell.setObject("a", at: 0)
    #expect(dwell.phase(at: 0.10) == .awake)
    #expect(dwell.phase(at: 0.29) == .awake)
  }

  @Test func reachesActionHintAtActionDelay() {
    var dwell = SemanticDwell(tuning: Self.t)
    dwell.setObject("a", at: 0)
    #expect(dwell.phase(at: 0.30) == .actionHint)
    #expect(dwell.phase(at: 5) == .actionHint)
  }

  @Test func fastPassThroughNeverWakes() {
    var dwell = SemanticDwell(tuning: Self.t)
    // Enters at t=0, leaves before the awake threshold.
    dwell.setObject("a", at: 0)
    #expect(dwell.phase(at: 0.05) == .rest)
    dwell.setObject(nil, at: 0.05)
    #expect(dwell.phase(at: 0.40) == .rest)
  }

  @Test func movingWithinSameObjectDoesNotResetClock() {
    var dwell = SemanticDwell(tuning: Self.t)
    dwell.setObject("a", at: 0)
    // Re-report the same id repeatedly (as mouseMoved would while over the URL).
    dwell.setObject("a", at: 0.03)
    dwell.setObject("a", at: 0.06)
    dwell.setObject("a", at: 0.11)
    // Clock still measured from t=0 → already awake.
    #expect(dwell.phase(at: 0.11) == .awake)
  }

  @Test func switchingObjectResetsClock() {
    var dwell = SemanticDwell(tuning: Self.t)
    dwell.setObject("a", at: 0)
    #expect(dwell.phase(at: 0.10) == .awake)
    // Move onto a different object at t=0.10 → clock restarts.
    dwell.setObject("b", at: 0.10)
    #expect(dwell.phase(at: 0.10) == .rest)
    #expect(dwell.phase(at: 0.19) == .rest)
    #expect(dwell.phase(at: 0.20) == .awake)
  }

  @Test func timeUntilNextTransitionCountsDownToAwakeThenActionHint() {
    var dwell = SemanticDwell(tuning: Self.t)
    dwell.setObject("a", at: 0)
    #expect(abs((dwell.timeUntilNextTransition(at: 0) ?? -1) - 0.10) < 1e-9)
    #expect(abs((dwell.timeUntilNextTransition(at: 0.05) ?? -1) - 0.05) < 1e-9)
    // After awake, counts down to the action-hint threshold.
    #expect(abs((dwell.timeUntilNextTransition(at: 0.10) ?? -1) - 0.20) < 1e-9)
    // After action-hint, nothing more pending.
    #expect(dwell.timeUntilNextTransition(at: 0.30) == nil)
  }

  @Test func defaultTuningValues() {
    let tuning = SemanticDwell.Tuning.default
    #expect(tuning.awakeDelay == 0.06)
    #expect(tuning.actionHintDelay == 0.26)
  }

  @Test func customTuning() {
    var dwell = SemanticDwell(tuning: .init(awakeDelay: 1.0, actionHintDelay: 2.0))
    dwell.setObject("a", at: 0)
    #expect(dwell.phase(at: 0.99) == .rest)
    #expect(dwell.phase(at: 1.0) == .awake)
    #expect(dwell.phase(at: 2.0) == .actionHint)
  }
}

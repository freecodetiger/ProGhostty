import Testing

@testable import ProGhosttyCore

@Suite("Link hover state machine")
struct LinkHoverStateMachineTests {
  @Test func fastPassThroughStaysAtRest() {
    var sm = LinkHoverStateMachine()
    #expect(sm.stage == .rest)
    // Pointer touches link then leaves within 100ms — never dwells.
    _ = sm.update(objectID: "a", now: 0.0)
    _ = sm.update(objectID: "a", now: 0.10)
    #expect(sm.stage == .rest)
    let changed = sm.update(objectID: nil, now: 0.11)
    #expect(!changed) // already rest
    #expect(sm.stage == .rest)
  }

  @Test func dwellReachesHoverThenActionHint() {
    var sm = LinkHoverStateMachine()
    _ = sm.update(objectID: "a", now: 0.0)
    #expect(sm.stage == .rest)
    let toHover = sm.update(objectID: "a", now: 0.20) // hover threshold
    #expect(toHover)
    #expect(sm.stage == .hover)
    let toHint = sm.update(objectID: "a", now: 0.40) // action hint threshold
    #expect(toHint)
    #expect(sm.stage == .actionHint)
  }

  @Test func tickAdvancesWhilePointerHoldsStill() {
    var sm = LinkHoverStateMachine()
    _ = sm.update(objectID: "a", now: 0.0)
    // No further pointer samples; display-link ticks drive the dwell.
    let toHover = sm.tick(now: 0.20)
    #expect(toHover)
    #expect(sm.stage == .hover)
    let toHint = sm.tick(now: 0.40)
    #expect(toHint)
    #expect(sm.stage == .actionHint)
  }

  @Test func movingWithinSameObjectDoesNotResetDwell() {
    var sm = LinkHoverStateMachine()
    _ = sm.update(objectID: "wrapped-url", now: 0.0)
    // Pointer wanders across the object's wrapped segments — same id each time.
    _ = sm.update(objectID: "wrapped-url", now: 0.10)
    _ = sm.update(objectID: "wrapped-url", now: 0.19)
    #expect(sm.stage == .rest)
    _ = sm.update(objectID: "wrapped-url", now: 0.21)
    #expect(sm.stage == .hover) // dwell accrued despite motion within object
  }

  @Test func switchingObjectRestartsDwell() {
    var sm = LinkHoverStateMachine()
    _ = sm.update(objectID: "a", now: 0.0)
    _ = sm.update(objectID: "a", now: 0.30) // a is at hover
    #expect(sm.stage == .hover)
    _ = sm.update(objectID: "b", now: 0.31) // moved to a different link
    #expect(sm.stage == .rest)
    #expect(sm.hoveredObjectID == "b")
    _ = sm.update(objectID: "b", now: 0.51) // b now dwelled 200ms
    #expect(sm.stage == .hover)
  }

  @Test func leavingResetsToRest() {
    var sm = LinkHoverStateMachine()
    _ = sm.update(objectID: "a", now: 0.0)
    _ = sm.update(objectID: "a", now: 0.45)
    #expect(sm.stage == .actionHint)
    let changed = sm.update(objectID: nil, now: 0.46)
    #expect(changed)
    #expect(sm.stage == .rest)
    #expect(sm.hoveredObjectID == nil)
  }

  @Test func nextDeadlineTracksUpcomingThreshold() {
    var sm = LinkHoverStateMachine()
    _ = sm.update(objectID: "a", now: 0.0)
    #expect(sm.nextDeadline(now: 0.0) == 0.20) // waiting for hover
    _ = sm.update(objectID: "a", now: 0.20)
    #expect(sm.nextDeadline(now: 0.20) == 0.40) // waiting for action hint
    _ = sm.update(objectID: "a", now: 0.40)
    #expect(sm.nextDeadline(now: 0.40) == nil) // terminal stage
  }

  @Test func customThresholds() {
    var sm = LinkHoverStateMachine(thresholds: .init(hover: 0.1, actionHint: 0.25))
    _ = sm.update(objectID: "a", now: 0.0)
    _ = sm.update(objectID: "a", now: 0.1)
    #expect(sm.stage == .hover)
    _ = sm.update(objectID: "a", now: 0.25)
    #expect(sm.stage == .actionHint)
  }
}

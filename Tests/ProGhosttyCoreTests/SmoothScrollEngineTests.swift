import CoreGraphics
import Foundation
import Testing

@testable import ProGhosttyCore

@Suite("Smooth scroll engine")
struct SmoothScrollEngineTests {
  @Test func startsIdleAndInactive() {
    let engine = SmoothScrollEngine()
    #expect(engine.phase == .idle)
    #expect(!engine.isActive)
    #expect(engine.position == 0)
  }

  @Test func discreteScrollEasesTowardTargetMonotonically() {
    var engine = SmoothScrollEngine()
    engine.addDiscreteScroll(delta: 100, time: 0)
    #expect(engine.target == 100)
    #expect(engine.isActive)

    var last: CGFloat = 0
    var t = 0.0
    // Simulate 120Hz ticks; position should rise monotonically toward 100.
    for _ in 0..<60 {
      t += 1.0 / 120.0
      let p = engine.tick(now: t)
      #expect(p >= last - 0.0001)  // monotonic (no back-and-forth jitter)
      last = p
    }
    #expect(last > 90)          // converged most of the way
    #expect(last <= 100.0001)   // never overshoots target
  }

  @Test func trackingFollowsAccumulatedTarget() {
    var engine = SmoothScrollEngine()
    engine.addWheelInput(delta: 10, phase: .began, time: 0)
    var t = 0.0
    for i in 1...10 {
      engine.addWheelInput(delta: 10, phase: .changed, time: Double(i) / 120.0)
      t = Double(i) / 120.0
      _ = engine.tick(now: t)
    }
    #expect(engine.target == 110)  // 10 began + 10*10 changed
    #expect(engine.position > 0)
    #expect(engine.position <= engine.target + 0.0001)
  }

  @Test func endedWithVelocityEntersInertiaThenSettles() {
    var engine = SmoothScrollEngine()
    // Build up velocity with a fast gesture.
    engine.addWheelInput(delta: 0, phase: .began, time: 0)
    for i in 1...5 {
      engine.addWheelInput(delta: 40, phase: .changed, time: Double(i) / 120.0)
      _ = engine.tick(now: Double(i) / 120.0)
    }
    engine.addWheelInput(delta: 0, phase: .ended, time: 6.0 / 120.0)
    #expect(engine.phase == .inertia || engine.phase == .settling)

    // Coast to rest.
    var t = 6.0 / 120.0
    var ticks = 0
    while engine.isActive, ticks < 2000 {
      t += 1.0 / 120.0
      _ = engine.tick(now: t)
      ticks += 1
    }
    #expect(!engine.isActive)          // inertia decays to idle
    #expect(engine.velocity == 0)
  }

  @Test func inertiaMovesPositionForwardThenStops() {
    var engine = SmoothScrollEngine(config: .init(minInertiaVelocity: 6))
    engine.addWheelInput(delta: 0, phase: .began, time: 0)
    for i in 1...4 {
      engine.addWheelInput(delta: 50, phase: .changed, time: Double(i) / 120.0)
      _ = engine.tick(now: Double(i) / 120.0)
    }
    let posAtRelease = engine.position
    engine.addWheelInput(delta: 0, phase: .ended, time: 5.0 / 120.0)
    var t = 5.0 / 120.0
    var ticks = 0
    while engine.isActive, ticks < 2000 { t += 1.0/120.0; _ = engine.tick(now: t); ticks += 1 }
    // Inertia carried the position further than where the finger released.
    #expect(engine.position >= posAtRelease)
  }

  @Test func resolveSplitsIntoRowAndRemainder() {
    var engine = SmoothScrollEngine()
    engine.addDiscreteScroll(delta: 50, time: 0)
    // Force position to a known value by ticking to convergence.
    var t = 0.0
    for _ in 0..<400 { t += 1.0/120.0; _ = engine.tick(now: t) }
    // position ~= 50; cellHeight 22 → 2 rows (44) + remainder 6.
    let r = engine.resolve(cellHeight: 22)
    #expect(r.rowDelta == 2)
    #expect(abs(r.offsetY - (engine.position - 44)) < 0.001)
    #expect(abs(r.offsetY) < 22)
  }

  @Test func resolveHandlesNegativePosition() {
    var engine = SmoothScrollEngine()
    engine.addDiscreteScroll(delta: -50, time: 0)
    var t = 0.0
    for _ in 0..<400 { t += 1.0/120.0; _ = engine.tick(now: t) }
    let r = engine.resolve(cellHeight: 22)
    #expect(r.rowDelta == -2)
    #expect(r.offsetY <= 0)
    #expect(abs(r.offsetY) < 22)
  }

  @Test func resolveZeroCellHeightIsSafe() {
    var engine = SmoothScrollEngine()
    engine.addDiscreteScroll(delta: 50, time: 0)
    let r = engine.resolve(cellHeight: 0)
    #expect(r.rowDelta == 0)
    #expect(r.offsetY == 0)
  }

  @Test func inertiaSeedsFromPeakNotLastSlowTick() {
    // A fast fling that ends with one near-still settling tick must still enter
    // inertia — the seed comes from the peak of the recent window, not the last
    // tick's tiny velocity.
    var engine = SmoothScrollEngine(config: .init(minInertiaVelocity: 6))
    engine.addWheelInput(delta: 0, phase: .began, time: 0)
    // Several fast tracking ticks build real velocity.
    for i in 1...4 {
      engine.addWheelInput(delta: 60, phase: .changed, time: Double(i) / 120.0)
      _ = engine.tick(now: Double(i) / 120.0)
    }
    // One more tick with NO new target delta: position nearly catches target, so
    // this tick's own velocity is small.
    _ = engine.tick(now: 5.0 / 120.0)
    engine.addWheelInput(delta: 0, phase: .ended, time: 5.0 / 120.0)
    #expect(engine.phase == .inertia)
    #expect(engine.velocity.magnitude >= 6)
  }

  @Test func resetReturnsToIdle() {
    var engine = SmoothScrollEngine()
    engine.addDiscreteScroll(delta: 50, time: 0)
    _ = engine.tick(now: 0.1)
    engine.reset()
    #expect(engine.phase == .idle)
    #expect(engine.position == 0)
    #expect(engine.velocity == 0)
    #expect(!engine.isActive)
  }

  @Test func idleTickDoesNothing() {
    var engine = SmoothScrollEngine()
    let p = engine.tick(now: 5.0)
    #expect(p == 0)
    #expect(!engine.isActive)
  }
}

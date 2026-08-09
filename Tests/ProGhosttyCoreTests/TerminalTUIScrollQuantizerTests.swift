import Testing

@testable import ProGhosttyCore

@Suite("TUI scroll quantizer")
struct TerminalTUIScrollQuantizerTests {
  @Test func preciseDeltasAccumulateByCellHeight() {
    var quantizer = TerminalTUIScrollQuantizer()

    #expect(quantizer.consume(delta: 3, precise: true, unitSize: 16) == 0)
    #expect(quantizer.pendingDelta == 6)
    #expect(quantizer.consume(delta: 5, precise: true, unitSize: 16) == 1)
    #expect(quantizer.pendingDelta == 0)
  }

  @Test func oppositePreciseDeltasCancelPendingRemainder() {
    var quantizer = TerminalTUIScrollQuantizer()

    #expect(quantizer.consume(delta: 3, precise: true, unitSize: 16) == 0)
    #expect(quantizer.consume(delta: -3, precise: true, unitSize: 16) == 0)
    #expect(quantizer.pendingDelta == 0)
  }

  @Test func discreteWheelUsesGhosttyDefaultThreeLineMultiplier() {
    var quantizer = TerminalTUIScrollQuantizer()

    #expect(quantizer.consume(delta: 0.1, precise: false, unitSize: 16) == 3)
    #expect(quantizer.consume(delta: -0.1, precise: false, unitSize: 16) == -3)
    #expect(quantizer.pendingDelta == 0)
  }

  @Test func preciseRemainderSurvivesWholeUnitEmission() {
    var quantizer = TerminalTUIScrollQuantizer()

    #expect(quantizer.consume(delta: 10, precise: true, unitSize: 16) == 1)
    #expect(quantizer.pendingDelta == 4)
    #expect(quantizer.consume(delta: 6, precise: true, unitSize: 16) == 1)
    #expect(quantizer.pendingDelta == 0)
  }

  @Test func resetClearsPendingInput() {
    var quantizer = TerminalTUIScrollQuantizer()
    _ = quantizer.consume(delta: 3, precise: true, unitSize: 16)

    quantizer.reset()

    #expect(quantizer.pendingDelta == 0)
  }
}

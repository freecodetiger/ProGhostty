import Foundation

struct TerminalTUIScrollQuantizer: Sendable, Equatable {
  static let preciseMultiplier = 2.0
  static let discreteMultiplier = 3.0

  private(set) var pendingDelta = 0.0

  mutating func consume(delta: Double, precise: Bool, cellHeight: Double) -> Int {
    guard delta != 0, cellHeight > 0 else { return 0 }

    let adjusted: Double
    if precise {
      adjusted = delta * Self.preciseMultiplier
    } else {
      let normalized = delta > 0 ? max(delta, 1) : min(delta, -1)
      adjusted = normalized * cellHeight * Self.discreteMultiplier
    }

    let accumulated = pendingDelta + adjusted
    guard abs(accumulated) >= cellHeight else {
      pendingDelta = accumulated
      return 0
    }

    let units = Int((accumulated / cellHeight).rounded(.towardZero))
    pendingDelta = accumulated - Double(units) * cellHeight
    return units
  }

  mutating func reset() {
    pendingDelta = 0
  }
}

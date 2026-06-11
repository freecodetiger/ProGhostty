import Foundation

public struct TerminalBellParser: Sendable {
  private enum State: Sendable {
    case scanning
    case sawEscape
    case collectingOsc
    case collectingOscSawEscape
  }

  private var state: State = .scanning
  private var oscByteCount = 0
  private let maxOscBytes: Int

  public init(maxOscBytes: Int = 16 * 1024) {
    self.maxOscBytes = maxOscBytes
  }

  public mutating func parse(_ data: Data) -> Int {
    var bellCount = 0
    for byte in data {
      switch state {
      case .scanning:
        if byte == 0x07 {
          bellCount += 1
        } else if byte == 0x1B {
          state = .sawEscape
        }

      case .sawEscape:
        if byte == 0x5D {
          oscByteCount = 0
          state = .collectingOsc
        } else if byte == 0x07 {
          bellCount += 1
          state = .scanning
        } else if byte != 0x1B {
          state = .scanning
        }

      case .collectingOsc:
        if byte == 0x07 {
          oscByteCount = 0
          state = .scanning
        } else if byte == 0x1B {
          state = .collectingOscSawEscape
        } else {
          noteOscByte()
        }

      case .collectingOscSawEscape:
        if byte == 0x5C {
          oscByteCount = 0
          state = .scanning
        } else {
          noteOscByte(count: 2)
          state = .collectingOsc
        }
      }
    }
    return bellCount
  }

  private mutating func noteOscByte(count: Int = 1) {
    oscByteCount += count
    if oscByteCount > maxOscBytes {
      oscByteCount = 0
      state = .scanning
    }
  }
}

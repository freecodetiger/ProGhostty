import Foundation

public struct OscSequence: Codable, Equatable, Sendable {
  public let raw: String
  public let command: String
  public let parameters: [String]

  public init(raw: String, command: String, parameters: [String]) {
    self.raw = raw
    self.command = command
    self.parameters = parameters
  }
}

public struct OscParser: Sendable {
  private enum State: Sendable {
    case scanning
    case sawEscape
    case collecting
    case collectingSawEscape
  }

  private var state: State = .scanning
  private var buffer = Data()
  private let maxSequenceBytes: Int

  public init(maxSequenceBytes: Int = 16 * 1024) {
    self.maxSequenceBytes = maxSequenceBytes
  }

  public mutating func parse(_ data: Data) -> [OscSequence] {
    var sequences: [OscSequence] = []

    for byte in data {
      switch state {
      case .scanning:
        if byte == 0x1B {
          state = .sawEscape
        }

      case .sawEscape:
        if byte == 0x5D {
          buffer.removeAll(keepingCapacity: true)
          state = .collecting
        } else if byte == 0x1B {
          state = .sawEscape
        } else {
          state = .scanning
        }

      case .collecting:
        if byte == 0x07 {
          if let sequence = makeSequence(from: buffer) {
            sequences.append(sequence)
          }
          buffer.removeAll(keepingCapacity: true)
          state = .scanning
        } else if byte == 0x1B {
          state = .collectingSawEscape
        } else {
          append(byte)
        }

      case .collectingSawEscape:
        if byte == 0x5C {
          if let sequence = makeSequence(from: buffer) {
            sequences.append(sequence)
          }
          buffer.removeAll(keepingCapacity: true)
          state = .scanning
        } else {
          append(0x1B)
          append(byte)
          state = .collecting
        }
      }
    }

    return sequences
  }

  private mutating func append(_ byte: UInt8) {
    guard buffer.count < maxSequenceBytes else {
      buffer.removeAll(keepingCapacity: true)
      state = .scanning
      return
    }
    buffer.append(byte)
  }

  private func makeSequence(from data: Data) -> OscSequence? {
    guard !data.isEmpty, let raw = String(data: data, encoding: .utf8) else {
      return nil
    }

    let parts = raw.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
    guard let command = parts.first, !command.isEmpty else {
      return nil
    }

    return OscSequence(raw: raw, command: command, parameters: Array(parts.dropFirst()))
  }
}

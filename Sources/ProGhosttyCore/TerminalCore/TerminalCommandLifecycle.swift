import Foundation

public enum TerminalCommandLifecycleMarker: Equatable, Sendable {
  case started
  case finished(exitCode: Int?)
  case promptStarted
}

public struct TerminalCommandFinished: Equatable, Sendable {
  public var exitCode: Int?
  public var duration: TimeInterval

  public init(exitCode: Int?, duration: TimeInterval) {
    self.exitCode = exitCode
    self.duration = duration
  }
}

public enum TerminalCommandLifecycleParser {
  public static func parse(_ sequence: OscSequence) -> TerminalCommandLifecycleMarker? {
    guard sequence.command == "133", let marker = sequence.parameters.first else {
      return nil
    }
    switch marker {
    case "C":
      return .started
    case "D":
      let exitCode = sequence.parameters.dropFirst().first.flatMap(Int.init)
      return .finished(exitCode: exitCode)
    case "A":
      return .promptStarted
    default:
      return nil
    }
  }
}

import Foundation

public struct TerminalDesktopNotification: Equatable, Sendable {
  public enum Source: Equatable, Sendable {
    case osc9
    case osc777
  }

  public var title: String
  public var body: String
  public var source: Source

  public init(title: String, body: String, source: Source) {
    self.title = title
    self.body = body
    self.source = source
  }
}

public enum TerminalDesktopNotificationParser {
  private static let maxTitleLength = 120
  private static let maxBodyLength = 300

  public static func parse(_ sequence: OscSequence) -> TerminalDesktopNotification? {
    switch sequence.command {
    case "9":
      guard let body = normalized(sequence.parameters.joined(separator: ";"), limit: maxBodyLength) else {
        return nil
      }
      return TerminalDesktopNotification(title: "ProGhostty", body: body, source: .osc9)

    case "777":
      guard sequence.parameters.count >= 3, sequence.parameters[0] == "notify" else {
        return nil
      }
      guard let title = normalized(sequence.parameters[1], limit: maxTitleLength) else {
        return nil
      }
      let rawBody = sequence.parameters.dropFirst(2).joined(separator: ";")
      guard let body = normalized(rawBody, limit: maxBodyLength) else {
        return nil
      }
      return TerminalDesktopNotification(title: title, body: body, source: .osc777)

    default:
      return nil
    }
  }

  private static func normalized(_ value: String, limit: Int) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    if trimmed.count <= limit { return trimmed }
    return String(trimmed.prefix(limit))
  }
}

import Foundation

public enum ProGhosttyControlCommand: String, Codable, CaseIterable, Sendable {
  case workspaceOpen = "workspace.open"
  case workspaceSwitch = "workspace.switch"
  case workspaceNew = "workspace.new"
  case pluginsOpen = "plugins.open"
  case pluginsScan = "plugins.scan"
  case pluginsPlan = "plugins.plan"
  case settingsOpen = "settings.open"
  case splitRight = "split.right"
  case splitDown = "split.down"
  case layoutSave = "layout.save"
  case layoutRestore = "layout.restore"

  public static let allowlist = Set(allCases)
}

public struct ProGhosttyControlMessage: Codable, Equatable, Sendable {
  public var version: Int
  public var sessionId: String
  public var token: String
  public var command: ProGhosttyControlCommand
  public var args: [String: String]

  public init(
    version: Int = 1,
    sessionId: String,
    token: String,
    command: ProGhosttyControlCommand,
    args: [String: String] = [:]
  ) {
    self.version = version
    self.sessionId = sessionId
    self.token = token
    self.command = command
    self.args = args
  }
}

public enum ProGhosttyControlOscParser {
  public static let oscCommand = "777"
  public static let namespace = "proghostty"
  public static let maxPayloadBytes = 16 * 1024

  public static func parse(_ sequence: OscSequence) -> ProGhosttyControlMessage? {
    guard sequence.command == oscCommand else { return nil }
    guard sequence.parameters.count == 2 else { return nil }
    guard sequence.parameters[0] == namespace else { return nil }

    let encodedPayload = sequence.parameters[1]
    guard encodedPayload.utf8.count <= maxPayloadBytes else { return nil }
    guard let data = Data(base64Encoded: encodedPayload), data.count <= maxPayloadBytes else { return nil }
    guard let message = try? JSONDecoder().decode(ProGhosttyControlMessage.self, from: data) else {
      return nil
    }
    guard message.version == 1 else { return nil }
    guard ProGhosttyControlCommand.allowlist.contains(message.command) else { return nil }
    return message
  }

  public static func encode(_ message: ProGhosttyControlMessage) throws -> String {
    let data = try JSONEncoder().encode(message)
    let payload = data.base64EncodedString()
    return "\u{1B}]\(oscCommand);\(namespace);\(payload)\u{07}"
  }
}

public enum ProGhosttyControlAuthorizer {
  public static func isAuthorized(
    _ message: ProGhosttyControlMessage,
    sourceSessionId: String,
    expectedToken: String?,
    isEnabled: Bool
  ) -> Bool {
    guard isEnabled else { return false }
    guard message.sessionId == sourceSessionId else { return false }
    guard let expectedToken, expectedToken == message.token else { return false }
    return true
  }
}

public enum PGHelperResponse: Equatable, Sendable {
  case osc(String)
  case message(String)
  case error(String)
}

public enum PGCommandMapper {
  public static func response(arguments: [String], environment: [String: String]) -> PGHelperResponse {
    guard environment["TERM_PROGRAM"] == "ProGhostty" else {
      return .message("pg control commands are only available inside ProGhostty.")
    }
    guard
      let sessionId = environment["PROGHOSTTY_SESSION_ID"], !sessionId.isEmpty,
      let token = environment["PROGHOSTTY_SESSION_TOKEN"], !token.isEmpty
    else {
      return .message("pg could not find an active ProGhostty session.")
    }
    guard let mapped = map(arguments: arguments) else {
      return .error(usage)
    }

    let message = ProGhosttyControlMessage(
      sessionId: sessionId,
      token: token,
      command: mapped.command,
      args: mapped.args
    )
    do {
      return .osc(try ProGhosttyControlOscParser.encode(message))
    } catch {
      return .error("pg could not encode the control message.")
    }
  }

  public static func map(arguments: [String]) -> (command: ProGhosttyControlCommand, args: [String: String])? {
    guard let head = arguments.first else { return nil }
    let tail = Array(arguments.dropFirst())

    switch head {
    case "ws", "workspace":
      return mapWorkspace(tail)
    case "plugins":
      return mapPlugins(tail)
    case "settings":
      return tail.isEmpty ? (.settingsOpen, [:]) : nil
    case "split":
      return mapSplit(tail)
    case "layout":
      return mapLayout(tail)
    default:
      return nil
    }
  }

  public static let usage =
    "Usage: pg ws|workspace [switch <name>|new <name>], pg plugins [scan|plan <pack>], pg settings, pg split right|down, pg layout save|restore"

  private static func mapWorkspace(_ arguments: [String]) -> (ProGhosttyControlCommand, [String: String])? {
    guard let subcommand = arguments.first else { return (.workspaceOpen, [:]) }
    let value = joined(Array(arguments.dropFirst()))
    switch subcommand {
    case "switch" where value != nil:
      return (.workspaceSwitch, ["name": value!])
    case "new" where value != nil:
      return (.workspaceNew, ["name": value!])
    default:
      return nil
    }
  }

  private static func mapPlugins(_ arguments: [String]) -> (ProGhosttyControlCommand, [String: String])? {
    guard let subcommand = arguments.first else { return (.pluginsOpen, [:]) }
    let value = joined(Array(arguments.dropFirst()))
    switch subcommand {
    case "scan" where arguments.count == 1:
      return (.pluginsScan, [:])
    case "plan" where value != nil:
      return (.pluginsPlan, ["pack": value!])
    default:
      return nil
    }
  }

  private static func mapSplit(_ arguments: [String]) -> (ProGhosttyControlCommand, [String: String])? {
    guard arguments.count == 1 else { return nil }
    switch arguments[0] {
    case "right":
      return (.splitRight, [:])
    case "down":
      return (.splitDown, [:])
    default:
      return nil
    }
  }

  private static func mapLayout(_ arguments: [String]) -> (ProGhosttyControlCommand, [String: String])? {
    guard arguments.count == 1 else { return nil }
    switch arguments[0] {
    case "save":
      return (.layoutSave, [:])
    case "restore":
      return (.layoutRestore, [:])
    default:
      return nil
    }
  }

  private static func joined(_ arguments: [String]) -> String? {
    let value = arguments.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
  }
}

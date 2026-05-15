import Foundation

public enum CommandBlockStatus: String, Codable, Sendable, CaseIterable {
  case running
  case success
  case failed
  case cancelled
  case unknown
  case partial
}

public struct CommandBlock: Identifiable, Codable, Equatable, Sendable {
  public let id: UUID
  public let workspaceId: UUID?
  public let sessionId: TerminalSessionID
  public var cwd: String?
  public var command: String?
  public var outputPreview: String
  public var outputStorageRef: String?
  public var startedAt: Date
  public var endedAt: Date?
  public var durationMs: Int?
  public var exitCode: Int?
  public var status: CommandBlockStatus
  public var shellIntegrationReliable: Bool
  public var createdAt: Date

  public init(
    id: UUID = UUID(),
    workspaceId: UUID?,
    sessionId: TerminalSessionID,
    cwd: String?,
    command: String?,
    outputPreview: String,
    outputStorageRef: String?,
    startedAt: Date,
    endedAt: Date?,
    durationMs: Int?,
    exitCode: Int?,
    status: CommandBlockStatus,
    shellIntegrationReliable: Bool,
    createdAt: Date
  ) {
    self.id = id
    self.workspaceId = workspaceId
    self.sessionId = sessionId
    self.cwd = cwd
    self.command = command
    self.outputPreview = outputPreview
    self.outputStorageRef = outputStorageRef
    self.startedAt = startedAt
    self.endedAt = endedAt
    self.durationMs = durationMs
    self.exitCode = exitCode
    self.status = status
    self.shellIntegrationReliable = shellIntegrationReliable
    self.createdAt = createdAt
  }
}

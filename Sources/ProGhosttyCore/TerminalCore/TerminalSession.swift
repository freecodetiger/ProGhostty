import Foundation

public struct TerminalSession: Identifiable, Equatable, Sendable {
  public var id: TerminalSessionID
  public var config: TerminalSessionConfig
  public var createdAt: Date
  public var closedAt: Date?

  public init(
    id: TerminalSessionID = TerminalSessionID(), config: TerminalSessionConfig,
    createdAt: Date = Date(), closedAt: Date? = nil
  ) {
    self.id = id
    self.config = config
    self.createdAt = createdAt
    self.closedAt = closedAt
  }
}

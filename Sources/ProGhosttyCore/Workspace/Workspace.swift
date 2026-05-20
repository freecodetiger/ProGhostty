import Foundation

public struct Workspace: Identifiable, Codable, Equatable, Sendable {
  public let id: UUID
  public var name: String
  public var rootPath: String?
  public var defaultShell: String?
  public var layoutSnapshot: WorkspaceLayout?
  public var createdAt: Date
  public var updatedAt: Date

  public init(
    id: UUID = UUID(),
    name: String,
    rootPath: String?,
    defaultShell: String? = nil,
    layoutSnapshot: WorkspaceLayout? = nil,
    createdAt: Date = Date(),
    updatedAt: Date = Date()
  ) {
    self.id = id
    self.name = name
    self.rootPath = rootPath
    self.defaultShell = defaultShell
    self.layoutSnapshot = layoutSnapshot
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

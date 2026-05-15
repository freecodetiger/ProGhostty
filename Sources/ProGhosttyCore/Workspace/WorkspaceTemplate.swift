import Foundation

public struct WorkspaceTemplate: Codable, Equatable, Sendable {
  public var name: String
  public var rootPath: String?
  public var defaultShell: String?

  public init(name: String, rootPath: String?, defaultShell: String? = nil) {
    self.name = name
    self.rootPath = rootPath
    self.defaultShell = defaultShell
  }
}

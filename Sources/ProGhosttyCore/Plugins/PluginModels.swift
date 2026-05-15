import Foundation

public enum PluginRiskLevel: String, Codable, Sendable {
  case low
  case medium
  case high
}

public struct PluginInstallPlan: Codable, Identifiable, Equatable, Sendable {
  public var id: String { name }
  public var name: String
  public var reason: String
  public var commands: [String]
  public var configSnippet: String?
  public var riskLevel: PluginRiskLevel

  public init(
    name: String, reason: String, commands: [String], configSnippet: String?,
    riskLevel: PluginRiskLevel
  ) {
    self.name = name
    self.reason = reason
    self.commands = commands
    self.configSnippet = configSnippet
    self.riskLevel = riskLevel
  }
}

public struct PluginRecommendation: Identifiable, Equatable, Sendable {
  public var id: String { plan.name }
  public var plan: PluginInstallPlan
  public var isInstalled: Bool
}

public struct ShellEnvironmentReport: Equatable, Sendable {
  public var defaultShell: String
  public var zshExists: Bool
  public var homebrewExists: Bool
  public var ohMyZshExists: Bool
  public var recommendations: [PluginRecommendation]
}

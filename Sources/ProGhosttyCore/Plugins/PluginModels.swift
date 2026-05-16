import Foundation

public enum PluginStatus: String, Codable, Sendable {
  case notInstalled
  case installed
  case installedButInactive
  case activeExternal
  case activeManaged
  case conflict
  case unknown
}

public enum PluginCategory: String, Codable, Sendable, CaseIterable {
  case essential
  case navigation
  case prompt
  case history
  case git
  case runtime
}

public enum PluginRiskLevel: String, Codable, Sendable {
  case low
  case medium
  case high
}

public enum PluginPlanOperation: String, Codable, Sendable {
  case install
  case uninstall
}

public enum ShellType: String, Codable, Sendable, CaseIterable {
  case zsh
  case bash
  case fish
}

public struct ShellPluginDefinition: Identifiable, Codable, Equatable, Sendable {
  public let id: String
  public let name: String
  public let category: PluginCategory
  public let description: String
  public let homepage: String?
  public let detectionCommands: [String]
  public let installCommands: [String]
  public let activationSnippets: [ShellType: String]
  public let configFilesTouched: [String]
  public let conflictGroup: String?
  public let shouldAutoRecommend: Bool
  public let riskLevel: PluginRiskLevel
  public let notes: [String]
}

public enum PluginSource: String, Codable, Sendable {
  case homebrew
  case ohMyZsh
  case manualZshrc
  case yourTerminalManaged
  case binaryPath
  case unknown
}

public struct PluginIssue: Identifiable, Codable, Equatable, Sendable {
  public let id: UUID
  public var title: String
  public var message: String
  public var severity: IssueSeverity

  public init(
    id: UUID = UUID(),
    title: String,
    message: String,
    severity: IssueSeverity
  ) {
    self.id = id
    self.title = title
    self.message = message
    self.severity = severity
  }
}

public enum IssueSeverity: String, Codable, Sendable {
  case info
  case warning
  case error
}

public struct DetectedShellPlugin: Identifiable, Codable, Equatable, Sendable {
  public let id: String
  public let definitionId: String
  public var name: String
  public var category: PluginCategory
  public var status: PluginStatus
  public var source: PluginSource
  public var detectedVersion: String?
  public var detectedPaths: [String]
  public var issues: [PluginIssue]
  public var riskLevel: PluginRiskLevel

  public init(
    id: String,
    definitionId: String,
    name: String,
    category: PluginCategory,
    status: PluginStatus,
    source: PluginSource,
    detectedVersion: String? = nil,
    detectedPaths: [String] = [],
    issues: [PluginIssue] = [],
    riskLevel: PluginRiskLevel
  ) {
    self.id = id
    self.definitionId = definitionId
    self.name = name
    self.category = category
    self.status = status
    self.source = source
    self.detectedVersion = detectedVersion
    self.detectedPaths = detectedPaths
    self.issues = issues
    self.riskLevel = riskLevel
  }
}

public struct PluginInstallPlan: Identifiable, Codable, Equatable, Sendable {
  public let id: UUID
  public var pluginIds: [String]
  public var operation: PluginPlanOperation
  public var title: String
  public var summary: String
  public var commands: [String]
  public var filePatches: [FilePatch]
  public var riskLevel: PluginRiskLevel
  public var requiresBackup: Bool
  public var rollbackDescription: String

  public init(
    id: UUID = UUID(),
    pluginIds: [String],
    operation: PluginPlanOperation = .install,
    title: String,
    summary: String,
    commands: [String],
    filePatches: [FilePatch],
    riskLevel: PluginRiskLevel,
    requiresBackup: Bool,
    rollbackDescription: String
  ) {
    self.id = id
    self.pluginIds = pluginIds
    self.operation = operation
    self.title = title
    self.summary = summary
    self.commands = commands
    self.filePatches = filePatches
    self.riskLevel = riskLevel
    self.requiresBackup = requiresBackup
    self.rollbackDescription = rollbackDescription
  }
}

public struct FilePatch: Identifiable, Codable, Equatable, Sendable {
  public let id: UUID
  public var filePath: String
  public var beforePreview: String?
  public var afterPreview: String
  public var explanation: String

  public init(
    id: UUID = UUID(),
    filePath: String,
    beforePreview: String?,
    afterPreview: String,
    explanation: String
  ) {
    self.id = id
    self.filePath = filePath
    self.beforePreview = beforePreview
    self.afterPreview = afterPreview
    self.explanation = explanation
  }
}

public struct ShellEnvironmentReport: Equatable, Sendable {
  public var defaultShell: String
  public var zshExists: Bool
  public var homebrewExists: Bool
  public var ohMyZshExists: Bool
  public var detectedPlugins: [DetectedShellPlugin]
  public var recommendations: [DetectedShellPlugin]

  public init(
    defaultShell: String,
    zshExists: Bool,
    homebrewExists: Bool,
    ohMyZshExists: Bool,
    detectedPlugins: [DetectedShellPlugin],
    recommendations: [DetectedShellPlugin]
  ) {
    self.defaultShell = defaultShell
    self.zshExists = zshExists
    self.homebrewExists = homebrewExists
    self.ohMyZshExists = ohMyZshExists
    self.detectedPlugins = detectedPlugins
    self.recommendations = recommendations
  }
}

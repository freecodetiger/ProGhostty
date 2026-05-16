import Foundation

public struct AICLIProfile: Codable, Identifiable, Hashable, Sendable {
  public let id: String
  public var name: String
  public var launchCommand: String
  public var processNames: [String]
  public var defaultSendMode: AISendMode

  public init(id: String, name: String, launchCommand: String, processNames: [String], defaultSendMode: AISendMode = .bracketedPasteOnly) {
    self.id = id
    self.name = name
    self.launchCommand = launchCommand
    self.processNames = processNames
    self.defaultSendMode = defaultSendMode
  }

  public static let codex = AICLIProfile(id: "codex", name: "Codex", launchCommand: "codex", processNames: ["codex"])
  public static let claudeCode = AICLIProfile(id: "claude-code", name: "Claude Code", launchCommand: "claude", processNames: ["claude"])
  public static let builtIns: [AICLIProfile] = [.codex, .claudeCode]
}

public enum AISendMode: String, Codable, Sendable {
  case bracketedPasteOnly
  case bracketedPasteAndEnter

  public func payload(for prompt: String) -> String {
    let payload = "\u{1B}[200~\(prompt)\u{1B}[201~"
    return self == .bracketedPasteAndEnter ? payload + "\n" : payload
  }
}

public enum AIOpenMode: String, Codable, Sendable {
  case currentPane
  case rightSplit
  case bottomSplit
}

public struct AIWorkspace: Equatable, Sendable {
  public var id: UUID
  public var name: String
  public var rootPath: String
  public var currentPaneID: UUID

  public init(id: UUID, name: String, rootPath: String, currentPaneID: UUID) {
    self.id = id
    self.name = name
    self.rootPath = rootPath
    self.currentPaneID = currentPaneID
  }
}

public struct AISession: Identifiable, Equatable, Sendable {
  public var id: UUID
  public var profile: AICLIProfile
  public var workspaceID: UUID
  public var paneID: UUID
  public var terminalSessionID: TerminalSessionID
  public var workspaceRoot: String
  public var createdAt: Date
}

public enum AISessionError: Error, Equatable {
  case paneNotFound
  case sessionNotFound
}

@MainActor
public final class AISessionManager {
  private let paneController: PaneWorkspaceController
  private let terminalSessionManager: TerminalSessionManager
  private let shellPathProvider: () -> String
  private var sessions: [UUID: AISession] = [:]

  public init(
    paneController: PaneWorkspaceController,
    terminalSessionManager: TerminalSessionManager,
    focusStore: TerminalFocusStore,
    shellPathProvider: @escaping () -> String = { "/bin/zsh" }
  ) {
    self.paneController = paneController
    self.terminalSessionManager = terminalSessionManager
    self.shellPathProvider = shellPathProvider
  }

  public func start(profile: AICLIProfile, workspace: AIWorkspace, openMode: AIOpenMode) throws -> AISession {
    let terminalSessionID: TerminalSessionID
    let paneID: UUID

    switch openMode {
    case .currentPane:
      guard
        let layout = paneController.workspaceLayout(id: workspace.id),
        let pane = PaneTreeReducer.findPane(in: layout.root, paneId: workspace.currentPaneID)
      else { throw AISessionError.paneNotFound }
      terminalSessionID = pane.sessionId
      paneID = pane.paneId
      terminalSessionManager.writeInput(Data((profile.launchCommand + "\n").utf8), to: terminalSessionID)
      _ = paneController.selectPane(paneID, in: workspace.id)
    case .rightSplit, .bottomSplit:
      let split = try paneController.splitPane(
        workspaceID: workspace.id,
        paneID: workspace.currentPaneID,
        axis: openMode == .rightSplit ? .horizontal : .vertical,
        config: TerminalSessionConfig(
          shellPath: shellPathProvider(),
          launchCommand: profile.launchCommand,
          workingDirectory: workspace.rootPath,
          environment: ["PROGHOSTTY_AI_COMMAND": profile.launchCommand],
          rows: 24,
          cols: 80
        ),
        paneTitle: profile.name,
        cwd: workspace.rootPath
      )
      terminalSessionID = split.pane.sessionId
      paneID = split.pane.paneId
    }

    let session = AISession(
      id: UUID(),
      profile: profile,
      workspaceID: workspace.id,
      paneID: paneID,
      terminalSessionID: terminalSessionID,
      workspaceRoot: workspace.rootPath,
      createdAt: Date()
    )
    sessions[session.id] = session
    return session
  }

  public func sendPrompt(_ prompt: String, to sessionId: UUID, mode: AISendMode) throws {
    guard let session = sessions[sessionId] else { throw AISessionError.sessionNotFound }
    terminalSessionManager.writeInput(Data(mode.payload(for: prompt).utf8), to: session.terminalSessionID)
  }

  public func listAISessions() -> [AISession] {
    sessions.values.sorted { $0.createdAt < $1.createdAt }
  }

  @discardableResult
  public func focusAISession(id: UUID) -> Bool {
    guard let session = sessions[id] else { return false }
    return paneController.selectPane(session.paneID, in: session.workspaceID)
  }
}

public enum GitFileStatus: String, Codable, Equatable, Sendable {
  case added
  case modified
  case deleted
  case renamed
  case untracked
  case copied
  case conflicted
}

public struct GitModifiedFile: Identifiable, Codable, Equatable, Sendable {
  public var status: GitFileStatus
  public var path: String
  public var id: String { "\(status.rawValue):\(path)" }

  public init(status: GitFileStatus, path: String) {
    self.status = status
    self.path = path
  }

  public static func parsePorcelain(_ output: String) -> [GitModifiedFile] {
    output.split(whereSeparator: \.isNewline).compactMap { rawLine in
      let line = String(rawLine)
      guard line.count >= 4 else { return nil }
      let statusText = String(line.prefix(2))
      let rawPath = String(line.dropFirst(3))
      let path = rawPath.components(separatedBy: " -> ").last ?? rawPath
      let status = statusText.contains("?") ? GitFileStatus.untracked : status(for: statusText)
      return GitModifiedFile(status: status, path: path)
    }
  }

  private static func status(for text: String) -> GitFileStatus {
    if text.contains("U") { return .conflicted }
    if text.contains("R") { return .renamed }
    if text.contains("C") { return .copied }
    if text.contains("A") { return .added }
    if text.contains("D") { return .deleted }
    return .modified
  }
}

public extension GitFileStatus {
  var label: String {
    switch self {
    case .added: return "Added"
    case .modified: return "Modified"
    case .deleted: return "Deleted"
    case .renamed: return "Renamed"
    case .untracked: return "Untracked"
    case .copied: return "Copied"
    case .conflicted: return "Conflicted"
    }
  }
}

public enum GitContextError: Error, Equatable {
  case commandFailed(String)
}

public enum GitContextCollector {
  public static func statusPorcelain(workspacePath: String) throws -> String {
    try runGit(arguments: ["status", "--porcelain"], workspacePath: workspacePath)
  }

  public static func branch(workspacePath: String) throws -> String {
    try runGit(arguments: ["branch", "--show-current"], workspacePath: workspacePath)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  public static func diff(workspacePath: String) throws -> String {
    try runGit(arguments: ["diff", "--"], workspacePath: workspacePath)
  }

  public static func modifiedFiles(workspacePath: String) throws -> [GitModifiedFile] {
    GitModifiedFile.parsePorcelain(try statusPorcelain(workspacePath: workspacePath))
  }

  private static func runGit(arguments: [String], workspacePath: String) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["git"] + arguments
    process.currentDirectoryURL = URL(fileURLWithPath: workspacePath, isDirectory: true)
    let pipe = Pipe()
    let errorPipe = Pipe()
    process.standardOutput = pipe
    process.standardError = errorPipe
    try process.run()
    process.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
    guard process.terminationStatus == 0 else {
      throw GitContextError.commandFailed(String(decoding: errorData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
    return String(decoding: data, as: UTF8.self)
  }
}

public enum AIPromptTemplate: String, CaseIterable, Identifiable, Codable, Sendable {
  case fixError = "Fix Error"
  case reviewDiff = "Review Diff"
  case writeTests = "Write Tests"
  case refactorSafely = "Refactor Safely"
  case explainCode = "Explain Code"
  case generateCommitMessage = "Generate Commit Message"

  public var id: String { rawValue }
}

public enum AIPromptContextOption: String, CaseIterable, Identifiable, Codable, Sendable {
  case workspacePath
  case gitBranch
  case gitStatus
  case gitDiff
  case selectedTerminalText
  case changedFileList

  public var id: String { rawValue }
}

public struct AIPromptContext: Equatable, Sendable {
  public var workspacePath: String?
  public var gitBranch: String?
  public var gitStatus: String?
  public var gitDiff: String?
  public var selectedTerminalText: String?
  public var changedFiles: [GitModifiedFile]

  public init(
    workspacePath: String? = nil,
    gitBranch: String? = nil,
    gitStatus: String? = nil,
    gitDiff: String? = nil,
    selectedTerminalText: String? = nil,
    changedFiles: [GitModifiedFile] = []
  ) {
    self.workspacePath = workspacePath
    self.gitBranch = gitBranch
    self.gitStatus = gitStatus
    self.gitDiff = gitDiff
    self.selectedTerminalText = selectedTerminalText
    self.changedFiles = changedFiles
  }
}

public enum AIPromptComposer {
  public static func compose(
    request: String,
    template: AIPromptTemplate,
    context: AIPromptContext,
    includedContext: Set<AIPromptContextOption>
  ) -> String {
    var sections = [
      "Task: \(template.rawValue)",
      "",
      "User request:",
      request.trimmingCharacters(in: .whitespacesAndNewlines),
      "",
      "Instructions:",
      "- Make the smallest practical change that solves the request.",
      "- Keep the existing style, architecture, and naming patterns.",
      "- Before editing, explain the evidence and judgment behind your approach.",
      "- Give concrete verification commands after the change.",
      "- If information is insufficient, ask focused questions before changing code.",
    ]

    var contextLines: [String] = []
    append("Workspace: \(context.workspacePath ?? "")", when: .workspacePath, includedContext: includedContext, to: &contextLines)
    append("Branch: \(context.gitBranch ?? "")", when: .gitBranch, includedContext: includedContext, to: &contextLines)
    appendBlock("Git status", context.gitStatus, when: .gitStatus, includedContext: includedContext, to: &contextLines)
    if includedContext.contains(.changedFileList), !context.changedFiles.isEmpty {
      contextLines.append("Changed files:\n" + context.changedFiles.map { "\($0.status.label): \($0.path)" }.joined(separator: "\n"))
    }
    appendBlock("Selected terminal text", context.selectedTerminalText, when: .selectedTerminalText, includedContext: includedContext, to: &contextLines)
    appendBlock("Git diff", context.gitDiff, when: .gitDiff, includedContext: includedContext, to: &contextLines)

    if !contextLines.isEmpty {
      sections += ["", "Context:", contextLines.joined(separator: "\n\n")]
    }
    return sections.joined(separator: "\n")
  }

  private static func append(_ line: String, when option: AIPromptContextOption, includedContext: Set<AIPromptContextOption>, to lines: inout [String]) {
    guard includedContext.contains(option), !line.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix(":") else { return }
    lines.append(line)
  }

  private static func appendBlock(_ title: String, _ body: String?, when option: AIPromptContextOption, includedContext: Set<AIPromptContextOption>, to lines: inout [String]) {
    let trimmed = body?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard includedContext.contains(option), !trimmed.isEmpty else { return }
    lines.append("\(title):\n\(trimmed)")
  }
}

public struct AliyunAPIKeyProvider: Sendable {
  private var keychainReader: @Sendable () -> String?
  private var configuredKeyReader: @Sendable () -> String?
  private var environmentReader: @Sendable (String) -> String?

  public init(
    keychainReader: @escaping @Sendable () -> String? = { AliyunKeychain.readAPIKey() },
    configuredKeyReader: @escaping @Sendable () -> String?,
    environmentReader: @escaping @Sendable (String) -> String? = { ProcessInfo.processInfo.environment[$0] }
  ) {
    self.keychainReader = keychainReader
    self.configuredKeyReader = configuredKeyReader
    self.environmentReader = environmentReader
  }

  public func apiKey() -> String? {
    nonEmpty(keychainReader()) ?? nonEmpty(configuredKeyReader()) ?? nonEmpty(environmentReader("DASHSCOPE_API_KEY"))
  }

  private func nonEmpty(_ value: String?) -> String? {
    let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? nil : trimmed
  }
}

import Foundation
import Testing

@testable import ProGhosttyCore

@Suite("AI CLI companion")
@MainActor
struct AICLICompanionTests {
  @Test func builtInProfilesUseBracketedPasteOnlyByDefault() {
    #expect(AICLIProfile.codex.launchCommand == "codex")
    #expect(AICLIProfile.codex.processNames == ["codex"])
    #expect(AICLIProfile.codex.defaultSendMode == .bracketedPasteOnly)

    #expect(AICLIProfile.claudeCode.launchCommand == "claude")
    #expect(AICLIProfile.claudeCode.processNames == ["claude"])
    #expect(AICLIProfile.claudeCode.defaultSendMode == .bracketedPasteOnly)
  }

  @Test func promptPayloadUsesBracketedPasteAndOnlySendsReturnWhenRequested() {
    let prompt = "Fix the failing test\nkeep the style"

    #expect(AISendMode.bracketedPasteOnly.payload(for: prompt) == "\u{1B}[200~Fix the failing test\nkeep the style\u{1B}[201~")
    #expect(AISendMode.bracketedPasteAndEnter.payload(for: prompt).hasSuffix("\u{1B}[201~\n"))
  }

  @Test func sessionManagerStartsInRightSplitWithWorkspaceRootAndFocusesSession() throws {
    let terminalManager = RecordingSessionManager()
    let focusStore = TerminalFocusStore()
    let paneController = PaneWorkspaceController(sessionManager: terminalManager, focusStore: focusStore)
    let base = try paneController.openTerminal(
      title: "Project",
      config: TerminalSessionConfig(shellPath: "/bin/zsh", workingDirectory: "/repo", environment: [:], rows: 24, cols: 80),
      paneTitle: "repo",
      cwd: "/repo"
    )
    let manager = AISessionManager(
      paneController: paneController,
      terminalSessionManager: terminalManager,
      focusStore: focusStore
    )

    let session = try manager.start(
      profile: .codex,
      workspace: AIWorkspace(id: base.workspace.id, name: "Project", rootPath: "/repo", currentPaneID: base.pane.paneId),
      openMode: .rightSplit
    )

    #expect(session.profile == .codex)
    #expect(session.workspaceID == base.workspace.id)
    #expect(terminalManager.createdConfigs.last?.shellPath == "/bin/zsh")
    #expect(terminalManager.createdConfigs.last?.launchCommand == "codex")
    #expect(terminalManager.createdConfigs.last?.environment["PROGHOSTTY_AI_COMMAND"] == "codex")
    #expect(terminalManager.createdConfigs.last?.workingDirectory == "/repo")
    #expect(focusStore.focusedPaneId(in: base.workspace.id) == session.paneID)
    #expect(manager.listAISessions().map(\.id) == [session.id])
  }

  @Test func sessionManagerSendsPromptToAISessionWithSelectedMode() throws {
    let terminalManager = RecordingSessionManager()
    let focusStore = TerminalFocusStore()
    let paneController = PaneWorkspaceController(sessionManager: terminalManager, focusStore: focusStore)
    let opened = try paneController.openTerminal(
      title: "Project",
      config: TerminalSessionConfig(shellPath: "/bin/zsh", workingDirectory: "/repo", environment: [:], rows: 24, cols: 80),
      paneTitle: "repo",
      cwd: "/repo"
    )
    let manager = AISessionManager(
      paneController: paneController,
      terminalSessionManager: terminalManager,
      focusStore: focusStore
    )
    let session = try manager.start(
      profile: .claudeCode,
      workspace: AIWorkspace(id: opened.workspace.id, name: "Project", rootPath: "/repo", currentPaneID: opened.pane.paneId),
      openMode: .currentPane
    )

    try manager.sendPrompt("review this", to: session.id, mode: .bracketedPasteOnly)

    #expect(String(decoding: terminalManager.writes.last?.data ?? Data(), as: UTF8.self) == "\u{1B}[200~review this\u{1B}[201~")
    #expect(terminalManager.writes.last?.session == session.terminalSessionID)
  }

  @Test func gitStatusParserMapsPorcelainStatuses() {
    let output = """
     M Sources/App.swift
    A  Sources/New.swift
    D  Sources/Old.swift
    ?? scratch.txt
    R  Sources/Before.swift -> Sources/After.swift
    """

    let files = GitModifiedFile.parsePorcelain(output)

    #expect(files.map(\.path) == [
      "Sources/App.swift",
      "Sources/New.swift",
      "Sources/Old.swift",
      "scratch.txt",
      "Sources/After.swift",
    ])
    #expect(files.map(\.status) == [.modified, .added, .deleted, .untracked, .renamed])
  }

  @Test func promptComposerBuildsStructuredPromptWithSelectedContext() {
    let prompt = AIPromptComposer.compose(
      request: "make tests pass",
      template: .fixError,
      context: AIPromptContext(
        workspacePath: "/repo",
        gitBranch: "main",
        gitStatus: " M Tests/FooTests.swift",
        gitDiff: "diff --git a/Foo.swift b/Foo.swift",
        selectedTerminalText: "error: no exact matches",
        changedFiles: [GitModifiedFile(status: .modified, path: "Tests/FooTests.swift")]
      ),
      includedContext: [.workspacePath, .gitBranch, .gitStatus, .changedFileList]
    )

    #expect(prompt.contains("Task: Fix Error"))
    #expect(prompt.contains("make tests pass"))
    #expect(prompt.contains("Make the smallest practical change"))
    #expect(prompt.contains("Keep the existing style"))
    #expect(prompt.contains("Before editing, explain"))
    #expect(prompt.contains("If information is insufficient, ask"))
    #expect(prompt.contains("Workspace: /repo"))
    #expect(prompt.contains("Branch: main"))
    #expect(prompt.contains("Modified: Tests/FooTests.swift"))
    #expect(!prompt.contains("diff --git"))
  }

  @Test func apiKeyProviderPrefersKeychainThenSettingsThenEnvironment() {
    let provider = AliyunAPIKeyProvider(
      keychainReader: { "keychain-value" },
      configuredKeyReader: { "configured-value" },
      environmentReader: { _ in "environment-value" }
    )

    #expect(provider.apiKey() == "keychain-value")
    #expect(AliyunAPIKeyProvider(
      keychainReader: { nil },
      configuredKeyReader: { "configured-value" },
      environmentReader: { _ in "environment-value" }
    ).apiKey() == "configured-value")
    #expect(AliyunAPIKeyProvider(
      keychainReader: { nil },
      configuredKeyReader: { "" },
      environmentReader: { $0 == "DASHSCOPE_API_KEY" ? "environment-value" : nil }
    ).apiKey() == "environment-value")
  }

  @Test func asrServiceReportsMissingAPIKeyBeforeRequestingAudio() async {
    let service = AliyunASRService(apiKeyProvider: AliyunAPIKeyProvider(
      keychainReader: { nil },
      configuredKeyReader: { nil },
      environmentReader: { _ in nil }
    ))

    var events: [ASRTranscriptEvent] = []
    for await event in service.transcribe() {
      events.append(event)
    }

    #expect(events == [.error("Missing DashScope API key. Configure it in Settings or set DASHSCOPE_API_KEY.")])
  }
}

@MainActor
private final class RecordingSessionManager: TerminalSessionManager {
  var createdConfigs: [TerminalSessionConfig] = []
  var closedSessions: [TerminalSessionID] = []
  var writes: [(data: Data, session: TerminalSessionID)] = []
  let events: AsyncStream<TerminalEvent> = AsyncStream { continuation in
    continuation.finish()
  }

  func createSession(config: TerminalSessionConfig) throws -> TerminalSessionID {
    createdConfigs.append(config)
    return TerminalSessionID()
  }

  func closeSession(_ id: TerminalSessionID) {
    closedSessions.append(id)
  }

  func resizeSession(_ id: TerminalSessionID, rows: Int, cols: Int) {}

  func writeInput(_ data: Data, to id: TerminalSessionID) {
    writes.append((data, id))
  }

  func controlToken(for id: TerminalSessionID) -> String? { nil }
}

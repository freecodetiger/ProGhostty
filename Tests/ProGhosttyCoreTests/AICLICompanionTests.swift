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

  @Test func openAICompatibleProviderConfigUsesConfiguredValuesThenEnvironment() {
    let configured = OpenAICompatibleProviderConfig(
      baseURL: "https://example.test/v1",
      apiKey: " configured-key ",
      model: " gpt-test ",
      environmentReader: { _ in nil }
    )

    #expect(configured.resolvedBaseURL?.absoluteString == "https://example.test/v1")
    #expect(configured.resolvedAPIKey == "configured-key")
    #expect(configured.resolvedModel == "gpt-test")

    let environment = OpenAICompatibleProviderConfig(
      baseURL: "",
      apiKey: nil,
      model: "",
      environmentReader: { key in
        switch key {
        case "OPENAI_BASE_URL": return "https://env.test/v1"
        case "OPENAI_API_KEY": return "env-key"
        case "OPENAI_MODEL": return "env-model"
        default: return nil
        }
      }
    )

    #expect(environment.resolvedBaseURL?.absoluteString == "https://env.test/v1")
    #expect(environment.resolvedAPIKey == "env-key")
    #expect(environment.resolvedModel == "env-model")
  }

  @Test func openAICompatibleRequestEncodesChatCompletionsPayload() throws {
    let request = OpenAICompatibleChatRequest(
      model: "gpt-test",
      messages: [
        OpenAICompatibleChatMessage(role: "system", content: "system"),
        OpenAICompatibleChatMessage(role: "user", content: "user"),
      ],
      temperature: 0.2
    )

    let data = try JSONEncoder().encode(request)
    let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

    #expect(json["model"] as? String == "gpt-test")
    #expect(json["temperature"] as? Double == 0.2)
    let messages = try #require(json["messages"] as? [[String: String]])
    #expect(messages.map { $0["role"] } == ["system", "user"])
    #expect(messages.map { $0["content"] } == ["system", "user"])
  }

  @Test func openAICompatibleResponseDecodesFirstMessageContent() throws {
    let data = """
      {
        "choices": [
          {
            "message": {
              "role": "assistant",
              "content": "Refined prompt"
            }
          }
        ]
      }
      """.data(using: .utf8)!

    let response = try JSONDecoder().decode(OpenAICompatibleChatResponse.self, from: data)

    #expect(response.firstContent == "Refined prompt")
  }

  @Test func openAICompatibleClientPostsToChatCompletions() async throws {
    let transport = RecordingOpenAITransport(responseData: """
      {"choices":[{"message":{"role":"assistant","content":"Refined"}}]}
      """.data(using: .utf8)!)
    let client = OpenAICompatibleChatClient(transport: transport)
    let config = OpenAICompatibleProviderConfig(
      baseURL: "https://api.test/v1",
      apiKey: "secret",
      model: "gpt-test",
      environmentReader: { _ in nil }
    )

    let content = try await client.complete(
      request: OpenAICompatibleChatRequest(
        model: "gpt-test",
        messages: [OpenAICompatibleChatMessage(role: "user", content: "hello")]
      ),
      config: config
    )

    #expect(content == "Refined")
    #expect(transport.lastRequest?.url?.absoluteString == "https://api.test/v1/chat/completions")
    #expect(transport.lastRequest?.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
    #expect(transport.lastRequest?.value(forHTTPHeaderField: "Content-Type") == "application/json")
  }

  @Test func codexPromptRefinerBuildsCodexFocusedMessages() throws {
    let config = OpenAICompatibleProviderConfig(
      baseURL: "https://api.test/v1",
      apiKey: "key",
      model: "gpt-test",
      environmentReader: { _ in nil }
    )
    let refiner = CodexPromptRefiner(client: StubPromptClient(result: "unused"))

    let request = try refiner.makeChatRequest(
      userRequest: "fix the test",
      context: AIPromptContext(
        workspacePath: "/repo",
        gitBranch: "main",
        gitStatus: " M Tests/FooTests.swift",
        selectedTerminalText: "failure output",
        changedFiles: [GitModifiedFile(status: .modified, path: "Tests/FooTests.swift")]
      ),
      includedContext: [.workspacePath, .gitBranch, .gitStatus, .changedFileList, .selectedTerminalText],
      config: config
    )

    #expect(request.model == "gpt-test")
    #expect(request.messages[0].role == "system")
    #expect(request.messages[0].content.contains("Codex CLI"))
    #expect(request.messages[1].content.contains("fix the test"))
    #expect(request.messages[1].content.contains("Workspace: /repo"))
    #expect(request.messages[1].content.contains("Branch: main"))
    #expect(request.messages[1].content.contains("Modified: Tests/FooTests.swift"))
    #expect(request.messages[1].content.contains("failure output"))
  }

  @Test func codexPromptRefinerFallsBackToRawRequestWhenProviderIsMissing() async {
    let refiner = CodexPromptRefiner(client: StubPromptClient(result: "should not be used"))
    let result = await refiner.refine(
      userRequest: "run tests",
      context: AIPromptContext(workspacePath: "/repo"),
      includedContext: [.workspacePath],
      config: OpenAICompatibleProviderConfig(baseURL: "", apiKey: nil, model: "", environmentReader: { _ in nil })
    )

    #expect(result == .raw("run tests"))
  }

  @Test func commandCapsuleStateTracksVoiceAndDraftLifecycle() {
    var state = CommandCapsuleState()

    state.open()
    #expect(state.isPresented == true)
    #expect(state.phase == .idle)
    #expect(state.includedContext == [.workspacePath, .gitBranch, .gitStatus, .changedFileList])

    state.startListening()
    state.updateVoicePartial("fix tests")
    #expect(state.phase == .listening)
    #expect(state.voicePartial == "fix tests")

    state.appendFinalTranscript("fix tests")
    #expect(state.request == "fix tests")
    #expect(state.voicePartial == "")
    #expect(state.phase == .idle)

    state.startRefining()
    #expect(state.phase == .refining)

    state.finishRefining(draft: "Refined prompt")
    #expect(state.phase == .ready)
    #expect(state.draft == "Refined prompt")

    state.markSent()
    #expect(state.phase == .sent)
  }

  @Test func commandCapsuleStatePreservesDraftOnError() {
    var state = CommandCapsuleState()
    state.open()
    state.request = "raw request"
    state.draft = "draft"

    state.fail("network failed")

    #expect(state.phase == .error)
    #expect(state.errorMessage == "network failed")
    #expect(state.request == "raw request")
    #expect(state.draft == "draft")
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

private final class RecordingOpenAITransport: OpenAICompatibleChatTransport, @unchecked Sendable {
  var lastRequest: URLRequest?
  var lastBody: Data?
  let responseData: Data

  init(responseData: Data) {
    self.responseData = responseData
  }

  func data(for request: URLRequest, body: Data) async throws -> (Data, HTTPURLResponse) {
    lastRequest = request
    lastBody = body
    return (
      responseData,
      HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
    )
  }
}

private struct StubPromptClient: CodexPromptRefiningClient {
  var result: String

  func complete(request: OpenAICompatibleChatRequest, config: OpenAICompatibleProviderConfig) async throws -> String {
    result
  }
}

# Codex Command Capsule Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a stable first version of the floating Codex Command Capsule for voice/text prompt drafting, OpenAI-compatible prompt refinement, and bracketed-paste delivery to Codex CLI.

**Architecture:** Add testable core models for OpenAI-compatible settings, chat request/response handling, prompt refinement, and capsule state transitions. Bridge those models through `AppModel`, then add a compact SwiftUI floating capsule above the terminal without changing terminal pane layout.

**Tech Stack:** Swift 6.1, SwiftPM, SwiftUI/AppKit, Foundation `URLSession`, existing `AliyunASRService`, existing `AISessionManager`, Swift Testing.

---

## File Structure

- Create `Sources/ProGhosttyCore/AI/OpenAICompatibleClient.swift`
  - Owns provider settings, API key resolution, request/response payload types, and non-streaming `/chat/completions` calls.
- Create `Sources/ProGhosttyCore/AI/CodexPromptRefiner.swift`
  - Turns a user request plus `AIPromptContext` and selected context options into a prompt-refinement request.
- Create `Sources/ProGhosttyCore/AI/CommandCapsuleState.swift`
  - Testable state model for lifecycle, request text, draft text, voice partial text, context selections, and errors.
- Modify `Sources/ProGhosttyCore/Settings/AppSettings.swift`
  - Add OpenAI-compatible API settings and an `openCodexCommandCapsule` keyboard shortcut action.
- Modify `Tests/ProGhosttyCoreTests/AppSettingsTests.swift`
  - Verify legacy decoding and default shortcut migration.
- Modify `Tests/ProGhosttyCoreTests/AICLICompanionTests.swift`
  - Add tests for provider config, request encoding, response decoding, prompt refiner behavior, and capsule state transitions.
- Modify `Sources/ProGhosttyApp/UI/AppModel.swift`
  - Add capsule visibility/state, ASR handling, refine task handling, and send-to-Codex bridge.
- Create `Sources/ProGhosttyApp/UI/CodexCommandCapsuleView.swift`
  - Floating capsule UI with idle/listening/refining/ready/error/sent states.
- Modify `Sources/ProGhosttyApp/UI/RootView.swift`
  - Overlay capsule at bottom center without dimming or resizing terminal.
- Modify `Sources/ProGhosttyApp/ProGhosttyApp.swift`
  - Add AI menu entry and keyboard shortcut for opening the capsule.
- Modify `Sources/ProGhosttyApp/UI/SettingsView.swift`
  - Add OpenAI-compatible settings fields and shortcut label support.

---

## Task 1: Core Settings and Configuration

**Files:**
- Modify: `Sources/ProGhosttyCore/Settings/AppSettings.swift`
- Modify: `Tests/ProGhosttyCoreTests/AppSettingsTests.swift`

- [ ] **Step 1: Write failing tests for OpenAI-compatible defaults and legacy decoding**

Add these tests to `Tests/ProGhosttyCoreTests/AppSettingsTests.swift`:

```swift
  @Test func openAICompatibleSettingsHaveStableDefaults() {
    let settings = AppSettings.defaults

    #expect(settings.openAICompatibleBaseURL == "https://api.openai.com/v1")
    #expect(settings.openAICompatibleAPIKey == nil)
    #expect(settings.openAICompatibleModel == "")
    #expect(settings.keyboardShortcuts.shortcut(for: .openCodexCommandCapsule).key == "i")
    #expect(settings.keyboardShortcuts.shortcut(for: .openCodexCommandCapsule).modifiers == [.command, .shift])
  }
```

Also add these expectations to the existing `decodesLegacySettingsWithNewLanguageAndThemeDefaults` test:

```swift
    #expect(settings.openAICompatibleBaseURL == "https://api.openai.com/v1")
    #expect(settings.openAICompatibleAPIKey == nil)
    #expect(settings.openAICompatibleModel == "")
    #expect(settings.keyboardShortcuts.shortcut(for: .openCodexCommandCapsule).key == "i")
```

- [ ] **Step 2: Run tests to verify failure**

Run:

```bash
swift test --filter AppSettingsTests/openAICompatibleSettingsHaveStableDefaults --no-parallel
```

Expected: FAIL because `AppSettings` has no `openAICompatibleBaseURL`, `openAICompatibleAPIKey`, `openAICompatibleModel`, or `.openCodexCommandCapsule`.

- [ ] **Step 3: Add settings fields and defaults**

In `Sources/ProGhosttyCore/Settings/AppSettings.swift`, add stored properties to `AppSettings`:

```swift
  public var openAICompatibleBaseURL: String
  public var openAICompatibleAPIKey: String?
  public var openAICompatibleModel: String
```

Update `AppSettings.defaults` with:

```swift
    openAICompatibleBaseURL: "https://api.openai.com/v1",
    openAICompatibleAPIKey: nil,
    openAICompatibleModel: "",
```

Add coding keys:

```swift
    case openAICompatibleBaseURL
    case openAICompatibleAPIKey
    case openAICompatibleModel
```

Update the public initializer signature and body with those fields.

Update `init(from:)`:

```swift
    openAICompatibleBaseURL = try container.decodeIfPresent(String.self, forKey: .openAICompatibleBaseURL)
      ?? Self.defaults.openAICompatibleBaseURL
    openAICompatibleAPIKey = try container.decodeIfPresent(String.self, forKey: .openAICompatibleAPIKey)
    openAICompatibleModel = try container.decodeIfPresent(String.self, forKey: .openAICompatibleModel)
      ?? Self.defaults.openAICompatibleModel
```

Add keyboard shortcut action:

```swift
  case openCodexCommandCapsule
```

Add default binding:

```swift
    .openCodexCommandCapsule: KeyboardShortcutBinding(key: "i", modifiers: [.command, .shift]),
```

- [ ] **Step 4: Run tests to verify pass**

Run:

```bash
swift test --filter AppSettingsTests --no-parallel
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/ProGhosttyCore/Settings/AppSettings.swift Tests/ProGhosttyCoreTests/AppSettingsTests.swift
git commit -m "feat: add codex capsule provider settings"
```

---

## Task 2: OpenAI-Compatible Client

**Files:**
- Create: `Sources/ProGhosttyCore/AI/OpenAICompatibleClient.swift`
- Modify: `Tests/ProGhosttyCoreTests/AICLICompanionTests.swift`

- [ ] **Step 1: Write failing tests for config resolution and payload coding**

Add tests to `Tests/ProGhosttyCoreTests/AICLICompanionTests.swift`:

```swift
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
```

- [ ] **Step 2: Run tests to verify failure**

Run:

```bash
swift test --filter AICLICompanionTests/openAICompatibleProviderConfigUsesConfiguredValuesThenEnvironment --no-parallel
```

Expected: FAIL because `OpenAICompatibleProviderConfig` is not defined.

- [ ] **Step 3: Implement provider config and payload types**

Create `Sources/ProGhosttyCore/AI/OpenAICompatibleClient.swift`:

```swift
import Foundation

public struct OpenAICompatibleProviderConfig: Equatable, Sendable {
  public var baseURL: String
  public var apiKey: String?
  public var model: String
  private var environmentReader: @Sendable (String) -> String?

  public init(
    baseURL: String,
    apiKey: String?,
    model: String,
    environmentReader: @escaping @Sendable (String) -> String? = { ProcessInfo.processInfo.environment[$0] }
  ) {
    self.baseURL = baseURL
    self.apiKey = apiKey
    self.model = model
    self.environmentReader = environmentReader
  }

  public var resolvedBaseURL: URL? {
    let value = nonEmpty(baseURL) ?? nonEmpty(environmentReader("OPENAI_BASE_URL")) ?? "https://api.openai.com/v1"
    return URL(string: value.trimmingCharacters(in: CharacterSet(charactersIn: "/").inverted.isEmpty ? value : value)
  }

  public var resolvedAPIKey: String? {
    nonEmpty(apiKey) ?? nonEmpty(environmentReader("OPENAI_API_KEY"))
  }

  public var resolvedModel: String? {
    nonEmpty(model) ?? nonEmpty(environmentReader("OPENAI_MODEL"))
  }

  private func nonEmpty(_ value: String?) -> String? {
    let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? nil : trimmed
  }
}

public struct OpenAICompatibleChatMessage: Codable, Equatable, Sendable {
  public var role: String
  public var content: String

  public init(role: String, content: String) {
    self.role = role
    self.content = content
  }
}

public struct OpenAICompatibleChatRequest: Codable, Equatable, Sendable {
  public var model: String
  public var messages: [OpenAICompatibleChatMessage]
  public var temperature: Double

  public init(model: String, messages: [OpenAICompatibleChatMessage], temperature: Double = 0.2) {
    self.model = model
    self.messages = messages
    self.temperature = temperature
  }
}

public struct OpenAICompatibleChatResponse: Decodable, Equatable, Sendable {
  public struct Choice: Decodable, Equatable, Sendable {
    public var message: OpenAICompatibleChatMessage
  }

  public var choices: [Choice]

  public var firstContent: String? {
    choices.first?.message.content.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
```

Before running tests, simplify `resolvedBaseURL` if needed to:

```swift
  public var resolvedBaseURL: URL? {
    let value = nonEmpty(baseURL) ?? nonEmpty(environmentReader("OPENAI_BASE_URL")) ?? "https://api.openai.com/v1"
    return URL(string: value)
  }
```

- [ ] **Step 4: Run tests to verify pass**

Run:

```bash
swift test --filter AICLICompanionTests/openAICompatible --no-parallel
```

Expected: PASS for the three OpenAI-compatible tests.

- [ ] **Step 5: Write failing test for client request execution**

Add a test-only transport and client test:

```swift
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
```

- [ ] **Step 6: Run client test to verify failure**

Run:

```bash
swift test --filter AICLICompanionTests/openAICompatibleClientPostsToChatCompletions --no-parallel
```

Expected: FAIL because `OpenAICompatibleChatClient` and `OpenAICompatibleChatTransport` are not defined.

- [ ] **Step 7: Implement transport and client**

Append to `OpenAICompatibleClient.swift`:

```swift
public enum OpenAICompatibleClientError: Error, LocalizedError, Equatable {
  case missingBaseURL
  case missingAPIKey
  case missingModel
  case badStatus(Int)
  case emptyResponse

  public var errorDescription: String? {
    switch self {
    case .missingBaseURL:
      return "OpenAI-compatible base URL is not configured."
    case .missingAPIKey:
      return "OpenAI-compatible API key is not configured."
    case .missingModel:
      return "OpenAI-compatible model is not configured."
    case .badStatus(let status):
      return "OpenAI-compatible API returned HTTP \(status)."
    case .emptyResponse:
      return "OpenAI-compatible API returned an empty response."
    }
  }
}

public protocol OpenAICompatibleChatTransport: Sendable {
  func data(for request: URLRequest, body: Data) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionOpenAICompatibleChatTransport: OpenAICompatibleChatTransport {
  public init() {}

  public func data(for request: URLRequest, body: Data) async throws -> (Data, HTTPURLResponse) {
    var request = request
    request.httpBody = body
    let (data, response) = try await URLSession.shared.data(for: request)
    return (data, response as? HTTPURLResponse ?? HTTPURLResponse(
      url: request.url!,
      statusCode: 200,
      httpVersion: nil,
      headerFields: nil
    )!)
  }
}

public struct OpenAICompatibleChatClient: Sendable {
  private let transport: OpenAICompatibleChatTransport

  public init(transport: OpenAICompatibleChatTransport = URLSessionOpenAICompatibleChatTransport()) {
    self.transport = transport
  }

  public func complete(request: OpenAICompatibleChatRequest, config: OpenAICompatibleProviderConfig) async throws -> String {
    guard let baseURL = config.resolvedBaseURL else { throw OpenAICompatibleClientError.missingBaseURL }
    guard let apiKey = config.resolvedAPIKey else { throw OpenAICompatibleClientError.missingAPIKey }
    guard config.resolvedModel != nil else { throw OpenAICompatibleClientError.missingModel }

    let url = baseURL.appendingPathComponent("chat/completions")
    var urlRequest = URLRequest(url: url)
    urlRequest.httpMethod = "POST"
    urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

    let body = try JSONEncoder().encode(request)
    let (data, response) = try await transport.data(for: urlRequest, body: body)
    guard (200..<300).contains(response.statusCode) else {
      throw OpenAICompatibleClientError.badStatus(response.statusCode)
    }
    let decoded = try JSONDecoder().decode(OpenAICompatibleChatResponse.self, from: data)
    guard let content = decoded.firstContent, !content.isEmpty else {
      throw OpenAICompatibleClientError.emptyResponse
    }
    return content
  }
}
```

- [ ] **Step 8: Run tests to verify pass**

Run:

```bash
swift test --filter AICLICompanionTests/openAICompatible --no-parallel
```

Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add Sources/ProGhosttyCore/AI/OpenAICompatibleClient.swift Tests/ProGhosttyCoreTests/AICLICompanionTests.swift
git commit -m "feat: add openai compatible prompt client"
```

---

## Task 3: Codex Prompt Refiner

**Files:**
- Create: `Sources/ProGhosttyCore/AI/CodexPromptRefiner.swift`
- Modify: `Tests/ProGhosttyCoreTests/AICLICompanionTests.swift`

- [ ] **Step 1: Write failing tests for prompt refine request construction**

Add tests:

```swift
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
```

Add this test helper near the existing helpers:

```swift
private struct StubPromptClient: CodexPromptRefiningClient {
  var result: String

  func complete(request: OpenAICompatibleChatRequest, config: OpenAICompatibleProviderConfig) async throws -> String {
    result
  }
}
```

- [ ] **Step 2: Run tests to verify failure**

Run:

```bash
swift test --filter AICLICompanionTests/codexPromptRefiner --no-parallel
```

Expected: FAIL because `CodexPromptRefiner` is not defined.

- [ ] **Step 3: Implement refiner**

Create `Sources/ProGhosttyCore/AI/CodexPromptRefiner.swift`:

```swift
import Foundation

public protocol CodexPromptRefiningClient: Sendable {
  func complete(request: OpenAICompatibleChatRequest, config: OpenAICompatibleProviderConfig) async throws -> String
}

extension OpenAICompatibleChatClient: CodexPromptRefiningClient {}

public enum CodexPromptRefineResult: Equatable, Sendable {
  case refined(String)
  case raw(String)
  case failed(String, fallback: String)

  public var draft: String {
    switch self {
    case .refined(let text), .raw(let text):
      return text
    case .failed(_, let fallback):
      return fallback
    }
  }
}

public struct CodexPromptRefiner: Sendable {
  private let client: CodexPromptRefiningClient

  public init(client: CodexPromptRefiningClient = OpenAICompatibleChatClient()) {
    self.client = client
  }

  public func refine(
    userRequest: String,
    context: AIPromptContext,
    includedContext: Set<AIPromptContextOption>,
    config: OpenAICompatibleProviderConfig
  ) async -> CodexPromptRefineResult {
    let trimmed = userRequest.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return .raw("") }
    guard config.resolvedBaseURL != nil, config.resolvedAPIKey != nil, config.resolvedModel != nil else {
      return .raw(trimmed)
    }
    do {
      let request = try makeChatRequest(
        userRequest: trimmed,
        context: context,
        includedContext: includedContext,
        config: config
      )
      return .refined(try await client.complete(request: request, config: config))
    } catch {
      let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
      return .failed(message, fallback: trimmed)
    }
  }

  public func makeChatRequest(
    userRequest: String,
    context: AIPromptContext,
    includedContext: Set<AIPromptContextOption>,
    config: OpenAICompatibleProviderConfig
  ) throws -> OpenAICompatibleChatRequest {
    guard let model = config.resolvedModel else { throw OpenAICompatibleClientError.missingModel }
    let contextText = AIPromptComposer.compose(
      request: userRequest,
      template: .refactorSafely,
      context: context,
      includedContext: includedContext
    )
    let system = """
    You refine short user requests into precise prompts for Codex CLI running inside a real terminal.
    Return only the prompt to paste into Codex.
    Keep the prompt concrete, scoped, and verification-oriented.
    Do not answer the task yourself.
    """
    return OpenAICompatibleChatRequest(
      model: model,
      messages: [
        OpenAICompatibleChatMessage(role: "system", content: system),
        OpenAICompatibleChatMessage(role: "user", content: contextText),
      ],
      temperature: 0.2
    )
  }
}
```

- [ ] **Step 4: Run tests to verify pass**

Run:

```bash
swift test --filter AICLICompanionTests/codexPromptRefiner --no-parallel
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/ProGhosttyCore/AI/CodexPromptRefiner.swift Tests/ProGhosttyCoreTests/AICLICompanionTests.swift
git commit -m "feat: add codex prompt refiner"
```

---

## Task 4: Command Capsule State Model

**Files:**
- Create: `Sources/ProGhosttyCore/AI/CommandCapsuleState.swift`
- Modify: `Tests/ProGhosttyCoreTests/AICLICompanionTests.swift`

- [ ] **Step 1: Write failing tests for capsule state transitions**

Add tests:

```swift
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
```

- [ ] **Step 2: Run tests to verify failure**

Run:

```bash
swift test --filter AICLICompanionTests/commandCapsuleState --no-parallel
```

Expected: FAIL because `CommandCapsuleState` is not defined.

- [ ] **Step 3: Implement state model**

Create `Sources/ProGhosttyCore/AI/CommandCapsuleState.swift`:

```swift
import Foundation

public enum CommandCapsulePhase: String, Codable, Equatable, Sendable {
  case idle
  case listening
  case refining
  case ready
  case error
  case sent
}

public struct CommandCapsuleState: Equatable, Sendable {
  public var isPresented: Bool
  public var phase: CommandCapsulePhase
  public var request: String
  public var voicePartial: String
  public var draft: String
  public var includedContext: Set<AIPromptContextOption>
  public var errorMessage: String?

  public init(
    isPresented: Bool = false,
    phase: CommandCapsulePhase = .idle,
    request: String = "",
    voicePartial: String = "",
    draft: String = "",
    includedContext: Set<AIPromptContextOption> = [.workspacePath, .gitBranch, .gitStatus, .changedFileList],
    errorMessage: String? = nil
  ) {
    self.isPresented = isPresented
    self.phase = phase
    self.request = request
    self.voicePartial = voicePartial
    self.draft = draft
    self.includedContext = includedContext
    self.errorMessage = errorMessage
  }

  public mutating func open() {
    isPresented = true
    if phase == .sent {
      phase = .idle
    }
  }

  public mutating func dismiss() {
    isPresented = false
    phase = .idle
    voicePartial = ""
    errorMessage = nil
  }

  public mutating func startListening() {
    phase = .listening
    voicePartial = ""
    errorMessage = nil
  }

  public mutating func updateVoicePartial(_ text: String) {
    voicePartial = text
  }

  public mutating func appendFinalTranscript(_ text: String) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    request = [request, trimmed]
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      .joined(separator: "\n")
    voicePartial = ""
    phase = .idle
  }

  public mutating func startRefining() {
    phase = .refining
    errorMessage = nil
    if draft.isEmpty {
      draft = request
    }
  }

  public mutating func finishRefining(draft: String) {
    self.draft = draft
    phase = .ready
    errorMessage = nil
  }

  public mutating func fail(_ message: String) {
    phase = .error
    errorMessage = message
  }

  public mutating func markSent() {
    phase = .sent
    errorMessage = nil
  }
}
```

- [ ] **Step 4: Run tests to verify pass**

Run:

```bash
swift test --filter AICLICompanionTests/commandCapsuleState --no-parallel
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/ProGhosttyCore/AI/CommandCapsuleState.swift Tests/ProGhosttyCoreTests/AICLICompanionTests.swift
git commit -m "feat: add codex command capsule state"
```

---

## Task 5: AppModel Integration

**Files:**
- Modify: `Sources/ProGhosttyApp/UI/AppModel.swift`

- [ ] **Step 1: Add app-level state and dependencies**

Add published state near existing AI properties:

```swift
  @Published var commandCapsuleState = CommandCapsuleState()
```

Add private task properties:

```swift
  private var commandCapsuleVoiceTask: Task<Void, Never>?
  private var commandCapsuleRefineTask: Task<Void, Never>?
```

- [ ] **Step 2: Add open/dismiss methods**

Add methods near existing AI companion methods:

```swift
  func openCodexCommandCapsule() {
    isHistoryPresented = false
    isWorkspaceSwitcherPresented = false
    isAICompanionPresented = false
    commandCapsuleState.open()
  }

  func dismissCodexCommandCapsule() {
    commandCapsuleVoiceTask?.cancel()
    commandCapsuleVoiceTask = nil
    commandCapsuleRefineTask?.cancel()
    commandCapsuleRefineTask = nil
    commandCapsuleState.dismiss()
  }
```

Update `closeUtilityOverlays()` to dismiss the capsule state without discarding the user draft only when the user explicitly closes all utility UI:

```swift
    commandCapsuleState.dismiss()
```

- [ ] **Step 3: Add context toggle and raw draft helpers**

Add:

```swift
  func toggleCommandCapsuleContext(_ option: AIPromptContextOption) {
    if commandCapsuleState.includedContext.contains(option) {
      commandCapsuleState.includedContext.remove(option)
    } else {
      commandCapsuleState.includedContext.insert(option)
    }
  }

  func useRawCommandCapsuleRequestAsDraft() {
    let trimmed = commandCapsuleState.request.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    commandCapsuleState.finishRefining(draft: trimmed)
  }
```

- [ ] **Step 4: Add ASR voice methods**

Add:

```swift
  func startCommandCapsuleVoiceInput() {
    guard commandCapsuleState.phase != .listening else { return }
    commandCapsuleState.startListening()
    let service = makeASRService()
    commandCapsuleVoiceTask?.cancel()
    commandCapsuleVoiceTask = Task { [weak self] in
      for await event in service.transcribe() {
        await MainActor.run {
          guard let self else { return }
          switch event {
          case .partial(let text):
            commandCapsuleState.updateVoicePartial(text)
          case .final(let text):
            commandCapsuleState.appendFinalTranscript(text)
          case .error(let message):
            commandCapsuleState.fail(message)
          case .completed:
            if commandCapsuleState.phase == .listening {
              commandCapsuleState.phase = .idle
            }
          }
        }
      }
    }
  }

  func stopCommandCapsuleVoiceInput() {
    commandCapsuleVoiceTask?.cancel()
    commandCapsuleVoiceTask = nil
    if commandCapsuleState.phase == .listening {
      commandCapsuleState.phase = .idle
      commandCapsuleState.voicePartial = ""
    }
  }
```

If direct assignment to `phase` or `voicePartial` is blocked by access control, add public mutating methods to `CommandCapsuleState` in Task 4 and use them here.

- [ ] **Step 5: Add refine method**

Add:

```swift
  func refineCommandCapsulePrompt() {
    let request = commandCapsuleState.request.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !request.isEmpty else { return }
    commandCapsuleState.startRefining()
    let context = makeAIContext(includeDiff: false)
    let included = commandCapsuleState.includedContext
    let config = OpenAICompatibleProviderConfig(
      baseURL: settings.openAICompatibleBaseURL,
      apiKey: settings.openAICompatibleAPIKey,
      model: settings.openAICompatibleModel
    )
    commandCapsuleRefineTask?.cancel()
    commandCapsuleRefineTask = Task { [weak self] in
      let result = await CodexPromptRefiner().refine(
        userRequest: request,
        context: context,
        includedContext: included,
        config: config
      )
      await MainActor.run {
        guard let self else { return }
        switch result {
        case .refined(let text), .raw(let text):
          commandCapsuleState.finishRefining(draft: text)
        case .failed(let message, let fallback):
          commandCapsuleState.draft = fallback
          commandCapsuleState.fail(message)
        }
      }
    }
  }
```

- [ ] **Step 6: Add send method**

Add:

```swift
  func sendCommandCapsuleDraftToCodex(enter: Bool) {
    let draft = commandCapsuleState.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? commandCapsuleState.request.trimmingCharacters(in: .whitespacesAndNewlines)
      : commandCapsuleState.draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !draft.isEmpty else { return }
    if activeAISession == nil {
      launchAI(profile: .codex, mode: .rightSplit)
    }
    guard let activeAISession else {
      commandCapsuleState.fail("Start Codex before sending this prompt.")
      return
    }
    do {
      try aiSessionManager.sendPrompt(draft, to: activeAISession.id, mode: enter ? .bracketedPasteAndEnter : .bracketedPasteOnly)
      _ = aiSessionManager.focusAISession(id: activeAISession.id)
      restoreTerminalKeyboardFocus()
      commandCapsuleState.markSent()
    } catch {
      commandCapsuleState.fail("Unable to send prompt to Codex: \(error.localizedDescription)")
    }
  }
```

- [ ] **Step 7: Run build**

Run:

```bash
swift build
```

Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add Sources/ProGhosttyApp/UI/AppModel.swift
git commit -m "feat: connect codex capsule app model"
```

---

## Task 6: Floating Capsule UI

**Files:**
- Create: `Sources/ProGhosttyApp/UI/CodexCommandCapsuleView.swift`
- Modify: `Sources/ProGhosttyApp/UI/RootView.swift`
- Modify: `Sources/ProGhosttyApp/ProGhosttyApp.swift`
- Modify: `Sources/ProGhosttyApp/UI/SettingsView.swift`

- [ ] **Step 1: Create SwiftUI capsule view**

Create `Sources/ProGhosttyApp/UI/CodexCommandCapsuleView.swift`:

```swift
import ProGhosttyCore
import SwiftUI

struct CodexCommandCapsuleView: View {
  @EnvironmentObject private var model: AppModel
  @FocusState private var requestFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      header
      requestEditor
      if model.commandCapsuleState.phase == .listening {
        listeningRow
      }
      if shouldShowDraft {
        draftEditor
      }
      contextChips
      if let error = model.commandCapsuleState.errorMessage {
        Text(error)
          .font(.system(size: 12))
          .foregroundStyle(.red)
      }
      actions
    }
    .padding(14)
    .frame(width: 640)
    .background(Color(nsColor: model.terminalBackgroundColor).opacity(model.usesDarkAppearance ? 0.94 : 0.98))
    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .stroke(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 1)
    )
    .shadow(color: .black.opacity(model.usesDarkAppearance ? 0.32 : 0.18), radius: 22, x: 0, y: 14)
    .onAppear { requestFocused = true }
  }

  private var header: some View {
    HStack {
      Text("Codex Command")
        .font(.system(size: 13, weight: .semibold))
      Spacer()
      phaseLabel
      Button {
        model.dismissCodexCommandCapsule()
      } label: {
        Image(systemName: "xmark")
      }
      .buttonStyle(.borderless)
      .keyboardShortcut(.escape, modifiers: [])
    }
  }

  private var phaseLabel: some View {
    Text(label(for: model.commandCapsuleState.phase))
      .font(.system(size: 11, weight: .medium))
      .foregroundStyle(.secondary)
  }

  private var requestEditor: some View {
    TextEditor(text: $model.commandCapsuleState.request)
      .focused($requestFocused)
      .font(.system(size: 13))
      .frame(height: 72)
      .scrollContentBackground(.hidden)
      .background(Color(nsColor: .textBackgroundColor).opacity(model.usesDarkAppearance ? 0.16 : 0.62))
      .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .stroke(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 1)
      )
  }

  private var listeningRow: some View {
    HStack(spacing: 8) {
      Circle()
        .fill(Color.red)
        .frame(width: 8, height: 8)
      Text(model.commandCapsuleState.voicePartial.isEmpty ? "Listening..." : model.commandCapsuleState.voicePartial)
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .lineLimit(2)
      Spacer()
      Button("Stop") {
        model.stopCommandCapsuleVoiceInput()
      }
    }
  }

  private var shouldShowDraft: Bool {
    !model.commandCapsuleState.draft.isEmpty || model.commandCapsuleState.phase == .ready
  }

  private var draftEditor: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Draft for Codex")
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.secondary)
      TextEditor(text: $model.commandCapsuleState.draft)
        .font(.system(size: 12, design: .monospaced))
        .frame(height: 140)
        .scrollContentBackground(.hidden)
        .background(Color(nsColor: .textBackgroundColor).opacity(model.usesDarkAppearance ? 0.16 : 0.62))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 1)
        )
    }
  }

  private var contextChips: some View {
    HStack(spacing: 6) {
      ForEach(contextOptions, id: \.self) { option in
        Button(label(for: option)) {
          model.toggleCommandCapsuleContext(option)
        }
        .buttonStyle(.borderless)
        .font(.system(size: 11, weight: .medium))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(model.commandCapsuleState.includedContext.contains(option) ? Color.accentColor.opacity(0.16) : Color(nsColor: .separatorColor).opacity(0.16))
        .clipShape(Capsule())
      }
    }
  }

  private var actions: some View {
    HStack(spacing: 8) {
      Button(model.commandCapsuleState.phase == .listening ? "Cancel Voice" : "Voice") {
        model.commandCapsuleState.phase == .listening
          ? model.stopCommandCapsuleVoiceInput()
          : model.startCommandCapsuleVoiceInput()
      }
      Button("Use Raw") {
        model.useRawCommandCapsuleRequestAsDraft()
      }
      Button("Refine") {
        model.refineCommandCapsulePrompt()
      }
      .disabled(model.commandCapsuleState.phase == .refining || model.commandCapsuleState.request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      Spacer()
      Button("Paste") {
        model.sendCommandCapsuleDraftToCodex(enter: false)
      }
      Button("Paste + Enter") {
        model.sendCommandCapsuleDraftToCodex(enter: true)
      }
      .keyboardShortcut(.return, modifiers: [.command])
    }
  }

  private var contextOptions: [AIPromptContextOption] {
    [.workspacePath, .gitBranch, .gitStatus, .changedFileList, .selectedTerminalText]
  }

  private func label(for option: AIPromptContextOption) -> String {
    switch option {
    case .workspacePath: return "Workspace"
    case .gitBranch: return "Branch"
    case .gitStatus: return "Status"
    case .gitDiff: return "Diff"
    case .selectedTerminalText: return "Selection"
    case .changedFileList: return "Files"
    }
  }

  private func label(for phase: CommandCapsulePhase) -> String {
    switch phase {
    case .idle: return "Ready"
    case .listening: return "Listening"
    case .refining: return "Refining"
    case .ready: return "Draft"
    case .error: return "Needs attention"
    case .sent: return "Sent"
    }
  }
}
```

- [ ] **Step 2: Overlay capsule in RootView**

In `Sources/ProGhosttyApp/UI/RootView.swift`, add inside the top-level `ZStack`, after existing overlays:

```swift
      if model.commandCapsuleState.isPresented {
        VStack {
          Spacer()
          CodexCommandCapsuleView()
            .environmentObject(model)
            .padding(.bottom, 28)
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
      }
```

Add animation token:

```swift
    .animation(.easeOut(duration: 0.14), value: model.commandCapsuleState.isPresented)
```

Add capsule state to `terminalChromeSyncToken`:

```swift
    hasher.combine(model.commandCapsuleState.isPresented)
    hasher.combine(model.commandCapsuleState.phase.rawValue)
```

- [ ] **Step 3: Add AI menu command**

In `Sources/ProGhosttyApp/ProGhosttyApp.swift`, add at the top of `CommandMenu("AI")`:

```swift
        Button("Open Codex Command Capsule") {
          model.openCodexCommandCapsule()
        }
        .keyboardShortcut(model.settings.keyboardShortcuts.shortcut(for: .openCodexCommandCapsule).swiftUIShortcut)

        Divider()
```

- [ ] **Step 4: Add settings UI fields**

In `Sources/ProGhosttyApp/UI/SettingsView.swift`, inside `SettingsSection("AI Companion")`, after DashScope key, add:

```swift
            SettingsRow("OpenAI Base URL") {
              TextField("https://api.openai.com/v1", text: $model.settings.openAICompatibleBaseURL)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13, design: .monospaced))
                .foregroundColor(Color(nsColor: model.configurationPrimaryTextColor))
            }

            SettingsRow("OpenAI API Key") {
              SecureField("OPENAI_API_KEY", text: Binding(
                get: { model.settings.openAICompatibleAPIKey ?? "" },
                set: { model.settings.openAICompatibleAPIKey = $0.isEmpty ? nil : $0 }
              ))
              .textFieldStyle(.roundedBorder)
              .font(.system(size: 13, design: .monospaced))
              .foregroundColor(Color(nsColor: model.configurationPrimaryTextColor))
            }

            SettingsRow("OpenAI Model") {
              TextField("gpt-5.1", text: $model.settings.openAICompatibleModel)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13, design: .monospaced))
                .foregroundColor(Color(nsColor: model.configurationPrimaryTextColor))
            }
```

Update `shortcutTitle(_:, text:)`:

```swift
    case .openCodexCommandCapsule:
      return "Open Codex Command Capsule"
```

- [ ] **Step 5: Run build**

Run:

```bash
swift build
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/ProGhosttyApp/UI/CodexCommandCapsuleView.swift Sources/ProGhosttyApp/UI/RootView.swift Sources/ProGhosttyApp/ProGhosttyApp.swift Sources/ProGhosttyApp/UI/SettingsView.swift
git commit -m "feat: add codex command capsule ui"
```

---

## Task 7: Verification

**Files:**
- No new files.

- [ ] **Step 1: Run focused AI tests**

Run:

```bash
swift test --filter AICLICompanionTests --no-parallel
```

Expected: PASS.

- [ ] **Step 2: Run settings tests**

Run:

```bash
swift test --filter AppSettingsTests --no-parallel
```

Expected: PASS.

- [ ] **Step 3: Run full test suite**

Run:

```bash
swift test --no-parallel
```

Expected: PASS.

- [ ] **Step 4: Build app**

Run:

```bash
swift build
```

Expected: PASS.

- [ ] **Step 5: Optional manual launch check**

Run:

```bash
swift run ProGhostty
```

Expected: app opens; AI menu shows "Open Codex Command Capsule"; capsule appears over the terminal; typed request can be refined if provider settings are configured; `Paste` sends bracketed paste to Codex.

- [ ] **Step 6: Commit verification fixes if needed**

If verification required fixes, stage the exact files changed by those fixes and commit them. For example, if the fix touches the capsule view:

```bash
git add Sources/ProGhosttyApp/UI/CodexCommandCapsuleView.swift
git commit -m "fix: stabilize codex command capsule"
```

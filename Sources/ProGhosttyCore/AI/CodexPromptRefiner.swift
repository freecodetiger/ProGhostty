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

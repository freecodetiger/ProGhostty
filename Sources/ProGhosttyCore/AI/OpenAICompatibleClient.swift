import Foundation

public struct OpenAICompatibleProviderConfig: Sendable {
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
    return URL(string: value)
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

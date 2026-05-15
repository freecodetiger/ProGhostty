public protocol RedactionEngine: Sendable {
  func redact(_ text: String) -> String
}

public struct NoopRedactionEngine: RedactionEngine {
  public init() {}
  public func redact(_ text: String) -> String { text }
}

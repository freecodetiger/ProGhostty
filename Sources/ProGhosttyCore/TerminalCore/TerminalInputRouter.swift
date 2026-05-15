import Foundation

@MainActor
public final class TerminalInputRouter {
  private let engine: TerminalEngine

  public init(engine: TerminalEngine) {
    self.engine = engine
  }

  public func send(_ text: String, to session: TerminalSessionID, appendNewline: Bool = false) {
    let payload = appendNewline ? text + "\n" : text
    engine.writeInput(Data(payload.utf8), to: session)
  }
}

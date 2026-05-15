import Foundation

@MainActor
public final class TerminalInputRouter {
  private let sessionManager: TerminalSessionManager

  public init(sessionManager: TerminalSessionManager) {
    self.sessionManager = sessionManager
  }

  public func send(_ text: String, to session: TerminalSessionID, appendNewline: Bool = false) {
    let payload = appendNewline ? text + "\n" : text
    sessionManager.writeInput(Data(payload.utf8), to: session)
  }
}

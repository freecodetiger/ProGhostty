import Foundation

public enum PaneCloseConfirmationPolicy {
  @MainActor
  public static func requiresConfirmation(
    for pane: TerminalPane,
    sessionManager: TerminalSessionManager
  ) -> Bool {
    sessionManager.hasForegroundProcess(in: pane.sessionId)
  }
}

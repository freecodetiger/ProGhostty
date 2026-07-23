import AppKit
import Foundation

public struct TerminalSessionID: Hashable, Codable, Sendable, CustomStringConvertible {
  public let rawValue: UUID

  public init(_ rawValue: UUID = UUID()) {
    self.rawValue = rawValue
  }

  public var description: String {
    rawValue.uuidString
  }
}

public struct TerminalSessionConfig: Codable, Equatable, Sendable {
  public var shellPath: String
  public var launchCommand: String?
  public var workingDirectory: String?
  public var environment: [String: String]
  public var rows: Int
  public var cols: Int
  public var workspaceId: UUID?

  public init(
    shellPath: String,
    launchCommand: String? = nil,
    workingDirectory: String?,
    environment: [String: String],
    rows: Int,
    cols: Int,
    workspaceId: UUID? = nil
  ) {
    self.shellPath = shellPath
    self.launchCommand = launchCommand
    self.workingDirectory = workingDirectory
    self.environment = environment
    self.rows = rows
    self.cols = cols
    self.workspaceId = workspaceId
  }
}

public enum TerminalEvent: Sendable {
  case sessionCreated(TerminalSessionID)
  case sessionClosed(TerminalSessionID)
  case output(session: TerminalSessionID, data: Data)
  case osc(session: TerminalSessionID, sequence: OscSequence)
  case desktopNotification(session: TerminalSessionID, notification: TerminalDesktopNotification)
  case cwdChanged(session: TerminalSessionID, cwd: String)
  case titleChanged(session: TerminalSessionID, title: String)
  case error(session: TerminalSessionID, message: String)
}

@MainActor public protocol TerminalSessionManager: AnyObject {
  func createSession(config: TerminalSessionConfig) throws -> TerminalSessionID
  func closeSession(_ id: TerminalSessionID)
  func resizeSession(_ id: TerminalSessionID, rows: Int, cols: Int)
  func writeInput(_ data: Data, to id: TerminalSessionID)
  func writePaste(_ text: String, to id: TerminalSessionID)
  func workingDirectory(for id: TerminalSessionID) -> String?
  func controlToken(for id: TerminalSessionID) -> String?
  func hasForegroundProcess(in id: TerminalSessionID) -> Bool
  var events: AsyncStream<TerminalEvent> { get }
}

@MainActor public protocol TerminalSurfaceRegistry: AnyObject {
  func viewForSession(_ id: TerminalSessionID) -> NSView?
  func selectedText(for id: TerminalSessionID) -> String?
  func rendererDiagnostics(for id: TerminalSessionID) -> TerminalRendererDiagnostics?
  func applyPalette(_ palette: TerminalSurfacePalette)
  func applyFont(family: String, size: CGFloat, cjkFallbackFamily: String?)
  func applyRendererOptions(_ options: TerminalRendererOptions)
  func setFocusedSession(_ id: TerminalSessionID?)
  func focusSessionView(_ id: TerminalSessionID?)
  func setInputHandler(_ handler: (@MainActor (TerminalSessionID, Data) -> Void)?)
  func setPasteHandler(_ handler: (@MainActor (TerminalSessionID, String) -> Void)?)
  func setActivationHandler(_ handler: (@MainActor (TerminalSessionID) -> Void)?)
  func setLinkHoverHandler(_ handler: (@MainActor (TerminalSessionID, Bool) -> Void)?)
  func setLinkTargetHandler(_ handler: (@MainActor (TerminalSessionID, TerminalLinkTarget) -> Void)?)
  func setPathExistenceProvider(_ provider: (@MainActor (TerminalSessionID, String) -> Bool)?)
  func setFileInfoProvider(_ provider: (@MainActor (TerminalSessionID, TerminalFilePathTarget) -> TerminalFileFacts?)?)
  func applySemanticLinkText(_ text: SemanticLinkText)
}

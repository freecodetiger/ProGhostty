import AppKit
import Foundation

@MainActor
public final class LibGhosttyTerminalEngine: TerminalSessionManager, TerminalSurfaceRegistry {
  public enum EngineError: Error {
    case unavailable
  }

  public let events: AsyncStream<TerminalEvent>

  public init() {
    events = AsyncStream { continuation in
      continuation.finish()
    }
  }

  public func createSession(config: TerminalSessionConfig) throws -> TerminalSessionID {
    throw EngineError.unavailable
  }

  public func closeSession(_ id: TerminalSessionID) {}
  public func resizeSession(_ id: TerminalSessionID, rows: Int, cols: Int) {}
  public func writeInput(_ data: Data, to id: TerminalSessionID) {}
  public func viewForSession(_ id: TerminalSessionID) -> NSView? { nil }
  public func setInputHandler(_ handler: (@MainActor (TerminalSessionID, Data) -> Void)?) {}
  public func setActivationHandler(_ handler: (@MainActor (TerminalSessionID) -> Void)?) {}
}

import Foundation

public struct CommandBlockIndexer: Sendable {
  private var runningBlocks: [TerminalSessionID: CommandBlock] = [:]
  private var currentCwd: [TerminalSessionID: String] = [:]
  private var workspaceBySession: [TerminalSessionID: UUID] = [:]
  private let maxPreviewBytes: Int
  private let redactionEngine: any RedactionEngine
  private let truncationMarker = "\n[output truncated]"

  public init(
    maxPreviewBytes: Int = 64 * 1024, redactionEngine: any RedactionEngine = NoopRedactionEngine()
  ) {
    self.maxPreviewBytes = maxPreviewBytes
    self.redactionEngine = redactionEngine
  }

  public mutating func associate(session: TerminalSessionID, workspaceId: UUID?) {
    workspaceBySession[session] = workspaceId
  }

  @discardableResult
  public mutating func process(_ event: TerminalEvent) -> [CommandBlock] {
    switch event {
    case .sessionCreated:
      return []

    case .sessionClosed(let session):
      return closeRunningBlock(session: session, status: .cancelled)

    case .cwdChanged(let session, let cwd):
      currentCwd[session] = cwd
      return []

    case .osc(let session, let sequence):
      return processOsc(sequence, session: session)

    case .commandStarted(let session, let command):
      var changes = closeRunningBlock(session: session, status: .unknown)
      let now = Date()
      let block = CommandBlock(
        workspaceId: workspaceBySession[session] ?? nil,
        sessionId: session,
        cwd: currentCwd[session],
        command: command,
        outputPreview: "",
        outputStorageRef: nil,
        startedAt: now,
        endedAt: nil,
        durationMs: nil,
        exitCode: nil,
        status: .running,
        shellIntegrationReliable: true,
        createdAt: now
      )
      runningBlocks[session] = block
      changes.append(block)
      return changes

    case .output(let session, let data):
      guard var block = runningBlocks[session] else { return [] }
      let text = String(decoding: data, as: UTF8.self)
      block.outputPreview = limitedPreview(block.outputPreview + redactionEngine.redact(text))
      runningBlocks[session] = block
      return [block]

    case .commandFinished(let session, let exitCode):
      guard var block = runningBlocks.removeValue(forKey: session) else { return [] }
      let endedAt = Date()
      block.endedAt = endedAt
      block.durationMs = max(0, Int(endedAt.timeIntervalSince(block.startedAt) * 1000))
      block.exitCode = exitCode
      if let exitCode {
        block.status = exitCode == 0 ? .success : .failed
      } else {
        block.status = .unknown
      }
      return [block]

    case .titleChanged, .error:
      return []
    }
  }

  public func runningBlock(for session: TerminalSessionID) -> CommandBlock? {
    runningBlocks[session]
  }

  private mutating func processOsc(_ sequence: OscSequence, session: TerminalSessionID)
    -> [CommandBlock]
  {
    if let cwd = CwdTracker.cwd(from: sequence) {
      currentCwd[session] = cwd
      return []
    }

    guard sequence.command == "133", let marker = sequence.parameters.first else {
      if sequence.command == "0" || sequence.command == "1" || sequence.command == "2" {
        return []
      }
      return []
    }

    switch marker {
    case "C":
      let command = sequence.parameters.dropFirst().first
      return process(.commandStarted(session: session, command: command))
    case "D":
      let exitCode = sequence.parameters.dropFirst().first.flatMap(Int.init)
      return process(.commandFinished(session: session, exitCode: exitCode))
    default:
      return []
    }
  }

  private mutating func closeRunningBlock(session: TerminalSessionID, status: CommandBlockStatus)
    -> [CommandBlock]
  {
    guard var block = runningBlocks.removeValue(forKey: session) else {
      return []
    }
    let endedAt = Date()
    block.endedAt = endedAt
    block.durationMs = max(0, Int(endedAt.timeIntervalSince(block.startedAt) * 1000))
    block.status = status
    return [block]
  }

  private func limitedPreview(_ text: String) -> String {
    let bytes = Array(text.utf8)
    guard bytes.count > maxPreviewBytes else {
      return text
    }

    let markerBytes = Array(truncationMarker.utf8)
    let prefixLimit = max(0, maxPreviewBytes - markerBytes.count)
    let prefix = String(decoding: bytes.prefix(prefixLimit), as: UTF8.self)
    return prefix + truncationMarker
  }
}

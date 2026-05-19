import Foundation

public enum CommandCapsulePhase: String, Codable, Equatable, Sendable {
  case idle
  case listening
  case paused
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

  public mutating func pauseListening() {
    guard phase == .listening else { return }
    phase = .paused
    voicePartial = ""
  }

  public mutating func resumeListening() {
    guard phase == .paused || phase == .idle || phase == .error else { return }
    phase = .listening
    voicePartial = ""
    errorMessage = nil
  }

  public mutating func stopListening() {
    if phase == .listening || phase == .paused {
      phase = .idle
    }
    voicePartial = ""
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

import Foundation

public struct ShortcutRecorderState: Equatable, Sendable {
  public var settings: KeyboardShortcutSettings
  public private(set) var recordingAction: KeyboardShortcutAction?
  public private(set) var conflictAction: KeyboardShortcutAction?

  public init(settings: KeyboardShortcutSettings) {
    self.settings = settings
  }

  public mutating func beginRecording(_ action: KeyboardShortcutAction) {
    recordingAction = action
    conflictAction = nil
  }

  public mutating func cancelRecording() {
    recordingAction = nil
  }

  @discardableResult
  public mutating func record(_ binding: KeyboardShortcutBinding) -> Bool {
    guard let action = recordingAction else { return false }
    var next = settings
    next.set(binding, for: action)
    if let conflict = next.conflict(for: action) {
      conflictAction = conflict
      recordingAction = nil
      return false
    }
    settings = next
    conflictAction = nil
    recordingAction = nil
    return true
  }

  public mutating func reset(_ action: KeyboardShortcutAction) {
    settings.reset(action)
    recordingAction = nil
    conflictAction = nil
  }
}

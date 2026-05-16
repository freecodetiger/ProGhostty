import Testing

@testable import ProGhosttyCore

@Suite("Shortcut recorder state")
struct ShortcutRecorderStateTests {
  @Test func conflictStopsRecordingAndKeepsExistingShortcut() {
    var state = ShortcutRecorderState(settings: .defaults)
    state.beginRecording(.splitDown)

    let accepted = state.record(KeyboardShortcutBinding(key: "d", modifiers: [.command]))

    #expect(accepted == false)
    #expect(state.recordingAction == nil)
    #expect(state.conflictAction == .splitRight)
    #expect(state.settings.shortcut(for: .splitDown) == KeyboardShortcutSettings.defaults.shortcut(for: .splitDown))
  }

  @Test func resetStopsRecordingAndClearsConflict() {
    var state = ShortcutRecorderState(settings: .defaults)
    state.beginRecording(.splitDown)
    _ = state.record(KeyboardShortcutBinding(key: "d", modifiers: [.command]))

    state.reset(.splitDown)

    #expect(state.recordingAction == nil)
    #expect(state.conflictAction == nil)
    #expect(state.settings.shortcut(for: .splitDown) == KeyboardShortcutSettings.defaults.shortcut(for: .splitDown))
  }
}

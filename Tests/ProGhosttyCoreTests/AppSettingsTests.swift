import Foundation
import Testing

@testable import ProGhosttyCore

@Suite("App settings")
struct AppSettingsTests {
  @Test func decodesLegacySettingsWithNewLanguageAndThemeDefaults() throws {
    let legacy = """
      {
        "defaultShell": "/bin/zsh",
        "fontFamily": "Menlo",
        "fontSize": 14,
        "themeName": "dark",
        "commandBlocksEnabled": true,
        "historyEnabled": true,
        "saveOutputPreview": true,
        "maxOutputPreviewKB": 64,
        "rerunAutoEnter": false
      }
      """.data(using: .utf8)!

    let settings = try JSONDecoder().decode(AppSettings.self, from: legacy)

    #expect(settings.appLanguage == "system")
    #expect(settings.followSystemAppearance == false)
    #expect(settings.themeName == "dark")
    #expect(settings.pgControlCommandsEnabled == true)
    #expect(settings.keyboardShortcuts.shortcut(for: .openSettings).key == ",")
    #expect(settings.keyboardShortcuts.shortcut(for: .splitRight).modifiers == [.command])
    #expect(settings.rendererMode == .auto)
    #expect(settings.smoothPixelScrollingEnabled == false)
    #expect(settings.dirtyRowRenderingEnabled == true)
    #expect(settings.forceFullRedrawEnabled == false)
  }

  @Test func rendererOptionsDoNotEnablePixelScrollWithoutDebugFlag() {
    var settings = AppSettings.defaults
    settings.smoothPixelScrollingEnabled = true

    #expect(settings.terminalRendererOptions.smoothPixelScrollingEnabled == false)
  }

  @Test func legacySystemThemeBecomesFollowSystemAppearance() throws {
    let legacy = """
      {
        "defaultShell": "/bin/zsh",
        "fontFamily": "Menlo",
        "fontSize": 14,
        "themeName": "system",
        "commandBlocksEnabled": true,
        "historyEnabled": true,
        "saveOutputPreview": true,
        "maxOutputPreviewKB": 64,
        "rerunAutoEnter": false
      }
      """.data(using: .utf8)!

    let settings = try JSONDecoder().decode(AppSettings.self, from: legacy)

    #expect(settings.followSystemAppearance == true)
    #expect(settings.themeName == "dark")
  }

  @Test func keyboardShortcutsDetectConflicts() {
    var shortcuts = KeyboardShortcutSettings.defaults
    shortcuts.set(KeyboardShortcutBinding(key: "d", modifiers: [.command]), for: .splitDown)

    #expect(shortcuts.conflict(for: .splitDown) == .splitRight)
    #expect(shortcuts.conflict(for: .splitRight) == .splitDown)
    #expect(shortcuts.conflict(for: .openSettings) == nil)
  }

  @Test func keyboardShortcutDisplayUsesMacModifierSymbols() {
    let binding = KeyboardShortcutBinding(key: "leftArrow", modifiers: [.command, .option])

    #expect(binding.displayString == "⌘⌥←")
  }

  @Test func defaultTerminalWorkingDirectoryFallsBackToHomeDirectory() {
    #expect(
      AppSettings.terminalWorkingDirectory(
        workspaceRootPath: nil,
        defaultWorkingDirectory: nil,
        homeDirectory: "/Users/example",
        processDirectory: "/"
      ) == "/Users/example"
    )
  }

  @Test func newWorkspaceRootPathUsesResolvedWorkingDirectoryWhenUnset() {
    #expect(
      AppSettings.workspaceRootPathForNewWorkspace(
        requestedRootPath: nil,
        defaultWorkingDirectory: nil,
        homeDirectory: "/Users/example"
      ) == "/Users/example"
    )
  }
}

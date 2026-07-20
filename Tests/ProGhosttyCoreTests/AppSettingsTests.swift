import Foundation
import Testing

@testable import ProGhosttyCore

@Suite("App settings")
struct AppSettingsTests {
  @Test func fontOptionsRecommendCommonTerminalFontsBeyondNameSubstringFilter() {
    let options = FontManager.fontOptions(
      availableFamilies: ["Fira Code", "Hack", "Iosevka", "Proportional Sans"],
      currentFamily: "Hack",
      searchText: "",
      includeAllFonts: false
    )

    #expect(options.map(\.familyName) == ["Fira Code", "Hack", "Iosevka"])
    #expect(options.allSatisfy { $0.isRecommendedForTerminal })
  }

  @Test func fontOptionsCanSearchAcrossAllInstalledFonts() {
    let options = FontManager.fontOptions(
      availableFamilies: ["Fira Code", "Hack", "Proportional Sans"],
      currentFamily: "Hack",
      searchText: "sans",
      includeAllFonts: true
    )

    #expect(options.map(\.familyName) == ["Proportional Sans"])
    #expect(options.first?.isRecommendedForTerminal == false)
  }

  @Test func fontOptionsPreserveCurrentCustomFontWhenMissingFromInstalledList() {
    let options = FontManager.fontOptions(
      availableFamilies: ["Fira Code", "Menlo"],
      currentFamily: "Custom Terminal Font",
      searchText: "",
      includeAllFonts: false
    )

    #expect(options.map(\.familyName).contains("Custom Terminal Font"))
    #expect(options.first { $0.familyName == "Custom Terminal Font" }?.isInstalled == false)
  }

  @Test func cjkFallbackOptionsRecommendChineseFontsAndPreserveCustomSelection() {
    let options = FontManager.cjkFallbackOptions(
      availableFamilies: ["Fira Code", "PingFang SC", "Sarasa Mono SC", "Proportional Sans"],
      currentFamily: "Custom CJK Font",
      searchText: "",
      includeAllFonts: false
    )

    #expect(options.map(\.familyName) == ["Custom CJK Font", "PingFang SC", "Sarasa Mono SC"])
    #expect(options.first { $0.familyName == "Custom CJK Font" }?.isInstalled == false)
    #expect(options.first { $0.familyName == "PingFang SC" }?.isRecommendedForCJKFallback == true)
  }

  @Test func decodesLegacySettingsWithNewLanguageAndThemeDefaults() throws {
    let legacy = """
      {
        "defaultShell": "/bin/zsh",
        "fontFamily": "Menlo",
        "fontSize": 14,
        "themeName": "dark"
      }
      """.data(using: .utf8)!

    let settings = try JSONDecoder().decode(AppSettings.self, from: legacy)

    #expect(settings.appLanguage == "system")
    #expect(settings.followSystemAppearance == false)
    #expect(settings.themeName == "dark")
    #expect(settings.pgControlCommandsEnabled == true)
    #expect(settings.keyboardShortcuts.shortcut(for: .openSettings).key == ",")
    #expect(settings.keyboardShortcuts.shortcut(for: .sideInput).key == "p")
    #expect(settings.keyboardShortcuts.shortcut(for: .sideInput).modifiers == [.command])
    #expect(settings.keyboardShortcuts.shortcut(for: .splitRight).modifiers == [.command])
    #expect(settings.rendererMode == .auto)
    #expect(settings.smoothPixelScrollingEnabled == true)
    #expect(settings.dirtyRowRenderingEnabled == true)
    #expect(settings.forceFullRedrawEnabled == false)
    #expect(settings.cjkFallbackFontFamily == nil)
  }

  @Test func cjkFallbackFontFamilyRoundTripsThroughSettingsJSON() throws {
    var settings = AppSettings.defaults
    settings.cjkFallbackFontFamily = "PingFang SC"

    let encoded = try JSONEncoder().encode(settings)
    let decoded = try JSONDecoder().decode(AppSettings.self, from: encoded)

    #expect(decoded.cjkFallbackFontFamily == "PingFang SC")
  }

  @Test func decodesLegacySettingsWithNotificationDefaults() throws {
    // Old persisted JSON (pre-redesign keys are simply ignored) still decodes,
    // and the two current notification toggles fall back to defaults.
    let data = Data(#"{"themeName":"dark","inAppNotificationsEnabled":false,"notifyOnCommandFinish":"always"}"#.utf8)

    let settings = try JSONDecoder().decode(AppSettings.self, from: data)

    // Missing key uses current default (off until user arms hooks).
    #expect(!settings.notificationsEnabled)
    #expect(!settings.notifyWhenFocused)
  }

  @Test func notificationSettingsDefaultToOff() {
    #expect(!AppSettings.defaults.notificationsEnabled)
    #expect(!AppSettings.defaults.notifyWhenFocused)
  }

  @Test func notificationSettingsRoundTripThroughJSON() throws {
    var settings = AppSettings.defaults
    settings.notificationsEnabled = true
    settings.notifyWhenFocused = true

    let data = try JSONEncoder().encode(settings)
    let decoded = try JSONDecoder().decode(AppSettings.self, from: data)

    #expect(decoded.notificationsEnabled == true)
    #expect(decoded.notifyWhenFocused == true)
  }

  @Test func rendererOptionsEnablePixelScrollByDefault() {
    var settings = AppSettings.defaults
    settings.smoothPixelScrollingEnabled = true

    #expect(settings.terminalRendererOptions.smoothPixelScrollingEnabled == true)
  }

  @Test func rendererOptionsCanDisablePixelScrollFromSettings() {
    var settings = AppSettings.defaults
    settings.smoothPixelScrollingEnabled = false

    #expect(settings.terminalRendererOptions.smoothPixelScrollingEnabled == false)
  }

  @Test func decodesLegacyMetalLiveRendererSettingAsAuto() throws {
    let legacy = """
      {
        "rendererMode": "metalLive",
        "defaultShell": "/bin/zsh",
        "fontFamily": "Menlo",
        "fontSize": 14,
        "themeName": "dark"
      }
      """.data(using: .utf8)!

    let settings = try JSONDecoder().decode(AppSettings.self, from: legacy)

    #expect(settings.rendererMode == .auto)
  }

  @Test func settingsStoreMigratesHiddenPixelScrollFlagToEnabled() throws {
    let suiteName = "proghostty.settings.test.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = SettingsStore(defaults: defaults)
    var settings = AppSettings.defaults
    settings.smoothPixelScrollingEnabled = false
    try store.save(settings)

    let loaded = store.load()

    #expect(loaded.smoothPixelScrollingEnabled == true)
  }

  @Test func legacySystemThemeBecomesFollowSystemAppearance() throws {
    let legacy = """
      {
        "defaultShell": "/bin/zsh",
        "fontFamily": "Menlo",
        "fontSize": 14,
        "themeName": "system"
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

  @Test func keyboardShortcutBindingMatchesNormalizedEventKeyAndModifiers() {
    let binding = KeyboardShortcutBinding(key: "o", modifiers: [.command, .shift])

    #expect(binding.matches(key: "O", modifiers: [.command, .shift]))
    #expect(!binding.matches(key: "o", modifiers: [.command]))
    #expect(!binding.matches(key: "k", modifiers: [.command, .shift]))
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

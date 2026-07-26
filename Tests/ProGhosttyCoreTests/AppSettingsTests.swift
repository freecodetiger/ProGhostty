import Foundation
import Testing

@testable import ProGhosttyCore

@Suite("App settings")
struct AppSettingsTests {
  @Test func fontOptionsRecommendCommonTerminalFontsBeyondNameSubstringFilter() {
    let options = FontCatalog.fontOptions(
      availableFamilies: ["Fira Code", "Hack", "Iosevka", "Proportional Sans"],
      currentFamily: "Hack",
      searchText: "",
      includeAllFonts: false
    )

    #expect(options.map(\.familyName) == ["Fira Code", "Hack", "Iosevka"])
    #expect(options.allSatisfy { $0.isRecommendedForTerminal })
  }

  @Test func fontOptionsCanSearchAcrossAllInstalledFonts() {
    let options = FontCatalog.fontOptions(
      availableFamilies: ["Fira Code", "Hack", "Proportional Sans"],
      currentFamily: "Hack",
      searchText: "sans",
      includeAllFonts: true
    )

    #expect(options.map(\.familyName) == ["Proportional Sans"])
    #expect(options.first?.isRecommendedForTerminal == false)
  }

  @Test func fontOptionsPreserveCurrentCustomFontWhenMissingFromInstalledList() {
    let options = FontCatalog.fontOptions(
      availableFamilies: ["Fira Code", "Menlo"],
      currentFamily: "Custom Terminal Font",
      searchText: "",
      includeAllFonts: false
    )

    #expect(options.map(\.familyName).contains("Custom Terminal Font"))
    #expect(options.first { $0.familyName == "Custom Terminal Font" }?.isInstalled == false)
  }

  @Test func cjkFallbackOptionsRecommendChineseFontsAndPreserveCustomSelection() {
    let options = FontCatalog.cjkFallbackOptions(
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

  @Test func programTitleReportingDefaultsOnAndDecodesWhenMissing() throws {
    #expect(AppSettings.defaults.programTitleReportingEnabled)

    let legacy = Data(#"{"themeName":"dark"}"#.utf8)
    let settings = try JSONDecoder().decode(AppSettings.self, from: legacy)
    #expect(settings.programTitleReportingEnabled)
  }

  @Test func programTitleReportingRoundTripsThroughSettingsJSON() throws {
    var settings = AppSettings.defaults
    settings.programTitleReportingEnabled = false

    let encoded = try JSONEncoder().encode(settings)
    let decoded = try JSONDecoder().decode(AppSettings.self, from: encoded)

    #expect(!decoded.programTitleReportingEnabled)
  }

  @Test func themeManagerRecognizesSoftThemes() {
    #expect(ThemeManager.normalizedThemeName("soft-dark") == "soft-dark")
    #expect(ThemeManager.normalizedThemeName("soft-light") == "soft-light")
    #expect(ThemeManager.normalizedThemeName("unknown") == "dark")
    #expect(ThemeManager.isDarkFamily("dark"))
    #expect(ThemeManager.isDarkFamily("soft-dark"))
    #expect(!ThemeManager.isDarkFamily("light"))
    #expect(!ThemeManager.isDarkFamily("soft-light"))
  }

  @Test func themeManagerResolvesTerminalPalettes() {
    #expect(ThemeManager.terminalPalette(for: "dark") == .dark)
    #expect(ThemeManager.terminalPalette(for: "light") == .light)
    #expect(ThemeManager.terminalPalette(for: "soft-dark") == .softDark)
    #expect(ThemeManager.terminalPalette(for: "soft-light") == .softLight)
  }

  @Test func softLightTerminalBodyUsesBlackOnWarmBackground() {
    let palette = TerminalSurfacePalette.softLight
    let fg = palette.foreground.usingColorSpace(.deviceRGB) ?? palette.foreground
    let bg = palette.background.usingColorSpace(.deviceRGB) ?? palette.background
    #expect(fg.redComponent < 0.05)
    #expect(fg.greenComponent < 0.05)
    #expect(fg.blueComponent < 0.05)
    #expect(bg.redComponent > 0.95)
    #expect(bg.greenComponent > 0.90)
    #expect(bg.blueComponent > 0.85)
  }

  @Test func effectiveThemeUsesSoftPreferencesWhenFollowingSystem() {
    #expect(
      ThemeManager.effectiveThemeName(
        themeName: "dark",
        followSystemAppearance: true,
        softDarkPreferred: true,
        softLightPreferred: false,
        systemIsLight: false
      ) == "soft-dark"
    )
    #expect(
      ThemeManager.effectiveThemeName(
        themeName: "dark",
        followSystemAppearance: true,
        softDarkPreferred: false,
        softLightPreferred: true,
        systemIsLight: true
      ) == "soft-light"
    )
    #expect(
      ThemeManager.effectiveThemeName(
        themeName: "soft-dark",
        followSystemAppearance: false,
        softDarkPreferred: false,
        softLightPreferred: false,
        systemIsLight: true
      ) == "soft-dark"
    )
  }

  @Test func softThemePreferencesRoundTripAndDefaultOff() throws {
    #expect(!AppSettings.defaults.softDarkPreferred)
    #expect(!AppSettings.defaults.softLightPreferred)

    var settings = AppSettings.defaults
    settings.softDarkPreferred = true
    settings.softLightPreferred = true
    settings.themeName = "soft-dark"

    let data = try JSONEncoder().encode(settings)
    let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
    #expect(decoded.softDarkPreferred)
    #expect(decoded.softLightPreferred)
    #expect(decoded.themeName == "soft-dark")
  }

  @Test func softThemePreferencesDefaultFromThemeNameWhenMissing() throws {
    let data = Data(#"{"themeName":"soft-light"}"#.utf8)
    let settings = try JSONDecoder().decode(AppSettings.self, from: data)
    #expect(settings.themeName == "soft-light")
    #expect(settings.softLightPreferred)
    #expect(!settings.softDarkPreferred)
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

import SwiftUI
import Testing

@testable import ProGhosttyApp
import ProGhosttyCore

@Suite("Appearance derivation")
struct AppearanceViewModelTests {
  private func makeSettings(
    themeName: String = "dark",
    followSystemAppearance: Bool = true,
    softDarkPreferred: Bool = false,
    softLightPreferred: Bool = false
  ) -> AppSettings {
    var settings = AppSettings.defaults
    settings.themeName = themeName
    settings.followSystemAppearance = followSystemAppearance
    settings.softDarkPreferred = softDarkPreferred
    settings.softLightPreferred = softLightPreferred
    return settings
  }

  @Test func followSystemTracksSystemLightDark() {
    let settings = makeSettings(followSystemAppearance: true)
    #expect(AppearanceViewModel(settings: settings, systemIsLight: true).effectiveThemeName == "light")
    #expect(AppearanceViewModel(settings: settings, systemIsLight: false).effectiveThemeName == "dark")
  }

  @Test func softPreferencesUpgradeFollowSystemFamilies() {
    let settings = makeSettings(followSystemAppearance: true, softDarkPreferred: true, softLightPreferred: true)
    #expect(AppearanceViewModel(settings: settings, systemIsLight: true).effectiveThemeName == "soft-light")
    #expect(AppearanceViewModel(settings: settings, systemIsLight: false).effectiveThemeName == "soft-dark")
  }

  @Test func followSystemYieldsNilAppColorScheme() {
    let settings = makeSettings(followSystemAppearance: true)
    #expect(AppearanceViewModel(settings: settings, systemIsLight: true).appColorScheme == nil)
  }

  @Test func explicitThemeIgnoresSystemState() {
    let settings = makeSettings(themeName: "soft-light", followSystemAppearance: false)
    let model = AppearanceViewModel(settings: settings, systemIsLight: false)
    #expect(model.effectiveThemeName == "soft-light")
    #expect(model.appColorScheme == .light)
    #expect(!model.usesDarkAppearance)
    #expect(model.configurationColorScheme == .light)
  }

  @Test func darkFamilyDrivesDarkDerivations() {
    let settings = makeSettings(themeName: "soft-dark", followSystemAppearance: false)
    let model = AppearanceViewModel(settings: settings, systemIsLight: true)
    #expect(model.usesDarkAppearance)
    #expect(model.configurationColorScheme == .dark)
    #expect(model.terminalBackgroundColor == model.terminalPalette.background)
  }
}

import AppKit
import ProGhosttyCore
import SwiftUI

/// Pure derivation of every appearance value from settings plus the current
/// system light/dark state.
///
/// Extracted from `AppModel` (debt spec 3-6). Value type: construct one per
/// read with the live `systemIsLight`, derive everything else. Directly
/// testable — tests inject `systemIsLight` instead of touching NSApp.
struct AppearanceViewModel {
  let settings: AppSettings
  let systemIsLight: Bool

  var effectiveThemeName: String {
    ThemeManager.effectiveThemeName(
      themeName: settings.themeName,
      followSystemAppearance: settings.followSystemAppearance,
      softDarkPreferred: settings.softDarkPreferred,
      softLightPreferred: settings.softLightPreferred,
      systemIsLight: systemIsLight
    )
  }

  var appColorScheme: ColorScheme? {
    guard !settings.followSystemAppearance else { return nil }
    return ThemeManager.isDarkFamily(settings.themeName) ? .dark : .light
  }

  var terminalPalette: TerminalSurfacePalette {
    ThemeManager.terminalPalette(for: effectiveThemeName)
  }

  var usesDarkAppearance: Bool {
    ThemeManager.isDarkFamily(effectiveThemeName)
  }

  var terminalBackgroundColor: NSColor {
    terminalPalette.background
  }

  var configurationColorScheme: ColorScheme {
    usesDarkAppearance ? .dark : .light
  }

  var settingsThemePalette: ProGhosttySettingsThemeColors {
    ProGhosttySettingsThemePalette.palette(for: effectiveThemeName)
  }

  var configurationWindowBackgroundColor: NSColor { settingsThemePalette.windowBackground }
  var configurationBarBackgroundColor: NSColor { settingsThemePalette.footerBackground }
  var configurationSectionBackgroundColor: NSColor { settingsThemePalette.controlBackground }
  var configurationTextBackgroundColor: NSColor { settingsThemePalette.textFieldBackground }
  var configurationSeparatorColor: NSColor { settingsThemePalette.separator }
  var configurationPrimaryTextColor: NSColor { settingsThemePalette.primaryText }
  var configurationSecondaryTextColor: NSColor { settingsThemePalette.secondaryText }
  var configurationTertiaryTextColor: NSColor { settingsThemePalette.tertiaryText }
}

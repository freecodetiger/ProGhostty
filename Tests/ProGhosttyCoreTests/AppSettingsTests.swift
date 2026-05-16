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
}

import AppKit
import Foundation

public struct AppSettings: Codable, Equatable, Sendable {
  public var defaultShell: String
  public var defaultWorkingDirectory: String?
  public var fontFamily: String
  public var fontSize: Double
  public var themeName: String
  public var followSystemAppearance: Bool
  public var appLanguage: String
  public var commandBlocksEnabled: Bool
  public var historyEnabled: Bool
  public var saveOutputPreview: Bool
  public var maxOutputPreviewKB: Int
  public var rerunAutoEnter: Bool
  public var pgControlCommandsEnabled: Bool

  public static let defaults = AppSettings(
    defaultShell: "/bin/zsh",
    defaultWorkingDirectory: nil,
    fontFamily: FontManager.defaultMonospacedFontName(),
    fontSize: 14,
    themeName: "dark",
    followSystemAppearance: true,
    appLanguage: "system",
    commandBlocksEnabled: true,
    historyEnabled: true,
    saveOutputPreview: true,
    maxOutputPreviewKB: 64,
    rerunAutoEnter: false,
    pgControlCommandsEnabled: true
  )

  enum CodingKeys: String, CodingKey {
    case defaultShell
    case defaultWorkingDirectory
    case fontFamily
    case fontSize
    case themeName
    case followSystemAppearance
    case appLanguage
    case commandBlocksEnabled
    case historyEnabled
    case saveOutputPreview
    case maxOutputPreviewKB
    case rerunAutoEnter
    case pgControlCommandsEnabled
  }

  public init(
    defaultShell: String,
    defaultWorkingDirectory: String?,
    fontFamily: String,
    fontSize: Double,
    themeName: String,
    followSystemAppearance: Bool,
    appLanguage: String,
    commandBlocksEnabled: Bool,
    historyEnabled: Bool,
    saveOutputPreview: Bool,
    maxOutputPreviewKB: Int,
    rerunAutoEnter: Bool,
    pgControlCommandsEnabled: Bool
  ) {
    self.defaultShell = defaultShell
    self.defaultWorkingDirectory = defaultWorkingDirectory
    self.fontFamily = fontFamily
    self.fontSize = fontSize
    self.themeName = ThemeManager.normalizedThemeName(themeName)
    self.followSystemAppearance = followSystemAppearance
    self.appLanguage = AppLanguageManager.normalizedLanguage(appLanguage)
    self.commandBlocksEnabled = commandBlocksEnabled
    self.historyEnabled = historyEnabled
    self.saveOutputPreview = saveOutputPreview
    self.maxOutputPreviewKB = maxOutputPreviewKB
    self.rerunAutoEnter = rerunAutoEnter
    self.pgControlCommandsEnabled = pgControlCommandsEnabled
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    defaultShell = try container.decodeIfPresent(String.self, forKey: .defaultShell) ?? Self.defaults.defaultShell
    defaultWorkingDirectory = try container.decodeIfPresent(String.self, forKey: .defaultWorkingDirectory)
    fontFamily = try container.decodeIfPresent(String.self, forKey: .fontFamily) ?? Self.defaults.fontFamily
    fontSize = try container.decodeIfPresent(Double.self, forKey: .fontSize) ?? Self.defaults.fontSize
    let rawThemeName = try container.decodeIfPresent(String.self, forKey: .themeName) ?? Self.defaults.themeName
    themeName = ThemeManager.normalizedThemeName(rawThemeName)
    followSystemAppearance = try container.decodeIfPresent(Bool.self, forKey: .followSystemAppearance) ?? (rawThemeName == "system")
    appLanguage = AppLanguageManager.normalizedLanguage(
      try container.decodeIfPresent(String.self, forKey: .appLanguage) ?? Self.defaults.appLanguage
    )
    commandBlocksEnabled = try container.decodeIfPresent(Bool.self, forKey: .commandBlocksEnabled) ?? Self.defaults.commandBlocksEnabled
    historyEnabled = try container.decodeIfPresent(Bool.self, forKey: .historyEnabled) ?? Self.defaults.historyEnabled
    saveOutputPreview = try container.decodeIfPresent(Bool.self, forKey: .saveOutputPreview) ?? Self.defaults.saveOutputPreview
    maxOutputPreviewKB = try container.decodeIfPresent(Int.self, forKey: .maxOutputPreviewKB) ?? Self.defaults.maxOutputPreviewKB
    rerunAutoEnter = try container.decodeIfPresent(Bool.self, forKey: .rerunAutoEnter) ?? Self.defaults.rerunAutoEnter
    pgControlCommandsEnabled = try container.decodeIfPresent(Bool.self, forKey: .pgControlCommandsEnabled) ?? Self.defaults.pgControlCommandsEnabled
  }
}

public final class SettingsStore {
  private let defaults: UserDefaults
  private let key = "proghostty.settings.v1"

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  public func load() -> AppSettings {
    guard
      let data = defaults.data(forKey: key),
      let settings = try? JSONDecoder().decode(AppSettings.self, from: data)
    else {
      return .defaults
    }
    return settings
  }

  public func save(_ settings: AppSettings) throws {
    let data = try JSONEncoder().encode(settings)
    defaults.set(data, forKey: key)
  }
}

public enum FontManager {
  public static func defaultMonospacedFontName() -> String {
    NSFont(name: "JetBrains Mono", size: 14) == nil ? "Menlo" : "JetBrains Mono"
  }

  public static func monospacedFonts() -> [String] {
    NSFontManager.shared.availableFontFamilies
      .filter { family in
        let lowercased = family.lowercased()
        return lowercased.contains("mono") || lowercased.contains("code") || family == "Menlo"
      }
      .sorted()
  }
}

public enum ThemeManager {
  public static let builtInThemes = ["light", "dark"]

  public static func normalizedThemeName(_ themeName: String) -> String {
    builtInThemes.contains(themeName) ? themeName : "dark"
  }
}

public enum AppLanguageManager {
  public static let builtInLanguages = ["system", "en", "zh-Hans"]

  public static func normalizedLanguage(_ language: String) -> String {
    builtInLanguages.contains(language) ? language : "system"
  }
}

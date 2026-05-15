import AppKit
import Foundation

public struct AppSettings: Codable, Equatable, Sendable {
  public var defaultShell: String
  public var defaultWorkingDirectory: String?
  public var fontFamily: String
  public var fontSize: Double
  public var themeName: String
  public var commandBlocksEnabled: Bool
  public var historyEnabled: Bool
  public var saveOutputPreview: Bool
  public var maxOutputPreviewKB: Int
  public var rerunAutoEnter: Bool

  public static let defaults = AppSettings(
    defaultShell: "/bin/zsh",
    defaultWorkingDirectory: nil,
    fontFamily: FontManager.defaultMonospacedFontName(),
    fontSize: 14,
    themeName: "system",
    commandBlocksEnabled: true,
    historyEnabled: true,
    saveOutputPreview: true,
    maxOutputPreviewKB: 64,
    rerunAutoEnter: false
  )
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
  public static let builtInThemes = ["system", "light", "dark"]
}

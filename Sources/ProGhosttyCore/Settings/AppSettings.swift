import AppKit
import Foundation

public struct AppSettings: Codable, Equatable, Sendable {
  public var rendererMode: TerminalRendererMode
  public var smoothPixelScrollingEnabled: Bool
  public var dirtyRowRenderingEnabled: Bool
  public var forceFullRedrawEnabled: Bool
  public var defaultShell: String
  public var defaultWorkingDirectory: String?
  public var fontFamily: String
  public var fontSize: Double
  public var themeName: String
  public var followSystemAppearance: Bool
  public var appLanguage: String
  public var pgControlCommandsEnabled: Bool
  public var keyboardShortcuts: KeyboardShortcutSettings

  public static let defaults = AppSettings(
    rendererMode: .auto,
    smoothPixelScrollingEnabled: true,
    dirtyRowRenderingEnabled: true,
    forceFullRedrawEnabled: false,
    defaultShell: "/bin/zsh",
    defaultWorkingDirectory: nil,
    fontFamily: FontManager.defaultMonospacedFontName(),
    fontSize: 14,
    themeName: "dark",
    followSystemAppearance: true,
    appLanguage: "system",
    pgControlCommandsEnabled: true,
    keyboardShortcuts: .defaults
  )

  enum CodingKeys: String, CodingKey {
    case rendererMode
    case smoothPixelScrollingEnabled
    case dirtyRowRenderingEnabled
    case forceFullRedrawEnabled
    case defaultShell
    case defaultWorkingDirectory
    case fontFamily
    case fontSize
    case themeName
    case followSystemAppearance
    case appLanguage
    case pgControlCommandsEnabled
    case keyboardShortcuts
  }

  public init(
    rendererMode: TerminalRendererMode,
    smoothPixelScrollingEnabled: Bool,
    dirtyRowRenderingEnabled: Bool,
    forceFullRedrawEnabled: Bool,
    defaultShell: String,
    defaultWorkingDirectory: String?,
    fontFamily: String,
    fontSize: Double,
    themeName: String,
    followSystemAppearance: Bool,
    appLanguage: String,
    pgControlCommandsEnabled: Bool,
    keyboardShortcuts: KeyboardShortcutSettings
  ) {
    self.rendererMode = rendererMode
    self.smoothPixelScrollingEnabled = smoothPixelScrollingEnabled
    self.dirtyRowRenderingEnabled = dirtyRowRenderingEnabled
    self.forceFullRedrawEnabled = forceFullRedrawEnabled
    self.defaultShell = defaultShell
    self.defaultWorkingDirectory = defaultWorkingDirectory
    self.fontFamily = fontFamily
    self.fontSize = fontSize
    self.themeName = ThemeManager.normalizedThemeName(themeName)
    self.followSystemAppearance = followSystemAppearance
    self.appLanguage = AppLanguageManager.normalizedLanguage(appLanguage)
    self.pgControlCommandsEnabled = pgControlCommandsEnabled
    self.keyboardShortcuts = keyboardShortcuts.mergedWithDefaults()
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    rendererMode = try container.decodeIfPresent(TerminalRendererMode.self, forKey: .rendererMode) ?? Self.defaults.rendererMode
    smoothPixelScrollingEnabled = try container.decodeIfPresent(Bool.self, forKey: .smoothPixelScrollingEnabled) ?? Self.defaults.smoothPixelScrollingEnabled
    dirtyRowRenderingEnabled = try container.decodeIfPresent(Bool.self, forKey: .dirtyRowRenderingEnabled) ?? Self.defaults.dirtyRowRenderingEnabled
    forceFullRedrawEnabled = try container.decodeIfPresent(Bool.self, forKey: .forceFullRedrawEnabled) ?? Self.defaults.forceFullRedrawEnabled
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
    pgControlCommandsEnabled = try container.decodeIfPresent(Bool.self, forKey: .pgControlCommandsEnabled) ?? Self.defaults.pgControlCommandsEnabled
    keyboardShortcuts = (
      try container.decodeIfPresent(KeyboardShortcutSettings.self, forKey: .keyboardShortcuts) ?? Self.defaults.keyboardShortcuts
    ).mergedWithDefaults()
  }
}

public enum KeyboardShortcutAction: String, CaseIterable, Codable, Sendable, Identifiable {
  case openSettings
  case openWorkspaceSwitcher
  case splitRight
  case splitDown
  case closePane
  case focusPreviousPane
  case focusNextPane

  public var id: String { rawValue }
}

public enum KeyboardShortcutModifier: String, CaseIterable, Codable, Sendable, Comparable {
  case command
  case control
  case option
  case shift

  public static func < (lhs: KeyboardShortcutModifier, rhs: KeyboardShortcutModifier) -> Bool {
    lhs.sortOrder < rhs.sortOrder
  }

  public var symbol: String {
    switch self {
    case .command:
      return "⌘"
    case .control:
      return "⌃"
    case .option:
      return "⌥"
    case .shift:
      return "⇧"
    }
  }

  private var sortOrder: Int {
    switch self {
    case .command:
      return 0
    case .control:
      return 1
    case .option:
      return 2
    case .shift:
      return 3
    }
  }
}

public struct KeyboardShortcutBinding: Codable, Equatable, Sendable {
  public var key: String
  public var modifiers: Set<KeyboardShortcutModifier>

  public init(key: String, modifiers: Set<KeyboardShortcutModifier>) {
    self.key = key
    self.modifiers = modifiers
  }

  public var displayString: String {
    let modifierText = modifiers.sorted().map(\.symbol).joined()
    return modifierText + Self.displayKey(key)
  }

  public var isValidGlobalShortcut: Bool {
    !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !modifiers.isEmpty
  }

  public func matches(key candidateKey: String?, modifiers candidateModifiers: Set<KeyboardShortcutModifier>) -> Bool {
    guard let candidateKey else { return false }
    return key.lowercased() == candidateKey.lowercased() && modifiers == candidateModifiers
  }

  private static func displayKey(_ key: String) -> String {
    switch key {
    case "leftArrow":
      return "←"
    case "rightArrow":
      return "→"
    case "upArrow":
      return "↑"
    case "downArrow":
      return "↓"
    case "escape":
      return "Esc"
    case "delete":
      return "Delete"
    case "return":
      return "Return"
    case "tab":
      return "Tab"
    case "space":
      return "Space"
    default:
      return key.count == 1 ? key.uppercased() : key
    }
  }
}

public struct KeyboardShortcutSettings: Codable, Equatable, Sendable {
  private var bindings: [KeyboardShortcutAction: KeyboardShortcutBinding]

  public static let defaults = KeyboardShortcutSettings(bindings: [
    .openSettings: KeyboardShortcutBinding(key: ",", modifiers: [.command]),
    .openWorkspaceSwitcher: KeyboardShortcutBinding(key: "o", modifiers: [.command, .shift]),
    .splitRight: KeyboardShortcutBinding(key: "d", modifiers: [.command]),
    .splitDown: KeyboardShortcutBinding(key: "d", modifiers: [.command, .shift]),
    .closePane: KeyboardShortcutBinding(key: "w", modifiers: [.command]),
    .focusPreviousPane: KeyboardShortcutBinding(key: "leftArrow", modifiers: [.command, .option]),
    .focusNextPane: KeyboardShortcutBinding(key: "rightArrow", modifiers: [.command, .option]),
  ])

  public init(bindings: [KeyboardShortcutAction: KeyboardShortcutBinding]) {
    self.bindings = bindings
  }

  public func shortcut(for action: KeyboardShortcutAction) -> KeyboardShortcutBinding {
    bindings[action] ?? Self.defaults.bindings[action]!
  }

  public mutating func set(_ binding: KeyboardShortcutBinding, for action: KeyboardShortcutAction) {
    bindings[action] = binding
  }

  public mutating func reset(_ action: KeyboardShortcutAction) {
    bindings[action] = Self.defaults.shortcut(for: action)
  }

  public func conflict(for action: KeyboardShortcutAction) -> KeyboardShortcutAction? {
    let binding = shortcut(for: action)
    guard binding.isValidGlobalShortcut else { return nil }
    return KeyboardShortcutAction.allCases.first { candidate in
      candidate != action && shortcut(for: candidate) == binding
    }
  }

  public func mergedWithDefaults() -> KeyboardShortcutSettings {
    var merged = Self.defaults
    for action in KeyboardShortcutAction.allCases {
      if let binding = bindings[action], binding.isValidGlobalShortcut {
        merged.bindings[action] = binding
      }
    }
    return merged
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
      var settings = try? JSONDecoder().decode(AppSettings.self, from: data)
    else {
      return .defaults
    }
    settings.smoothPixelScrollingEnabled = true
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

public extension AppSettings {
  static func terminalWorkingDirectory(
    workspaceRootPath: String?,
    defaultWorkingDirectory: String?,
    homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
    processDirectory: String = FileManager.default.currentDirectoryPath
  ) -> String {
    if let workspaceRootPath = nonEmptyPath(workspaceRootPath) {
      return workspaceRootPath
    }
    if let defaultWorkingDirectory = nonEmptyPath(defaultWorkingDirectory) {
      return defaultWorkingDirectory
    }
    if let homeDirectory = nonEmptyPath(homeDirectory) {
      return homeDirectory
    }
    return processDirectory
  }

  static func workspaceRootPathForNewWorkspace(
    requestedRootPath: String?,
    defaultWorkingDirectory: String?,
    homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path
  ) -> String {
    terminalWorkingDirectory(
      workspaceRootPath: requestedRootPath,
      defaultWorkingDirectory: defaultWorkingDirectory,
      homeDirectory: homeDirectory
    )
  }

  private static func nonEmptyPath(_ path: String?) -> String? {
    let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? nil : trimmed
  }
}

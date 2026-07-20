import Foundation
import ProGhosttyCore

/// The settings categories shown in the sidebar.
enum SettingsCategory: String, CaseIterable, Hashable, Identifiable {
  case terminal
  case appearance
  case font
  case shortcuts
  case notifications
  case about

  var id: String { rawValue }

  func title(_ text: AppText) -> String {
    switch self {
    case .terminal: return text.terminal
    case .appearance: return text.appearance
    case .font: return text.font
    case .shortcuts: return text.shortcuts
    case .notifications: return text.notifications
    case .about: return text.about
    }
  }

  var systemImage: String {
    switch self {
    case .terminal: return "terminal"
    case .appearance: return "paintbrush"
    case .font: return "textformat"
    case .shortcuts: return "command"
    case .notifications: return "bell"
    case .about: return "info.circle"
    }
  }
}

/// A single searchable settings entry. Anchors search results to a concrete
/// control (via `id`, matched by a `.settingsAnchor(id)` in the pane) and its
/// owning category.
struct SettingsItem: Identifiable, Hashable {
  let id: String
  let category: SettingsCategory
  private let titleProvider: @Sendable (AppText) -> String
  private let keywordsProvider: @Sendable (AppText) -> [String]

  init(
    id: String,
    category: SettingsCategory,
    title: @escaping @Sendable (AppText) -> String,
    keywords: @escaping @Sendable (AppText) -> [String] = { _ in [] }
  ) {
    self.id = id
    self.category = category
    self.titleProvider = title
    self.keywordsProvider = keywords
  }

  func title(_ text: AppText) -> String { titleProvider(text) }
  func keywords(_ text: AppText) -> [String] { keywordsProvider(text) }

  static func == (lhs: SettingsItem, rhs: SettingsItem) -> Bool { lhs.id == rhs.id }
  func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Static registry of searchable settings, the single source of truth for
/// item-level search. Keywords include both English and Chinese aliases so a
/// query matches regardless of the current app language.
enum SettingsIndex {
  static let all: [SettingsItem] = [
    SettingsItem(
      id: "terminal.shell", category: .terminal,
      title: { $0.defaultShell },
      keywords: { [$0.defaultShell, "shell", "zsh", "bash", "终端", "shell 路径"] }
    ),
    SettingsItem(
      id: "terminal.cwd", category: .terminal,
      title: { $0.workingDirectory },
      keywords: { [$0.workingDirectory, "working directory", "cwd", "工作目录", "目录"] }
    ),
    SettingsItem(
      id: "appearance.language", category: .appearance,
      title: { $0.appLanguage },
      keywords: { [$0.appLanguage, "language", "语言", "中文", "english"] }
    ),
    SettingsItem(
      id: "appearance.theme", category: .appearance,
      title: { $0.theme },
      keywords: {
        [
          $0.theme, $0.followSystem, $0.softDark, $0.softLight,
          "theme", "dark", "light", "soft", "soft-dark", "soft-light",
          "主题", "深色", "浅色", "柔和", "外观", "solarized",
        ]
      }
    ),
    SettingsItem(
      id: "font.family", category: .font,
      title: { $0.font },
      keywords: { [$0.font, "font", "typeface", "字体", "monospace", "等宽"] }
    ),
    SettingsItem(
      id: "font.size", category: .font,
      title: { $0.fontSize },
      keywords: { [$0.fontSize, "font size", "字号", "size", "大小"] }
    ),
    SettingsItem(
      id: "font.cjk", category: .font,
      title: { $0.cjkFallbackFont },
      keywords: { [$0.cjkFallbackFont, "cjk", "中文", "回退", "fallback", "chinese", "日文", "韩文"] }
    ),
    SettingsItem(
      id: "font.advanced", category: .font,
      title: { $0.fontAdvanced },
      keywords: { [$0.fontAdvanced, "advanced", "exact font", "进阶", "精确字体", "all fonts", "全部字体"] }
    ),
    SettingsItem(
      id: "notifications.enable", category: .notifications,
      title: { $0.enableNotifications },
      keywords: { [$0.enableNotifications, "notification", "notify", "通知", "任务完成", "task", "agent"] }
    ),
    SettingsItem(
      id: "notifications.focused", category: .notifications,
      title: { $0.notifyWhenFocused },
      keywords: { [$0.notifyWhenFocused, "focus", "聚焦", "unfocused", "未聚焦"] }
    ),
    SettingsItem(
      id: "about.version", category: .about,
      title: { $0.version },
      keywords: { [$0.version, "version", "版本", "about", "关于"] }
    ),
    SettingsItem(
      id: "about.updates", category: .about,
      title: { $0.checkForUpdates },
      keywords: { [$0.checkForUpdates, "update", "更新", "升级"] }
    ),
  ] + KeyboardShortcutAction.allCases.map { action in
    SettingsItem(
      id: "shortcut.\(action.rawValue)", category: .shortcuts,
      title: { AppText.shortcutActionTitle(action, text: $0) },
      keywords: { [AppText.shortcutActionTitle(action, text: $0), "shortcut", "keybinding", "快捷键", "按键"] }
    )
  }

  /// Items whose title or any keyword contains the query (case/space-insensitive).
  static func results(query: String, text: AppText) -> [SettingsItem] {
    let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !needle.isEmpty else { return [] }
    return all.filter { item in
      if item.title(text).lowercased().contains(needle) { return true }
      return item.keywords(text).contains { $0.lowercased().contains(needle) }
    }
  }
}

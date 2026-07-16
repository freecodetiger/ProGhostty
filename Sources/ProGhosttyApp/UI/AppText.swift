import Foundation
import ProGhosttyCore

struct AppText {
  private let language: String

  init(language: String) {
    if language == "system" {
      self.language = Locale.preferredLanguages.first?.hasPrefix("zh") == true ? "zh-Hans" : "en"
    } else {
      self.language = language
    }
  }

  var settings: String { text("Settings", "设置") }
  var workspaces: String { text("Workspaces...", "工作区...") }
  var copy: String { text("Copy", "复制") }
  var paste: String { text("Paste", "粘贴") }
  var splitPane: String { text("Split", "分屏") }
  var splitRight: String { text("Split Right", "向右分屏") }
  var splitDown: String { text("Split Down", "向下分屏") }
  var closePane: String { text("Close Pane", "关闭分屏") }
  var closePaneConfirmationTitle: String { text("Close pane?", "关闭分屏？") }
  var closePaneConfirmationMessage: String {
    text(
      "This pane has a running foreground process. Closing it will terminate that process.",
      "这个分屏中有正在运行的前台进程。关闭分屏会终止该进程。"
    )
  }
  var terminal: String { text("Terminal", "终端") }
  var defaultShell: String { text("Default shell", "默认 shell") }
  var workingDirectory: String { text("Working directory", "工作目录") }
  var currentDirectory: String { text("Current directory", "当前目录") }
  var choose: String { text("Choose...", "选择...") }
  var appearance: String { text("Appearance", "外观") }
  var languageSection: String { text("Language", "语言") }
  var appLanguage: String { text("App language", "软件语言") }
  var systemLanguage: String { text("System", "跟随系统") }
  var english: String { text("English", "英文") }
  var simplifiedChinese: String { text("Simplified Chinese", "简体中文") }
  var font: String { text("Font", "字体") }
  var fontSearchPlaceholder: String { text("Search installed fonts", "搜索已安装字体") }
  var showAllFonts: String { text("Show all installed fonts", "显示全部已安装字体") }
  var customFontName: String { text("Exact font name", "精确字体名称") }
  var cjkFallbackFont: String { text("CJK fallback", "中文回退字体") }
  var systemCJKFallback: String { text("System fallback", "系统回退") }
  var customCJKFallbackName: String { text("Exact CJK fallback name", "精确中文回退字体名称") }
  var cjkFallbackSystemStatus: String { text("Using system fallback for CJK glyphs", "使用系统中文回退字体") }
  var cjkFallbackHint: String {
    text(
      "CJK fallback only affects Chinese/Japanese/Korean glyphs. Cell size still follows the primary font.",
      "中文回退只影响中日韩字符；终端格子的宽高仍由主字体决定。"
    )
  }
  var installedMonospacedFontsHint: String {
    text(
      "Filtered to terminal-friendly fonts by default. Show all fonts or type an exact name for more control.",
      "默认筛选适合终端的字体。也可以显示全部字体，或输入精确字体名称。"
    )
  }
  var fontAvailableStatus: String { text("Installed", "已安装") }
  var fontInstalledStatus: String { text("Installed, but may not be monospaced", "已安装，但可能不是等宽字体") }
  var fontMissingStatus: String { text("Not installed; system fallback will be used", "未安装；会使用系统回退字体") }
  var fontSize: String { text("Font size", "字号") }
  var followSystem: String { text("Follow system appearance", "跟随系统外观") }
  var theme: String { text("Theme", "主题") }
  var light: String { text("Light", "浅色") }
  var dark: String { text("Dark", "深色") }
  var renderer: String { text("Renderer", "渲染器") }
  var rendererAuto: String { text("Auto", "自动") }
  var rendererMetalDirect: String { text("Metal direct", "Metal 直接渲染") }
  var rendererCellGrid: String { text("Ghostty VT Cell Grid", "Ghostty VT Cell Grid") }
  var rendererTextFallback: String { text("Text fallback", "文本回退") }
  var dirtyRowRendering: String { text("Dirty row rendering", "脏行增量渲染") }
  var forceFullRedraw: String { text("Force full redraw for debug", "调试时强制全量重绘") }
  var taskCompletionNotifications: String { text("Task Completion Notifications", "任务完成通知") }
  var notifications: String { text("Notifications", "通知") }
  var fontAdvanced: String { text("Advanced", "进阶") }
  var settingsSearchPlaceholder: String { text("Search settings", "搜索设置") }
  var noSearchResults: String { text("No matching settings", "无匹配设置项") }
  var enableNotifications: String { text("Notify on task completion", "任务完成时通知") }
  var enableNotificationsCaption: String { text("Notifies you when an agent (Claude Code, Codex, …) finishes a task via pg notify.", "当 agent（Claude Code、Codex 等）通过 pg notify 报告任务完成时提醒你。") }
  var notifyWhenFocused: String { text("Notify even when focused", "聚焦时也通知") }
  var notifyWhenFocusedCaption: String { text("By default you are only notified when the pane is not focused.", "默认只在该分屏未聚焦时通知。") }
  var notificationsPermissionHint: String { text("System notifications are not enabled for ProGhostty.", "系统尚未授予 ProGhostty 通知权限。") }
  var openSystemSettings: String { text("Open System Settings", "打开系统设置") }
  var shortcuts: String { text("Shortcuts", "快捷键") }
  var shortcutConflict: String { text("Shortcut is already used.", "快捷键已被占用。") }
  var recordShortcut: String { text("Record", "录制") }
  var recordingShortcut: String { text("Press shortcut", "按下快捷键") }
  var resetShortcut: String { text("Reset", "重置") }
  var openWorkspaceSwitcher: String { text("Switch Workspace", "切换工作区") }
  var sideInput: String { text("Side Input", "旁路输入") }
  var sideInputPlaceholder: String { text("Type without moving the terminal view", "输入不会打断当前终端预览位置") }
  var focusPreviousPane: String { text("Focus Previous Pane", "聚焦上一个分屏") }
  var focusNextPane: String { text("Focus Next Pane", "聚焦下一个分屏") }
  var cancel: String { text("Cancel", "取消") }
  var applyPlan: String { text("Apply Plan", "应用计划") }
  var close: String { text("Close", "关闭") }
  var open: String { text("Open", "打开") }
  var restoreDefaults: String { text("Restore Defaults", "恢复默认") }
  var restoreDefaultsTitle: String { text("Restore default settings?", "恢复默认设置？") }
  var restoreDefaultsMessage: String {
    text(
      "This will reset terminal, appearance, and shortcut settings.",
      "这会重置终端、外观和快捷键设置。"
    )
  }
  var about: String { text("About", "关于") }
  var version: String { text("Version", "版本") }
  var checkForUpdates: String { text("Check for Updates", "检查更新") }
  var checkingForUpdates: String { text("Checking...", "正在检查...") }
  var updateAvailableToast: String { text("Update available", "发现新版本") }
  var upToDateToast: String { text("ProGhostty is up to date", "ProGhostty 已是最新版本") }
  var updateCheckFailedToast: String { text("Update check failed", "检查更新失败") }
  var settingsSavedToast: String { text("Settings saved", "设置已保存") }
  var openLinkHintToast: String { text("⌘ Click to open link", "按住 ⌘ 点击打开链接") }
  var pathNotFoundToast: String { text("Path not found", "路径不存在") }
  var relativePathMissingCwdToast: String { text("No working directory for relative path", "没有用于解析相对路径的工作目录") }
  var revealPathFailedToast: String { text("Could not reveal path", "无法在访达中定位路径") }
  var splitRequiresMoreSpaceToast: String { text("Split needs more screen space", "屏幕空间不足，无法继续分屏") }
  var defaultsRestored: String { text("Defaults restored.", "已恢复默认设置。") }
  var newWorkspace: String { text("New Workspace", "新建工作区") }
  var newWorkspaceName: String { text("Workspace name", "工作区名称") }
  var createWorkspaceCaption: String { text("Name it before the first terminal opens.", "命名后再打开第一个终端。") }
  var renameWorkspace: String { text("Rename Workspace", "重命名工作区") }
  var deleteWorkspace: String { text("Delete Workspace", "删除工作区") }
  var deleteWorkspaceConfirmationTitle: String { text("Delete workspace?", "删除工作区？") }
  func deleteWorkspaceConfirmationMessage(_ name: String, runningPaneCount: Int) -> String {
    if runningPaneCount > 0 {
      return text(
        "\"\(name)\" will be deleted. \(runningPaneCount) running terminal session\(runningPaneCount == 1 ? "" : "s") in this workspace will be closed.",
        "“\(name)”将被删除。这个工作区中的 \(runningPaneCount) 个运行中终端会话会被关闭。"
      )
    }
    return text(
      "\"\(name)\" will be removed from saved workspaces.",
      "“\(name)”将从已保存工作区中移除。"
    )
  }
  var renameShortcutHint: String { text("Space to rename", "空格重命名") }
  var enterWorkspaceHint: String { text("Return or Tab to enter", "回车或 Tab 进入") }
  var deleteWorkspaceHint: String { text("Delete to delete workspace", "Delete 删除工作区") }
  var create: String { text("Create", "创建") }
  var current: String { text("Current", "当前") }
  var running: String { text("Running", "运行中") }
  var savedStatus: String { text("Saved", "已保存") }
  var fontPreview: String { text("Font preview", "字体预览") }
  var fontPreviewSample: String {
    text(
      "zpc@mac ~/project % git status --short",
      "zpc@mac ~/project % git status --short"
    )
  }
  var fontPreviewDetail: String {
    text(
      "ABC abc 0123456789 中文 │  λ 😀",
      "ABC abc 0123456789 中文 │  λ 😀"
    )
  }

  func availability(_ isAvailable: Bool) -> String {
    isAvailable ? text("Available", "可用") : text("Not found", "未找到")
  }

  func localized(_ english: String, _ simplifiedChinese: String) -> String {
    text(english, simplifiedChinese)
  }

  private func text(_ english: String, _ simplifiedChinese: String) -> String {
    language == "zh-Hans" ? simplifiedChinese : english
  }

  static func shortcutActionTitle(_ action: KeyboardShortcutAction, text: AppText) -> String {
    switch action {
    case .openSettings: return text.settings
    case .openWorkspaceSwitcher: return text.openWorkspaceSwitcher
    case .sideInput: return text.sideInput
    case .splitRight: return text.splitRight
    case .splitDown: return text.splitDown
    case .closePane: return text.closePane
    case .focusPreviousPane: return text.focusPreviousPane
    case .focusNextPane: return text.focusNextPane
    }
  }
}

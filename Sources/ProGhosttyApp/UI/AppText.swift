import Foundation

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
  var settingsCaption: String { text("Quiet defaults for terminal behavior, appearance, and plugins.", "调整终端行为、外观和插件管理的克制默认值。") }
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
  var installedMonospacedFontsHint: String { text("Installed monospaced fonts appear here.", "已安装的等宽字体会显示在这里。") }
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
  var pgControlCommands: String { text("Enable pg control commands", "启用 pg 控制命令") }
  var shellEnhancements: String { text("Plugin Management", "插件管理") }
  var shellEnhancementsCaption: String { text("Inspect and manage terminal plugins without changing your environment until a plan is reviewed.", "检查和管理终端插件；只有在确认计划后才会修改环境。") }
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
  var shellTools: String { text("Terminal plugins", "终端插件") }
  var shellToolsCaption: String { text("Detect-only by default; installs and removals require an explicit plan.", "默认仅检测；安装和卸载都需要明确的计划。") }
  var refresh: String { text("Refresh", "刷新") }
  var recommended: String { text("Recommended", "推荐") }
  var plan: String { text("Plan", "计划") }
  var install: String { text("Install", "安装") }
  var installing: String { text("Installing...", "正在安装...") }
  var uninstall: String { text("Uninstall", "卸载") }
  var confirmInstall: String { text("Confirm Install", "确认安装") }
  var confirmUninstall: String { text("Confirm Uninstall", "确认卸载") }
  var rollback: String { text("Rollback", "回滚") }
  var confirmRollback: String { text("Confirm Rollback", "确认回滚") }
  var rollbackTitle: String { text("Rollback latest change", "回滚最近一次变更") }
  var rollbackCaption: String {
    text(
      "Restore files from the latest backup manifest. Homebrew package changes are not automatically reversed.",
      "从最近一次备份清单恢复文件。Homebrew 包的安装或卸载不会自动反向执行。"
    )
  }
  var backupManifest: String { text("Backup manifest", "备份清单") }
  var affectedFiles: String { text("Affected files", "受影响文件") }
  var cancel: String { text("Cancel", "取消") }
  var applyPlan: String { text("Apply Plan", "应用计划") }
  var close: String { text("Close", "关闭") }
  var commands: String { text("Commands", "命令") }
  var files: String { text("Files", "文件") }
  var noFileChanges: String { text("No file changes.", "没有文件变更。") }
  var risk: String { text("Risk", "风险") }
  var noCommands: String { text("No commands.", "没有命令。") }
  var description: String { text("Description", "描述") }
  var usageInstructions: String { text("Usage", "使用说明") }
  var status: String { text("Status", "状态") }
  var source: String { text("Source", "来源") }
  var category: String { text("Category", "类别") }
  var detectedPaths: String { text("Detected paths", "检测到的路径") }
  var noDetectedPaths: String { text("No detected paths", "未检测到路径") }
  var issues: String { text("Issues", "问题") }
  var environmentSummary: String { text("Environment", "环境") }
  var selectShellEnhancement: String { text("Select a plugin", "选择一个插件") }
  var noPlanAvailable: String { text("No plan available", "暂无可用计划") }
  var shellDefault: String { text("Default shell", "默认 Shell") }
  var homebrew: String { text("Homebrew", "Homebrew") }
  var ohMyZsh: String { text("Oh My Zsh", "Oh My Zsh") }
  var open: String { text("Open", "打开") }
  var restoreDefaults: String { text("Restore Defaults", "恢复默认") }
  var restoreDefaultsTitle: String { text("Restore default settings?", "恢复默认设置？") }
  var restoreDefaultsMessage: String {
    text(
      "This will reset terminal, appearance, shortcut, and plugin settings.",
      "这会重置终端、外观、快捷键和插件设置。"
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
  var pluginReloadCommandHint: String {
    text(
      "To apply plugin changes in an existing pane, copy and paste this command when you need it.",
      "如需让已有分屏中的插件变更生效，可复制并按需粘贴运行这行命令。"
    )
  }
  var pluginReloadCommandCopied: String { text("Copied", "已复制") }
  var save: String { text("Save", "保存") }
  var saved: String { text("Saved.", "已保存。") }
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
      "The quick brown fox jumps over 0123456789",
      "字体预览会随着字体和字号实时变化 0123456789"
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
}

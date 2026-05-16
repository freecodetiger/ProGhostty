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
  var settingsCaption: String { text("Quiet defaults for terminal behavior, appearance, and shell tools.", "调整终端行为、外观和 Shell 工具的克制默认值。") }
  var workspaces: String { text("Workspaces...", "工作区...") }
  var splitRight: String { text("Split Right", "向右分屏") }
  var splitDown: String { text("Split Down", "向下分屏") }
  var closePane: String { text("Close Pane", "关闭分屏") }
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
  var fontSize: String { text("Font size", "字号") }
  var followSystem: String { text("Follow system appearance", "跟随系统外观") }
  var theme: String { text("Theme", "主题") }
  var light: String { text("Light", "浅色") }
  var dark: String { text("Dark", "深色") }
  var history: String { text("History", "历史") }
  var commandBlocks: String { text("Command blocks", "命令块") }
  var outputPreviews: String { text("Output previews", "输出预览") }
  var previewLimit: String { text("Preview limit", "预览上限") }
  var rerunCommandsWithReturn: String { text("Rerun commands with Return", "按回车重新运行命令") }
  var pgControlCommands: String { text("Enable pg control commands", "启用 pg 控制命令") }
  var shellEnhancements: String { text("Shell Enhancements", "Shell 增强") }
  var shellEnhancementsCaption: String { text("Inspect shell tools without changing your terminal until a plan is reviewed.", "检查 Shell 工具；只有在确认计划后才会修改环境。") }
  var shellTools: String { text("Shell tools", "Shell 工具") }
  var shellToolsCaption: String { text("Detect-only by default; installs require an explicit plan.", "默认仅检测；安装需要明确的计划。") }
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
  var selectShellEnhancement: String { text("Select a shell enhancement", "选择一个 Shell 增强") }
  var noPlanAvailable: String { text("No plan available", "暂无可用计划") }
  var shellDefault: String { text("Default shell", "默认 Shell") }
  var homebrew: String { text("Homebrew", "Homebrew") }
  var ohMyZsh: String { text("Oh My Zsh", "Oh My Zsh") }
  var open: String { text("Open", "打开") }
  var restoreDefaults: String { text("Restore Defaults", "恢复默认") }
  var save: String { text("Save", "保存") }
  var saved: String { text("Saved.", "已保存。") }
  var defaultsRestored: String { text("Defaults restored.", "已恢复默认设置。") }
  var searchWorkspaces: String { text("Search workspaces", "搜索工作区") }
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

  func createWorkspace(_ name: String) -> String {
    text("Create \"\(name)\"", "创建“\(name)”")
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

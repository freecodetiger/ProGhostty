import Foundation
import ProGhosttyCore

/// App 全局组合根：拥有跨窗口共享的服务与状态，`AppModel`（每窗口）通过它拿
/// 持久化、通知、更新检查、设置窗口等能力，不再在窗口内 `new` 协作者。
///
/// 每窗口的终端栈（sessionManager / surfaceRegistry / PaneWorkspaceController /
/// focusStore）**不**在这里——它们归属各自的 `AppModel`（见 `.claude/MULTI_WINDOW_SPEC.md` §2.3）。
@MainActor
final class AppComposition {
  /// 供 AppDelegate 等 app 级对象回链。weak 与 `AppModel.shared` 同理由：
  /// 真正持有者是创建它的对象（当前是首个 `AppModel`）。
  static weak var shared: AppComposition?

  let settingsStore: SettingsStore
  let workspaceStore: WorkspaceStore?
  let terminalNotificationCenter: TerminalNotificationCenter
  let terminalNotificationSoundPlayer: TerminalNotificationSoundPlaying
  let agentNotificationHookManager: AgentNotificationHookManager
  let updateChecker: AppUpdateChecker
  let utilityWindows: UtilityWindowController
  let terminalActionDispatcher: TerminalActionDispatcher

  init(
    terminalNotificationCenter: TerminalNotificationCenter = TerminalNotificationCenter(),
    terminalNotificationSoundPlayer: TerminalNotificationSoundPlaying = TerminalNotificationSoundPlayer(),
    agentNotificationHookManager: AgentNotificationHookManager = AgentNotificationHookManager()
  ) {
    self.terminalNotificationCenter = terminalNotificationCenter
    self.terminalNotificationSoundPlayer = terminalNotificationSoundPlayer
    self.agentNotificationHookManager = agentNotificationHookManager
    self.settingsStore = SettingsStore()
    self.updateChecker = AppUpdateChecker()
    self.utilityWindows = UtilityWindowController()
    self.terminalActionDispatcher = TerminalActionDispatcher()

    if let database = Self.openDatabase() {
      self.workspaceStore = WorkspaceStore(database: database)
    } else {
      self.workspaceStore = nil
    }
  }

  static func openDatabase() -> AppDatabase? {
    let appSupport = FileManager.default.urls(
      for: .applicationSupportDirectory, in: .userDomainMask
    ).first!
    .appendingPathComponent("ProGhostty", isDirectory: true)
    try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)

    do {
      return try AppDatabase(path: appSupport.appendingPathComponent("proghostty.sqlite").path)
    } catch {
      let fallback = FileManager.default.temporaryDirectory
        .appendingPathComponent("proghostty-\(UUID().uuidString).sqlite")
      return try? AppDatabase(path: fallback.path)
    }
  }
}

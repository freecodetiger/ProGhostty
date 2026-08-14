import AppKit
import Combine
import Foundation
import ProGhosttyCore
import SwiftUI

/// App 全局组合根：拥有跨窗口共享的服务与状态（settings、workspaces 库、更新、
/// 通知、设置窗口），`AppModel`（每窗口）通过它拿这些能力，不再在窗口内 `new`。
///
/// 每窗口的终端栈（sessionManager / surfaceRegistry / PaneWorkspaceController /
/// focusStore）**不**在这里——它们归属各自的 `AppModel`（见 `.claude/MULTI_WINDOW_SPEC.md` §2.3）。
@MainActor
final class AppComposition: ObservableObject {
  /// 供 AppDelegate 等 app 级对象回链。weak 与 `AppModel.shared` 同理由：
  /// 真正持有者是创建它的对象（当前是首个 `AppModel`）。
  static weak var shared: AppComposition?

  // MARK: 服务（组合根）

  let settingsStore: SettingsStore
  let workspaceStore: WorkspaceStore?
  let terminalNotificationCenter: TerminalNotificationCenter
  let terminalNotificationSoundPlayer: TerminalNotificationSoundPlaying
  let agentNotificationHookManager: AgentNotificationHookManager
  let updateChecker: AppUpdateChecker
  let utilityWindows: UtilityWindowController
  let terminalActionDispatcher: TerminalActionDispatcher

  // MARK: 全局状态

  @Published var settings: AppSettings {
    didSet {
      persistSettings()
      broadcastAppearance()
    }
  }
  @Published var workspaces: [Workspace] = []
  @Published var isCheckingForUpdates = false
  @Published var updateCheckResult: UpdateCheckResult?
  @Published var systemNotificationsAuthorized = true

  /// 每窗口的 `AppModel` 注册表，用于 settings 变更广播与 ⌘Q 聚合。
  private(set) var windowModels: [AppModel] = []
  private var cancellables: Set<AnyCancellable> = []

  private(set) lazy var agentNotifyGate = AgentNotifyGateController(
    hookManager: agentNotificationHookManager,
    setNotificationsEnabledSetting: { [weak self] enabled in
      self?.settings.notificationsEnabled = enabled
    },
    didEnableNotifications: { [weak self] in
      self?.requestNotificationAuthorizationOnEnable()
    }
  )

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

    self.settings = settingsStore.load()
    refreshWorkspaces()
    agentNotifyGate.objectWillChange
      .sink { [weak self] _ in self?.objectWillChange.send() }
      .store(in: &cancellables)

    Task { await checkForUpdates(manual: false) }
    refreshNotificationAuthorization()
    refreshAgentNotifyHookStatus()
  }

  // MARK: 窗口注册

  func registerWindow(_ window: AppModel) {
    guard !windowModels.contains(where: { $0 === window }) else { return }
    windowModels.append(window)
  }

  private func broadcastAppearance() {
    for window in windowModels {
      window.applyTerminalAppearance()
    }
  }

  private func broadcastToast(
    _ message: String,
    style: AppModel.TitlebarToast.Style,
    lifetime: ProGhosttyTitlebarToastLifetime
  ) {
    for window in windowModels {
      window.presentTitlebarToast(message, style: style, lifetime: lifetime)
    }
  }

  // MARK: appearance 派生

  var appearance: AppearanceViewModel {
    let match = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
    return AppearanceViewModel(settings: settings, systemIsLight: match == .aqua)
  }

  var appColorScheme: ColorScheme? { appearance.appColorScheme }
  var terminalPalette: TerminalSurfacePalette { appearance.terminalPalette }
  var usesDarkAppearance: Bool { appearance.usesDarkAppearance }
  var terminalBackgroundColor: NSColor { appearance.terminalBackgroundColor }
  var configurationColorScheme: ColorScheme { appearance.configurationColorScheme }
  var settingsThemePalette: ProGhosttySettingsThemeColors { appearance.settingsThemePalette }
  var configurationWindowBackgroundColor: NSColor { appearance.configurationWindowBackgroundColor }
  var configurationBarBackgroundColor: NSColor { appearance.configurationBarBackgroundColor }
  var configurationSectionBackgroundColor: NSColor { appearance.configurationSectionBackgroundColor }
  var configurationTextBackgroundColor: NSColor { appearance.configurationTextBackgroundColor }
  var configurationSeparatorColor: NSColor { appearance.configurationSeparatorColor }
  var configurationPrimaryTextColor: NSColor { appearance.configurationPrimaryTextColor }
  var configurationSecondaryTextColor: NSColor { appearance.configurationSecondaryTextColor }
  var configurationTertiaryTextColor: NSColor { appearance.configurationTertiaryTextColor }

  var appText: AppText {
    AppText(language: settings.appLanguage)
  }

  // MARK: agent notify 转发

  var agentNotifyHooksStatus: AgentNotifyHookStatus { agentNotifyGate.hooksStatus }
  var agentNotifyHookError: String? { agentNotifyGate.hookError }
  var isInstallingAgentNotifyHooks: Bool { agentNotifyGate.isInstalling }
  var showAgentNotifyInstallSheet: Bool {
    get { agentNotifyGate.showInstallSheet }
    set { agentNotifyGate.showInstallSheet = newValue }
  }
  var showAgentNotifyUninstallSheet: Bool {
    get { agentNotifyGate.showUninstallSheet }
    set { agentNotifyGate.showUninstallSheet = newValue }
  }

  func refreshAgentNotifyHookStatus() {
    agentNotifyGate.refreshStatus()
  }

  func setNotificationsEnabled(_ enabled: Bool) {
    agentNotifyGate.setNotificationsEnabled(enabled)
  }

  func confirmInstallAgentNotifyHooks() {
    agentNotifyGate.confirmInstall()
  }

  func cancelInstallAgentNotifyHooks() {
    agentNotifyGate.cancelInstall()
  }

  func confirmUninstallAgentNotifyHooks(removeHooks: Bool) {
    agentNotifyGate.confirmUninstall(removeHooks: removeHooks)
  }

  func cancelUninstallAgentNotifyHooks() {
    agentNotifyGate.cancelUninstall()
  }

  func repairAgentNotifyHooks() {
    agentNotifyGate.repair()
  }

  private func requestNotificationAuthorizationOnEnable() {
    terminalNotificationCenter.requestAuthorizationForEnable()
    refreshNotificationAuthorization()
  }

  // MARK: 通知授权

  func refreshNotificationAuthorization() {
    terminalNotificationCenter.refreshAuthorizationStatus { [weak self] granted in
      self?.systemNotificationsAuthorized = granted
    }
  }

  func openSystemNotificationSettings() {
    guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") else { return }
    NSWorkspace.shared.open(url)
  }

  // MARK: 更新检查

  func checkForUpdates(manual: Bool) async {
    if manual {
      isCheckingForUpdates = true
      updateCheckResult = nil
    }
    defer {
      if manual {
        isCheckingForUpdates = false
      }
    }

    do {
      let availability = try await updateChecker.check(currentVersion: appShortVersionString())
      switch availability {
      case .upToDate:
        if manual {
          updateCheckResult = .upToDate
        }
      case .available(let update):
        if manual {
          updateCheckResult = .available(update)
        } else {
          broadcastToast(
            "\(appText.updateAvailableToast) \(update.version)",
            style: .update(update.releaseURL),
            lifetime: .persistent
          )
        }
      }
    } catch {
      if manual {
        updateCheckResult = .failed
      }
    }
  }

  func appVersionString() -> String {
    appShortVersionString()
  }

  private func appShortVersionString() -> String {
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
  }

  // MARK: 工作区库

  func refreshWorkspaces() {
    workspaces = (try? workspaceStore?.all()) ?? []
  }

  /// Updates the in-memory library for a just-persisted workspace, without a
  /// full reload (which would reorder and churn the switcher).
  func upsertWorkspace(_ workspace: Workspace) {
    if let index = workspaces.firstIndex(where: { $0.id == workspace.id }) {
      workspaces[index] = workspace
    } else {
      workspaces.append(workspace)
    }
  }

  // MARK: 设置持久化

  private func persistSettings() {
    try? settingsStore.save(settings)
  }

  func saveSettings() {
    persistSettings()
    broadcastToast(appText.settingsSavedToast, style: .success, lifetime: .settingsSaved)
  }

  func resetSettings() {
    settings = .defaults
    saveSettings()
  }

  // MARK: 设置窗口

  func closeSettingsWindow(_ window: NSWindow? = nil) {
    utilityWindows.closeSettings(window)
  }

  func openSettingsWindow() {
    utilityWindows.openSettings(
      makeContent: {
        NSHostingController(
          rootView: SettingsView()
            .environmentObject(self)
            .preferredColorScheme(configurationColorScheme)
        )
      },
      applyChrome: { [weak self] window in
        self?.applyConfigurationWindowAppearance(to: window)
      }
    )
  }

  func reassertSettingsWindowChrome() {
    utilityWindows.reassertSettingsChrome { [weak self] window in
      self?.applyConfigurationWindowAppearance(to: window)
    }
  }

  func applyConfigurationWindowAppearance(to window: NSWindow) {
    let background = settingsThemePalette.windowBackground
    ProGhosttyWindowAppearance.applyConfigurationChrome(
      to: window,
      backgroundColor: background,
      usesDarkAppearance: usesDarkAppearance
    )
  }

  // MARK: 数据库

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

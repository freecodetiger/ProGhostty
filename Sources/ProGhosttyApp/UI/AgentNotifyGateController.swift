import Foundation
import ProGhosttyCore

/// State machine for the Settings notification toggle's install/uninstall
/// gate: agent notify hooks must be installed (with consent) before the
/// toggle turns on, and removing them is offered when it turns off.
///
/// Extracted from `AppModel` (debt spec 3-9). Owns the sheet/progress/error
/// published state; the two effects that belong to the app — persisting
/// `settings.notificationsEnabled` and requesting system authorization on
/// enable — are injected closures.
@MainActor
final class AgentNotifyGateController: ObservableObject {
  @Published private(set) var hooksStatus: AgentNotifyHookStatus
  @Published private(set) var hookError: String?
  @Published private(set) var isInstalling = false
  @Published var showInstallSheet = false
  @Published var showUninstallSheet = false

  private let hookManager: AgentNotificationHookManager
  private let setNotificationsEnabledSetting: (Bool) -> Void
  private let didEnableNotifications: () -> Void

  init(
    hookManager: AgentNotificationHookManager,
    setNotificationsEnabledSetting: @escaping (Bool) -> Void,
    didEnableNotifications: @escaping () -> Void
  ) {
    self.hookManager = hookManager
    self.setNotificationsEnabledSetting = setNotificationsEnabledSetting
    self.didEnableNotifications = didEnableNotifications
    hooksStatus = AgentNotifyHookStatus(
      scriptsReady: false,
      codexConfigured: false,
      claudeConfigured: false,
      detail: nil
    )
  }

  func refreshStatus() {
    hooksStatus = hookManager.status()
  }

  /// Settings toggle entry: enabling requires ready hooks or an install sheet.
  func setNotificationsEnabled(_ enabled: Bool) {
    if enabled {
      refreshStatus()
      if hooksStatus.isReady {
        setNotificationsEnabledSetting(true)
        didEnableNotifications()
      } else {
        showInstallSheet = true
      }
    } else {
      refreshStatus()
      let hadHooks = hooksStatus.isReady
        || hooksStatus.isPartial
        || hooksStatus.scriptsReady
      setNotificationsEnabledSetting(false)
      if hadHooks {
        showUninstallSheet = true
      }
    }
  }

  func confirmInstall() {
    guard !isInstalling else { return }
    isInstalling = true
    hookError = nil
    defer { isInstalling = false }
    do {
      try hookManager.install()
      refreshStatus()
      showInstallSheet = false
      if hooksStatus.isReady {
        setNotificationsEnabledSetting(true)
        didEnableNotifications()
      } else {
        hookError = hooksStatus.detail
          ?? "Hooks installed but not detected as ready"
      }
    } catch {
      hookError = error.localizedDescription
    }
  }

  func cancelInstall() {
    showInstallSheet = false
  }

  func confirmUninstall(removeHooks: Bool) {
    showUninstallSheet = false
    guard removeHooks else {
      refreshStatus()
      return
    }
    do {
      try hookManager.uninstall(removeScripts: true)
      hookError = nil
    } catch {
      hookError = error.localizedDescription
    }
    refreshStatus()
  }

  func cancelUninstall() {
    showUninstallSheet = false
  }

  func repair() {
    showInstallSheet = true
  }
}

import AppKit
import ProGhosttyCore
import SwiftUI

@main
struct ProGhosttyApp: App {
  @NSApplicationDelegateAdaptor(ProGhosttyAppDelegate.self) private var appDelegate
  @StateObject private var composition = AppComposition()

  var body: some Scene {
    WindowGroup {
      TerminalWindowRoot(composition: composition)
    }
    .defaultSize(
      width: ProGhosttyWindowSizing.defaultContentWidth,
      height: ProGhosttyWindowSizing.defaultContentHeight
    )
    .commands {
      ProGhosttyCommands(composition: composition)
    }

    Settings {
      SettingsView()
        .environmentObject(composition)
        .preferredColorScheme(composition.appColorScheme)
    }
  }
}

/// Per-window root: owns the window's `AppModel` (terminal session stack +
/// workspace runtime) and publishes it as the focused scene value so menu
/// commands route to the key window.
@MainActor
private struct TerminalWindowRoot: View {
  @StateObject private var model: AppModel

  init(composition: AppComposition) {
    _model = StateObject(wrappedValue: AppModel(composition: composition))
  }

  var body: some View {
    RootView()
      .environmentObject(model)
      .frame(
        minWidth: ProGhosttyWindowSizing.minimumContentWidth,
        minHeight: ProGhosttyWindowSizing.minimumContentHeight
      )
      .focusedSceneValue(\.terminalWindowModel, model)
  }
}

private struct TerminalWindowModelKey: FocusedValueKey {
  typealias Value = AppModel
}

extension FocusedValues {
  var terminalWindowModel: AppModel? {
    get { self[TerminalWindowModelKey.self] }
    set { self[TerminalWindowModelKey.self] = newValue }
  }
}

private struct ProGhosttyCommands: Commands {
  @FocusedValue(\.terminalWindowModel) private var focusedModel
  let composition: AppComposition

  var body: some Commands {
    CommandGroup(replacing: .newItem) {
      if ProGhosttyWindowPolicy.supportsMultipleTerminalWindows {
        Button("New Window") {}
      }
    }

    CommandGroup(replacing: .appSettings) {
      Button(composition.appText.settings + "...") {
        composition.openSettingsWindow()
      }
      .keyboardShortcut(composition.settings.keyboardShortcuts.shortcut(for: .openSettings).swiftUIShortcut)
    }

    CommandMenu("Workspace") {
      Button("Switch Workspace...") {
        focusedModel?.openWorkspaceSwitcher()
      }
      .keyboardShortcut(composition.settings.keyboardShortcuts.shortcut(for: .openWorkspaceSwitcher).swiftUIShortcut)
    }

    CommandMenu("Pane") {
      Button("Split Right") {
        focusedModel?.splitSelectedTerminal(axis: .horizontal)
      }
      .keyboardShortcut(composition.settings.keyboardShortcuts.shortcut(for: .splitRight).swiftUIShortcut)

      Button("Split Down") {
        focusedModel?.splitSelectedTerminal(axis: .vertical)
      }
      .keyboardShortcut(composition.settings.keyboardShortcuts.shortcut(for: .splitDown).swiftUIShortcut)

      Divider()

      Button("Close Pane") {
        focusedModel?.closeSelectedPane()
      }
      .keyboardShortcut(composition.settings.keyboardShortcuts.shortcut(for: .closePane).swiftUIShortcut)

      Divider()

      Button("Rename Pane") {
        focusedModel?.startRenamePane()
      }
      .keyboardShortcut(composition.settings.keyboardShortcuts.shortcut(for: .renamePane).swiftUIShortcut)

      Divider()

      Button("Focus Previous Pane") {
        focusedModel?.focusNeighbor(offset: -1)
      }
      .keyboardShortcut(composition.settings.keyboardShortcuts.shortcut(for: .focusPreviousPane).swiftUIShortcut)

      Button("Focus Next Pane") {
        focusedModel?.focusNeighbor(offset: 1)
      }
      .keyboardShortcut(composition.settings.keyboardShortcuts.shortcut(for: .focusNextPane).swiftUIShortcut)
    }
  }
}

final class ProGhosttyAppDelegate: NSObject, NSApplicationDelegate {
  private var windowCloseGuard: TerminalWindowCloseGuard?
  /// True while the quit confirmation modal is up: duplicate terminate/close
  /// requests (the modal pumps the run loop) are dropped instead of stacking
  /// more dialogs.
  private var isConfirmingQuit = false
  /// Set when the user already confirmed via the window-close guard, so the
  /// terminate that follows the last window closing doesn't ask again.
  private var quitApprovedByWindowClose = false

  func applicationWillFinishLaunching(_ notification: Notification) {
    UserDefaults.standard.register(defaults: [
      "NSAutoFillHeuristicControllerEnabled": false,
    ])
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
    // Ask BEFORE the terminal window closes (red button / ⌘W). Closing the
    // last window terminates the app, so this is the quit confirmation moved
    // ahead of the close instead of after it.
    windowCloseGuard = TerminalWindowCloseGuard { [weak self] _ in
      guard let self, let composition = AppComposition.shared else { return true }
      guard composition.hasAnyForegroundSession() else { return true }
      if self.isConfirmingQuit { return false }
      self.isConfirmingQuit = true
      defer { self.isConfirmingQuit = false }
      guard composition.confirmQuitWithForegroundProcess() else { return false }
      self.quitApprovedByWindowClose = true
      return true
    }
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    true
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard let composition = AppComposition.shared else { return .terminateNow }
    // Already confirmed in the window-close guard — don't ask twice.
    if quitApprovedByWindowClose {
      quitApprovedByWindowClose = false
      return .terminateNow
    }
    guard composition.hasAnyForegroundSession() else { return .terminateNow }
    // A confirmation modal is already up (it pumps the run loop, so repeated
    // terminate requests can arrive re-entrantly) — refuse instead of
    // stacking another dialog.
    if isConfirmingQuit { return .terminateCancel }
    isConfirmingQuit = true
    defer { isConfirmingQuit = false }
    // The confirmation dialog blocks the main run-loop until answered, so we
    // can return a synchronous reply.
    if composition.confirmQuitWithForegroundProcess() {
      return .terminateNow
    }
    return .terminateCancel
  }
}

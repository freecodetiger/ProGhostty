import AppKit
import ProGhosttyCore
import SwiftUI

@main
struct ProGhosttyApp: App {
  @NSApplicationDelegateAdaptor(ProGhosttyAppDelegate.self) private var appDelegate
  @StateObject private var model = AppModel()

  var body: some Scene {
    Window("ProGhostty", id: "main") {
      RootView()
        .environmentObject(model)
        .frame(
          minWidth: ProGhosttyWindowSizing.minimumContentWidth,
          minHeight: ProGhosttyWindowSizing.minimumContentHeight
        )
    }
    .defaultSize(
      width: ProGhosttyWindowSizing.defaultContentWidth,
      height: ProGhosttyWindowSizing.defaultContentHeight
    )
    .commands {
      CommandGroup(replacing: .newItem) {
        if ProGhosttyWindowPolicy.supportsMultipleTerminalWindows {
          Button("New Window") {}
        }
      }

      CommandGroup(replacing: .appSettings) {
        Button(model.appText.settings + "...") {
          model.openSettingsWindow()
        }
        .keyboardShortcut(model.settings.keyboardShortcuts.shortcut(for: .openSettings).swiftUIShortcut)
      }

      CommandMenu("Workspace") {
        Button("Switch Workspace...") {
          model.openWorkspaceSwitcher()
        }
        .keyboardShortcut(model.settings.keyboardShortcuts.shortcut(for: .openWorkspaceSwitcher).swiftUIShortcut)
      }

      CommandMenu("Pane") {
        Button("Split Right") {
          model.splitSelectedTerminal(axis: .horizontal)
        }
        .keyboardShortcut(model.settings.keyboardShortcuts.shortcut(for: .splitRight).swiftUIShortcut)

        Button("Split Down") {
          model.splitSelectedTerminal(axis: .vertical)
        }
        .keyboardShortcut(model.settings.keyboardShortcuts.shortcut(for: .splitDown).swiftUIShortcut)

        Divider()

        Button("Close Pane") {
          model.closeSelectedPane()
        }
        .keyboardShortcut(model.settings.keyboardShortcuts.shortcut(for: .closePane).swiftUIShortcut)

        Divider()

        Button("Rename Pane") {
          model.startRenamePane()
        }
        .keyboardShortcut(model.settings.keyboardShortcuts.shortcut(for: .renamePane).swiftUIShortcut)

        Divider()

        Button("Focus Previous Pane") {
          model.focusNeighbor(offset: -1)
        }
        .keyboardShortcut(model.settings.keyboardShortcuts.shortcut(for: .focusPreviousPane).swiftUIShortcut)

        Button("Focus Next Pane") {
          model.focusNeighbor(offset: 1)
        }
        .keyboardShortcut(model.settings.keyboardShortcuts.shortcut(for: .focusNextPane).swiftUIShortcut)
      }

    }
    Settings {
      SettingsView()
        .environmentObject(model.composition)
        .preferredColorScheme(model.composition.appColorScheme)
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
      guard let self, let model = AppModel.shared else { return true }
      guard model.hasAnyForegroundSession() else { return true }
      if self.isConfirmingQuit { return false }
      self.isConfirmingQuit = true
      defer { self.isConfirmingQuit = false }
      guard model.confirmQuitWithForegroundProcess() else { return false }
      self.quitApprovedByWindowClose = true
      return true
    }
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    true
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard let model = AppModel.shared else { return .terminateNow }
    // Already confirmed in the window-close guard — don't ask twice.
    if quitApprovedByWindowClose {
      quitApprovedByWindowClose = false
      return .terminateNow
    }
    guard model.hasAnyForegroundSession() else { return .terminateNow }
    // A confirmation modal is already up (it pumps the run loop, so repeated
    // terminate requests can arrive re-entrantly) — refuse instead of
    // stacking another dialog.
    if isConfirmingQuit { return .terminateCancel }
    isConfirmingQuit = true
    defer { isConfirmingQuit = false }
    // The confirmation dialog blocks the main run-loop until answered, so we
    // can return a synchronous reply.
    if model.confirmQuitWithForegroundProcess() {
      return .terminateNow
    }
    return .terminateCancel
  }
}

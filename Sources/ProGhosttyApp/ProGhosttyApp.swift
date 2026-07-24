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
        .environmentObject(model)
        .preferredColorScheme(model.appColorScheme)
    }
  }
}

final class ProGhosttyAppDelegate: NSObject, NSApplicationDelegate {
  func applicationWillFinishLaunching(_ notification: Notification) {
    UserDefaults.standard.register(defaults: [
      "NSAutoFillHeuristicControllerEnabled": false,
    ])
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    true
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard let model = AppModel.shared else { return .terminateNow }
    guard model.hasAnyForegroundSession() else { return .terminateNow }
    // The confirmation dialog blocks the main run-loop until answered, so we
    // can return synchronous reply; just make sure to move the defer-ring of
    // termination to after the dialog returns.
    if model.confirmQuitWithForegroundProcess() {
      return .terminateNow
    }
    return .terminateCancel
  }
}

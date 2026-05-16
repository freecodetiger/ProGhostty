import ProGhosttyCore
import SwiftUI

@main
struct ProGhosttyApp: App {
  @StateObject private var model = AppModel()

  var body: some Scene {
    WindowGroup("ProGhostty") {
      RootView()
        .environmentObject(model)
        .frame(minWidth: 980, minHeight: 640)
    }
    .commands {
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

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
        .keyboardShortcut(",", modifiers: [.command])
      }

      CommandMenu("Workspace") {
        Button("Switch Workspace...") {
          model.openWorkspaceSwitcher()
        }
        .keyboardShortcut("o", modifiers: [.command, .shift])
      }

      CommandMenu("Pane") {
        Button("Split Right") {
          model.splitSelectedTerminal(axis: .horizontal)
        }
        .keyboardShortcut("d", modifiers: [.command])

        Button("Split Down") {
          model.splitSelectedTerminal(axis: .vertical)
        }
        .keyboardShortcut("d", modifiers: [.command, .shift])

        Divider()

        Button("Close Pane") {
          model.closeSelectedPane()
        }
        .keyboardShortcut("w", modifiers: [.command])

        Divider()

        Button("Focus Previous Pane") {
          model.focusNeighbor(offset: -1)
        }
        .keyboardShortcut(.leftArrow, modifiers: [.command, .option])

        Button("Focus Next Pane") {
          model.focusNeighbor(offset: 1)
        }
        .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
      }
    }
    Settings {
      SettingsView()
        .environmentObject(model)
        .preferredColorScheme(model.appColorScheme)
    }
  }
}

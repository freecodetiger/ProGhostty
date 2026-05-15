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
      CommandMenu("Workspace") {
        Button("Switch Workspace...") {
          model.openWorkspaceSwitcher()
        }
        .keyboardShortcut("o", modifiers: [.command, .shift])

        Button("New Workspace") {
          model.createAndOpenWorkspace(name: "Workspace")
        }
        .keyboardShortcut("n", modifiers: [.command, .option])

        Divider()

        Button("Previous Workspace") {
          model.focusWorkspaceNeighbor(offset: -1)
        }
        .keyboardShortcut(.leftArrow, modifiers: [.command, .option, .shift])

        Button("Next Workspace") {
          model.focusWorkspaceNeighbor(offset: 1)
        }
        .keyboardShortcut(.rightArrow, modifiers: [.command, .option, .shift])
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
    }
  }
}

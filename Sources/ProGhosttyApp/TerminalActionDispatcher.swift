import Foundation
import ProGhosttyCore

@MainActor
struct TerminalActionDispatcher {
  func dispatch(_ message: ProGhosttyControlMessage, in model: AppModel) {
    switch message.command {
    case .workspaceOpen:
      model.openWorkspaceSwitcher()
    case .workspaceSwitch:
      if let name = message.args["name"] {
        model.switchWorkspace(named: name)
      }
    case .workspaceNew:
      if let name = message.args["name"] {
        model.openWorkspaceCreation(named: name)
      }
    case .settingsOpen:
      model.openSettingsWindow()
    case .splitRight:
      model.splitSelectedTerminal(axis: .horizontal)
    case .splitDown:
      model.splitSelectedTerminal(axis: .vertical)
    case .layoutSave:
      model.saveActiveLayoutSnapshot()
    case .layoutRestore:
      model.restoreActiveLayoutSnapshot()
    }
  }
}

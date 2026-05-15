import AppKit
import ProGhosttyCore
import SwiftUI

struct RootView: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    VStack(spacing: 0) {
      switch model.section {
      case .terminals:
        TerminalCanvasView()
      case .history:
        ToolPage(title: "History") { HistoryView() }
      case .workspaces:
        ToolPage(title: "Workspaces") { WorkspaceView() }
      case .plugins:
        ToolPage(title: "Plugins") { PluginManagerView() }
      case .settings:
        ToolPage(title: "Settings") { SettingsView() }
      }
    }
    .background(
      WorkspaceTitlebarView(
        title: model.activeWorkspaceTitle,
        workspaces: model.workspaceSwitcherState.workspaces,
        activeWorkspaceID: model.workspaceSwitcherState.activeWorkspaceID,
        onActivate: { model.activateWorkspaceFromSwitcher($0) },
        onOpenSwitcher: { model.openWorkspaceSwitcher() },
        onNewWorkspace: { model.createAndOpenWorkspace(name: "Workspace") },
        onManageWorkspaces: { model.section = .workspaces },
        onSettings: { NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) }
      )
      .frame(width: 0, height: 0)
    )
  }
}

private struct ToolPage<Content: View>: View {
  @EnvironmentObject private var model: AppModel
  let title: String
  @ViewBuilder var content: Content

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Button("Terminals") { model.section = .terminals }
          .buttonStyle(.plain)
          .padding(.horizontal, 10)
          .padding(.vertical, 6)
          .background(Color.primary.opacity(0.08))
          .clipShape(RoundedRectangle(cornerRadius: 6))
        Text(title)
          .font(.headline)
        Spacer()
      }
      .padding(10)
      Divider()
      content
    }
  }
}

import ProGhosttyCore
import SwiftUI

struct RootView: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    NavigationSplitView {
      List(selection: $model.section) {
        ForEach(AppModel.Section.allCases) { section in
          Text(section.rawValue).tag(section)
        }
      }
      .navigationSplitViewColumnWidth(180)
    } detail: {
      switch model.section {
      case .terminals:
        TerminalTabView()
      case .history:
        HistoryView()
      case .workspaces:
        WorkspaceView()
      case .plugins:
        PluginManagerView()
      case .settings:
        SettingsView()
      }
    }
  }
}

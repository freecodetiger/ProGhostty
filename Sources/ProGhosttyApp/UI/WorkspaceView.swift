import ProGhosttyCore
import SwiftUI

struct WorkspaceView: View {
  @EnvironmentObject private var model: AppModel
  @State private var name = ""
  @State private var rootPath = FileManager.default.currentDirectoryPath

  var body: some View {
    VStack(spacing: 0) {
      Form {
        TextField("Name", text: $name)
        TextField("Root Path", text: $rootPath)
        HStack {
          Button("Create Workspace") {
            model.createWorkspace(name: name, rootPath: rootPath.isEmpty ? nil : rootPath)
            name = ""
          }
          Button("Use Current Directory") {
            rootPath = FileManager.default.currentDirectoryPath
          }
        }
      }
      .padding()

      Divider()

      List {
        ForEach(model.workspaces) { workspace in
          HStack {
            VStack(alignment: .leading) {
              Text(workspace.name)
              Text(workspace.rootPath ?? "(no root path)")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Open Terminal") { model.openTerminal(workspace: workspace) }
            Button("Delete", role: .destructive) { model.deleteWorkspace(workspace) }
          }
          .padding(.vertical, 4)
        }
      }
    }
  }
}

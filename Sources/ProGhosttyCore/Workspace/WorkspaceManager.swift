import Foundation

public final class WorkspaceManager {
  private let store: WorkspaceStore

  public init(store: WorkspaceStore) {
    self.store = store
  }

  public func create(name: String, rootPath: String?, defaultShell: String? = nil) throws
    -> Workspace
  {
    let workspace = Workspace(name: name, rootPath: rootPath, defaultShell: defaultShell)
    try store.save(workspace)
    return workspace
  }

  public func terminalConfig(
    for workspace: Workspace, fallbackShell: String, rows: Int = 24, cols: Int = 80
  ) -> TerminalSessionConfig {
    TerminalSessionConfig(
      shellPath: workspace.defaultShell ?? fallbackShell,
      workingDirectory: workspace.rootPath,
      environment: [:],
      rows: rows,
      cols: cols,
      workspaceId: workspace.id
    )
  }
}

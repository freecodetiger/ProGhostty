import Foundation

@MainActor
public final class PaneWorkspaceController {
  public struct OpenResult: Equatable {
    public var workspace: WorkspaceLayout
    public var pane: TerminalPane
  }

  public struct SplitResult: Equatable {
    public var workspace: WorkspaceLayout
    public var pane: TerminalPane
  }

  public struct CloseWorkspaceResult: Equatable {
    public var workspaceID: UUID
    public var panes: [TerminalPane]
  }

  private let sessionManager: TerminalSessionManager
  private let focusStore: TerminalFocusStore
  public private(set) var workspaceLayouts: [WorkspaceLayout] = []
  public var activeWorkspaceID: UUID?

  public init(sessionManager: TerminalSessionManager, focusStore: TerminalFocusStore) {
    self.sessionManager = sessionManager
    self.focusStore = focusStore
  }

  public func workspaceLayout(id: UUID) -> WorkspaceLayout? {
    workspaceLayouts.first { $0.id == id }
  }

  public func replaceWorkspaceLayout(_ workspace: WorkspaceLayout) {
    guard let index = workspaceLayouts.firstIndex(where: { $0.id == workspace.id }) else { return }
    workspaceLayouts[index] = workspace
  }

  public func openTerminal(
    title: String,
    config: TerminalSessionConfig,
    paneTitle: String,
    cwd: String?
  ) throws -> OpenResult {
    let session = try sessionManager.createSession(config: config)
    let pane = TerminalPane(sessionId: session, title: paneTitle, cwd: cwd)
    let workspace = WorkspaceLayout(title: title, root: .leaf(pane), workspaceId: config.workspaceId)
    workspaceLayouts.append(workspace)
    activeWorkspaceID = workspace.id
    focusStore.focusPane(pane.paneId, in: workspace.id)
    return OpenResult(workspace: workspace, pane: pane)
  }

  public func restoreWorkspace(
    workspace: Workspace,
    layoutSnapshot: WorkspaceLayout?,
    fallbackShell: String,
    defaultWorkingDirectory: String,
    rows: Int = 24,
    cols: Int = 80
  ) throws -> WorkspaceLayout {
    let fallbackCwd = nonEmpty(workspace.rootPath) ?? nonEmpty(defaultWorkingDirectory) ?? FileManager.default.homeDirectoryForCurrentUser.path
    var template = layoutSnapshot ?? WorkspaceLayout(
      title: workspace.name,
      root: .leaf(TerminalPane(
        sessionId: TerminalSessionID(),
        title: paneTitle(for: fallbackCwd, fallback: workspace.name),
        cwd: fallbackCwd
      )),
      workspaceId: workspace.id
    )
    template.title = workspace.name
    template.workspaceId = workspace.id

    let restoredRoot = try PaneTreeReducer.mapLeaves(in: template.root) { pane in
      let cwd = nonEmpty(pane.cwd) ?? fallbackCwd
      let config = TerminalSessionConfig(
        shellPath: workspace.defaultShell ?? fallbackShell,
        workingDirectory: cwd,
        environment: [:],
        rows: rows,
        cols: cols,
        workspaceId: workspace.id
      )
      let session = try sessionManager.createSession(config: config)
      return TerminalPane(
        paneId: pane.paneId,
        sessionId: session,
        title: pane.title.isEmpty ? paneTitle(for: cwd, fallback: workspace.name) : pane.title,
        cwd: cwd
      )
    }

    let restored = WorkspaceLayout(
      id: template.id,
      title: template.title,
      root: restoredRoot,
      workspaceId: template.workspaceId
    )
    if let index = workspaceLayouts.firstIndex(where: { $0.id == restored.id }) {
      workspaceLayouts[index] = restored
    } else {
      workspaceLayouts.append(restored)
    }
    activeWorkspaceID = restored.id
    focusStore.focusPane(PaneTreeReducer.listLeaves(in: restored.root).first?.paneId, in: restored.id)
    return restored
  }

  public func closeSelectedTerminal() -> (workspaceID: UUID, panes: [TerminalPane])? {
    guard let activeWorkspaceID else {
      return nil
    }
    return closeWorkspace(workspaceID: activeWorkspaceID).map { ($0.workspaceID, $0.panes) }
  }

  public func closeWorkspace(workspaceID: UUID) -> CloseWorkspaceResult? {
    guard let index = workspaceLayouts.firstIndex(where: { $0.id == workspaceID }) else {
      return nil
    }

    let workspace = workspaceLayouts.remove(at: index)
    let panes = PaneTreeReducer.listLeaves(in: workspace.root)
    for pane in panes {
      sessionManager.closeSession(pane.sessionId)
    }
    focusStore.removeFocus(for: workspace.id)
    if activeWorkspaceID == workspace.id {
      activeWorkspaceID = workspaceLayouts.last?.id
    }
    return CloseWorkspaceResult(workspaceID: workspace.id, panes: panes)
  }

  public func selectPane(_ paneID: UUID, in workspaceID: UUID) -> Bool {
    guard let workspace = workspaceLayout(id: workspaceID), PaneTreeReducer.findPane(in: workspace.root, paneId: paneID) != nil else {
      return false
    }
    activeWorkspaceID = workspaceID
    focusStore.focusPane(paneID, in: workspaceID)
    return true
  }

  public func selectSession(_ sessionID: TerminalSessionID) -> WorkspaceLayout? {
    for workspace in workspaceLayouts {
      guard
        let pane = PaneTreeReducer.listLeaves(in: workspace.root)
          .first(where: { $0.sessionId == sessionID })
      else {
        continue
      }
      activeWorkspaceID = workspace.id
      focusStore.focusPane(pane.paneId, in: workspace.id)
      return workspace
    }
    return nil
  }

  public func splitPane(
    workspaceID: UUID,
    paneID: UUID,
    axis: SplitAxis,
    config: TerminalSessionConfig,
    paneTitle: String,
    cwd: String?
  ) throws -> SplitResult {
    guard let index = workspaceLayouts.firstIndex(where: { $0.id == workspaceID }) else {
      throw PaneWorkspaceError.workspaceNotFound
    }
    var workspace = workspaceLayouts[index]
    guard PaneTreeReducer.findPane(in: workspace.root, paneId: paneID) != nil else {
      throw PaneWorkspaceError.paneNotFound
    }

    let session = try sessionManager.createSession(config: config)
    let pane = TerminalPane(sessionId: session, title: paneTitle, cwd: cwd)
    guard PaneTreeReducer.splitPane(in: &workspace.root, targetPaneId: paneID, axis: axis, newPane: pane) else {
      sessionManager.closeSession(session)
      throw PaneWorkspaceError.paneNotFound
    }

    workspaceLayouts[index] = workspace
    activeWorkspaceID = workspace.id
    focusStore.focusPane(pane.paneId, in: workspace.id)
    return SplitResult(workspace: workspace, pane: pane)
  }

  @discardableResult
  public func closePane(workspaceID: UUID, paneID: UUID) throws -> TerminalPane? {
    guard let index = workspaceLayouts.firstIndex(where: { $0.id == workspaceID }) else {
      throw PaneWorkspaceError.workspaceNotFound
    }

    var workspace = workspaceLayouts[index]
    let previousRoot = workspace.root
    guard let closed = PaneTreeReducer.closePane(in: &workspace.root, paneId: paneID) else {
      return nil
    }

    sessionManager.closeSession(closed.sessionId)
    workspaceLayouts[index] = workspace
    focusStore.focusPane(nextPane(afterClosing: paneID, previousRoot: previousRoot, currentRoot: workspace.root)?.paneId, in: workspace.id)
    return closed
  }

  public func resizePane(_ paneID: UUID, in workspaceID: UUID, rows: Int, cols: Int) {
    guard let workspace = workspaceLayout(id: workspaceID),
      let session = PaneTreeReducer.findPane(in: workspace.root, paneId: paneID)?.sessionId
    else {
      return
    }
    sessionManager.resizeSession(session, rows: rows, cols: cols)
  }

  public func updateSplitRatio(_ splitID: UUID, in workspaceID: UUID, ratio: Double) -> Bool {
    guard let index = workspaceLayouts.firstIndex(where: { $0.id == workspaceID }) else { return false }
    var workspace = workspaceLayouts[index]
    guard PaneTreeReducer.updateRatio(in: &workspace.root, splitId: splitID, ratio: ratio) else {
      return false
    }
    workspaceLayouts[index] = workspace
    return true
  }

  public func focusNeighbor(in workspaceID: UUID, offset: Int) -> UUID? {
    guard
      let workspace = workspaceLayout(id: workspaceID),
      let focusedPaneId = focusStore.focusedPaneId(in: workspaceID),
      let next = PaneTreeReducer.neighborPaneId(in: workspace.root, from: focusedPaneId, offset: offset)
    else {
      return nil
    }
    focusStore.focusPane(next, in: workspaceID)
    return next
  }

  private func nextPane(afterClosing paneID: UUID, previousRoot: PaneNode, currentRoot: PaneNode) -> TerminalPane? {
    let previousLeaves = PaneTreeReducer.listLeaves(in: previousRoot)
    let currentLeaves = PaneTreeReducer.listLeaves(in: currentRoot)
    let closedIndex = previousLeaves.firstIndex(where: { $0.paneId == paneID }) ?? 0
    let nextIndex = min(closedIndex, max(0, currentLeaves.count - 1))
    return currentLeaves.isEmpty ? nil : currentLeaves[nextIndex]
  }

  private func nonEmpty(_ value: String?) -> String? {
    let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? nil : trimmed
  }

  private func paneTitle(for cwd: String, fallback: String) -> String {
    let title = URL(fileURLWithPath: cwd).lastPathComponent
    return title.isEmpty ? fallback : title
  }
}

public enum PaneWorkspaceError: Error, Equatable {
  case workspaceNotFound
  case paneNotFound
}

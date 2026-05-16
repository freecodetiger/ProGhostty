import Foundation

public struct WorkspaceSwitcherState: Equatable, Sendable {
  public enum WorkspaceStatus: Equatable, Sendable {
    case active
    case running
    case saved
  }

  public struct DecoratedWorkspace: Identifiable, Equatable, Sendable {
    public var workspace: Workspace
    public var status: WorkspaceStatus

    public var id: UUID {
      workspace.id
    }

    public init(workspace: Workspace, status: WorkspaceStatus) {
      self.workspace = workspace
      self.status = status
    }
  }

  public var workspaces: [Workspace] {
    didSet {
      ensureSelection()
    }
  }

  public var activeWorkspaceID: UUID?
  public var runningWorkspaceIDs: Set<UUID>
  public var selectedWorkspaceID: UUID?
  public var query: String = ""

  public init(
    workspaces: [Workspace],
    activeWorkspaceID: UUID?,
    runningWorkspaceIDs: Set<UUID> = []
  ) {
    self.workspaces = workspaces
    self.activeWorkspaceID = activeWorkspaceID
    self.runningWorkspaceIDs = runningWorkspaceIDs
    selectedWorkspaceID = activeWorkspaceID ?? workspaces.first?.id
    ensureSelection()
  }

  public var filteredWorkspaces: [Workspace] {
    workspaces
  }

  public var canCreateWorkspaceFromQuery: Bool {
    false
  }

  public var isCreateWorkspaceSelected: Bool {
    selectedWorkspaceID == nil
  }

  public var decoratedWorkspaces: [DecoratedWorkspace] {
    filteredWorkspaces.map { workspace in
      let status: WorkspaceStatus
      if workspace.id == activeWorkspaceID {
        status = .active
      } else if runningWorkspaceIDs.contains(workspace.id) {
        status = .running
      } else {
        status = .saved
      }
      return DecoratedWorkspace(workspace: workspace, status: status)
    }
  }

  public mutating func moveSelection(delta: Int) {
    let items = filteredWorkspaces
    let createIndex = items.count
    guard createIndex > 0 else {
      selectedWorkspaceID = nil
      return
    }

    let currentIndex = selectedWorkspaceID.flatMap { selected in
      items.firstIndex { $0.id == selected }
    } ?? createIndex
    let nextIndex = (currentIndex + delta + createIndex + 1) % (createIndex + 1)
    selectedWorkspaceID = nextIndex == createIndex ? nil : items[nextIndex].id
  }

  public mutating func selectCreateWorkspace() {
    selectedWorkspaceID = nil
  }

  private mutating func ensureSelection() {
    let items = filteredWorkspaces
    guard !items.isEmpty else {
      selectedWorkspaceID = nil
      return
    }
    if let selectedWorkspaceID, items.contains(where: { $0.id == selectedWorkspaceID }) {
      return
    }
    selectedWorkspaceID = activeWorkspaceID.flatMap { active in
      items.first { $0.id == active }?.id
    } ?? items.first?.id
  }
}

import Foundation

public struct WorkspaceSwitcherState: Equatable, Sendable {
  public var workspaces: [Workspace] {
    didSet {
      ensureSelection()
    }
  }

  public var activeWorkspaceID: UUID?
  public var selectedWorkspaceID: UUID?
  public var query: String = "" {
    didSet {
      selectedWorkspaceID = filteredWorkspaces.first?.id
    }
  }

  public init(workspaces: [Workspace], activeWorkspaceID: UUID?) {
    self.workspaces = workspaces
    self.activeWorkspaceID = activeWorkspaceID
    selectedWorkspaceID = activeWorkspaceID ?? workspaces.first?.id
    ensureSelection()
  }

  public var filteredWorkspaces: [Workspace] {
    let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !needle.isEmpty else { return workspaces }
    return workspaces.filter { workspace in
      workspace.name.lowercased().contains(needle)
        || (workspace.rootPath?.lowercased().contains(needle) == true)
    }
  }

  public var canCreateWorkspaceFromQuery: Bool {
    let name = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { return false }
    return !workspaces.contains { $0.name.caseInsensitiveCompare(name) == .orderedSame }
  }

  public mutating func moveSelection(delta: Int) {
    let items = filteredWorkspaces
    guard !items.isEmpty else {
      selectedWorkspaceID = nil
      return
    }

    let currentIndex = selectedWorkspaceID.flatMap { selected in
      items.firstIndex { $0.id == selected }
    } ?? 0
    let nextIndex = (currentIndex + delta + items.count) % items.count
    selectedWorkspaceID = items[nextIndex].id
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

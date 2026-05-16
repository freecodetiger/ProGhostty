import Foundation
import Testing

@testable import ProGhosttyCore

@Suite("Workspace switcher state")
struct WorkspaceSwitcherStateTests {
  @Test func filtersWorkspacesByNameAndPath() {
    let project = Workspace(id: UUID(), name: "Project", rootPath: "/Users/zpc/projects/proghostty")
    let notes = Workspace(id: UUID(), name: "Notes", rootPath: "/Users/zpc/notes")
    var state = WorkspaceSwitcherState(workspaces: [project, notes], activeWorkspaceID: project.id)

    state.query = "ghost"

    #expect(state.filteredWorkspaces.map(\.id) == [project.id])
  }

  @Test func selectionMovesWithinFilteredResults() {
    let first = Workspace(id: UUID(), name: "Alpha", rootPath: "/a")
    let second = Workspace(id: UUID(), name: "Beta", rootPath: "/b")
    var state = WorkspaceSwitcherState(workspaces: [first, second], activeWorkspaceID: first.id)

    state.moveSelection(delta: 1)

    #expect(state.selectedWorkspaceID == second.id)
  }

  @Test func changingQuerySelectsFirstFilteredWorkspace() {
    let first = Workspace(id: UUID(), name: "Alpha", rootPath: "/a")
    let second = Workspace(id: UUID(), name: "Beta", rootPath: "/b")
    var state = WorkspaceSwitcherState(workspaces: [first, second], activeWorkspaceID: first.id)

    state.query = "bet"

    #expect(state.selectedWorkspaceID == second.id)
  }

  @Test func canCreateWorkspaceWhenQueryHasNoExactMatch() {
    let first = Workspace(id: UUID(), name: "Alpha", rootPath: "/a")
    var state = WorkspaceSwitcherState(workspaces: [first], activeWorkspaceID: first.id)

    state.query = "New Project"

    #expect(state.canCreateWorkspaceFromQuery == true)
  }

  @Test func decoratedWorkspacesMarkActiveAndRunningWorkspaces() {
    let active = Workspace(id: UUID(), name: "Active", rootPath: "/active")
    let running = Workspace(id: UUID(), name: "Running", rootPath: "/running")
    let saved = Workspace(id: UUID(), name: "Saved", rootPath: "/saved")
    let state = WorkspaceSwitcherState(
      workspaces: [active, running, saved],
      activeWorkspaceID: active.id,
      runningWorkspaceIDs: [active.id, running.id]
    )

    let items = state.decoratedWorkspaces

    #expect(items.map(\.workspace.id) == [active.id, running.id, saved.id])
    #expect(items[0].status == .active)
    #expect(items[1].status == .running)
    #expect(items[2].status == .saved)
  }
}

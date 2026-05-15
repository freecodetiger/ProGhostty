import Foundation
import Testing

@testable import ProGhosttyCore

@Suite("Pane workspace controller")
@MainActor
struct PaneWorkspaceControllerTests {
  @Test func openTerminalCreatesSessionBackedWorkspaceAndFocusesPane() throws {
    let manager = RecordingSessionManager()
    let focusStore = TerminalFocusStore()
    let controller = PaneWorkspaceController(sessionManager: manager, focusStore: focusStore)
    let config = makeConfig(cwd: "/tmp")

    let result = try controller.openTerminal(title: "work", config: config, paneTitle: "zsh", cwd: "/tmp")

    #expect(manager.createdConfigs == [config])
    #expect(controller.workspaceLayouts.map(\.id) == [result.workspace.id])
    #expect(PaneTreeReducer.listLeaves(in: result.workspace.root) == [result.pane])
    #expect(focusStore.focusedPaneId(in: result.workspace.id) == result.pane.paneId)
  }

  @Test func splitPaneCreatesNewSessionAndUpdatesOnlyTargetWorkspace() throws {
    let manager = RecordingSessionManager()
    let focusStore = TerminalFocusStore()
    let controller = PaneWorkspaceController(sessionManager: manager, focusStore: focusStore)
    let first = try controller.openTerminal(title: "work", config: makeConfig(cwd: "/a"), paneTitle: "zsh", cwd: "/a")
    let second = try controller.openTerminal(title: "other", config: makeConfig(cwd: "/b"), paneTitle: "zsh", cwd: "/b")

    let split = try controller.splitPane(
      workspaceID: first.workspace.id,
      paneID: first.pane.paneId,
      axis: .horizontal,
      config: makeConfig(cwd: "/a"),
      paneTitle: "zsh",
      cwd: "/a"
    )

    let updatedFirst = try #require(controller.workspaceLayout(id: first.workspace.id))
    let untouchedSecond = try #require(controller.workspaceLayout(id: second.workspace.id))
    #expect(PaneTreeReducer.listLeaves(in: updatedFirst.root).map(\.paneId) == [first.pane.paneId, split.pane.paneId])
    #expect(PaneTreeReducer.listLeaves(in: untouchedSecond.root).map(\.paneId) == [second.pane.paneId])
    #expect(focusStore.focusedPaneId(in: first.workspace.id) == split.pane.paneId)
  }

  @Test func closePaneClosesOnlyRequestedSessionAndPreservesSiblingPanes() throws {
    let manager = RecordingSessionManager()
    let controller = PaneWorkspaceController(sessionManager: manager, focusStore: TerminalFocusStore())
    let opened = try controller.openTerminal(title: "work", config: makeConfig(cwd: "/a"), paneTitle: "zsh", cwd: "/a")
    let split = try controller.splitPane(
      workspaceID: opened.workspace.id,
      paneID: opened.pane.paneId,
      axis: .horizontal,
      config: makeConfig(cwd: "/a"),
      paneTitle: "zsh",
      cwd: "/a"
    )

    let closed = try controller.closePane(workspaceID: opened.workspace.id, paneID: split.pane.paneId)

    let updated = try #require(controller.workspaceLayout(id: opened.workspace.id))
    #expect(closed == split.pane)
    #expect(manager.closedSessions == [split.pane.sessionId])
    #expect(PaneTreeReducer.listLeaves(in: updated.root) == [opened.pane])
  }

  private func makeConfig(cwd: String) -> TerminalSessionConfig {
    TerminalSessionConfig(shellPath: "/bin/sh", workingDirectory: cwd, environment: [:], rows: 24, cols: 80)
  }
}

@MainActor
private final class RecordingSessionManager: TerminalSessionManager {
  var createdConfigs: [TerminalSessionConfig] = []
  var closedSessions: [TerminalSessionID] = []
  let events: AsyncStream<TerminalEvent> = AsyncStream { continuation in
    continuation.finish()
  }

  func createSession(config: TerminalSessionConfig) throws -> TerminalSessionID {
    createdConfigs.append(config)
    return TerminalSessionID()
  }

  func closeSession(_ id: TerminalSessionID) {
    closedSessions.append(id)
  }

  func resizeSession(_ id: TerminalSessionID, rows: Int, cols: Int) {}
  func writeInput(_ data: Data, to id: TerminalSessionID) {}
}

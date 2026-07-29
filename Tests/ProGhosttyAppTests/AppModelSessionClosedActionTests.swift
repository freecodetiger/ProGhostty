import Foundation
import ProGhosttyCore
import Testing

@testable import ProGhosttyApp

@Suite("AppModel session closed action")
@MainActor
struct AppModelSessionClosedActionTests {
  @Test func choosesClosePaneWhenWorkspaceStillHasSiblingPanes() {
    let targetSession = TerminalSessionID()
    let targetPane = TerminalPane(sessionId: targetSession, title: "zsh")
    let siblingPane = TerminalPane(sessionId: TerminalSessionID(), title: "zsh")
    let runtime = runtime(
      root: .split(SplitPane(axis: .horizontal, first: .leaf(targetPane), second: .leaf(siblingPane)))
    )

    #expect(
      AppModel.sessionClosedAction(for: targetSession, in: [runtime])
        == .closePane(workspaceID: runtime.id, paneID: targetPane.paneId)
    )
  }

  @Test func choosesCloseWorkspaceWhenClosedSessionIsLastPane() {
    let targetSession = TerminalSessionID()
    let runtime = runtime(root: .leaf(TerminalPane(sessionId: targetSession, title: "zsh")))

    #expect(
      AppModel.sessionClosedAction(for: targetSession, in: [runtime])
        == .closeWorkspace(workspaceID: runtime.id)
    )
  }

  @Test func returnsNoneWhenSessionDoesNotBelongToAnyRuntime() {
    let runtime = runtime(root: .leaf(TerminalPane(sessionId: TerminalSessionID(), title: "zsh")))

    #expect(
      AppModel.sessionClosedAction(for: TerminalSessionID(), in: [runtime])
        == .none
    )
  }

  private func runtime(root: PaneNode) -> AppModel.WorkspaceRuntime {
    AppModel.WorkspaceRuntime(
      layout: WorkspaceLayout(title: "Workspace", root: root),
      workspace: nil,
      cwdBySession: [:]
    )
  }
}

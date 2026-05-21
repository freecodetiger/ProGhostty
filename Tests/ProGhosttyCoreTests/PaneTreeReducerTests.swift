import Foundation
import Testing

@testable import ProGhosttyCore

@Suite("Pane tree reducer")
struct PaneTreeReducerTests {
  @Test func terminalPaneIsLightweightAndCodable() throws {
    let pane = TerminalPane(
      paneId: UUID(),
      sessionId: TerminalSessionID(),
      title: "zsh",
      cwd: "/tmp"
    )

    let data = try JSONEncoder().encode(pane)
    let decoded = try JSONDecoder().decode(TerminalPane.self, from: data)

    #expect(decoded == pane)
  }

  @Test func splitPaneReplacesTargetLeafWithSplitNode() {
    let first = TerminalPane(sessionId: TerminalSessionID(), title: "first", cwd: "/a")
    let second = TerminalPane(sessionId: TerminalSessionID(), title: "second", cwd: "/b")
    var root = PaneNode.leaf(first)

    let didSplit = PaneTreeReducer.splitPane(
      in: &root,
      targetPaneId: first.paneId,
      axis: .horizontal,
      newPane: second,
      ratio: 0.42
    )

    #expect(didSplit)
    guard case .split(let split) = root else {
      Issue.record("expected split")
      return
    }
    #expect(split.axis == .horizontal)
    #expect(split.ratio == 0.42)
    #expect(split.first == .leaf(first))
    #expect(split.second == .leaf(second))
  }

  @Test func closePanePromotesSiblingAndAvoidsEmptySplit() {
    let first = TerminalPane(sessionId: TerminalSessionID(), title: "first", cwd: "/a")
    let second = TerminalPane(sessionId: TerminalSessionID(), title: "second", cwd: "/b")
    var root = PaneNode.split(SplitPane(axis: .horizontal, ratio: 0.5, first: .leaf(first), second: .leaf(second)))

    let closed = PaneTreeReducer.closePane(in: &root, paneId: first.paneId)

    #expect(closed == first)
    #expect(root == .leaf(second))
  }

  @Test func closeNestedPanePreservesUnrelatedSibling() {
    let first = TerminalPane(sessionId: TerminalSessionID(), title: "first", cwd: "/a")
    let second = TerminalPane(sessionId: TerminalSessionID(), title: "second", cwd: "/b")
    let third = TerminalPane(sessionId: TerminalSessionID(), title: "third", cwd: "/c")
    var root = PaneNode.split(SplitPane(
      axis: .horizontal,
      ratio: 0.5,
      first: .leaf(first),
      second: .split(SplitPane(
        axis: .vertical,
        ratio: 0.5,
        first: .leaf(second),
        second: .leaf(third)
      ))
    ))

    let closed = PaneTreeReducer.closePane(in: &root, paneId: third.paneId)

    #expect(closed == third)
    #expect(PaneTreeReducer.listLeaves(in: root) == [first, second])
  }

  @Test func closeOnlyLeafIsRejected() {
    let first = TerminalPane(sessionId: TerminalSessionID(), title: "first", cwd: "/a")
    var root = PaneNode.leaf(first)

    let closed = PaneTreeReducer.closePane(in: &root, paneId: first.paneId)

    #expect(closed == nil)
    #expect(root == .leaf(first))
  }

  @Test func updateRatioChangesOnlyTargetSplit() {
    let first = TerminalPane(sessionId: TerminalSessionID(), title: "first", cwd: nil)
    let second = TerminalPane(sessionId: TerminalSessionID(), title: "second", cwd: nil)
    let splitId = UUID()
    var root = PaneNode.split(SplitPane(
      id: splitId,
      axis: .vertical,
      ratio: 0.5,
      first: .leaf(first),
      second: .leaf(second)
    ))

    let didUpdate = PaneTreeReducer.updateRatio(in: &root, splitId: splitId, ratio: 0.7)

    #expect(didUpdate)
    guard case .split(let split) = root else {
      Issue.record("expected split")
      return
    }
    #expect(split.ratio == 0.7)
  }

  @Test func findPaneAndListLeavesTraverseNestedTree() {
    let first = TerminalPane(sessionId: TerminalSessionID(), title: "first", cwd: nil)
    let second = TerminalPane(sessionId: TerminalSessionID(), title: "second", cwd: nil)
    let third = TerminalPane(sessionId: TerminalSessionID(), title: "third", cwd: nil)
    let root = PaneNode.split(SplitPane(
      axis: .horizontal,
      ratio: 0.4,
      first: .leaf(first),
      second: .split(SplitPane(axis: .vertical, ratio: 0.5, first: .leaf(second), second: .leaf(third)))
    ))

    #expect(PaneTreeReducer.findPane(in: root, paneId: third.paneId) == third)
    #expect(PaneTreeReducer.listLeaves(in: root) == [first, second, third])
  }

  @Test func cwdForPanePrefersLiveSessionCwdThenPaneSnapshotThenFallback() {
    let firstSession = TerminalSessionID()
    let secondSession = TerminalSessionID()
    let first = TerminalPane(sessionId: firstSession, title: "first", cwd: "/snapshot/a")
    let second = TerminalPane(sessionId: secondSession, title: "second", cwd: "/snapshot/b")
    let root = PaneNode.split(SplitPane(
      axis: .horizontal,
      first: .leaf(first),
      second: .leaf(second)
    ))

    #expect(PaneTreeReducer.cwd(
      forPane: first.paneId,
      in: root,
      cwdBySession: [firstSession: "/live/a", secondSession: "/live/b"],
      fallback: "/fallback"
    ) == "/live/a")
    #expect(PaneTreeReducer.cwd(
      forPane: second.paneId,
      in: root,
      cwdBySession: [:],
      fallback: "/fallback"
    ) == "/snapshot/b")
    #expect(PaneTreeReducer.cwd(
      forPane: UUID(),
      in: root,
      cwdBySession: [:],
      fallback: "/fallback"
    ) == "/fallback")
  }

  @Test func splitCwdResolverPrefersTargetPaneLiveCwd() {
    let session = TerminalSessionID()
    let pane = TerminalPane(sessionId: session, title: "zsh", cwd: "/snapshot")
    let root = PaneNode.leaf(pane)

    let cwd = PaneSplitCwdResolver.cwd(
      forPane: pane.paneId,
      in: root,
      cwdBySession: [session: "/live/project"],
      liveWorkingDirectory: "/live/process",
      workspaceRootPath: "/workspace",
      defaultWorkingDirectory: "/default"
    )

    #expect(cwd == "/live/process")
  }

  @Test func mapLeavesPreservesStructureWhileReplacingLeafPayloads() {
    let first = TerminalPane(sessionId: TerminalSessionID(), title: "first", cwd: "/a")
    let second = TerminalPane(sessionId: TerminalSessionID(), title: "second", cwd: "/b")
    let third = TerminalPane(sessionId: TerminalSessionID(), title: "third", cwd: "/c")
    let root = PaneNode.split(SplitPane(
      axis: .horizontal,
      ratio: 0.6,
      first: .leaf(first),
      second: .split(SplitPane(axis: .vertical, ratio: 0.4, first: .leaf(second), second: .leaf(third)))
    ))

    let remapped = try? PaneTreeReducer.mapLeaves(in: root) { pane in
      TerminalPane(
        paneId: pane.paneId,
        sessionId: TerminalSessionID(),
        title: pane.title.uppercased(),
        cwd: pane.cwd.map { "\($0)/restored" }
      )
    }

    guard let remapped else {
      Issue.record("expected remapped tree")
      return
    }

    #expect(PaneTreeReducer.listLeaves(in: remapped).map(\.title) == ["FIRST", "SECOND", "THIRD"])
    #expect(PaneTreeReducer.listLeaves(in: remapped).map(\.cwd) == ["/a/restored", "/b/restored", "/c/restored"])
    guard case .split(let outer) = remapped, case .split(let inner) = outer.second else {
      Issue.record("expected nested split structure")
      return
    }
    #expect(outer.axis == .horizontal)
    #expect(inner.axis == .vertical)
  }

  @Test func workspaceLayoutOwnsRootPaneNodeAndIsCodable() throws {
    let pane = TerminalPane(sessionId: TerminalSessionID(), title: "zsh", cwd: "/tmp")
    let workspace = WorkspaceLayout(title: "work", root: .leaf(pane), workspaceId: UUID())

    let data = try JSONEncoder().encode(workspace)
    let decoded = try JSONDecoder().decode(WorkspaceLayout.self, from: data)

    #expect(decoded == workspace)
  }

  @MainActor @Test func focusStoreResolvesFocusedSession() {
    let pane = TerminalPane(sessionId: TerminalSessionID(), title: "zsh", cwd: "/tmp")
    let workspace = WorkspaceLayout(title: "work", root: .leaf(pane))
    let store = TerminalFocusStore()

    store.focusPane(pane.paneId, in: workspace.id)

    #expect(store.focusedPaneId(in: workspace.id) == pane.paneId)
    #expect(store.focusedSessionId(in: workspace) == pane.sessionId)
  }

  @MainActor @Test func focusStoreKeepsFocusIndependentPerWorkspace() {
    let firstPane = TerminalPane(sessionId: TerminalSessionID(), title: "first", cwd: "/a")
    let secondPane = TerminalPane(sessionId: TerminalSessionID(), title: "second", cwd: "/b")
    let firstWorkspace = WorkspaceLayout(title: "first", root: .leaf(firstPane))
    let secondWorkspace = WorkspaceLayout(title: "second", root: .leaf(secondPane))
    let store = TerminalFocusStore()

    store.focusPane(firstPane.paneId, in: firstWorkspace.id)
    store.focusPane(secondPane.paneId, in: secondWorkspace.id)

    #expect(store.focusedPaneId(in: firstWorkspace.id) == firstPane.paneId)
    #expect(store.focusedPaneId(in: secondWorkspace.id) == secondPane.paneId)
    #expect(store.focusedSessionId(in: firstWorkspace) == firstPane.sessionId)
    #expect(store.focusedSessionId(in: secondWorkspace) == secondPane.sessionId)
  }
}

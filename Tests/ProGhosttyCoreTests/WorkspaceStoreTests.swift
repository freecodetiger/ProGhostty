import Foundation
import Testing

@testable import ProGhosttyCore

@Suite("Workspace store")
struct WorkspaceStoreTests {
  @Test func createWorkspace() throws {
    let store = try makeStore()
    let workspace = Workspace(name: "Core", rootPath: "/tmp/core")
    try store.save(workspace)

    #expect(try store.all().map(\.id) == [workspace.id])
  }

  @Test func updateWorkspace() throws {
    let store = try makeStore()
    var workspace = Workspace(name: "Core", rootPath: "/tmp/core")
    try store.save(workspace)
    workspace.name = "Renamed"
    workspace.rootPath = "/tmp/renamed"
    try store.save(workspace)

    let saved = try #require(try store.workspace(id: workspace.id))
    #expect(saved.name == "Renamed")
    #expect(saved.rootPath == "/tmp/renamed")
  }

  @Test func workspaceLayoutSnapshotRoundTrips() throws {
    let store = try makeStore()
    let first = TerminalPane(sessionId: TerminalSessionID(), title: "first", cwd: "/a")
    let second = TerminalPane(sessionId: TerminalSessionID(), title: "second", cwd: "/b")
    let layout = WorkspaceLayout(
      title: "Core",
      root: .split(SplitPane(
        axis: .horizontal,
        first: .leaf(first),
        second: .leaf(second)
      ))
    )
    let workspace = Workspace(
      name: "Core",
      rootPath: "/tmp/core",
      layoutSnapshot: layout
    )

    try store.save(workspace)

    let saved = try #require(try store.workspace(id: workspace.id))
    #expect(saved.layoutSnapshot == layout)
    #expect(PaneTreeReducer.listLeaves(in: try #require(saved.layoutSnapshot?.root)).map(\.cwd) == ["/a", "/b"])
  }

  @Test func deleteWorkspace() throws {
    let store = try makeStore()
    let workspace = Workspace(name: "Core", rootPath: "/tmp/core")
    try store.save(workspace)
    try store.delete(id: workspace.id)

    #expect(try store.all().isEmpty)
  }

  @Test func sessionAssociatesWithWorkspace() throws {
    let session = TerminalSessionConfig(
      shellPath: "/bin/zsh",
      workingDirectory: "/tmp/project",
      environment: [:],
      rows: 24,
      cols: 80,
      workspaceId: UUID()
    )

    #expect(session.workspaceId != nil)
  }

  private func makeStore() throws -> WorkspaceStore {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("sqlite")
    return try WorkspaceStore(database: AppDatabase(path: url.path))
  }
}

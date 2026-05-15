import Foundation
import Testing

@testable import ProGhosttyCore

@Suite("History store")
struct HistoryStoreTests {
  @Test func insertAndQueryCommandBlock() throws {
    let store = try makeStore()
    let block = block(command: "swift test", output: "pass")
    try store.upsert(block)

    let results = try store.search(HistoryQuery(text: "swift"))
    #expect(results.map(\.id) == [block.id])
  }

  @Test func queryByFailedStatus() throws {
    let store = try makeStore()
    let failed = block(command: "false", status: .failed, exitCode: 1)
    let success = block(command: "true", status: .success, exitCode: 0)
    try store.upsert(failed)
    try store.upsert(success)

    let results = try store.search(HistoryQuery(status: .failed))
    #expect(results.map(\.id) == [failed.id])
  }

  @Test func queryByWorkspace() throws {
    let store = try makeStore()
    let workspaceID = UUID()
    let inWorkspace = block(command: "pwd", workspaceId: workspaceID)
    let outside = block(command: "pwd")
    try store.upsert(inWorkspace)
    try store.upsert(outside)

    let results = try store.search(HistoryQuery(workspaceId: workspaceID))
    #expect(results.map(\.id) == [inWorkspace.id])
  }

  @Test func deleteAllHistory() throws {
    let store = try makeStore()
    try store.upsert(block(command: "echo secret"))
    try store.deleteAll()

    #expect(try store.search(HistoryQuery()).isEmpty)
  }

  private func makeStore() throws -> HistoryStore {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("sqlite")
    return try HistoryStore(database: HistoryDatabase(path: url.path))
  }

  private func block(
    command: String,
    output: String = "",
    workspaceId: UUID? = nil,
    status: CommandBlockStatus = .success,
    exitCode: Int? = 0
  ) -> CommandBlock {
    CommandBlock(
      id: UUID(),
      workspaceId: workspaceId,
      sessionId: TerminalSessionID(),
      cwd: "/tmp",
      command: command,
      outputPreview: output,
      outputStorageRef: nil,
      startedAt: Date(timeIntervalSince1970: 1),
      endedAt: Date(timeIntervalSince1970: 2),
      durationMs: 1000,
      exitCode: exitCode,
      status: status,
      shellIntegrationReliable: true,
      createdAt: Date(timeIntervalSince1970: 1)
    )
  }
}

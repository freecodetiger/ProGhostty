import Foundation
import SQLite3

public struct HistoryQuery: Sendable {
  public var text: String?
  public var workspaceId: UUID?
  public var cwd: String?
  public var status: CommandBlockStatus?

  public init(
    text: String? = nil,
    workspaceId: UUID? = nil,
    cwd: String? = nil,
    status: CommandBlockStatus? = nil
  ) {
    self.text = text
    self.workspaceId = workspaceId
    self.cwd = cwd
    self.status = status
  }
}

public final class HistoryStore {
  private let database: HistoryDatabase

  public init(database: HistoryDatabase) {
    self.database = database
  }

  public func upsert(_ block: CommandBlock) throws {
    let statement = try database.prepare(
      """
      INSERT INTO command_blocks (
          id, workspace_id, session_id, cwd, command, output_preview, output_storage_ref,
          started_at, ended_at, duration_ms, exit_code, status, shell_integration_reliable, created_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
          workspace_id = excluded.workspace_id,
          session_id = excluded.session_id,
          cwd = excluded.cwd,
          command = excluded.command,
          output_preview = excluded.output_preview,
          output_storage_ref = excluded.output_storage_ref,
          started_at = excluded.started_at,
          ended_at = excluded.ended_at,
          duration_ms = excluded.duration_ms,
          exit_code = excluded.exit_code,
          status = excluded.status,
          shell_integration_reliable = excluded.shell_integration_reliable,
          created_at = excluded.created_at;
      """)
    defer { sqlite3_finalize(statement) }

    try database.bind(block.id.uuidString, to: 1, in: statement)
    try database.bind(block.workspaceId?.uuidString, to: 2, in: statement)
    try database.bind(block.sessionId.rawValue.uuidString, to: 3, in: statement)
    try database.bind(block.cwd, to: 4, in: statement)
    try database.bind(block.command, to: 5, in: statement)
    try database.bind(block.outputPreview, to: 6, in: statement)
    try database.bind(block.outputStorageRef, to: 7, in: statement)
    try database.bind(int64Seconds(block.startedAt), to: 8, in: statement)
    try database.bind(int64Seconds(block.endedAt), to: 9, in: statement)
    try database.bind(block.durationMs, to: 10, in: statement)
    try database.bind(block.exitCode, to: 11, in: statement)
    try database.bind(block.status.rawValue, to: 12, in: statement)
    try database.bind(block.shellIntegrationReliable ? 1 : 0, to: 13, in: statement)
    try database.bind(int64Seconds(block.createdAt), to: 14, in: statement)
    try database.stepDone(statement)

    try syncFTS(block)
  }

  public func search(_ query: HistoryQuery) throws -> [CommandBlock] {
    var clauses: [String] = []
    var values: [String] = []

    if let text = query.text, !text.isEmpty {
      clauses.append(
        """
        id IN (
            SELECT id FROM command_blocks_fts
            WHERE command_blocks_fts MATCH ?
        )
        """)
      values.append(ftsQuery(text))
    }

    if let workspaceId = query.workspaceId {
      clauses.append("workspace_id = ?")
      values.append(workspaceId.uuidString)
    }

    if let cwd = query.cwd, !cwd.isEmpty {
      clauses.append("cwd = ?")
      values.append(cwd)
    }

    if let status = query.status {
      clauses.append("status = ?")
      values.append(status.rawValue)
    }

    let whereSQL = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
    let statement = try database.prepare(
      """
      SELECT id, workspace_id, session_id, cwd, command, output_preview, output_storage_ref,
             started_at, ended_at, duration_ms, exit_code, status, shell_integration_reliable, created_at
      FROM command_blocks
      \(whereSQL)
      ORDER BY created_at ASC, started_at ASC;
      """)
    defer { sqlite3_finalize(statement) }

    for (index, value) in values.enumerated() {
      try database.bind(value, to: Int32(index + 1), in: statement)
    }

    var blocks: [CommandBlock] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      if let block = readBlock(statement) {
        blocks.append(block)
      }
    }
    return blocks
  }

  public func deleteAll() throws {
    try database.execute("DELETE FROM command_blocks; DELETE FROM command_blocks_fts;")
  }

  private func syncFTS(_ block: CommandBlock) throws {
    var statement = try database.prepare("DELETE FROM command_blocks_fts WHERE id = ?;")
    try database.bind(block.id.uuidString, to: 1, in: statement)
    try database.stepDone(statement)
    sqlite3_finalize(statement)

    statement = try database.prepare(
      """
      INSERT INTO command_blocks_fts (id, command, output_preview, cwd)
      VALUES (?, ?, ?, ?);
      """)
    defer { sqlite3_finalize(statement) }
    try database.bind(block.id.uuidString, to: 1, in: statement)
    try database.bind(block.command, to: 2, in: statement)
    try database.bind(block.outputPreview, to: 3, in: statement)
    try database.bind(block.cwd, to: 4, in: statement)
    try database.stepDone(statement)
  }

  private func readBlock(_ statement: OpaquePointer?) -> CommandBlock? {
    guard
      let idText = textColumn(statement, 0),
      let id = UUID(uuidString: idText),
      let sessionText = textColumn(statement, 2),
      let sessionUUID = UUID(uuidString: sessionText),
      let startedAt = dateFromSeconds(int64Column(statement, 7)),
      let statusText = textColumn(statement, 11),
      let status = CommandBlockStatus(rawValue: statusText),
      let createdAt = dateFromSeconds(int64Column(statement, 13))
    else {
      return nil
    }

    let workspaceId = textColumn(statement, 1).flatMap(UUID.init(uuidString:))
    return CommandBlock(
      id: id,
      workspaceId: workspaceId,
      sessionId: TerminalSessionID(sessionUUID),
      cwd: textColumn(statement, 3),
      command: textColumn(statement, 4),
      outputPreview: textColumn(statement, 5) ?? "",
      outputStorageRef: textColumn(statement, 6),
      startedAt: startedAt,
      endedAt: dateFromSeconds(int64Column(statement, 8)),
      durationMs: intColumn(statement, 9),
      exitCode: intColumn(statement, 10),
      status: status,
      shellIntegrationReliable: sqlite3_column_int(statement, 12) == 1,
      createdAt: createdAt
    )
  }

  private func ftsQuery(_ text: String) -> String {
    text
      .split(whereSeparator: { $0.isWhitespace })
      .map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }
      .joined(separator: " ")
  }
}

import Foundation
import SQLite3

public final class WorkspaceStore {
  private let database: HistoryDatabase

  public init(database: HistoryDatabase) {
    self.database = database
  }

  public func save(_ workspace: Workspace) throws {
    let statement = try database.prepare(
      """
      INSERT INTO workspaces (id, name, root_path, default_shell, created_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
          name = excluded.name,
          root_path = excluded.root_path,
          default_shell = excluded.default_shell,
          updated_at = excluded.updated_at;
      """)
    defer { sqlite3_finalize(statement) }

    try database.bind(workspace.id.uuidString, to: 1, in: statement)
    try database.bind(workspace.name, to: 2, in: statement)
    try database.bind(workspace.rootPath, to: 3, in: statement)
    try database.bind(workspace.defaultShell, to: 4, in: statement)
    try database.bind(int64Seconds(workspace.createdAt), to: 5, in: statement)
    try database.bind(int64Seconds(workspace.updatedAt), to: 6, in: statement)
    try database.stepDone(statement)
  }

  public func all() throws -> [Workspace] {
    let statement = try database.prepare(
      """
      SELECT id, name, root_path, default_shell, created_at, updated_at
      FROM workspaces
      ORDER BY created_at ASC;
      """)
    defer { sqlite3_finalize(statement) }

    var workspaces: [Workspace] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      if let workspace = readWorkspace(statement) {
        workspaces.append(workspace)
      }
    }
    return workspaces
  }

  public func workspace(id: UUID) throws -> Workspace? {
    let statement = try database.prepare(
      """
      SELECT id, name, root_path, default_shell, created_at, updated_at
      FROM workspaces
      WHERE id = ?;
      """)
    defer { sqlite3_finalize(statement) }
    try database.bind(id.uuidString, to: 1, in: statement)

    guard sqlite3_step(statement) == SQLITE_ROW else {
      return nil
    }
    return readWorkspace(statement)
  }

  public func delete(id: UUID) throws {
    let statement = try database.prepare("DELETE FROM workspaces WHERE id = ?;")
    defer { sqlite3_finalize(statement) }
    try database.bind(id.uuidString, to: 1, in: statement)
    try database.stepDone(statement)
  }

  private func readWorkspace(_ statement: OpaquePointer?) -> Workspace? {
    guard
      let idText = textColumn(statement, 0),
      let id = UUID(uuidString: idText),
      let name = textColumn(statement, 1),
      let createdAt = dateFromSeconds(int64Column(statement, 4)),
      let updatedAt = dateFromSeconds(int64Column(statement, 5))
    else {
      return nil
    }

    return Workspace(
      id: id,
      name: name,
      rootPath: textColumn(statement, 2),
      defaultShell: textColumn(statement, 3),
      createdAt: createdAt,
      updatedAt: updatedAt
    )
  }
}

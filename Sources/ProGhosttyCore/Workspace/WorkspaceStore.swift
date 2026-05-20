import Foundation
import SQLite3

public final class WorkspaceStore {
  private let database: AppDatabase
  private let decoder = JSONDecoder()
  private let encoder = JSONEncoder()

  public init(database: AppDatabase) {
    self.database = database
  }

  public func save(_ workspace: Workspace) throws {
    let layoutSnapshot = try encodedLayoutSnapshot(workspace.layoutSnapshot)
    let statement = try database.prepare(
      """
      INSERT INTO workspaces (id, name, root_path, default_shell, layout_snapshot, created_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
          name = excluded.name,
          root_path = excluded.root_path,
          default_shell = excluded.default_shell,
          layout_snapshot = excluded.layout_snapshot,
          updated_at = excluded.updated_at;
      """)
    defer { sqlite3_finalize(statement) }

    try database.bind(workspace.id.uuidString, to: 1, in: statement)
    try database.bind(workspace.name, to: 2, in: statement)
    try database.bind(workspace.rootPath, to: 3, in: statement)
    try database.bind(workspace.defaultShell, to: 4, in: statement)
    try database.bind(layoutSnapshot, to: 5, in: statement)
    try database.bind(int64Seconds(workspace.createdAt), to: 6, in: statement)
    try database.bind(int64Seconds(workspace.updatedAt), to: 7, in: statement)
    try database.stepDone(statement)
  }

  public func all() throws -> [Workspace] {
    let statement = try database.prepare(
      """
      SELECT id, name, root_path, default_shell, layout_snapshot, created_at, updated_at
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
      SELECT id, name, root_path, default_shell, layout_snapshot, created_at, updated_at
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
      let createdAt = dateFromSeconds(int64Column(statement, 5)),
      let updatedAt = dateFromSeconds(int64Column(statement, 6))
    else {
      return nil
    }

    return Workspace(
      id: id,
      name: name,
      rootPath: textColumn(statement, 2),
      defaultShell: textColumn(statement, 3),
      layoutSnapshot: decodedLayoutSnapshot(textColumn(statement, 4)),
      createdAt: createdAt,
      updatedAt: updatedAt
    )
  }

  private func encodedLayoutSnapshot(_ snapshot: WorkspaceLayout?) throws -> String? {
    guard let snapshot else { return nil }
    let data = try encoder.encode(snapshot)
    guard let text = String(data: data, encoding: .utf8) else {
      throw DatabaseError.bindFailed("layout snapshot is not valid UTF-8")
    }
    return text
  }

  private func decodedLayoutSnapshot(_ text: String?) -> WorkspaceLayout? {
    guard let text, let data = text.data(using: .utf8) else { return nil }
    return try? decoder.decode(WorkspaceLayout.self, from: data)
  }
}

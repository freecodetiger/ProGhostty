import Foundation
import SQLite3

public enum DatabaseError: Error, CustomStringConvertible {
  case openFailed(String)
  case prepareFailed(String)
  case stepFailed(String)
  case bindFailed(String)

  public var description: String {
    switch self {
    case .openFailed(let message):
      return "open failed: \(message)"
    case .prepareFailed(let message):
      return "prepare failed: \(message)"
    case .stepFailed(let message):
      return "step failed: \(message)"
    case .bindFailed(let message):
      return "bind failed: \(message)"
    }
  }
}

public final class AppDatabase {
  private let db: OpaquePointer?

  public init(path: String) throws {
    var handle: OpaquePointer?
    guard sqlite3_open(path, &handle) == SQLITE_OK else {
      let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
      sqlite3_close(handle)
      throw DatabaseError.openFailed(message)
    }

    db = handle
    try execute("PRAGMA foreign_keys = ON")
    try migrate()
  }

  deinit {
    sqlite3_close(db)
  }

  func execute(_ sql: String) throws {
    var error: UnsafeMutablePointer<CChar>?
    guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
      let message = error.map { String(cString: $0) } ?? lastError
      sqlite3_free(error)
      throw DatabaseError.stepFailed(message)
    }
  }

  func prepare(_ sql: String) throws -> OpaquePointer? {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
      throw DatabaseError.prepareFailed(lastError)
    }
    return statement
  }

  func bind(_ value: String?, to index: Int32, in statement: OpaquePointer?) throws {
    if let value {
      guard sqlite3_bind_text(statement, index, value, -1, sqliteTransient) == SQLITE_OK else {
        throw DatabaseError.bindFailed(lastError)
      }
    } else {
      sqlite3_bind_null(statement, index)
    }
  }

  func bind(_ value: Int64?, to index: Int32, in statement: OpaquePointer?) throws {
    if let value {
      sqlite3_bind_int64(statement, index, sqlite3_int64(value))
    } else {
      sqlite3_bind_null(statement, index)
    }
  }

  func stepDone(_ statement: OpaquePointer?) throws {
    guard sqlite3_step(statement) == SQLITE_DONE else {
      throw DatabaseError.stepFailed(lastError)
    }
  }

  var lastError: String {
    db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
  }

  private func migrate() throws {
    try execute(
      """
      CREATE TABLE IF NOT EXISTS workspaces (
          id TEXT PRIMARY KEY,
          name TEXT NOT NULL,
          root_path TEXT,
          default_shell TEXT,
          layout_snapshot TEXT,
          created_at INTEGER NOT NULL,
          updated_at INTEGER NOT NULL
      );
      """)
    try addColumnIfNeeded(table: "workspaces", column: "layout_snapshot", definition: "TEXT")
  }

  private func addColumnIfNeeded(table tableName: String, column: String, definition: String) throws {
    guard try !tableHasColumn(tableName, column: column) else { return }
    try execute("ALTER TABLE \(tableName) ADD COLUMN \(column) \(definition);")
  }

  private func tableHasColumn(_ tableName: String, column: String) throws -> Bool {
    let statement = try prepare("PRAGMA table_info(\(tableName));")
    defer { sqlite3_finalize(statement) }
    while sqlite3_step(statement) == SQLITE_ROW {
      if textColumn(statement, 1) == column {
        return true
      }
    }
    return false
  }
}

let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

func int64Seconds(_ date: Date?) -> Int64? {
  date.map { Int64($0.timeIntervalSince1970) }
}

func dateFromSeconds(_ value: Int64?) -> Date? {
  value.map { Date(timeIntervalSince1970: TimeInterval($0)) }
}

func textColumn(_ statement: OpaquePointer?, _ column: Int32) -> String? {
  guard let pointer = sqlite3_column_text(statement, column) else {
    return nil
  }
  return String(cString: pointer)
}

func int64Column(_ statement: OpaquePointer?, _ column: Int32) -> Int64? {
  sqlite3_column_type(statement, column) == SQLITE_NULL
    ? nil : sqlite3_column_int64(statement, column)
}

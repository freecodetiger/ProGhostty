import Foundation

public struct BackupManifest: Codable, Equatable, Sendable {
  public var createdAt: String
  public var backupDirectory: String
  public var entries: [BackupManifestEntry]
}

public struct BackupManifestEntry: Codable, Equatable, Sendable {
  public var originalPath: String
  public var backupPath: String?
  public var existed: Bool
}

public struct BackupManager {
  private let fileManager: FileManager

  public init(fileManager: FileManager = .default) {
    self.fileManager = fileManager
  }

  public func backup(files: [String], homeDirectory: String, date: Date = Date()) throws -> BackupManifest {
    let directory = backupDirectory(homeDirectory: homeDirectory, date: date)
    try fileManager.createDirectory(atPath: directory, withIntermediateDirectories: true)

    var entries: [BackupManifestEntry] = []
    for path in Array(Set(files)).sorted() {
      if fileManager.fileExists(atPath: path) {
        let backupPath = "\(directory)/\(backupFileName(for: path))"
        if fileManager.fileExists(atPath: backupPath) {
          try fileManager.removeItem(atPath: backupPath)
        }
        try fileManager.copyItem(atPath: path, toPath: backupPath)
        entries.append(BackupManifestEntry(originalPath: path, backupPath: backupPath, existed: true))
      } else {
        entries.append(BackupManifestEntry(originalPath: path, backupPath: nil, existed: false))
      }
    }

    let manifest = BackupManifest(
      createdAt: timestamp(date),
      backupDirectory: directory,
      entries: entries
    )
    let data = try JSONEncoder.pretty.encode(manifest)
    try data.write(to: URL(fileURLWithPath: "\(directory)/manifest.json"), options: .atomic)
    return manifest
  }

  private func backupDirectory(homeDirectory: String, date: Date) -> String {
    "\(homeDirectory)/.your-terminal/backups/\(timestamp(date))"
  }

  private func timestamp(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .current
    formatter.dateFormat = "yyyy-MM-dd-HH-mm-ss"
    return formatter.string(from: date)
  }

  private func backupFileName(for path: String) -> String {
    path
      .replacingOccurrences(of: "/", with: "_")
      .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
  }
}

public struct RollbackManager {
  private let fileManager: FileManager

  public init(fileManager: FileManager = .default) {
    self.fileManager = fileManager
  }

  public func latestManifest(homeDirectory: String) throws -> BackupManifest? {
    let root = "\(homeDirectory)/.your-terminal/backups"
    guard let names = try? fileManager.contentsOfDirectory(atPath: root) else { return nil }
    for name in names.sorted(by: >) {
      let path = "\(root)/\(name)/manifest.json"
      guard fileManager.fileExists(atPath: path),
        let data = fileManager.contents(atPath: path)
      else {
        continue
      }
      return try JSONDecoder().decode(BackupManifest.self, from: data)
    }
    return nil
  }

  @discardableResult
  public func rollbackLatest(homeDirectory: String) throws -> BackupManifest? {
    guard let manifest = try latestManifest(homeDirectory: homeDirectory) else { return nil }
    for entry in manifest.entries {
      if entry.existed, let backupPath = entry.backupPath {
        let directory = URL(fileURLWithPath: entry.originalPath).deletingLastPathComponent().path
        try fileManager.createDirectory(atPath: directory, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: entry.originalPath) {
          try fileManager.removeItem(atPath: entry.originalPath)
        }
        try fileManager.copyItem(atPath: backupPath, toPath: entry.originalPath)
      } else if fileManager.fileExists(atPath: entry.originalPath) {
        try fileManager.removeItem(atPath: entry.originalPath)
      }
    }
    return manifest
  }
}

private extension JSONEncoder {
  static var pretty: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return encoder
  }
}

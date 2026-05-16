import Foundation

public struct ShellPluginInstallReceipt: Equatable, Sendable {
  public var planId: UUID
  public var backupDirectory: String
  public var manifestPath: String
  public var executedCommands: [String]
  public var patchedFiles: [String]
}

public enum ShellPluginInstallExecutorError: Error, Equatable {
  case commandFailed(String, Int32)
}

public struct ShellPluginInstallExecutor {
  private let fileManager: FileManager
  private let commandRunner: (String) throws -> Void

  public init(
    fileManager: FileManager = .default,
    commandRunner: @escaping (String) throws -> Void = ShellPluginInstallExecutor.runShellCommand(_:)
  ) {
    self.fileManager = fileManager
    self.commandRunner = commandRunner
  }

  public func apply(plan: PluginInstallPlan, backupDirectory: String? = nil) throws -> ShellPluginInstallReceipt {
    let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
    let manifest: BackupManifest
    if let backupDirectory {
      manifest = try backupFiles(for: plan, backupDirectory: backupDirectory)
    } else {
      manifest = try BackupManager(fileManager: fileManager).backup(
        files: plan.filePatches.map(\.filePath),
        homeDirectory: home
      )
    }

    var executed: [String] = []
    for command in plan.commands {
      try commandRunner(command)
      executed.append(command)
    }

    var patched: [String] = []
    for patch in plan.filePatches {
      let directory = URL(fileURLWithPath: patch.filePath).deletingLastPathComponent().path
      try fileManager.createDirectory(atPath: directory, withIntermediateDirectories: true)
      try patch.afterPreview.write(toFile: patch.filePath, atomically: true, encoding: .utf8)
      patched.append(patch.filePath)
    }

    return ShellPluginInstallReceipt(
      planId: plan.id,
      backupDirectory: manifest.backupDirectory,
      manifestPath: "\(manifest.backupDirectory)/manifest.json",
      executedCommands: executed,
      patchedFiles: patched
    )
  }

  private func backupFiles(for plan: PluginInstallPlan, backupDirectory: String) throws -> BackupManifest {
    try fileManager.createDirectory(atPath: backupDirectory, withIntermediateDirectories: true)
    var entries: [BackupManifestEntry] = []
    for path in Array(Set(plan.filePatches.map(\.filePath))).sorted() {
      if fileManager.fileExists(atPath: path) {
        let backupName = path
          .replacingOccurrences(of: "/", with: "_")
          .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        let destination = "\(backupDirectory)/\(backupName)"
        if fileManager.fileExists(atPath: destination) {
          try fileManager.removeItem(atPath: destination)
        }
        try fileManager.copyItem(atPath: path, toPath: destination)
        entries.append(BackupManifestEntry(originalPath: path, backupPath: destination, existed: true))
      } else {
        entries.append(BackupManifestEntry(originalPath: path, backupPath: nil, existed: false))
      }
    }
    let manifest = BackupManifest(
      createdAt: URL(fileURLWithPath: backupDirectory).lastPathComponent,
      backupDirectory: backupDirectory,
      entries: entries
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(manifest).write(to: URL(fileURLWithPath: "\(backupDirectory)/manifest.json"), options: .atomic)
    return manifest
  }

  public static func runShellCommand(_ command: String) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = ["-lc", command]
    try process.run()
    process.waitUntilExit()
    if process.terminationStatus != 0 {
      throw ShellPluginInstallExecutorError.commandFailed(command, process.terminationStatus)
    }
  }
}

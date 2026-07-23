import Foundation

/// Runs read-only `git` commands off the main thread to assemble a `ProjectInfo`
/// for the titlebar panel. Never fetches (no network); every command has a
/// timeout so a wedged git can't stall the panel. See spec §4 + revision record.
enum ProjectInfoService {
  /// How many recent commits to show in the panel.
  static let recentCommitLimit = 2

  /// Assemble project info for `cwd`. Call off the main thread; the closure form
  /// below handles threading + cancellation for callers.
  static func fetch(cwd: String, timeout: TimeInterval = 1.5) -> ProjectInfo {
    let url = URL(fileURLWithPath: cwd)
    var info = ProjectInfo(
      absolutePath: cwd,
      displayName: url.lastPathComponent.isEmpty ? cwd : url.lastPathComponent,
      isGitRepository: false,
      branch: nil,
      modifiedCount: 0,
      addedCount: 0,
      recentCommits: [],
      remoteURL: nil
    )

    func git(_ args: [String]) -> String? {
      runGit(args, cwd: cwd, timeout: timeout)
    }

    guard git(["rev-parse", "--is-inside-work-tree"])?.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    else {
      return info
    }
    info.isGitRepository = true

    if let branch = git(["rev-parse", "--abbrev-ref", "HEAD"])?.trimmingCharacters(in: .whitespacesAndNewlines),
      !branch.isEmpty {
      // Detached HEAD reports "HEAD"; show the short hash instead.
      info.branch = branch == "HEAD"
        ? git(["rev-parse", "--short", "HEAD"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? branch
        : branch
    }
    if let porcelain = git(["status", "--porcelain"]) {
      let counts = GitStatusParser.changeCounts(porcelain: porcelain)
      info.modifiedCount = counts.modified
      info.addedCount = counts.added
    }
    if let log = git(["log", "-\(recentCommitLimit)", "--format=%h%x1f%s%x1f%cI%x1f%an%x1e"]) {
      info.recentCommits = GitStatusParser.commits(log: log)
    }
    if let remote = git(["remote", "get-url", "origin"]) {
      info.remoteURL = GitStatusParser.browsableRemoteURL(remote: remote)
    }
    return info
  }

  /// Spawn `git -C <cwd> <args>`, return stdout (nil on nonzero exit / timeout /
  /// launch failure). Timeout kills the process so a hung git can't block.
  private static func runGit(_ args: [String], cwd: String, timeout: TimeInterval) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", cwd] + args
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    // Keep git from prompting for credentials — this must never touch the network
    // or block on auth (spec §5: no fetch, no prompts).
    var env = ProcessInfo.processInfo.environment
    env["GIT_TERMINAL_PROMPT"] = "0"
    env["GIT_OPTIONAL_LOCKS"] = "0"
    process.environment = env

    do {
      try process.run()
    } catch {
      return nil
    }

    let deadline = DispatchWorkItem { [weak process] in
      if process?.isRunning == true { process?.terminate() }
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    deadline.cancel()

    guard process.terminationStatus == 0 else { return nil }
    return String(data: data, encoding: .utf8)
  }
}

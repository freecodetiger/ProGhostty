import Foundation

/// Owns the titlebar's asynchronous Git lookup without constructing AppModel's
/// terminal sessions or application services.
@MainActor
final class GitBranchTitlebarController {
  private var cwd: String?
  private var cachedBranch: String?
  private var hasLoaded = false
  private var requestID: UUID?
  private var refreshTask: Task<Void, Never>?
  private let refreshInterval: Duration
  private let readBranch: @Sendable (String) -> String?
  private let onChange: () -> Void

  init(
    refreshInterval: Duration = .seconds(2),
    readBranch: @escaping @Sendable (String) -> String? = { GitBranchTitlebarController.runGitBranch(cwd: $0) },
    onChange: @escaping () -> Void
  ) {
    self.refreshInterval = refreshInterval
    self.readBranch = readBranch
    self.onChange = onChange
  }

  func branch(for cwd: String?) -> String? {
    selectDirectory(cwd)
    if !hasLoaded { refresh(cwd: cwd) }
    return cachedBranch
  }

  func invalidate() {
    refreshTask?.cancel()
    refreshTask = nil
    cwd = nil
    cachedBranch = nil
    hasLoaded = false
    requestID = nil
  }

  private func selectDirectory(_ directory: String?) {
    guard cwd != directory else { return }
    invalidate()
    cwd = directory
    guard directory != nil else { return }
    let interval = refreshInterval
    // Branches can change in another process while a TUI owns the foreground
    // and emits no output. Poll only the selected directory, off the UI thread.
    refreshTask = Task { [weak self] in
      while !Task.isCancelled {
        do { try await Task.sleep(for: interval) } catch { return }
        guard let self else { return }
        self.refresh(cwd: self.cwd)
      }
    }
  }

  func refresh(cwd: String?) {
    selectDirectory(cwd)
    guard let cwd, requestID == nil else { return }
    let id = UUID()
    requestID = id
    let readBranch = readBranch
    DispatchQueue.global(qos: .utility).async { [weak self] in
      let branch = readBranch(cwd)
      Task { @MainActor [weak self] in
        // Also reject stale results after switching away and back to the same cwd.
        guard let self, self.requestID == id else { return }
        self.requestID = nil
        self.hasLoaded = true
        guard self.cachedBranch != branch else { return }
        self.cachedBranch = branch
        self.onChange()
      }
    }
  }

  deinit {
    refreshTask?.cancel()
  }

  /// Run `git rev-parse --abbrev-ref HEAD` in `cwd`. Returns the branch name,
  /// or the short hash for detached HEAD, or nil on failure / timeout / non-git.
  /// Mirrors the lightweight subprocess pattern from ProjectInfoService.
  private nonisolated static func runGitBranch(cwd: String) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", cwd, "rev-parse", "--abbrev-ref", "HEAD"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    var env = ProcessInfo.processInfo.environment
    env["GIT_TERMINAL_PROMPT"] = "0"
    process.environment = env
    do {
      try process.run()
    } catch {
      return nil
    }
    let deadline = DispatchWorkItem { process.terminate() }
    DispatchQueue.global().asyncAfter(deadline: .now() + 1.5, execute: deadline)
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    deadline.cancel()
    guard process.terminationStatus == 0 else { return nil }
    let raw = String(data: data, encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !raw.isEmpty else { return nil }
    // Detached HEAD reports "HEAD"; resolve to short hash.
    if raw == "HEAD" {
      return runGitShortHash(cwd: cwd) ?? raw
    }
    return raw
  }

  private nonisolated static func runGitShortHash(cwd: String) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", cwd, "rev-parse", "--short", "HEAD"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    var env = ProcessInfo.processInfo.environment
    env["GIT_TERMINAL_PROMPT"] = "0"
    process.environment = env
    do {
      try process.run()
    } catch {
      return nil
    }
    let deadline = DispatchWorkItem { process.terminate() }
    DispatchQueue.global().asyncAfter(deadline: .now() + 1.5, execute: deadline)
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    deadline.cancel()
    guard process.terminationStatus == 0 else { return nil }
    return String(data: data, encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

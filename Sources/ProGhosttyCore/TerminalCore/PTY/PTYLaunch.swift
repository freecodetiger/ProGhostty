import Foundation
import ProGhosttyPTY

public enum PTYLaunch {
  public struct SpawnResult: Sendable {
    public let pid: pid_t
    public let fileDescriptor: Int32
  }

  public enum LaunchError: Error, CustomStringConvertible {
    case spawnFailed(errno: Int32)

    public var description: String {
      switch self {
      case .spawnFailed(let code):
        return "PTY spawn failed: \(String(cString: strerror(code)))"
      }
    }
  }

  public static func shellArguments(shellPath: String) -> [String] {
    shellArguments(shellPath: shellPath, launchCommand: nil)
  }

  public static func shellArguments(shellPath: String, launchCommand: String?) -> [String] {
    let name = URL(fileURLWithPath: shellPath).lastPathComponent
    let argv0 = name.isEmpty ? shellPath : name
    guard let launchCommand, !launchCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return [argv0]
    }
    return [argv0, "-lc", launchCommand]
  }

  static func spawn(config: TerminalSessionConfig) throws -> SpawnResult {
    var pid = pid_t()
    var fd: Int32 = -1
    let arguments = shellArguments(shellPath: config.shellPath, launchCommand: config.launchCommand)
    let environment = launchEnvironment(config.environment, shellPath: config.shellPath)

    let result = try withCStringArray(arguments) { argv in
      try withCStringArray(environment) { envp in
        config.workingDirectory.withCStringOrNil { cwd in
          proghostty_spawn_pty(
            config.shellPath,
            argv,
            envp,
            cwd,
            Int32(config.rows),
            Int32(config.cols),
            &pid,
            &fd
          )
        }
      }
    }

    guard result == 0 else {
      throw LaunchError.spawnFailed(errno: result)
    }
    return SpawnResult(pid: pid, fileDescriptor: fd)
  }

  static func resize(fileDescriptor: Int32, rows: Int, cols: Int) {
    _ = proghostty_resize_pty(fileDescriptor, Int32(rows), Int32(cols))
  }

  static func wait(pid: pid_t) -> Int? {
    var exitCode: Int32 = -1
    var signalCode: Int32 = 0
    let result = proghostty_wait_pid(pid, &exitCode, &signalCode)
    guard result == 1 else { return nil }
    if exitCode >= 0 { return Int(exitCode) }
    if signalCode > 0 { return 128 + Int(signalCode) }
    return nil
  }

  static func launchEnvironment(
    _ overrides: [String: String],
    baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
    shellPath: String? = nil,
    ghosttyResourcesDirectory: String? = ghosttyResourcesDirectory()
  ) -> [String] {
    var environment = baseEnvironment
    environment["TERM"] = environment["TERM"] ?? "xterm-256color"
    environment["COLORTERM"] = environment["COLORTERM"] ?? "truecolor"
    environment["CLICOLOR"] = environment["CLICOLOR"] ?? "1"
    environment["PROGHOSTTY"] = "1"
    environment["PROMPT_EOL_MARK"] = environment["PROMPT_EOL_MARK"] ?? ""
    normalizeLocale(&environment, explicitKeys: Set(overrides.keys))
    if let ghosttyResourcesDirectory {
      environment["GHOSTTY_RESOURCES_DIR"] = environment["GHOSTTY_RESOURCES_DIR"] ?? ghosttyResourcesDirectory
      environment["GHOSTTY_SHELL_FEATURES"] = environment["GHOSTTY_SHELL_FEATURES"] ?? "cursor:blink,path,title"
      if isZsh(shellPath) {
        if let existingZdotdir = environment["ZDOTDIR"] {
          environment["GHOSTTY_ZSH_ZDOTDIR"] = environment["GHOSTTY_ZSH_ZDOTDIR"] ?? existingZdotdir
        }
        environment["ZDOTDIR"] = "\(ghosttyResourcesDirectory)/shell-integration/zsh"
      }
    }
    if overrides["NO_COLOR"] == nil {
      environment.removeValue(forKey: "NO_COLOR")
    }
    for (key, value) in overrides {
      environment[key] = value
    }
    return environment.map { "\($0.key)=\($0.value)" }.sorted()
  }

  private static func normalizeLocale(_ environment: inout [String: String], explicitKeys: Set<String>) {
    if let lcAll = environment["LC_ALL"], isUTF8Locale(lcAll) {
      return
    }
    if explicitKeys.contains("LC_ALL") {
      return
    }
    if !explicitKeys.contains("LC_CTYPE"),
      !isUTF8Locale(environment["LC_CTYPE"])
    {
      environment["LC_CTYPE"] = "en_US.UTF-8"
    }
    if !explicitKeys.contains("LANG"),
      !isUTF8Locale(environment["LANG"])
    {
      environment["LANG"] = "en_US.UTF-8"
    }
  }

  private static func isUTF8Locale(_ value: String?) -> Bool {
    guard let value else { return false }
    return value.range(of: "UTF-8", options: .caseInsensitive) != nil
      || value.range(of: "UTF8", options: .caseInsensitive) != nil
  }

  private static func isZsh(_ shellPath: String?) -> Bool {
    guard let shellPath else { return false }
    return URL(fileURLWithPath: shellPath).lastPathComponent == "zsh"
  }

  private static func ghosttyResourcesDirectory() -> String? {
    guard let resourcesURL = Bundle.main.resourceURL else { return nil }
    let ghosttyURL = resourcesURL.appendingPathComponent("ghostty", isDirectory: true)
    let zshIntegrationURL = ghosttyURL
      .appendingPathComponent("shell-integration", isDirectory: true)
      .appendingPathComponent("zsh", isDirectory: true)
      .appendingPathComponent(".zshenv", isDirectory: false)
    guard FileManager.default.isReadableFile(atPath: zshIntegrationURL.path) else {
      return nil
    }
    return ghosttyURL.path
  }
}

private func withCStringArray<R>(_ strings: [String], _ body: ([UnsafeMutablePointer<CChar>?]) throws -> R)
  throws -> R
{
  let cStrings = strings.map { strdup($0) }
  defer { cStrings.forEach { free($0) } }
  return try body(cStrings + [nil])
}

extension Optional where Wrapped == String {
  fileprivate func withCStringOrNil<R>(_ body: (UnsafePointer<CChar>?) throws -> R) rethrows -> R {
    switch self {
    case .some(let value):
      return try value.withCString { try body($0) }
    case .none:
      return try body(nil)
    }
  }
}

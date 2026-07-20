import Foundation

/// User-level Codex / Claude Code Stop-hook install + status for agent task-completion
/// notifications. App-layer only (writes home config); never silent — Settings gates install.
struct AgentNotifyHookStatus: Equatable, Sendable {
  var scriptsReady: Bool
  var codexConfigured: Bool
  var claudeConfigured: Bool
  var detail: String?

  var isReady: Bool { scriptsReady && (codexConfigured || claudeConfigured) }
  var isMissing: Bool { !scriptsReady && !codexConfigured && !claudeConfigured }
  var isPartial: Bool { !isReady && !isMissing }
}

enum AgentNotificationHookError: Error, Equatable, LocalizedError {
  case cannotCreateDirectory(String)
  case cannotWriteScript(String)
  case invalidJSON(String)
  case writeFailed(String)

  var errorDescription: String? {
    switch self {
    case .cannotCreateDirectory(let path): return "Could not create \(path)"
    case .cannotWriteScript(let path): return "Could not write \(path)"
    case .invalidJSON(let path): return "Invalid JSON in \(path)"
    case .writeFailed(let path): return "Could not update \(path)"
    }
  }
}

/// Installs / detects / removes ProGhostty agent notify hooks under a configurable home root
/// (default: real user home). Injectable paths for tests.
struct AgentNotificationHookManager {
  var homeDirectory: URL
  var codexHome: URL
  var claudeHome: URL
  var hooksDirectory: URL
  var fileManager: FileManager
  var pgHelperPath: String?

  static let notifyScriptName = "notify_agent.sh"
  static let codexScriptName = "codex_stop_notify.sh"
  static let claudeScriptName = "claude_stop_notify.sh"
  static let pgHelperPathFileName = "pg-helper-path"

  init(
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
    codexHome: URL? = nil,
    claudeHome: URL? = nil,
    hooksDirectory: URL? = nil,
    fileManager: FileManager = .default,
    pgHelperPath: String? = nil
  ) {
    self.homeDirectory = homeDirectory
    self.fileManager = fileManager
    if let codexHome {
      self.codexHome = codexHome
    } else if let env = ProcessInfo.processInfo.environment["CODEX_HOME"], !env.isEmpty {
      self.codexHome = URL(fileURLWithPath: env, isDirectory: true)
    } else {
      self.codexHome = homeDirectory.appendingPathComponent(".codex", isDirectory: true)
    }
    if let claudeHome {
      self.claudeHome = claudeHome
    } else if let env = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !env.isEmpty {
      self.claudeHome = URL(fileURLWithPath: env, isDirectory: true)
    } else {
      self.claudeHome = homeDirectory.appendingPathComponent(".claude", isDirectory: true)
    }
    self.hooksDirectory = hooksDirectory
      ?? homeDirectory.appendingPathComponent(".proghostty/hooks", isDirectory: true)
    self.pgHelperPath = pgHelperPath ?? Self.resolveBundledPGHelperPath()
  }

  var codexHooksJSON: URL { codexHome.appendingPathComponent("hooks.json") }
  var claudeSettingsJSON: URL { claudeHome.appendingPathComponent("settings.json") }
  var notifyScriptURL: URL { hooksDirectory.appendingPathComponent(Self.notifyScriptName) }
  var codexScriptURL: URL { hooksDirectory.appendingPathComponent(Self.codexScriptName) }
  var claudeScriptURL: URL { hooksDirectory.appendingPathComponent(Self.claudeScriptName) }
  var pgHelperPathURL: URL { hooksDirectory.appendingPathComponent(Self.pgHelperPathFileName) }

  var codexHookCommand: String {
    "/bin/sh \(shellQuote(codexScriptURL.path))"
  }

  var claudeHookCommand: String {
    "/bin/sh \(shellQuote(claudeScriptURL.path))"
  }

  func status() -> AgentNotifyHookStatus {
    let scriptsReady =
      fileManager.isExecutableFile(atPath: notifyScriptURL.path)
      && fileManager.isExecutableFile(atPath: codexScriptURL.path)
      && fileManager.isExecutableFile(atPath: claudeScriptURL.path)
    let codexConfigured = configurationContainsScript(
      at: codexHooksJSON,
      scriptName: Self.codexScriptName
    )
    let claudeConfigured = configurationContainsScript(
      at: claudeSettingsJSON,
      scriptName: Self.claudeScriptName
    )
    var detail: String?
    if scriptsReady, !codexConfigured, !claudeConfigured {
      detail = "Scripts installed but agent configs are missing Stop hooks"
    } else if !scriptsReady, codexConfigured || claudeConfigured {
      detail = "Agent configs reference hooks but scripts are missing"
    } else if scriptsReady, codexConfigured != claudeConfigured {
      detail = codexConfigured ? "Only Codex is configured" : "Only Claude Code is configured"
    }
    return AgentNotifyHookStatus(
      scriptsReady: scriptsReady,
      codexConfigured: codexConfigured,
      claudeConfigured: claudeConfigured,
      detail: detail
    )
  }

  func install() throws {
    try createDirectory(hooksDirectory)
    try createDirectory(codexHome)
    try createDirectory(claudeHome)

    try writeExecutable(notifyScriptURL, contents: Self.notifyAgentScript)
    try writeExecutable(codexScriptURL, contents: Self.codexStopScript)
    try writeExecutable(claudeScriptURL, contents: Self.claudeStopScript)

    let helper = pgHelperPath ?? ""
    try helper.write(to: pgHelperPathURL, atomically: true, encoding: .utf8)

    try ensureStopHook(
      at: codexHooksJSON,
      command: codexHookCommand,
      scriptName: Self.codexScriptName,
      matcher: nil
    )
    try ensureStopHook(
      at: claudeSettingsJSON,
      command: claudeHookCommand,
      scriptName: Self.claudeScriptName,
      matcher: ""
    )
  }

  /// Removes only ProGhostty notify Stop handlers; leaves other hooks intact.
  func uninstall(removeScripts: Bool = true) throws {
    try removeStopHook(at: codexHooksJSON, scriptName: Self.codexScriptName)
    try removeStopHook(at: claudeSettingsJSON, scriptName: Self.claudeScriptName)
    if removeScripts {
      for url in [notifyScriptURL, codexScriptURL, claudeScriptURL, pgHelperPathURL] {
        try? fileManager.removeItem(at: url)
      }
    }
  }

  // MARK: - Paths

  static func resolveBundledPGHelperPath() -> String? {
    let bundlePG = Bundle.main.bundleURL
      .appendingPathComponent("Contents/MacOS/pg")
    if FileManager.default.isExecutableFile(atPath: bundlePG.path) {
      return bundlePG.path
    }
    if let path = ProcessInfo.processInfo.environment["PATH"] {
      for dir in path.split(separator: ":") {
        let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent("pg")
        if FileManager.default.isExecutableFile(atPath: candidate.path) {
          return candidate.path
        }
      }
    }
    return nil
  }

  // MARK: - Scripts

  private static let notifyAgentScript = """
  #!/bin/sh

  title="${1:-ProGhostty}"
  body="${2:-Waiting for input}"
  hook_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

  dedupe_root="${TMPDIR:-/tmp}/proghostty-agent-notify-${USER:-user}"
  mkdir -p "$dedupe_root" 2>/dev/null || true

  dedupe_key=$(printf '%s:%s:%s' "${PWD:-}" "$title" "$body" | cksum | awk '{print $1}')
  dedupe_file="$dedupe_root/$dedupe_key"
  now=$(date +%s)
  last=
  if [ -r "$dedupe_file" ]; then
    last=$(cat "$dedupe_file" 2>/dev/null || true)
  fi

  if [ "$last" = "$now" ]; then
    exit 0
  fi

  printf '%s\\n' "$now" >"$dedupe_file" 2>/dev/null || true

  # Prefer concrete slave path. /dev/tty often fails inside agent Stop hooks.
  tty_path="${PROGHOSTTY_NOTIFY_TTY:-}"
  if [ -z "$tty_path" ] || [ "$tty_path" = "/dev/tty" ] || [ ! -w "$tty_path" ]; then
    tty_path=$(tty 2>/dev/null || true)
  fi
  if [ -z "$tty_path" ] || [ ! -w "$tty_path" ]; then
    tty_path=
  fi

  pg_helper=$(cat "$hook_dir/pg-helper-path" 2>/dev/null || true)
  run_pg() {
    if [ -n "$tty_path" ]; then
      "$@" notify --title "$title" --body "$body" --tty "$tty_path"
    else
      "$@" notify --title "$title" --body "$body"
    fi
  }
  if command -v pg >/dev/null 2>&1; then
    run_pg pg >/dev/null 2>&1 || true
  elif [ -n "$pg_helper" ] && [ -x "$pg_helper" ]; then
    run_pg "$pg_helper" >/dev/null 2>&1 || true
  fi
  """

  private static let codexStopScript = """
  #!/bin/sh

  hook_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
  /bin/sh "$hook_dir/notify_agent.sh" "Codex" "Waiting for input"

  printf '{"continue":true}\\n'
  """

  private static let claudeStopScript = """
  #!/bin/sh

  hook_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
  /bin/sh "$hook_dir/notify_agent.sh" "Claude Code" "Waiting for input"
  """

  // MARK: - JSON merge

  private func configurationContainsScript(at url: URL, scriptName: String) -> Bool {
    guard let root = loadJSONObject(at: url) else { return false }
    return stopCommands(in: root).contains { $0.contains(scriptName) }
  }

  private func ensureStopHook(
    at url: URL,
    command: String,
    scriptName: String,
    matcher: String?
  ) throws {
    var root = loadJSONObject(at: url) ?? [:]
    var hooks = root["hooks"] as? [String: Any] ?? [:]
    var groups = hooks["Stop"] as? [[String: Any]] ?? []

    var exactPresent = false
    var nextGroups: [[String: Any]] = []
    for group in groups {
      var handlers = group["hooks"] as? [[String: Any]] ?? []
      var nextHandlers: [[String: Any]] = []
      for handler in handlers {
        let handlerCommand = handler["command"] as? String ?? ""
        if handlerCommand == command {
          exactPresent = true
          nextHandlers.append(handler)
        } else if handlerCommand.contains(scriptName) {
          // Drop stale ProGhostty commands; re-add exact below.
          continue
        } else {
          nextHandlers.append(handler)
        }
      }
      var nextGroup = group
      nextGroup["hooks"] = nextHandlers
      if !nextHandlers.isEmpty || group["hooks"] == nil {
        nextGroups.append(nextGroup)
      }
    }

    if !exactPresent {
      var handler: [String: Any] = [
        "type": "command",
        "command": command,
      ]
      var group: [String: Any] = [
        "hooks": [handler],
      ]
      if let matcher {
        group["matcher"] = matcher
      }
      nextGroups.append(group)
    }

    hooks["Stop"] = nextGroups
    root["hooks"] = hooks
    try writeJSONObject(root, to: url, backup: fileManager.fileExists(atPath: url.path))
  }

  private func removeStopHook(at url: URL, scriptName: String) throws {
    guard var root = loadJSONObject(at: url) else { return }
    guard var hooks = root["hooks"] as? [String: Any] else { return }
    guard let groups = hooks["Stop"] as? [[String: Any]] else { return }

    var nextGroups: [[String: Any]] = []
    var changed = false
    for group in groups {
      let handlers = group["hooks"] as? [[String: Any]] ?? []
      let nextHandlers = handlers.filter { handler in
        let command = handler["command"] as? String ?? ""
        if command.contains(scriptName) {
          changed = true
          return false
        }
        return true
      }
      if nextHandlers.isEmpty, changed {
        continue
      }
      var nextGroup = group
      nextGroup["hooks"] = nextHandlers
      nextGroups.append(nextGroup)
    }
    guard changed else { return }
    hooks["Stop"] = nextGroups
    root["hooks"] = hooks
    try writeJSONObject(root, to: url, backup: true)
  }

  private func stopCommands(in root: [String: Any]) -> [String] {
    guard let hooks = root["hooks"] as? [String: Any],
      let groups = hooks["Stop"] as? [[String: Any]]
    else { return [] }
    var commands: [String] = []
    for group in groups {
      guard let handlers = group["hooks"] as? [[String: Any]] else { continue }
      for handler in handlers {
        if let command = handler["command"] as? String {
          commands.append(command)
        }
      }
    }
    return commands
  }

  private func loadJSONObject(at url: URL) -> [String: Any]? {
    guard fileManager.fileExists(atPath: url.path) else { return nil }
    guard let data = try? Data(contentsOf: url) else { return nil }
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return nil
    }
    return object
  }

  private func writeJSONObject(_ object: [String: Any], to url: URL, backup: Bool) throws {
    try createDirectory(url.deletingLastPathComponent())
    if backup, fileManager.fileExists(atPath: url.path) {
      let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
      let backupURL = url.deletingLastPathComponent()
        .appendingPathComponent("\(url.lastPathComponent).proghostty.bak.\(stamp)")
      try? fileManager.copyItem(at: url, to: backupURL)
    }
    let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    var payload = data
    payload.append(contentsOf: "\n".utf8)
    let tmp = url.appendingPathExtension("tmp")
    do {
      try payload.write(to: tmp, options: .atomic)
      if fileManager.fileExists(atPath: url.path) {
        try fileManager.removeItem(at: url)
      }
      try fileManager.moveItem(at: tmp, to: url)
    } catch {
      throw AgentNotificationHookError.writeFailed(url.path)
    }
  }

  private func createDirectory(_ url: URL) throws {
    do {
      try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    } catch {
      throw AgentNotificationHookError.cannotCreateDirectory(url.path)
    }
  }

  private func writeExecutable(_ url: URL, contents: String) throws {
    do {
      try contents.write(to: url, atomically: true, encoding: .utf8)
      try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    } catch {
      throw AgentNotificationHookError.cannotWriteScript(url.path)
    }
  }

  private func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }
}

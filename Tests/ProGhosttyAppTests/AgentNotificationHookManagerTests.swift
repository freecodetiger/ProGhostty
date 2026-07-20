import Foundation
import Testing

@testable import ProGhosttyApp

@Suite("Agent notification hook manager")
struct AgentNotificationHookManagerTests {
  @Test func installMakesReadyAndIsIdempotent() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("proghostty-hook-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let manager = AgentNotificationHookManager(
      homeDirectory: root,
      codexHome: root.appendingPathComponent(".codex", isDirectory: true),
      claudeHome: root.appendingPathComponent(".claude", isDirectory: true),
      hooksDirectory: root.appendingPathComponent(".proghostty/hooks", isDirectory: true),
      pgHelperPath: "/usr/bin/true"
    )

    #expect(manager.status().isMissing)

    try manager.install()
    let first = manager.status()
    #expect(first.isReady)
    #expect(first.scriptsReady)
    #expect(first.codexConfigured)
    #expect(first.claudeConfigured)

    try manager.install()
    let second = manager.status()
    #expect(second.isReady)
    #expect(second.codexConfigured)
    #expect(second.claudeConfigured)
  }

  @Test func uninstallRemovesOnlyOurHandlers() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("proghostty-hook-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let codexHome = root.appendingPathComponent(".codex", isDirectory: true)
    try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
    let foreign = """
    {
      "hooks": {
        "Stop": [
          {
            "hooks": [
              { "type": "command", "command": "/bin/echo foreign" }
            ]
          }
        ]
      }
    }
    """
    try foreign.write(
      to: codexHome.appendingPathComponent("hooks.json"),
      atomically: true,
      encoding: .utf8
    )

    let manager = AgentNotificationHookManager(
      homeDirectory: root,
      codexHome: codexHome,
      claudeHome: root.appendingPathComponent(".claude", isDirectory: true),
      hooksDirectory: root.appendingPathComponent(".proghostty/hooks", isDirectory: true),
      pgHelperPath: "/usr/bin/true"
    )
    try manager.install()
    #expect(manager.status().isReady)

    try manager.uninstall(removeScripts: true)
    let after = manager.status()
    #expect(!after.scriptsReady)
    #expect(!after.codexConfigured)
    #expect(!after.claudeConfigured)

    let data = try Data(contentsOf: codexHome.appendingPathComponent("hooks.json"))
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    let hooks = json?["hooks"] as? [String: Any]
    let stop = hooks?["Stop"] as? [[String: Any]] ?? []
    let commands = stop.flatMap { group -> [String] in
      let handlers = group["hooks"] as? [[String: Any]] ?? []
      return handlers.compactMap { $0["command"] as? String }
    }
    #expect(commands.contains("/bin/echo foreign"))
    #expect(!commands.contains(where: { $0.contains("codex_stop_notify") }))
  }

  @Test func statusPartialWhenOnlyScriptsPresent() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("proghostty-hook-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let hooks = root.appendingPathComponent(".proghostty/hooks", isDirectory: true)
    try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
    for name in [
      AgentNotificationHookManager.notifyScriptName,
      AgentNotificationHookManager.codexScriptName,
      AgentNotificationHookManager.claudeScriptName,
    ] {
      let url = hooks.appendingPathComponent(name)
      try "#!/bin/sh\n".write(to: url, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    let manager = AgentNotificationHookManager(
      homeDirectory: root,
      codexHome: root.appendingPathComponent(".codex", isDirectory: true),
      claudeHome: root.appendingPathComponent(".claude", isDirectory: true),
      hooksDirectory: hooks
    )
    let status = manager.status()
    #expect(status.scriptsReady)
    #expect(!status.codexConfigured)
    #expect(status.isPartial)
  }
}

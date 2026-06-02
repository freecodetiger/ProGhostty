import Foundation
import Testing
import Darwin
import AppKit

@testable import ProGhosttyCore

@Suite("PTY launch")
struct PTYLaunchTests {
  @Test func shiftEnterProducesLineFeed() throws {
    let event = try #require(makeKeyEvent(
      keyCode: 36,
      characters: "\r",
      charactersIgnoringModifiers: "\r",
      modifierFlags: [.shift]
    ))

    #expect(terminalControlInputData(for: event) == Data([0x0A]))
  }

  @Test func plainEnterProducesCarriageReturn() throws {
    let event = try #require(makeKeyEvent(
      keyCode: 36,
      characters: "\r",
      charactersIgnoringModifiers: "\r",
      modifierFlags: []
    ))

    #expect(terminalControlInputData(for: event) == Data([0x0D]))
  }

  @Test func shellArgumentsUseShellBasename() {
    #expect(PTYLaunch.shellArguments(shellPath: "/bin/zsh") == ["zsh"])
  }

  @Test func shellArgumentsFallbackToPathWhenBasenameMissing() {
    #expect(PTYLaunch.shellArguments(shellPath: "zsh") == ["zsh"])
  }

  @Test func shellArgumentsRunLaunchCommandThroughLoginShell() {
    #expect(PTYLaunch.shellArguments(shellPath: "/bin/zsh", launchCommand: "codex") == ["zsh", "-lc", "codex"])
  }

  @Test func launchEnvironmentSuppressesZshEndOfLineMarkerByDefault() {
    let environment = PTYLaunch.launchEnvironment([:], baseEnvironment: [:])

    #expect(environment.contains("PROMPT_EOL_MARK="))
  }

  @Test func launchEnvironmentInjectsUtf8LocaleWhenMissing() {
    let environment = PTYLaunch.launchEnvironment([:], baseEnvironment: [:])

    #expect(environment.contains("LANG=en_US.UTF-8"))
    #expect(environment.contains("LC_CTYPE=en_US.UTF-8"))
  }

  @Test func launchEnvironmentPreservesExistingUtf8Locale() {
    let environment = PTYLaunch.launchEnvironment(
      [:],
      baseEnvironment: [
        "LANG": "zh_CN.UTF-8",
        "LC_CTYPE": "UTF-8",
      ]
    )

    #expect(environment.contains("LANG=zh_CN.UTF-8"))
    #expect(environment.contains("LC_CTYPE=UTF-8"))
  }

  @Test func launchEnvironmentDoesNotForceLocaleWhenLcAllIsUtf8() {
    let environment = PTYLaunch.launchEnvironment(
      [:],
      baseEnvironment: ["LC_ALL": "en_US.UTF-8"]
    )

    #expect(environment.contains("LC_ALL=en_US.UTF-8"))
    #expect(!environment.contains("LANG=en_US.UTF-8"))
    #expect(!environment.contains("LC_CTYPE=en_US.UTF-8"))
  }

  @Test func launchEnvironmentAllowsExplicitLocaleOverrides() {
    let environment = PTYLaunch.launchEnvironment(
      [
        "LANG": "ja_JP.UTF-8",
        "LC_CTYPE": "zh_CN.UTF-8",
      ],
      baseEnvironment: [
        "LANG": "C",
        "LC_CTYPE": "C",
      ]
    )

    #expect(environment.contains("LANG=ja_JP.UTF-8"))
    #expect(environment.contains("LC_CTYPE=zh_CN.UTF-8"))
  }

  @Test func launchEnvironmentDoesNotLeakHostNoColorIntoTerminalSessions() {
    let environment = PTYLaunch.launchEnvironment(
      [:],
      baseEnvironment: ["NO_COLOR": "1", "TERM": "xterm-ghostty"]
    )

    #expect(!environment.contains("NO_COLOR=1"))
    #expect(environment.contains("COLORTERM=truecolor"))
    #expect(environment.contains("CLICOLOR=1"))
  }

  @Test func launchEnvironmentAllowsExplicitNoColorOverride() {
    let environment = PTYLaunch.launchEnvironment(
      ["NO_COLOR": "1"],
      baseEnvironment: ["TERM": "xterm-ghostty"]
    )

    #expect(environment.contains("NO_COLOR=1"))
  }

  @Test func launchEnvironmentInjectsGhosttyZshIntegrationWhenResourcesExist() {
    let environment = PTYLaunch.launchEnvironment(
      [:],
      baseEnvironment: ["ZDOTDIR": "/Users/zpc/.config/zsh"],
      shellPath: "/bin/zsh",
      ghosttyResourcesDirectory: "/Applications/ProGhostty.app/Contents/Resources/ghostty"
    )

    #expect(environment.contains("GHOSTTY_RESOURCES_DIR=/Applications/ProGhostty.app/Contents/Resources/ghostty"))
    #expect(environment.contains("GHOSTTY_ZSH_ZDOTDIR=/Users/zpc/.config/zsh"))
    #expect(environment.contains("ZDOTDIR=/Applications/ProGhostty.app/Contents/Resources/ghostty/shell-integration/zsh"))
  }

  @Test func launchEnvironmentDoesNotInjectZdotdirForNonZshShells() {
    let environment = PTYLaunch.launchEnvironment(
      [:],
      baseEnvironment: [:],
      shellPath: "/bin/bash",
      ghosttyResourcesDirectory: "/Applications/ProGhostty.app/Contents/Resources/ghostty"
    )

    #expect(!environment.contains("ZDOTDIR=/Applications/ProGhostty.app/Contents/Resources/ghostty/shell-integration/zsh"))
  }

  @Test func controlEnvironmentInjectsSessionIdentityAndHelperPath() {
    let session = TerminalSessionID(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!)
    let environment = PTYTerminalSessionManager.controlEnvironment(
      base: ["PATH": "/usr/bin"],
      session: session,
      token: "secret-token",
      helperSearchPath: "/Applications/ProGhostty.app/Contents/MacOS"
    )

    #expect(environment["TERM_PROGRAM"] == "ProGhostty")
    #expect(environment["PROGHOSTTY_SESSION_ID"] == "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
    #expect(environment["PROGHOSTTY_SESSION_TOKEN"] == "secret-token")
    #expect(environment["PATH"] == "/Applications/ProGhostty.app/Contents/MacOS:/usr/bin")
  }

  @MainActor @Test func processWorkingDirectoryTracksCurrentShellDirectory() {
    #expect(PTYTerminalSessionManager.processWorkingDirectory(pid: getpid()) == FileManager.default.currentDirectoryPath)
  }

  @Test func ptyCanRunShellCommand() throws {
    let config = TerminalSessionConfig(
      shellPath: "/bin/sh",
      workingDirectory: FileManager.default.currentDirectoryPath,
      environment: [:],
      rows: 24,
      cols: 80
    )
    let result = try PTYLaunch.spawn(config: config)
    defer {
      _ = Darwin.kill(result.pid, SIGHUP)
      Darwin.close(result.fileDescriptor)
    }

    "printf PROGHOSTTY_PTY_OK\\n; exit 0\n".withCString { pointer in
      #expect(Darwin.write(result.fileDescriptor, pointer, strlen(pointer)) > 0)
    }

    var output = ""
    let deadline = Date().addingTimeInterval(3)
    var buffer = [UInt8](repeating: 0, count: 4096)
    while Date() < deadline, !output.contains("PROGHOSTTY_PTY_OK") {
      let count = Darwin.read(result.fileDescriptor, &buffer, buffer.count)
      if count > 0 {
        output += String(decoding: buffer.prefix(count), as: UTF8.self)
      }
    }

    #expect(output.contains("PROGHOSTTY_PTY_OK"))
  }

  @MainActor @Test func resizeSessionReturnsBeforeDeferredRenderCompletes() throws {
    let registry = PTYTerminalSurfaceRegistry()
    let manager = PTYTerminalSessionManager(surfaceRegistry: registry)
    let session = try manager.createSession(config: TerminalSessionConfig(
      shellPath: "/bin/sh",
      workingDirectory: FileManager.default.currentDirectoryPath,
      environment: [:],
      rows: 6,
      cols: 20
    ))
    defer { manager.closeSession(session) }

    manager.resizeSession(session, rows: 8, cols: 24)

    #expect(registry.rendererDiagnostics(for: session)?.pendingResize == true)
    #expect(registry.rendererDiagnostics(for: session)?.lastResizeTotalDuration == 0)
  }

  @MainActor @Test func deferredResizeRecordsDiagnosticsAfterRenderCompletes() async throws {
    let registry = PTYTerminalSurfaceRegistry()
    let manager = PTYTerminalSessionManager(surfaceRegistry: registry)
    let session = try manager.createSession(config: TerminalSessionConfig(
      shellPath: "/bin/sh",
      workingDirectory: FileManager.default.currentDirectoryPath,
      environment: [:],
      rows: 6,
      cols: 20
    ))
    defer { manager.closeSession(session) }

    manager.resizeSession(session, rows: 8, cols: 24)

    let deadline = Date().addingTimeInterval(2)
    while Date() < deadline {
      if let diagnostics = registry.rendererDiagnostics(for: session),
        !diagnostics.pendingResize,
        diagnostics.lastResizeTotalDuration > 0
      {
        #expect(diagnostics.lastResizeVTDuration >= 0)
        #expect(diagnostics.lastResizeSnapshotDuration >= 0)
        return
      }
      try await Task.sleep(for: .milliseconds(20))
    }

    Issue.record("Deferred resize did not finish within deadline")
  }
}

private func makeKeyEvent(
  keyCode: UInt16,
  characters: String,
  charactersIgnoringModifiers: String,
  modifierFlags: NSEvent.ModifierFlags
) -> NSEvent? {
  NSEvent.keyEvent(
    with: .keyDown,
    location: .zero,
    modifierFlags: modifierFlags,
    timestamp: 0,
    windowNumber: 0,
    context: nil,
    characters: characters,
    charactersIgnoringModifiers: charactersIgnoringModifiers,
    isARepeat: false,
    keyCode: keyCode
  )
}

import Foundation
import Testing
import Darwin

@testable import ProGhosttyCore

@Suite("PTY launch")
struct PTYLaunchTests {
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

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
    let environment = PTYLaunch.launchEnvironment([:])

    #expect(environment.contains("PROMPT_EOL_MARK="))
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
}

import Testing

@testable import ProGhosttyApp

@Suite("ProGhostty window policy")
struct ProGhosttyWindowPolicyTests {
  @Test func terminalWindowsAreSingleInstanceWhileSessionsShareSurfaceRegistry() {
    #expect(ProGhosttyWindowPolicy.supportsMultipleTerminalWindows == false)
  }
}

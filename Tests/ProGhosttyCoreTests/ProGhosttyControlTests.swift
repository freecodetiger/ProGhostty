import Foundation
import Testing

@testable import ProGhosttyCore

@Suite("ProGhostty control")
struct ProGhosttyControlTests {
  @Test func parserDecodesOsc777ProGhosttyPayload() throws {
    let message = ProGhosttyControlMessage(
      sessionId: "session-1",
      token: "token-1",
      command: .workspaceOpen
    )
    let osc = try ProGhosttyControlOscParser.encode(message)
    var oscParser = OscParser()
    let sequence = try #require(oscParser.parse(Data(osc.utf8)).first)

    let parsed = ProGhosttyControlOscParser.parse(sequence)

    #expect(parsed == message)
  }

  @Test func parserIgnoresInvalidPayloads() {
    let badJSON = Data("{".utf8).base64EncodedString()
    let oversized = String(repeating: "A", count: ProGhosttyControlOscParser.maxPayloadBytes + 1)

    #expect(ProGhosttyControlOscParser.parse(OscSequence(raw: "", command: "777", parameters: ["other", badJSON])) == nil)
    #expect(ProGhosttyControlOscParser.parse(OscSequence(raw: "", command: "777", parameters: ["proghostty", badJSON])) == nil)
    #expect(ProGhosttyControlOscParser.parse(OscSequence(raw: "", command: "777", parameters: ["proghostty", oversized])) == nil)
  }

  @Test func parserRejectsCommandsOutsideAllowlist() {
    let payload = """
      {
        "version": 1,
        "sessionId": "session-1",
        "token": "token-1",
        "command": "system.exec",
        "args": {}
      }
      """.data(using: .utf8)!.base64EncodedString()

    let parsed = ProGhosttyControlOscParser.parse(
      OscSequence(raw: "", command: "777", parameters: ["proghostty", payload])
    )

    #expect(parsed == nil)
  }

  @Test func pgMapperMapsAliasesAndArguments() {
    #expect(PGCommandMapper.map(arguments: ["ws"])?.command == .workspaceOpen)
    #expect(PGCommandMapper.map(arguments: ["workspace"])?.command == .workspaceOpen)
    #expect(PGCommandMapper.map(arguments: ["plugins"])?.command == .pluginsOpen)
    #expect(PGCommandMapper.map(arguments: ["settings"])?.command == .settingsOpen)
    #expect(PGCommandMapper.map(arguments: ["split", "right"])?.command == .splitRight)
    #expect(PGCommandMapper.map(arguments: ["split", "down"])?.command == .splitDown)
    #expect(PGCommandMapper.map(arguments: ["layout", "save"])?.command == .layoutSave)
    #expect(PGCommandMapper.map(arguments: ["layout", "restore"])?.command == .layoutRestore)

    let switchWorkspace = PGCommandMapper.map(arguments: ["ws", "switch", "Client", "A"])
    #expect(switchWorkspace?.command == .workspaceSwitch)
    #expect(switchWorkspace?.args == ["name": "Client A"])

    let pluginPlan = PGCommandMapper.map(arguments: ["plugins", "plan", "zsh-autosuggestions"])
    #expect(pluginPlan?.command == .pluginsPlan)
    #expect(pluginPlan?.args == ["pack": "zsh-autosuggestions"])
  }

  @Test func pgMapperPlansNotificationWithoutControlSession() throws {
    let response = PGCommandMapper.response(
      arguments: ["notify", "--title", "Codex", "--body", "Waiting for input"],
      environment: ["PROGHOSTTY_NOTIFY_TTY": "/tmp/proghostty-test-tty"]
    )

    guard case .notification(let plan) = response else {
      Issue.record("Expected notification response")
      return
    }
    #expect(plan.targetPath == "/tmp/proghostty-test-tty")

    var oscParser = OscParser()
    let sequence = try #require(oscParser.parse(Data(plan.sequence.utf8)).first)
    let notification = try #require(TerminalDesktopNotificationParser.parse(sequence))
    #expect(notification.title == "Codex")
    #expect(notification.body == "Waiting for input")
  }

  @Test func pgNotifySanitizesControlCharactersAndSemicolonTitleSeparators() throws {
    let response = PGCommandMapper.response(
      arguments: ["notify", "--title", "Bad;Title\u{1B}", "--body", "Done\u{07}now"],
      environment: [:]
    )

    guard case .notification(let plan) = response else {
      Issue.record("Expected notification response")
      return
    }
    #expect(plan.targetPath == "/dev/tty")

    var oscParser = OscParser()
    let sequence = try #require(oscParser.parse(Data(plan.sequence.utf8)).first)
    let notification = try #require(TerminalDesktopNotificationParser.parse(sequence))
    #expect(notification.title == "Bad Title")
    #expect(notification.body == "Done now")
  }

  @Test func pgMapperDoesNotEmitOscOutsideProGhostty() {
    let response = PGCommandMapper.response(
      arguments: ["ws"],
      environment: ["TERM_PROGRAM": "Apple_Terminal"]
    )

    if case .message(let text) = response {
      #expect(text.contains("ProGhostty"))
    } else {
      Issue.record("Expected friendly non-ProGhostty message")
    }
  }

  @Test func pgMapperEmitsPrivateOscInsideProGhostty() throws {
    let response = PGCommandMapper.response(
      arguments: ["ws"],
      environment: [
        "TERM_PROGRAM": "ProGhostty",
        "PROGHOSTTY_SESSION_ID": "session-1",
        "PROGHOSTTY_SESSION_TOKEN": "token-1",
      ]
    )

    guard case .osc(let osc) = response else {
      Issue.record("Expected OSC response")
      return
    }
    var oscParser = OscParser()
    let sequence = try #require(oscParser.parse(Data(osc.utf8)).first)
    let message = try #require(ProGhosttyControlOscParser.parse(sequence))

    #expect(message.command == ProGhosttyControlCommand.workspaceOpen)
    #expect(message.sessionId == "session-1")
    #expect(message.token == "token-1")
  }

  @Test func authorizationRejectsDisabledOrMismatchedSessions() {
    let message = ProGhosttyControlMessage(
      sessionId: "session-1",
      token: "token-1",
      command: .workspaceOpen
    )

    #expect(ProGhosttyControlAuthorizer.isAuthorized(
      message,
      sourceSessionId: "session-1",
      expectedToken: "token-1",
      isEnabled: true
    ))
    #expect(!ProGhosttyControlAuthorizer.isAuthorized(
      message,
      sourceSessionId: "session-1",
      expectedToken: "token-1",
      isEnabled: false
    ))
    #expect(!ProGhosttyControlAuthorizer.isAuthorized(
      message,
      sourceSessionId: "session-2",
      expectedToken: "token-1",
      isEnabled: true
    ))
    #expect(!ProGhosttyControlAuthorizer.isAuthorized(
      message,
      sourceSessionId: "session-1",
      expectedToken: "wrong-token",
      isEnabled: true
    ))
  }
}

import Foundation
import Testing

@testable import ProGhosttyCore

@Suite("Terminal notification OSC parsers")
struct TerminalNotificationParserTests {
  @Test func parsesOsc9AsDesktopNotificationBody() {
    let sequence = OscSequence(raw: "9;Codex finished", command: "9", parameters: ["Codex finished"])

    let notification = TerminalDesktopNotificationParser.parse(sequence)

    #expect(notification == TerminalDesktopNotification(
      title: "ProGhostty",
      body: "Codex finished",
      source: .osc9
    ))
  }

  @Test func parsesOsc777NotifyAsDesktopNotificationTitleAndBody() {
    let sequence = OscSequence(
      raw: "777;notify;Codex;Waiting for input",
      command: "777",
      parameters: ["notify", "Codex", "Waiting for input"]
    )

    let notification = TerminalDesktopNotificationParser.parse(sequence)

    #expect(notification == TerminalDesktopNotification(
      title: "Codex",
      body: "Waiting for input",
      source: .osc777
    ))
  }

  @Test func keepsSemicolonsInsideOsc777NotificationBody() {
    let sequence = OscSequence(
      raw: "777;notify;Claude Code;Done; review changes",
      command: "777",
      parameters: ["notify", "Claude Code", "Done", " review changes"]
    )

    let notification = TerminalDesktopNotificationParser.parse(sequence)

    #expect(notification?.title == "Claude Code")
    #expect(notification?.body == "Done; review changes")
  }

  @Test func ignoresEmptyOrUnknownDesktopNotificationOscs() {
    #expect(TerminalDesktopNotificationParser.parse(
      OscSequence(raw: "9;", command: "9", parameters: [""])
    ) == nil)
    #expect(TerminalDesktopNotificationParser.parse(
      OscSequence(raw: "777;unknown;Title;Body", command: "777", parameters: ["unknown", "Title", "Body"])
    ) == nil)
    #expect(TerminalDesktopNotificationParser.parse(
      OscSequence(raw: "777;notify;Title", command: "777", parameters: ["notify", "Title"])
    ) == nil)
  }

  @Test func trimsAndLimitsDesktopNotificationText() {
    let longBody = String(repeating: "x", count: 600)
    let sequence = OscSequence(raw: "9;\(longBody)", command: "9", parameters: [longBody])

    let notification = TerminalDesktopNotificationParser.parse(sequence)

    #expect(notification?.body.count == 300)
  }

  @MainActor @Test func ptySessionManagerEmitsDesktopNotificationEventForOsc9() async throws {
    let registry = PTYTerminalSurfaceRegistry()
    let manager = PTYTerminalSessionManager(surfaceRegistry: registry)
    let session = try manager.createSession(config: TerminalSessionConfig(
      shellPath: "/bin/zsh",
      launchCommand: "printf '\\033]9;Codex finished\\007'; sleep 0.1",
      workingDirectory: nil,
      environment: [:],
      rows: 24,
      cols: 80
    ))

    var iterator = manager.events.makeAsyncIterator()
    let deadline = Date().addingTimeInterval(2)
    while Date() < deadline {
      guard let event = await iterator.next() else { break }
      if case .desktopNotification(let eventSession, let notification) = event {
        #expect(eventSession == session)
        #expect(notification.body == "Codex finished")
        manager.closeSession(session)
        return
      }
    }

    manager.closeSession(session)
    Issue.record("Expected desktop notification event")
  }

  @MainActor @Test func ptySessionManagerEmitsDesktopNotificationForOsc9() async throws {
    let registry = PTYTerminalSurfaceRegistry()
    let manager = PTYTerminalSessionManager(surfaceRegistry: registry)
    let session = try manager.createSession(config: TerminalSessionConfig(
      shellPath: "/bin/zsh",
      launchCommand: "printf '\\033]9;Codex finished\\007'; sleep 0.1",
      workingDirectory: nil,
      environment: [:],
      rows: 24,
      cols: 80
    ))

    var iterator = manager.events.makeAsyncIterator()
    let deadline = Date().addingTimeInterval(2)
    while Date() < deadline {
      guard let event = await iterator.next() else { break }
      if case .desktopNotification(let eventSession, _) = event {
        #expect(eventSession == session)
        manager.closeSession(session)
        return
      }
    }

    manager.closeSession(session)
    Issue.record("Expected desktop notification event")
  }
}

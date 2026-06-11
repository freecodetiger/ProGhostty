import Foundation
import Testing

@testable import ProGhosttyApp
@testable import ProGhosttyCore

@MainActor
@Suite("Terminal notification center")
struct TerminalNotificationCenterTests {
  @Test func rateLimitsRepeatedDesktopNotifications() {
    let sender = RecordingTerminalNotificationSender()
    let center = TerminalNotificationCenter(sender: sender, minimumInterval: 1)
    let notification = TerminalDesktopNotification(title: "Codex", body: "Done", source: .osc777)

    center.showDesktopNotification(notification, session: TerminalSessionID(), now: Date(timeIntervalSince1970: 10))
    center.showDesktopNotification(notification, session: TerminalSessionID(), now: Date(timeIntervalSince1970: 10.2))

    #expect(sender.requests.count == 1)
  }

  @Test func allowsDifferentNotificationsWithinRateLimitWindow() {
    let sender = RecordingTerminalNotificationSender()
    let center = TerminalNotificationCenter(sender: sender, minimumInterval: 1)

    center.showDesktopNotification(
      TerminalDesktopNotification(title: "Codex", body: "Done", source: .osc777),
      session: TerminalSessionID(),
      now: Date(timeIntervalSince1970: 10)
    )
    center.showDesktopNotification(
      TerminalDesktopNotification(title: "Claude", body: "Waiting", source: .osc777),
      session: TerminalSessionID(),
      now: Date(timeIntervalSince1970: 10.2)
    )

    #expect(sender.requests.count == 2)
  }

  @Test func explicitTerminalNotificationUsesInAppAndSoundWhenDesktopIsDisabled() {
    var settings = AppSettings.defaults
    settings.desktopNotificationsEnabled = false
    settings.inAppNotificationsEnabled = true
    settings.inAppNotificationSoundEnabled = true
    let notification = TerminalDesktopNotification(title: "Codex", body: "Waiting for input", source: .osc777)

    let actions = TerminalNotificationPolicy.desktopNotificationActions(
      settings: settings,
      notification: notification
    )

    #expect(actions == [
      .inApp(notification),
      .sound,
    ])
  }

  @Test func explicitTerminalNotificationCanUseInAppSoundAndDesktopTogether() {
    var settings = AppSettings.defaults
    settings.desktopNotificationsEnabled = true
    settings.inAppNotificationsEnabled = true
    settings.inAppNotificationSoundEnabled = true
    let notification = TerminalDesktopNotification(title: "Codex", body: "Waiting for input", source: .osc777)

    let actions = TerminalNotificationPolicy.desktopNotificationActions(
      settings: settings,
      notification: notification
    )

    #expect(actions == [
      .inApp(notification),
      .sound,
      .desktop(notification),
    ])
  }

  @Test func commandFinishPolicySkipsShortCommands() {
    var settings = AppSettings.defaults
    settings.notifyOnCommandFinish = .always
    settings.notifyOnCommandFinishDesktopEnabled = true
    settings.notifyOnCommandFinishAfterSeconds = 5

    let actions = TerminalNotificationPolicy.commandFinishedActions(
      settings: settings,
      command: TerminalCommandFinished(exitCode: 0, duration: 1),
      isAppActive: false,
      isSessionFocused: false
    )

    #expect(actions.isEmpty)
  }

  @Test func commandFinishPolicyNotifiesLongCommandWhenDesktopActionEnabled() {
    var settings = AppSettings.defaults
    settings.notifyOnCommandFinish = .always
    settings.notifyOnCommandFinishDesktopEnabled = true
    settings.notifyOnCommandFinishAfterSeconds = 5

    let actions = TerminalNotificationPolicy.commandFinishedActions(
      settings: settings,
      command: TerminalCommandFinished(exitCode: 0, duration: 6),
      isAppActive: true,
      isSessionFocused: true
    )

    #expect(actions == [
      .bell,
      .desktop(TerminalDesktopNotification(
        title: "Command Succeeded",
        body: "Command took 6s.",
        source: .commandFinished
      )),
    ])
  }

  @Test func commandFinishPolicySkipsFocusedSessionWhenConfiguredForUnfocusedOnly() {
    var settings = AppSettings.defaults
    settings.notifyOnCommandFinish = .unfocused
    settings.notifyOnCommandFinishDesktopEnabled = true

    let actions = TerminalNotificationPolicy.commandFinishedActions(
      settings: settings,
      command: TerminalCommandFinished(exitCode: 0, duration: 6),
      isAppActive: true,
      isSessionFocused: true
    )

    #expect(actions.isEmpty)
  }

  @Test func terminalBellPolicyNotifiesUnfocusedSessionByDefault() {
    let actions = TerminalNotificationPolicy.terminalBellActions(
      settings: .defaults,
      isAppActive: false,
      isSessionFocused: false
    )

    #expect(actions == [
      .desktop(TerminalDesktopNotification(
        title: "Terminal Bell",
        body: "A terminal session needs attention.",
        source: .bell
      )),
    ])
  }

  @Test func terminalBellPolicySkipsFocusedSessionWhenConfiguredForUnfocusedOnly() {
    let actions = TerminalNotificationPolicy.terminalBellActions(
      settings: .defaults,
      isAppActive: true,
      isSessionFocused: true
    )

    #expect(actions.isEmpty)
  }
}

private final class RecordingTerminalNotificationSender: TerminalNotificationSending {
  var requests: [(title: String, body: String)] = []

  func requestAuthorizationIfNeeded() {}

  func send(title: String, body: String) {
    requests.append((title, body))
  }
}

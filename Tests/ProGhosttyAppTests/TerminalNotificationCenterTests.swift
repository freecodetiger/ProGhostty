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

  @Test func taskCompletionNotifiesInAppSoundAndDesktopInParallel() {
    var settings = AppSettings.defaults
    settings.notificationsEnabled = true
    let notification = TerminalDesktopNotification(title: "Codex", body: "Waiting for input", source: .osc777)

    let actions = TerminalNotificationPolicy.desktopNotificationActions(
      settings: settings,
      notification: notification,
      isAppActive: false,
      isSessionFocused: false
    )

    #expect(actions == [
      .inApp(notification),
      .sound,
      .desktop(notification),
    ])
  }

  @Test func taskCompletionSuppressedWhenNotificationsDisabled() {
    var settings = AppSettings.defaults
    settings.notificationsEnabled = false
    let notification = TerminalDesktopNotification(title: "Codex", body: "Done", source: .osc777)

    let actions = TerminalNotificationPolicy.desktopNotificationActions(
      settings: settings,
      notification: notification,
      isAppActive: false,
      isSessionFocused: false
    )

    #expect(actions.isEmpty)
  }

  @Test func taskCompletionSkippedWhenFocusedSessionAndNotifyWhenFocusedOff() {
    var settings = AppSettings.defaults
    settings.notificationsEnabled = true
    settings.notifyWhenFocused = false
    let notification = TerminalDesktopNotification(title: "Codex", body: "Done", source: .osc777)

    let actions = TerminalNotificationPolicy.desktopNotificationActions(
      settings: settings,
      notification: notification,
      isAppActive: true,
      isSessionFocused: true
    )

    #expect(actions.isEmpty)
  }

  @Test func taskCompletionNotifiesUnfocusedSessionEvenWhenNotifyWhenFocusedOff() {
    var settings = AppSettings.defaults
    settings.notificationsEnabled = true
    settings.notifyWhenFocused = false
    let notification = TerminalDesktopNotification(title: "Codex", body: "Done", source: .osc777)

    // App active but the notifying session is NOT the focused pane → still notify.
    let actions = TerminalNotificationPolicy.desktopNotificationActions(
      settings: settings,
      notification: notification,
      isAppActive: true,
      isSessionFocused: false
    )

    #expect(actions == [.inApp(notification), .sound, .desktop(notification)])
  }

  @Test func taskCompletionNotifiesFocusedSessionWhenNotifyWhenFocusedOn() {
    var settings = AppSettings.defaults
    settings.notificationsEnabled = true
    settings.notifyWhenFocused = true
    let notification = TerminalDesktopNotification(title: "Codex", body: "Done", source: .osc777)

    let actions = TerminalNotificationPolicy.desktopNotificationActions(
      settings: settings,
      notification: notification,
      isAppActive: true,
      isSessionFocused: true
    )

    #expect(actions == [.inApp(notification), .sound, .desktop(notification)])
  }
}

private final class RecordingTerminalNotificationSender: TerminalNotificationSending {
  var requests: [(title: String, body: String)] = []

  func requestAuthorizationIfNeeded() {}

  func send(title: String, body: String) {
    requests.append((title, body))
  }

  func fetchAuthorizationGranted(_ completion: @escaping @Sendable (Bool) -> Void) {
    completion(true)
  }
}

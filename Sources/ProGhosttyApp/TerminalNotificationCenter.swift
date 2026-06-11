import AppKit
import Foundation
import ProGhosttyCore
import UserNotifications

protocol TerminalNotificationSending: AnyObject {
  func requestAuthorizationIfNeeded()
  func send(title: String, body: String)
}

protocol TerminalNotificationSoundPlaying: AnyObject {
  func playNotificationSound()
}

@MainActor
final class TerminalNotificationCenter {
  private let sender: TerminalNotificationSending
  private let minimumInterval: TimeInterval
  private var lastSentAtByFingerprint: [String: Date] = [:]

  init(
    sender: TerminalNotificationSending = MacTerminalNotificationSender(),
    minimumInterval: TimeInterval = 1
  ) {
    self.sender = sender
    self.minimumInterval = minimumInterval
  }

  func showDesktopNotification(
    _ notification: TerminalDesktopNotification,
    session _: TerminalSessionID,
    now: Date = Date()
  ) {
    let fingerprint = "\(notification.title)\u{1F}\(notification.body)"
    if let lastSentAt = lastSentAtByFingerprint[fingerprint],
      now.timeIntervalSince(lastSentAt) < minimumInterval
    {
      return
    }
    lastSentAtByFingerprint[fingerprint] = now
    sender.requestAuthorizationIfNeeded()
    sender.send(title: notification.title, body: notification.body)
  }
}

enum TerminalNotificationAction: Equatable {
  case bell
  case inApp(TerminalDesktopNotification)
  case sound
  case desktop(TerminalDesktopNotification)
}

enum TerminalNotificationPolicy {
  static func desktopNotificationActions(
    settings: AppSettings,
    notification: TerminalDesktopNotification
  ) -> [TerminalNotificationAction] {
    var actions: [TerminalNotificationAction] = []
    if settings.inAppNotificationsEnabled {
      actions.append(.inApp(notification))
      if settings.inAppNotificationSoundEnabled {
        actions.append(.sound)
      }
    }
    if settings.desktopNotificationsEnabled {
      actions.append(.desktop(notification))
    }
    return actions
  }

  static func terminalBellActions(
    settings: AppSettings,
    isAppActive: Bool,
    isSessionFocused: Bool
  ) -> [TerminalNotificationAction] {
    guard settings.desktopNotificationsEnabled, settings.notifyOnTerminalBellDesktopEnabled else {
      return []
    }

    switch settings.notifyOnTerminalBell {
    case .never:
      return []
    case .unfocused:
      if isAppActive && isSessionFocused { return [] }
    case .always:
      break
    }

    return [.desktop(TerminalDesktopNotification(
      title: "Terminal Bell",
      body: "A terminal session needs attention.",
      source: .bell
    ))]
  }

  static func commandFinishedActions(
    settings: AppSettings,
    command: TerminalCommandFinished,
    isAppActive: Bool,
    isSessionFocused: Bool
  ) -> [TerminalNotificationAction] {
    guard command.duration >= settings.notifyOnCommandFinishAfterSeconds else { return [] }

    switch settings.notifyOnCommandFinish {
    case .never:
      return []
    case .unfocused:
      if isAppActive && isSessionFocused { return [] }
    case .always:
      break
    }

    var actions: [TerminalNotificationAction] = []
    if settings.notifyOnCommandFinishBellEnabled {
      actions.append(.bell)
    }
    if settings.desktopNotificationsEnabled, settings.notifyOnCommandFinishDesktopEnabled {
      actions.append(.desktop(TerminalDesktopNotification(
        title: commandFinishedTitle(exitCode: command.exitCode),
        body: commandFinishedBody(command),
        source: .commandFinished
      )))
    }
    return actions
  }

  private static func commandFinishedTitle(exitCode: Int?) -> String {
    guard let exitCode else { return "Command Finished" }
    return exitCode == 0 ? "Command Succeeded" : "Command Failed"
  }

  private static func commandFinishedBody(_ command: TerminalCommandFinished) -> String {
    let duration = formattedDuration(command.duration)
    if let exitCode = command.exitCode, exitCode != 0 {
      return "Command took \(duration) and exited with code \(exitCode)."
    }
    return "Command took \(duration)."
  }

  private static func formattedDuration(_ duration: TimeInterval) -> String {
    if duration >= 60 {
      return "\(Int(duration / 60))m \(Int(duration) % 60)s"
    }
    return "\(Int(duration))s"
  }
}

private final class MacTerminalNotificationSender: NSObject, TerminalNotificationSending, UNUserNotificationCenterDelegate {
  private var hasRequestedAuthorization = false

  override init() {
    super.init()
    UNUserNotificationCenter.current().delegate = self
  }

  func requestAuthorizationIfNeeded() {
    guard !hasRequestedAuthorization else { return }
    hasRequestedAuthorization = true
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { isGranted, error in
      if let error {
        Self.log("notification authorization failed granted=\(isGranted) error=\(error.localizedDescription)")
        Self.requestFallbackAttention()
      } else {
        Self.log("notification authorization granted=\(isGranted)")
      }
    }
  }

  func send(title: String, body: String) {
    let center = UNUserNotificationCenter.current()
    center.getNotificationSettings { settings in
      switch settings.authorizationStatus {
      case .authorized, .provisional, .ephemeral:
        Self.addNotification(title: title, body: body, center: center)
      case .notDetermined:
        center.requestAuthorization(options: [.alert, .sound]) { isGranted, _ in
          guard isGranted else {
            Self.requestFallbackAttention()
            return
          }
          Self.addNotification(title: title, body: body, center: center)
        }
      case .denied:
        Self.log("notification skipped: authorization denied")
        Self.requestFallbackAttention()
        return
      @unknown default:
        return
      }
    }
  }

  private static func addNotification(title: String, body: String, center: UNUserNotificationCenter) {
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    content.sound = .default

    let request = UNNotificationRequest(
      identifier: "proghostty.terminal.\(UUID().uuidString)",
      content: content,
      trigger: nil
    )
    center.add(request) { error in
      if let error {
        log("notification add failed error=\(error.localizedDescription)")
      } else {
        log("notification add succeeded title=\(title)")
      }
    }
  }

  private static func log(_ message: String) {
    Task { @MainActor in
      DebugLog.write(message)
    }
  }

  private static func requestFallbackAttention() {
    Task { @MainActor in
      NSSound.beep()
      NSApp.requestUserAttention(.informationalRequest)
    }
  }

  nonisolated func userNotificationCenter(
    _: UNUserNotificationCenter,
    willPresent _: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([.banner, .list, .sound])
  }
}

final class TerminalNotificationSoundPlayer: TerminalNotificationSoundPlaying {
  private var sound: NSSound?

  func playNotificationSound() {
    guard let sound = notificationSound() else {
      NSSound.beep()
      return
    }
    sound.stop()
    sound.currentTime = 0
    sound.play()
  }

  private func notificationSound() -> NSSound? {
    if let sound {
      return sound
    }
    guard let url = Self.notificationSoundURL() else {
      return nil
    }
    let loaded = NSSound(contentsOf: url, byReference: true)
    sound = loaded
    return loaded
  }

  private static func notificationSoundURL() -> URL? {
    if let bundled = Bundle.main.url(forResource: "notification-piano", withExtension: "mp3") {
      return bundled
    }
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .appendingPathComponent("Resources/notification-piano.mp3")
    return FileManager.default.fileExists(atPath: sourceURL.path) ? sourceURL : nil
  }
}

import AppKit
import Foundation
import ProGhosttyCore
import UserNotifications

protocol TerminalNotificationSending: AnyObject {
  func requestAuthorizationIfNeeded()
  func send(title: String, body: String)
  func fetchAuthorizationGranted(_ completion: @escaping @Sendable (Bool) -> Void)
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

  /// Reports whether the system has granted notification authorization, for the
  /// low-key permission hint in Settings. Result is delivered on the main actor.
  func refreshAuthorizationStatus(_ completion: @escaping @MainActor (Bool) -> Void) {
    sender.fetchAuthorizationGranted { granted in
      Task { @MainActor in completion(granted) }
    }
  }
}

enum TerminalNotificationAction: Equatable {
  case inApp(TerminalDesktopNotification)
  case sound
  case desktop(TerminalDesktopNotification)
}

enum TerminalNotificationPolicy {
  /// The sole notification trigger: an agent task-completion notification
  /// (`pg notify`, arriving via OSC 777). Fires in-app toast + system
  /// notification + the piano sound in parallel, gated by the master toggle
  /// and focus.
  ///
  /// - When notifications are disabled: nothing.
  /// - When `notifyWhenFocused` is off (default): suppressed while the app is
  ///   active AND the notifying session is the focused pane (you are already
  ///   looking at it).
  static func desktopNotificationActions(
    settings: AppSettings,
    notification: TerminalDesktopNotification,
    isAppActive: Bool,
    isSessionFocused: Bool
  ) -> [TerminalNotificationAction] {
    guard settings.notificationsEnabled else { return [] }
    if !settings.notifyWhenFocused, isAppActive, isSessionFocused {
      return []
    }
    return [.inApp(notification), .sound, .desktop(notification)]
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

  func fetchAuthorizationGranted(_ completion: @escaping @Sendable (Bool) -> Void) {
    UNUserNotificationCenter.current().getNotificationSettings { settings in
      switch settings.authorizationStatus {
      case .authorized, .provisional, .ephemeral:
        completion(true)
      default:
        completion(false)
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
    // Bundle.main first: the packaged .app copies the mp3 into Contents/Resources,
    // and this avoids touching Bundle.module (whose synthesized accessor
    // fatalErrors if the SwiftPM resource bundle isn't found next to the binary).
    if let bundled = Bundle.main.url(forResource: "notification-piano", withExtension: "mp3") {
      return bundled
    }
    // SwiftPM resource bundle: used by `swift run` and the test target.
    if let bundled = Bundle.module.url(forResource: "notification-piano", withExtension: "mp3") {
      return bundled
    }
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .appendingPathComponent("Resources/notification-piano.mp3")
    return FileManager.default.fileExists(atPath: sourceURL.path) ? sourceURL : nil
  }
}

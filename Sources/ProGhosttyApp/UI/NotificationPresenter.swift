import Foundation
import ProGhosttyCore

/// Owner of transient notification presentation: the titlebar toast, the
/// in-app notification banner, and their auto-dismiss lifecycles — plus the
/// status line (formerly `shellIntegrationState`) that many flows write.
///
/// Extracted from `AppModel` (debt spec 3-7). AppModel chains
/// `objectWillChange` and keeps same-named forwarders, so views keep reading
/// `model.titlebarToast` etc. Actions that need app semantics (opening URLs,
/// selecting sessions) stay in AppModel and call `dismiss*` here.
@MainActor
final class NotificationPresenter: ObservableObject {
  @Published private(set) var titlebarToast: AppModel.TitlebarToast?
  @Published private(set) var inAppNotification: AppModel.InAppNotification?
  /// Free-form status line shown in the inspector; historically a shared
  /// "state bus" written by save/restore/split/update flows.
  @Published var statusLine = "partial"

  private var titlebarToastTask: Task<Void, Never>?
  private var inAppNotificationTask: Task<Void, Never>?

  func showTitlebarToast(
    _ message: String,
    style: AppModel.TitlebarToast.Style,
    lifetime: ProGhosttyTitlebarToastLifetime = .transient(1.8)
  ) {
    titlebarToastTask?.cancel()
    titlebarToastTask = nil
    let toast = AppModel.TitlebarToast(message: message, style: style, lifetime: lifetime)
    titlebarToast = toast
    guard let delay = lifetime.dismissDelay else { return }
    titlebarToastTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
      // Cancelling a Task does NOT stop code after the (throwing) sleep — `try?`
      // swallows the CancellationError and execution falls through. Without this
      // guard a rapid second toast would cancel the first task, which then
      // immediately cleared the *new* toast (it showed for one frame). Bail if
      // cancelled, and only clear if this is still the toast we scheduled.
      if Task.isCancelled { return }
      await MainActor.run {
        guard let self, self.titlebarToast?.id == toast.id else { return }
        self.titlebarToast = nil
      }
    }
  }

  func dismissTitlebarToast() {
    titlebarToast = nil
    titlebarToastTask?.cancel()
    titlebarToastTask = nil
  }

  func showInAppNotification(_ next: AppModel.InAppNotification) {
    inAppNotification = next
    inAppNotificationTask?.cancel()
    inAppNotificationTask = Task { [weak self, id = next.id] in
      try? await Task.sleep(nanoseconds: 4_000_000_000)
      guard !Task.isCancelled else { return }
      await MainActor.run {
        guard self?.inAppNotification?.id == id else { return }
        self?.inAppNotification = nil
        self?.inAppNotificationTask = nil
      }
    }
  }

  func dismissInAppNotification() {
    inAppNotification = nil
    inAppNotificationTask?.cancel()
    inAppNotificationTask = nil
  }
}

import AppKit

/// Intercepts the terminal window's close button so the quit confirmation
/// runs BEFORE the window disappears.
///
/// Closing the last window terminates the app
/// (`applicationShouldTerminateAfterLastWindowClosed`), so without this guard
/// the window vanished first and the foreground-process confirmation only
/// appeared afterwards — and cancelling left a windowless app whose repeated
/// terminate requests re-opened the dialog in a loop. The guard asks first;
/// on cancel the window simply stays open.
@MainActor
final class TerminalWindowCloseGuard: NSObject {
  /// Retains the proxies (NSWindow.delegate is a weak reference).
  private var proxies: [ObjectIdentifier: WindowDelegateProxy] = [:]
  /// SwiftUI re-asserts its own `Coordinator` as `NSWindow.delegate` whenever the
  /// window's state refreshes, evicting our proxy — after which the close button
  /// goes straight to the coordinator and the guard never runs. Watching the
  /// property lets us take it back the instant it's swapped.
  private var delegateObservations: [ObjectIdentifier: NSKeyValueObservation] = [:]
  private let shouldClose: @MainActor (NSWindow) -> Bool

  init(shouldClose: @escaping @MainActor (NSWindow) -> Bool) {
    self.shouldClose = shouldClose
    super.init()
    // Selector-based so the observer auto-removes on dealloc; didBecomeKey
    // always posts on the main thread.
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(windowDidBecomeKey(_:)),
      name: NSWindow.didBecomeKeyNotification,
      object: nil
    )
  }

  @objc private func windowDidBecomeKey(_ note: Notification) {
    guard let window = note.object as? NSWindow else { return }
    installIfNeeded(on: window)
  }

  /// Idempotent: guards every regular window except panels (alerts, popovers)
  /// and the settings window. Re-wraps if SwiftUI swapped the delegate.
  private func installIfNeeded(on window: NSWindow) {
    guard !(window is NSPanel) else { return }
    if let settings = AppComposition.shared?.utilityWindows.settingsWindow, window === settings { return }
    if window.delegate is WindowDelegateProxy { return }
    let key = ObjectIdentifier(window)
    // Register the observation once per window. SwiftUI re-asserts its own
    // coordinator on window-state updates, so this method runs often; tearing
    // down and re-creating the KVO registration each time churns the main
    // thread for no benefit.
    if delegateObservations[key] == nil {
      delegateObservations[key] = window.observe(\.delegate, options: [.new]) { [weak self] window, _ in
        // KVO fires synchronously on the setter, i.e. already on whichever
        // thread SwiftUI set the delegate from — main, for window state.
        MainActor.assumeIsolated { self?.installIfNeeded(on: window) }
      }
    }
    let proxy = WindowDelegateProxy(base: window.delegate, shouldClose: shouldClose)
    proxies[key] = proxy
    window.delegate = proxy
  }
}

/// NSWindowDelegate proxy: answers `windowShouldClose` with the injected
/// guard (consulting the wrapped delegate only when the guard allows) and
/// forwards every other delegate method to the wrapped delegate untouched.
final class WindowDelegateProxy: NSObject, NSWindowDelegate {
  /// Strong on purpose: NSWindow.delegate is weak, and forwarding must keep
  /// working for the window's lifetime (the proxy itself is retained by the
  /// guard's `proxies` map, which lives as long as the app).
  private let base: NSWindowDelegate?
  private let shouldClose: @MainActor (NSWindow) -> Bool

  init(base: NSWindowDelegate?, shouldClose: @escaping @MainActor (NSWindow) -> Bool) {
    self.base = base
    self.shouldClose = shouldClose
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    // AppKit calls delegate methods on the main thread.
    let allowed = MainActor.assumeIsolated { shouldClose(sender) }
    guard allowed else { return false }
    if let base, base.responds(to: #selector(NSWindowDelegate.windowShouldClose(_:))) {
      return base.windowShouldClose?(sender) ?? true
    }
    return true
  }

  override func responds(to aSelector: Selector!) -> Bool {
    super.responds(to: aSelector) || (base?.responds(to: aSelector) ?? false)
  }

  override func forwardingTarget(for aSelector: Selector!) -> Any? {
    if base?.responds(to: aSelector) == true {
      return base
    }
    return super.forwardingTarget(for: aSelector)
  }
}

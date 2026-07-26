import AppKit

/// Owner of auxiliary (non-terminal) windows — today just Settings.
///
/// Extracted from `AppModel` (debt spec 3-5). Content construction and window
/// chrome stay with the caller (they need the view model and appearance
/// state); this type owns the window controller lifecycle and identity, which
/// terminal-window discovery and appearance passes query via `settingsWindow`.
@MainActor
final class UtilityWindowController {
  private var settingsWindowController: NSWindowController?

  /// The live settings window, if open. Used to exclude it from terminal
  /// window discovery and terminal-chrome passes.
  var settingsWindow: NSWindow? { settingsWindowController?.window }

  func closeSettings(_ window: NSWindow? = nil) {
    if let window {
      window.close()
      if window === settingsWindowController?.window {
        settingsWindowController = nil
      }
      return
    }

    settingsWindowController?.window?.close()
    settingsWindowController = nil
  }

  /// Shows the settings window, creating it on first open. `makeContent`
  /// builds the hosting controller; `applyChrome` applies configuration
  /// chrome and is retained for the deferred re-assert.
  func openSettings(
    makeContent: () -> NSViewController,
    applyChrome: @escaping (NSWindow) -> Void
  ) {
    if let window = settingsWindowController?.window {
      applyChrome(window)
      window.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
      // show/makeKey can reinstate system title after we hide it; re-apply next turn.
      reassertSettingsChrome(applyChrome)
      return
    }

    let window = NSWindow(contentViewController: makeContent())
    window.title = "Settings"
    window.styleMask = [.titled, .closable, .miniaturizable]
    window.setContentSize(NSSize(width: 640, height: 520))
    window.minSize = NSSize(width: 560, height: 460)
    window.isReleasedWhenClosed = false
    window.center()
    window.toolbarStyle = .preference
    applyChrome(window)

    let windowController = NSWindowController(window: window)
    settingsWindowController = windowController
    windowController.showWindow(nil)
    NSApp.activate(ignoringOtherApps: true)
    // Preference-style titlebar materializes on show and can reset titleVisibility.
    reassertSettingsChrome(applyChrome)
  }

  /// Sidebar / split layout can briefly restore the system "Settings" title; cheap re-hide.
  func reassertSettingsChrome(_ applyChrome: @escaping (NSWindow) -> Void) {
    guard let window = settingsWindowController?.window else { return }
    applyChrome(window)
    // Cover AppKit applying defaults after the current layout pass.
    DispatchQueue.main.async { [weak self] in
      guard let self, let window = self.settingsWindowController?.window else { return }
      applyChrome(window)
    }
  }
}

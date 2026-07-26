import AppKit
import ProGhosttyCore

/// Owner of terminal-window size geometry: discovery of the terminal window,
/// per-workspace remembered content sizes, minimum-size enforcement, and
/// workspace-switch expansion.
///
/// Extracted from `AppModel` (debt spec 3-4). Which windows are *not* terminal
/// windows (settings, etc.) is injected via `isExcludedWindow` so this type
/// stays decoupled from utility-window ownership.
@MainActor
final class TerminalWindowSizingController {
  private var rememberedContentSizes: [UUID: NSSize] = [:]
  private let isExcludedWindow: (NSWindow) -> Bool

  init(isExcludedWindow: @escaping (NSWindow) -> Bool) {
    self.isExcludedWindow = isExcludedWindow
  }

  func rememberContentSize(for workspaceID: UUID) {
    guard
      let window = terminalWindow(),
      let contentSize = terminalWindowContentSize(window)
    else {
      return
    }
    rememberedContentSizes[workspaceID] = contentSize
  }

  func forgetContentSize(for workspaceID: UUID) {
    rememberedContentSizes[workspaceID] = nil
  }

  /// Grows the window when the incoming workspace's layout minimum (or its
  /// remembered size) exceeds the current content size; never shrinks.
  func expandWindowIfNeeded(for root: PaneNode, workspaceID: UUID) {
    guard let window = terminalWindow(), let currentSize = terminalWindowContentSize(window) else {
      return
    }

    let minimum = minimumContentSize(for: root)
    applyMinimumSize(to: window, minimum: minimum)
    let target = SplitRatioLayout.workspaceSwitchTargetContentSize(
      current: contentSize(from: currentSize),
      remembered: rememberedContentSizes[workspaceID].map(contentSize(from:)),
      layoutMinimum: minimum
    )

    if target.width > Double(currentSize.width) + 0.5 || target.height > Double(currentSize.height) + 0.5 {
      window.setContentSize(nsSize(from: target))
    }
  }

  func applyMinimumContentSize(for root: PaneNode) {
    guard let window = terminalWindow() else { return }
    applyMinimumSize(to: window, minimum: minimumContentSize(for: root))
  }

  func maximumContentSize() -> NSSize? {
    guard let window = terminalWindow(), let screen = window.screen ?? NSScreen.main else {
      return nil
    }
    let size = window.contentRect(forFrameRect: screen.visibleFrame).size
    return size.width > 0 && size.height > 0 ? size : nil
  }

  // MARK: Internals

  private func minimumContentSize(for root: PaneNode) -> SplitRatioLayout.ContentSize {
    SplitRatioLayout.windowMinimumContentSize(
      for: root,
      baseWidth: ProGhosttyWindowSizing.minimumContentWidth,
      baseHeight: ProGhosttyWindowSizing.minimumContentHeight
    )
  }

  private func applyMinimumSize(
    to window: NSWindow,
    minimum: SplitRatioLayout.ContentSize
  ) {
    let contentSize = nsSize(from: minimum)
    window.contentMinSize = contentSize
    window.minSize = window.frameRect(forContentRect: NSRect(origin: .zero, size: contentSize)).size
  }

  private func terminalWindow() -> NSWindow? {
    func isTerminalCandidate(_ window: NSWindow) -> Bool {
      guard window.isVisible else { return false }
      if isExcludedWindow(window) { return false }
      return true
    }

    if let keyWindow = NSApp.keyWindow, isTerminalCandidate(keyWindow) {
      return keyWindow
    }
    if let mainWindow = NSApp.mainWindow, isTerminalCandidate(mainWindow) {
      return mainWindow
    }
    return NSApp.windows.first(where: isTerminalCandidate)
  }

  private func terminalWindowContentSize(_ window: NSWindow) -> NSSize? {
    if let contentView = window.contentView {
      let contentSize = contentView.bounds.size
      if contentSize.width > 0, contentSize.height > 0 {
        return contentSize
      }
    }
    let size = window.contentLayoutRect.size
    return size.width > 0 && size.height > 0 ? size : nil
  }

  private func contentSize(from size: NSSize) -> SplitRatioLayout.ContentSize {
    SplitRatioLayout.ContentSize(width: Double(size.width), height: Double(size.height))
  }

  private func nsSize(from size: SplitRatioLayout.ContentSize) -> NSSize {
    NSSize(width: size.width, height: size.height)
  }
}

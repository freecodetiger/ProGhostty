import AppKit
import ProGhosttyCore
import SwiftUI

struct TerminalChromeSyncView: NSViewRepresentable {
  let backgroundColor: NSColor
  let usesDarkAppearance: Bool
  let syncToken: Int

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  func makeNSView(context: Context) -> NSView {
    NSView(frame: .zero)
  }

  func updateNSView(_ view: NSView, context: Context) {
    context.coordinator.backgroundColor = backgroundColor
    context.coordinator.usesDarkAppearance = usesDarkAppearance
    context.coordinator.syncToken = syncToken
    context.coordinator.sync(window: view.window)
    DispatchQueue.main.async {
      context.coordinator.sync(window: view.window)
    }
  }

  @MainActor final class Coordinator {
    var backgroundColor: NSColor = .black
    var usesDarkAppearance = true
    var syncToken = 0

    func sync(window: NSWindow?) {
      guard let window else { return }
      ProGhosttyWindowAppearance.applyTerminalChrome(
        to: window,
        backgroundColor: backgroundColor,
        usesDarkAppearance: usesDarkAppearance
      )
    }
  }
}

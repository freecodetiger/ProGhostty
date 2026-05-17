import AppKit
import Testing

@testable import ProGhosttyCore

@Suite("Terminal window appearance", .serialized)
struct TerminalWindowAppearanceTests {
  @MainActor @Test func terminalChromePaintsWindowContentAndTitlebarBackgrounds() throws {
    let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 260))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
      styleMask: [.titled, .closable, .miniaturizable],
      backing: .buffered,
      defer: false
    )
    window.contentView = contentView
    _ = try #require(window.contentView?.superview)
    let managedTitlebarContainer = NSView()
    window.contentView?.addSubview(managedTitlebarContainer)
    let titlebarBackground = NSView()
    titlebarBackground.identifier = ProGhosttyWindowAppearance.titlebarBackgroundIdentifier
    managedTitlebarContainer.addSubview(titlebarBackground)

    let background = NSColor(calibratedWhite: 0.075, alpha: 1)
    ProGhosttyWindowAppearance.applyTerminalChrome(
      to: window,
      backgroundColor: background,
      usesDarkAppearance: true
    )

    #expect(window.titlebarAppearsTransparent)
    #expect(window.titlebarSeparatorStyle == .none)
    #expect(window.styleMask.contains(.fullSizeContentView))
    #expect(window.backgroundColor.sameRGB(as: background))
    #expect(window.contentView?.layer?.backgroundColor?.sameRGB(as: background.cgColor) == true)
    #expect(window.contentView?.superview?.layer?.backgroundColor?.sameRGB(as: background.cgColor) == true)
    #expect(titlebarBackground.layer?.backgroundColor?.sameRGB(as: background.cgColor) == true)
  }
}

private extension NSColor {
  func sameRGB(as other: NSColor) -> Bool {
    guard let lhs = usingColorSpace(.deviceRGB), let rhs = other.usingColorSpace(.deviceRGB) else {
      return false
    }
    return abs(lhs.redComponent - rhs.redComponent) < 0.001
      && abs(lhs.greenComponent - rhs.greenComponent) < 0.001
      && abs(lhs.blueComponent - rhs.blueComponent) < 0.001
  }
}

private extension CGColor {
  func sameRGB(as other: CGColor) -> Bool {
    guard
      let lhs = NSColor(cgColor: self)?.usingColorSpace(.deviceRGB),
      let rhs = NSColor(cgColor: other)?.usingColorSpace(.deviceRGB)
    else {
      return false
    }
    return abs(lhs.redComponent - rhs.redComponent) < 0.001
      && abs(lhs.greenComponent - rhs.greenComponent) < 0.001
      && abs(lhs.blueComponent - rhs.blueComponent) < 0.001
  }
}

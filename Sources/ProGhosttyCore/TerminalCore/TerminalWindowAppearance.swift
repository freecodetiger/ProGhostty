import AppKit

@MainActor
public enum ProGhosttyWindowAppearance {
  public static let titlebarBackgroundIdentifier = NSUserInterfaceItemIdentifier("ProGhosttyTitlebarBackground")

  public static func applyTerminalChrome(
    to window: NSWindow,
    backgroundColor: NSColor,
    usesDarkAppearance: Bool
  ) {
    window.appearance = NSAppearance(named: usesDarkAppearance ? .darkAqua : .aqua)
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.titlebarSeparatorStyle = .none
    window.styleMask.insert(.fullSizeContentView)
    window.isOpaque = true
    window.backgroundColor = backgroundColor

    let background = backgroundColor.cgColor
    paint(view: window.contentView, background: background)
    paint(view: window.contentView?.superview, background: background)

    for view in window.contentView?.superview?.descendants(matchingIdentifier: titlebarBackgroundIdentifier) ?? [] {
      paint(view: view, background: background)
    }
  }

  private static func paint(view: NSView?, background: CGColor) {
    guard let view else { return }
    view.wantsLayer = true
    view.layer?.backgroundColor = background
  }
}

private extension NSView {
  func descendants(matchingIdentifier identifier: NSUserInterfaceItemIdentifier) -> [NSView] {
    var result: [NSView] = []
    for subview in subviews {
      if subview.identifier == identifier {
        result.append(subview)
      }
      result.append(contentsOf: subview.descendants(matchingIdentifier: identifier))
    }
    return result
  }
}

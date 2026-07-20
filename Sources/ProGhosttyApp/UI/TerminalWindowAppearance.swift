import AppKit
import ProGhosttyCore

@MainActor
public enum ProGhosttyWindowAppearance {
  public static let titlebarBackgroundIdentifier = NSUserInterfaceItemIdentifier("ProGhosttyTitlebarBackground")

  public static func applyTerminalChrome(
    to window: NSWindow,
    backgroundColor: NSColor,
    usesDarkAppearance: Bool
  ) {
    let appearance = NSAppearance(named: usesDarkAppearance ? .darkAqua : .aqua)
    window.appearance = appearance
    window.contentView?.appearance = appearance
    window.contentViewController?.view.appearance = appearance
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.titlebarSeparatorStyle = .none
    window.styleMask.insert(.fullSizeContentView)
    window.isOpaque = true
    window.backgroundColor = backgroundColor

    let background = backgroundColor.cgColor
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    paint(view: window.contentView, background: background)
    paint(view: window.contentViewController?.view, background: background)
    for titlebarHost in titlebarHosts(in: window) {
      paint(view: titlebarHost, background: background)

      for view in titlebarHost.descendants(matchingIdentifier: titlebarBackgroundIdentifier) {
        paint(view: view, background: background)
      }
    }
    CATransaction.commit()
  }

  public static func applyConfigurationChrome(
    to window: NSWindow,
    backgroundColor: NSColor,
    usesDarkAppearance: Bool
  ) {
    let appearance = NSAppearance(named: usesDarkAppearance ? .darkAqua : .aqua)
    window.appearance = appearance
    window.contentView?.appearance = appearance
    window.contentViewController?.view.appearance = appearance
    // Transparent painted titlebar + visible system title fights: system label color
    // does not follow our layer paint, so dark Soft/Default often got black title on
    // dark chrome. Hide title (same as terminal); window.title still works for WM.
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.titlebarSeparatorStyle = .none
    window.backgroundColor = backgroundColor

    let background = backgroundColor.cgColor
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    paint(view: window.contentView, background: background)
    paint(view: window.contentViewController?.view, background: background)
    for titlebarHost in titlebarHosts(in: window) {
      paint(view: titlebarHost, background: background)
    }
    CATransaction.commit()
  }

  private static func titlebarHosts(in window: NSWindow) -> [NSView] {
    var hosts: [NSView] = []
    func append(_ view: NSView?) {
      guard let view, !hosts.contains(where: { $0 === view }) else { return }
      hosts.append(view)
    }

    append(window.contentView?.superview)
    append(window.standardWindowButton(.closeButton)?.superview)
    append(window.standardWindowButton(.miniaturizeButton)?.superview)
    append(window.standardWindowButton(.zoomButton)?.superview)
    return hosts
  }

  private static func paint(view: NSView?, background: CGColor) {
    guard let view else { return }
    view.wantsLayer = true
    view.layer?.backgroundColor = background
  }
}

public struct ProGhosttyTitlebarToastColors: Equatable, Sendable {
  public var background: NSColor
  public var foreground: NSColor
  public var border: NSColor

  public init(background: NSColor, foreground: NSColor, border: NSColor) {
    self.background = background
    self.foreground = foreground
    self.border = border
  }
}

public enum ProGhosttyTitlebarToastLifetime: Equatable, Sendable {
  case persistent
  case transient(TimeInterval)

  public static let settingsSaved: ProGhosttyTitlebarToastLifetime = .transient(2.4)

  public var dismissDelay: TimeInterval? {
    switch self {
    case .persistent:
      return nil
    case .transient(let delay):
      return delay
    }
  }
}

public enum ProGhosttyTitlebarToastMetrics {
  public static let horizontalPadding: CGFloat = 10
  public static let verticalPadding: CGFloat = 4
  public static let maximumWidth: CGFloat = 180

  public static func capsuleRadius(for height: CGFloat) -> CGFloat {
    max(0, height / 2)
  }

  public static func borderWidth(backingScaleFactor: CGFloat) -> CGFloat {
    guard backingScaleFactor > 0 else { return 1 }
    return 1 / backingScaleFactor
  }
}

public enum ProGhosttyTitlebarToastPalette {
  public static func success(usesDarkAppearance: Bool) -> ProGhosttyTitlebarToastColors {
    if usesDarkAppearance {
      return ProGhosttyTitlebarToastColors(
        background: NSColor(calibratedRed: 0.04, green: 0.42, blue: 0.25, alpha: 1),
        foreground: NSColor(calibratedRed: 0.94, green: 1.00, blue: 0.96, alpha: 1),
        border: NSColor(calibratedRed: 0.18, green: 0.64, blue: 0.41, alpha: 1)
      )
    }

    return ProGhosttyTitlebarToastColors(
      background: NSColor(calibratedRed: 0.71, green: 0.94, blue: 0.81, alpha: 1),
      foreground: NSColor(calibratedRed: 0.03, green: 0.24, blue: 0.13, alpha: 1),
      border: NSColor(calibratedRed: 0.38, green: 0.70, blue: 0.49, alpha: 1)
    )
  }

  public static func info(usesDarkAppearance: Bool) -> ProGhosttyTitlebarToastColors {
    if usesDarkAppearance {
      return ProGhosttyTitlebarToastColors(
        background: NSColor(calibratedRed: 0.10, green: 0.28, blue: 0.50, alpha: 1),
        foreground: NSColor(calibratedRed: 0.93, green: 0.97, blue: 1.00, alpha: 1),
        border: NSColor(calibratedRed: 0.25, green: 0.53, blue: 0.84, alpha: 1)
      )
    }

    return ProGhosttyTitlebarToastColors(
      background: NSColor(calibratedRed: 0.80, green: 0.90, blue: 1.00, alpha: 1),
      foreground: NSColor(calibratedRed: 0.06, green: 0.20, blue: 0.38, alpha: 1),
      border: NSColor(calibratedRed: 0.45, green: 0.66, blue: 0.90, alpha: 1)
    )
  }

  public static func error(usesDarkAppearance: Bool) -> ProGhosttyTitlebarToastColors {
    if usesDarkAppearance {
      return ProGhosttyTitlebarToastColors(
        background: NSColor(calibratedRed: 0.44, green: 0.14, blue: 0.13, alpha: 1),
        foreground: NSColor(calibratedRed: 1.00, green: 0.95, blue: 0.94, alpha: 1),
        border: NSColor(calibratedRed: 0.74, green: 0.32, blue: 0.29, alpha: 1)
      )
    }

    return ProGhosttyTitlebarToastColors(
      background: NSColor(calibratedRed: 1.00, green: 0.84, blue: 0.82, alpha: 1),
      foreground: NSColor(calibratedRed: 0.38, green: 0.08, blue: 0.07, alpha: 1),
      border: NSColor(calibratedRed: 0.83, green: 0.43, blue: 0.39, alpha: 1)
    )
  }
}

public struct ProGhosttySettingsThemeColors: Equatable, Sendable {
  public var windowBackground: NSColor
  public var controlBackground: NSColor
  public var textFieldBackground: NSColor
  public var footerBackground: NSColor
  public var primaryText: NSColor
  public var secondaryText: NSColor
  public var tertiaryText: NSColor
  public var separator: NSColor

  public init(
    windowBackground: NSColor,
    controlBackground: NSColor,
    textFieldBackground: NSColor,
    footerBackground: NSColor,
    primaryText: NSColor,
    secondaryText: NSColor,
    tertiaryText: NSColor,
    separator: NSColor
  ) {
    self.windowBackground = windowBackground
    self.controlBackground = controlBackground
    self.textFieldBackground = textFieldBackground
    self.footerBackground = footerBackground
    self.primaryText = primaryText
    self.secondaryText = secondaryText
    self.tertiaryText = tertiaryText
    self.separator = separator
  }
}

public enum ProGhosttySettingsThemePalette {
  public static let light = ProGhosttySettingsThemeColors(
    windowBackground: NSColor(calibratedWhite: 0.965, alpha: 1),
    controlBackground: NSColor(calibratedWhite: 0.995, alpha: 1),
    textFieldBackground: NSColor(calibratedWhite: 1.000, alpha: 1),
    footerBackground: NSColor(calibratedWhite: 0.935, alpha: 1),
    primaryText: NSColor(calibratedWhite: 0.075, alpha: 1),
    secondaryText: NSColor(calibratedWhite: 0.34, alpha: 1),
    tertiaryText: NSColor(calibratedWhite: 0.50, alpha: 1),
    separator: NSColor(calibratedWhite: 0.72, alpha: 1)
  )

  public static let dark = ProGhosttySettingsThemeColors(
    windowBackground: NSColor(calibratedWhite: 0.105, alpha: 1),
    controlBackground: NSColor(calibratedWhite: 0.155, alpha: 1),
    textFieldBackground: NSColor(calibratedWhite: 0.075, alpha: 1),
    footerBackground: NSColor(calibratedWhite: 0.135, alpha: 1),
    primaryText: NSColor(calibratedWhite: 0.900, alpha: 1),
    secondaryText: NSColor(calibratedWhite: 0.660, alpha: 1),
    tertiaryText: NSColor(calibratedWhite: 0.500, alpha: 1),
    separator: NSColor(calibratedWhite: 0.300, alpha: 1)
  )

  /// Soft Dark settings chrome — same blue-black family as terminal `#23272E`.
  public static let softDark = ProGhosttySettingsThemeColors(
    windowBackground: NSColor(calibratedRed: 0.106, green: 0.122, blue: 0.141, alpha: 1), // #1B1F24
    controlBackground: NSColor(calibratedRed: 0.165, green: 0.188, blue: 0.220, alpha: 1), // #2A3038
    textFieldBackground: NSColor(calibratedRed: 0.137, green: 0.153, blue: 0.180, alpha: 1), // #23272E
    footerBackground: NSColor(calibratedRed: 0.125, green: 0.141, blue: 0.165, alpha: 1),
    primaryText: NSColor(calibratedRed: 0.671, green: 0.698, blue: 0.749, alpha: 1), // #ABB2BF
    secondaryText: NSColor(calibratedRed: 0.514, green: 0.549, blue: 0.612, alpha: 1),
    tertiaryText: NSColor(calibratedRed: 0.361, green: 0.388, blue: 0.439, alpha: 1), // #5C6370
    separator: NSColor(calibratedRed: 0.271, green: 0.302, blue: 0.349, alpha: 1)
  )

  /// Soft Light settings chrome — Solarized base2/base3 family.
  /// Primary text uses base02 (not base01) so settings labels clear AA on base3.
  public static let softLight = ProGhosttySettingsThemeColors(
    windowBackground: NSColor(calibratedRed: 0.992, green: 0.965, blue: 0.890, alpha: 1), // #FDF6E3
    controlBackground: NSColor(calibratedRed: 0.933, green: 0.910, blue: 0.835, alpha: 1), // #EEE8D5
    textFieldBackground: NSColor(calibratedRed: 1.000, green: 0.980, blue: 0.925, alpha: 1),
    footerBackground: NSColor(calibratedRed: 0.933, green: 0.910, blue: 0.835, alpha: 1),
    primaryText: NSColor(calibratedRed: 0.027, green: 0.212, blue: 0.259, alpha: 1), // #073642 base02
    secondaryText: NSColor(calibratedRed: 0.345, green: 0.431, blue: 0.459, alpha: 1), // #586E75 base01
    tertiaryText: NSColor(calibratedRed: 0.396, green: 0.482, blue: 0.514, alpha: 1), // #657B83 base00
    separator: NSColor(calibratedRed: 0.576, green: 0.631, blue: 0.631, alpha: 0.55)
  )

  public static func palette(for themeName: String) -> ProGhosttySettingsThemeColors {
    switch ThemeManager.normalizedThemeName(themeName) {
    case "light":
      return light
    case "soft-light":
      return softLight
    case "soft-dark":
      return softDark
    default:
      return dark
    }
  }
}

public enum ProGhosttyOverlayStyle {
  public static let workspaceSwitcherBackdropOpacity: CGFloat = 0
  public static let workspaceSwitcherTerminalBlurRadius: CGFloat = 2.4
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

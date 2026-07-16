import AppKit
import Testing

@testable import ProGhosttyApp

@Suite("Terminal window appearance", .serialized)
struct TerminalWindowAppearanceTests {
  @Test func titlebarSuccessToastUsesLivelyHighContrastColors() {
    let dark = ProGhosttyTitlebarToastPalette.success(usesDarkAppearance: true)
    let light = ProGhosttyTitlebarToastPalette.success(usesDarkAppearance: false)

    #expect(dark.foreground.contrastRatio(against: dark.background) >= 4.5)
    #expect(light.foreground.contrastRatio(against: light.background) >= 4.5)
    #expect(dark.background.greenComponent - dark.background.redComponent >= 0.34)
    #expect(light.background.greenComponent - light.background.redComponent >= 0.22)
  }

  @Test func titlebarStatusToastPalettesStayReadable() {
    for colors in [
      ProGhosttyTitlebarToastPalette.info(usesDarkAppearance: true),
      ProGhosttyTitlebarToastPalette.info(usesDarkAppearance: false),
      ProGhosttyTitlebarToastPalette.error(usesDarkAppearance: true),
      ProGhosttyTitlebarToastPalette.error(usesDarkAppearance: false),
    ] {
      #expect(colors.foreground.contrastRatio(against: colors.background) >= 4.5)
    }
  }

  @Test func settingsSavedTitlebarToastUsesReadableTransientDuration() {
    #expect(ProGhosttyTitlebarToastLifetime.settingsSaved == .transient(2.4))
    #expect(ProGhosttyTitlebarToastLifetime.settingsSaved.dismissDelay == 2.4)
    #expect(ProGhosttyTitlebarToastLifetime.transient(1.8).dismissDelay == 1.8)
  }

  @Test func titlebarToastMetricsUsePixelAlignedCapsuleDrawing() {
    #expect(ProGhosttyTitlebarToastMetrics.capsuleRadius(for: 24) == 12)
    #expect(ProGhosttyTitlebarToastMetrics.borderWidth(backingScaleFactor: 2) == 0.5)
    #expect(ProGhosttyTitlebarToastMetrics.borderWidth(backingScaleFactor: 1) == 1)
    #expect(ProGhosttyTitlebarToastMetrics.borderWidth(backingScaleFactor: 0) == 1)
  }

  @Test func workspaceSwitcherBackdropUsesBlurInsteadOfDimming() {
    #expect(ProGhosttyOverlayStyle.workspaceSwitcherBackdropOpacity == 0)
    #expect(ProGhosttyOverlayStyle.workspaceSwitcherTerminalBlurRadius > 0)
  }

  @Test func settingsThemePalettesUseExplicitReadableLightAndDarkColors() {
    let light = ProGhosttySettingsThemePalette.light
    let dark = ProGhosttySettingsThemePalette.dark

    #expect(light.windowBackground.lightness > 0.90)
    #expect(light.primaryText.lightness < 0.18)
    #expect(light.primaryText.contrastRatio(against: light.windowBackground) >= 10)
    #expect(light.secondaryText.contrastRatio(against: light.windowBackground) >= 4.5)
    #expect(light.primaryText.contrastRatio(against: light.controlBackground) >= 8)
    #expect(light.primaryText.contrastRatio(against: light.textFieldBackground) >= 8)

    #expect(dark.windowBackground.lightness < 0.16)
    #expect(dark.primaryText.lightness > 0.82)
    #expect(dark.primaryText.contrastRatio(against: dark.windowBackground) >= 10)
    #expect(dark.secondaryText.contrastRatio(against: dark.windowBackground) >= 4.5)
    #expect(dark.primaryText.contrastRatio(against: dark.controlBackground) >= 8)
    #expect(dark.primaryText.contrastRatio(against: dark.textFieldBackground) >= 8)
  }

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

  @MainActor @Test func terminalChromePaintsStandardTitlebarHost() throws {
    let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 260))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
    )
    window.contentView = contentView
    window.styleMask.insert(.fullSizeContentView)
    let titlebarHost = try #require(window.standardWindowButton(.closeButton)?.superview)
    titlebarHost.wantsLayer = true
    titlebarHost.layer?.backgroundColor = NSColor.white.cgColor

    let background = NSColor(calibratedWhite: 0.075, alpha: 1)
    ProGhosttyWindowAppearance.applyTerminalChrome(
      to: window,
      backgroundColor: background,
      usesDarkAppearance: true
    )

    #expect(window.appearance?.name == .darkAqua)
    #expect(titlebarHost.layer?.backgroundColor?.sameRGB(as: background.cgColor) == true)
  }

  @MainActor @Test func configurationChromePaintsTitlebarAndContentTogether() throws {
    let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 260))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
      styleMask: [.titled, .closable, .miniaturizable],
      backing: .buffered,
      defer: false
    )
    window.contentView = contentView
    let titlebarHost = try #require(window.contentView?.superview)
    let previous = NSColor(calibratedWhite: 0.12, alpha: 1)
    titlebarHost.wantsLayer = true
    titlebarHost.layer?.backgroundColor = previous.cgColor

    let background = NSColor(calibratedWhite: 0.96, alpha: 1)
    ProGhosttyWindowAppearance.applyConfigurationChrome(
      to: window,
      backgroundColor: background,
      usesDarkAppearance: false
    )

    #expect(window.appearance?.name == .aqua)
    #expect(window.titlebarAppearsTransparent)
    #expect(window.titlebarSeparatorStyle == .none)
    #expect(window.backgroundColor.sameRGB(as: background))
    #expect(window.contentView?.layer?.backgroundColor?.sameRGB(as: background.cgColor) == true)
    #expect(window.contentView?.superview?.layer?.backgroundColor?.sameRGB(as: background.cgColor) == true)

    let dark = NSColor(calibratedWhite: 0.10, alpha: 1)
    ProGhosttyWindowAppearance.applyConfigurationChrome(
      to: window,
      backgroundColor: dark,
      usesDarkAppearance: true
    )

    #expect(window.appearance?.name == .darkAqua)
    #expect(window.backgroundColor.sameRGB(as: dark))
    #expect(window.contentView?.layer?.backgroundColor?.sameRGB(as: dark.cgColor) == true)
    #expect(window.contentView?.superview?.layer?.backgroundColor?.sameRGB(as: dark.cgColor) == true)
  }
}

private extension NSColor {
  func contrastRatio(against other: NSColor) -> CGFloat {
    let lhs = relativeLuminance
    let rhs = other.relativeLuminance
    let lighter = max(lhs, rhs)
    let darker = min(lhs, rhs)
    return (lighter + 0.05) / (darker + 0.05)
  }

  func sameRGB(as other: NSColor) -> Bool {
    guard let lhs = usingColorSpace(.deviceRGB), let rhs = other.usingColorSpace(.deviceRGB) else {
      return false
    }
    return abs(lhs.redComponent - rhs.redComponent) < 0.001
      && abs(lhs.greenComponent - rhs.greenComponent) < 0.001
      && abs(lhs.blueComponent - rhs.blueComponent) < 0.001
  }

  private var relativeLuminance: CGFloat {
    let rgb = usingColorSpace(.deviceRGB) ?? self
    func channel(_ value: CGFloat) -> CGFloat {
      value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * channel(rgb.redComponent)
      + 0.7152 * channel(rgb.greenComponent)
      + 0.0722 * channel(rgb.blueComponent)
  }

  var lightness: CGFloat {
    let rgb = usingColorSpace(.deviceRGB) ?? self
    return (rgb.redComponent + rgb.greenComponent + rgb.blueComponent) / 3
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

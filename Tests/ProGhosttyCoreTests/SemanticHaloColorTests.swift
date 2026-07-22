import AppKit
import Testing

@testable import ProGhosttyCore

@Suite("Semantic halo color")
struct SemanticHaloColorTests {
  @Test func lightBackgroundHaloGoesDarker() {
    let bg = NSColor(calibratedWhite: 0.96, alpha: 1)
    #expect(SemanticHaloColor.goesDarker(forBackground: bg))
    let halo = SemanticHaloColor.color(forBackground: bg)
    let opaqueHalo = halo.withAlphaComponent(1)
    #expect(luminance(opaqueHalo) < luminance(bg))
  }

  @Test func darkBackgroundHaloGoesLighter() {
    let bg = NSColor(calibratedWhite: 0.09, alpha: 1)
    #expect(!SemanticHaloColor.goesDarker(forBackground: bg))
    let halo = SemanticHaloColor.color(forBackground: bg)
    let opaqueHalo = halo.withAlphaComponent(1)
    #expect(luminance(opaqueHalo) > luminance(bg))
  }

  @Test func haloStaysSubtleLowAlpha() {
    let halo = SemanticHaloColor.color(forBackground: NSColor(calibratedWhite: 0.09, alpha: 1))
    let rgba = halo.usingColorSpace(.deviceRGB)!
    #expect(rgba.alphaComponent <= 0.12)
    #expect(rgba.alphaComponent > 0)
  }

  @Test func softDarkThemeGetsLighterHalo() {
    // #23272E → dark family → halo lighter.
    let bg = NSColor(calibratedRed: 0.137, green: 0.153, blue: 0.180, alpha: 1)
    #expect(!SemanticHaloColor.goesDarker(forBackground: bg))
    let halo = SemanticHaloColor.color(forBackground: bg).withAlphaComponent(1)
    #expect(luminance(halo) > luminance(bg))
  }

  @Test func softLightThemeGetsDarkerHalo() {
    // Solarized cream #FDF6E3 → light family → halo darker.
    let bg = NSColor(calibratedRed: 0.992, green: 0.965, blue: 0.890, alpha: 1)
    #expect(SemanticHaloColor.goesDarker(forBackground: bg))
    let halo = SemanticHaloColor.color(forBackground: bg).withAlphaComponent(1)
    #expect(luminance(halo) < luminance(bg))
  }

  @Test func largerStepPushesFurtherFromBackground() {
    let bg = NSColor(calibratedWhite: 0.09, alpha: 1)
    let small = SemanticHaloColor.color(forBackground: bg, tuning: .init(luminanceStep: 0.05)).withAlphaComponent(1)
    let large = SemanticHaloColor.color(forBackground: bg, tuning: .init(luminanceStep: 0.30)).withAlphaComponent(1)
    #expect(luminance(large) > luminance(small))
  }

  private func luminance(_ color: NSColor) -> CGFloat {
    let rgb = color.usingColorSpace(.deviceRGB)!
    return 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
  }
}

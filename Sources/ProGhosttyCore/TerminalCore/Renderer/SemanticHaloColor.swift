import AppKit
import Foundation

/// Derives the **Semantic Halo** color for a hovered URL from the background it
/// sits on, per `URL_SEMANTIC_OBJECT_SPEC.md` §4.2.1.
///
/// The halo is never a fixed white wash. It is nudged in luminance **away** from
/// the local background — light backgrounds get a slightly darker halo, dark
/// backgrounds a slightly lighter one — so it reads as the same barely-visible
/// "breath" in every theme. Color is taken from the *actual local background*
/// under the run (per-cell, not just theme default) so it stays coherent over
/// colored or inverse cells.
///
/// Pure and AppKit-color-only (no rendering); the feathered falloff itself is a
/// rendering concern layered on top of this base color + alpha.
public enum SemanticHaloColor {
  /// Tuning knobs. Defaults are intentionally subtle — "just visible", never a box.
  public struct Tuning: Equatable, Sendable {
    /// Perceptual luminance step to push away from the background, in [0,1].
    public var luminanceStep: CGFloat
    /// Effective alpha ceiling of the halo fill center.
    public var alpha: CGFloat
    /// Background luminance at/above which we treat it as "light" and go darker.
    public var lightThreshold: CGFloat

    public init(luminanceStep: CGFloat = 0.14, alpha: CGFloat = 0.09, lightThreshold: CGFloat = 0.5) {
      self.luminanceStep = luminanceStep
      self.alpha = alpha
      self.lightThreshold = lightThreshold
    }

    public static let `default` = Tuning()
  }

  /// The halo base color (with its center alpha) for a given local background.
  ///
  /// - Light background (`luminance >= lightThreshold`) → blend toward black.
  /// - Dark background → blend toward white.
  /// The blend amount is `luminanceStep`, kept small so contrast stays slight.
  public static func color(
    forBackground background: NSColor,
    tuning: Tuning = .default
  ) -> NSColor {
    let rgb = background.usingColorSpace(.deviceRGB) ?? background
    let isLight = rgb.relativeHaloLuminance >= tuning.lightThreshold
    let target: NSColor = isLight ? .black : .white
    let step = min(1, max(0, tuning.luminanceStep))
    let blended = rgb.blendedHalo(toward: target, amount: step)
    return blended.withAlphaComponent(min(1, max(0, tuning.alpha)))
  }

  /// Whether the derived halo goes darker (true) or lighter (false) than `background`.
  /// Exposed for tests and for reasoning about contrast direction.
  public static func goesDarker(forBackground background: NSColor, tuning: Tuning = .default) -> Bool {
    let rgb = background.usingColorSpace(.deviceRGB) ?? background
    return rgb.relativeHaloLuminance >= tuning.lightThreshold
  }
}

private extension NSColor {
  /// WCAG relative luminance (duplicated locally so this file has no cross-file
  /// dependency on the private helper in `TerminalSurfaceStyle`).
  var relativeHaloLuminance: CGFloat {
    let rgb = usingColorSpace(.deviceRGB) ?? self
    func channel(_ value: CGFloat) -> CGFloat {
      value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * channel(rgb.redComponent)
      + 0.7152 * channel(rgb.greenComponent)
      + 0.0722 * channel(rgb.blueComponent)
  }

  func blendedHalo(toward target: NSColor, amount: CGFloat) -> NSColor {
    let lhs = usingColorSpace(.deviceRGB) ?? self
    let rhs = target.usingColorSpace(.deviceRGB) ?? target
    let amount = min(1, max(0, amount))
    return NSColor(
      calibratedRed: lhs.redComponent + (rhs.redComponent - lhs.redComponent) * amount,
      green: lhs.greenComponent + (rhs.greenComponent - lhs.greenComponent) * amount,
      blue: lhs.blueComponent + (rhs.blueComponent - lhs.blueComponent) * amount,
      alpha: 1
    )
  }
}

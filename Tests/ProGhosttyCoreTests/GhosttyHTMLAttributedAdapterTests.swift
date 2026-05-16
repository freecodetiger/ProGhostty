import AppKit
import Foundation
import Testing

@testable import ProGhosttyCore

@Suite("Ghostty HTML attributed adapter")
struct GhosttyHTMLAttributedAdapterTests {
  @MainActor @Test func normalizesGhosttyPaletteVariablesIntoForegroundColors() throws {
    let attributed = try GhosttyHTMLAttributedAdapter(
      palette: .dark,
      fontFamily: "Menlo",
      fontSize: 14
    ).attributedString(fromHTML:
      """
      <style>:root{--vt-palette-8: #777777;}</style><div style="font-family: monospace; white-space: pre;">typed <div style="display: inline;color: var(--vt-palette-8);">suggestion</div></div>
      """,
      isFocused: true
    )

    let text = attributed.string as NSString
    let normalIndex = text.range(of: "typed").location
    let suggestionIndex = text.range(of: "suggestion").location
    let normalColor = try #require(attributed.attribute(.foregroundColor, at: normalIndex, effectiveRange: nil) as? NSColor)
    let suggestionColor = try #require(attributed.attribute(.foregroundColor, at: suggestionIndex, effectiveRange: nil) as? NSColor)

    #expect(suggestionColor.lightness < normalColor.lightness)
  }

  @MainActor @Test func appliesFaintOpacityToForegroundColor() throws {
    let attributed = try GhosttyHTMLAttributedAdapter(
      palette: .dark,
      fontFamily: "Menlo",
      fontSize: 14
    ).attributedString(fromHTML:
      """
      <div style="font-family: monospace; white-space: pre;">typed <div style="display: inline;opacity: 0.5;">suggestion</div></div>
      """,
      isFocused: true
    )

    let text = attributed.string as NSString
    let normalIndex = text.range(of: "typed").location
    let suggestionIndex = text.range(of: "suggestion").location
    let normalColor = try #require(attributed.attribute(.foregroundColor, at: normalIndex, effectiveRange: nil) as? NSColor)
    let suggestionColor = try #require(attributed.attribute(.foregroundColor, at: suggestionIndex, effectiveRange: nil) as? NSColor)

    #expect(suggestionColor.lightness < normalColor.lightness)
  }

  @MainActor @Test func mapsDecorationAndBackgroundStylesToAppKitAttributes() throws {
    let attributed = try GhosttyHTMLAttributedAdapter(
      palette: .dark,
      fontFamily: "Menlo",
      fontSize: 14
    ).attributedString(fromHTML:
      """
      <div style="font-family: monospace; white-space: pre;"><div style="display: inline;background-color: rgb(16, 32, 48);text-decoration-line: underline line-through;">decorated</div></div>
      """,
      isFocused: true
    )

    let index = (attributed.string as NSString).range(of: "decorated").location
    let underline = try #require(attributed.attribute(.underlineStyle, at: index, effectiveRange: nil) as? Int)
    let strike = try #require(attributed.attribute(.strikethroughStyle, at: index, effectiveRange: nil) as? Int)
    let background = try #require(attributed.attribute(.backgroundColor, at: index, effectiveRange: nil) as? NSColor)

    #expect(underline == NSUnderlineStyle.single.rawValue)
    #expect(strike == NSUnderlineStyle.single.rawValue)
    #expect(background.sameRGB(as: NSColor(calibratedRed: 16 / 255, green: 32 / 255, blue: 48 / 255, alpha: 1)))
  }

  @MainActor @Test func mapsInverseAndInvisibleStyles() throws {
    let attributed = try GhosttyHTMLAttributedAdapter(
      palette: .dark,
      fontFamily: "Menlo",
      fontSize: 14
    ).attributedString(fromHTML:
      """
      <div style="font-family: monospace; white-space: pre;"><div style="display: inline;filter: invert(100%);">inverse</div><div style="display: inline;visibility: hidden;">hidden</div></div>
      """,
      isFocused: true
    )

    let text = attributed.string as NSString
    let inverseIndex = text.range(of: "inverse").location
    let hiddenIndex = text.range(of: "hidden").location
    let inverseForeground = try #require(attributed.attribute(.foregroundColor, at: inverseIndex, effectiveRange: nil) as? NSColor)
    let inverseBackground = try #require(attributed.attribute(.backgroundColor, at: inverseIndex, effectiveRange: nil) as? NSColor)
    let hiddenForeground = try #require(attributed.attribute(.foregroundColor, at: hiddenIndex, effectiveRange: nil) as? NSColor)

    #expect(inverseForeground.sameRGB(as: TerminalSurfacePalette.dark.background))
    #expect(inverseBackground.sameRGB(as: TerminalSurfacePalette.dark.foreground))
    #expect(hiddenForeground.sameRGB(as: TerminalSurfacePalette.dark.background))
  }

  @MainActor @Test func decodesGhosttyHTMLEntitiesWithoutUsingTerminalSemantics() throws {
    let attributed = try GhosttyHTMLAttributedAdapter(
      palette: .dark,
      fontFamily: "Menlo",
      fontSize: 14
    ).attributedString(fromHTML:
      """
      <div style="font-family: monospace; white-space: pre;">&lt;tag&gt;&amp;&quot;&#39;&#9584;</div>
      """,
      isFocused: true
    )

    #expect(attributed.string == "<tag>&\"'╰")
  }

  @MainActor @Test func mapsHyperlinksToAppKitLinkAttributes() throws {
    let attributed = try GhosttyHTMLAttributedAdapter(
      palette: .dark,
      fontFamily: "Menlo",
      fontSize: 14
    ).attributedString(fromHTML:
      """
      <div style="font-family: monospace; white-space: pre;"><a href="https://example.com?a=1&amp;b=2">link</a> plain</div>
      """,
      isFocused: true
    )

    let text = attributed.string as NSString
    let linkIndex = text.range(of: "link").location
    let plainIndex = text.range(of: "plain").location

    #expect(attributed.attribute(.link, at: linkIndex, effectiveRange: nil) as? String == "https://example.com?a=1&b=2")
    #expect(attributed.attribute(.link, at: plainIndex, effectiveRange: nil) == nil)
  }

  @MainActor @Test func degradesRichUnderlineStylesToReadableUnderline() throws {
    let attributed = try GhosttyHTMLAttributedAdapter(
      palette: .dark,
      fontFamily: "Menlo",
      fontSize: 14
    ).attributedString(fromHTML:
      """
      <div style="font-family: monospace; white-space: pre;"><div style="display: inline;text-decoration-line: underline;text-decoration-style: wavy;">curly</div></div>
      """,
      isFocused: true
    )

    let index = (attributed.string as NSString).range(of: "curly").location
    let underline = try #require(attributed.attribute(.underlineStyle, at: index, effectiveRange: nil) as? Int)

    #expect(underline == NSUnderlineStyle.single.rawValue)
  }

  @MainActor @Test func preservesWideAndComposedCharactersAsText() throws {
    let attributed = try GhosttyHTMLAttributedAdapter(
      palette: .dark,
      fontFamily: "Menlo",
      fontSize: 14
    ).attributedString(fromHTML:
      """
      <div style="font-family: monospace; white-space: pre;">中文 e&#769; 😀</div>
      """,
      isFocused: true
    )

    #expect(attributed.string == "中文 é 😀")
  }

  @MainActor @Test func reusesCachedResultForIdenticalInput() throws {
    let adapter = GhosttyHTMLAttributedAdapter(
      palette: .dark,
      fontFamily: "Menlo",
      fontSize: 14
    )
    let html = "<div style=\"font-family: monospace; white-space: pre;\">cached</div>"

    let first = try adapter.attributedString(fromHTML: html, isFocused: true)
    let second = try adapter.attributedString(fromHTML: html, isFocused: true)

    #expect(first === second)
  }
}

private extension NSColor {
  var lightness: CGFloat {
    guard let rgb = usingColorSpace(.deviceRGB) else { return 0 }
    return (rgb.redComponent + rgb.greenComponent + rgb.blueComponent) / 3
  }

  func sameRGB(as other: NSColor) -> Bool {
    guard let lhs = usingColorSpace(.deviceRGB), let rhs = other.usingColorSpace(.deviceRGB) else {
      return false
    }
    return abs(lhs.redComponent - rhs.redComponent) < 0.001
      && abs(lhs.greenComponent - rhs.greenComponent) < 0.001
      && abs(lhs.blueComponent - rhs.blueComponent) < 0.001
  }
}

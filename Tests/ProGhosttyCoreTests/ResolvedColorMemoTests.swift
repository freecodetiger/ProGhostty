import AppKit
import Testing

@testable import ProGhosttyCore

/// `ResolvedColorMemo` exists because resolving a cell's colors runs the WCAG
/// minimum-contrast pass (up to 14 rounds of NSColor → deviceRGB conversion),
/// and a full-screen TUI redraws ~1k cells per frame sharing a handful of
/// distinct color pairs.
///
/// The failure this guards against is a **stale key**: if a field the resolver
/// reads is missing from the key, cells that differ only in that field silently
/// render with the wrong color. `everyResolverInputParticipatesInTheKey` is the
/// test that catches it.
@Suite("Resolved color memo")
struct ResolvedColorMemoTests {
  private let palette = TerminalSurfacePalette.dark

  private func makeCell(
    foreground: GhosttyTerminalFrame.RGB = .init(r: 200, g: 200, b: 200),
    background: GhosttyTerminalFrame.RGB = .init(r: 10, g: 10, b: 10),
    faint: Bool = false,
    inverse: Bool = false,
    usesDefaultForeground: Bool = false,
    usesDefaultBackground: Bool = false
  ) -> GhosttyTerminalFrame.Cell {
    GhosttyTerminalFrame.Cell(
      scalar: "a",
      foreground: foreground,
      background: background,
      bold: false, italic: false, faint: faint, underline: false,
      inverse: inverse,
      usesDefaultForeground: usesDefaultForeground,
      usesDefaultBackground: usesDefaultBackground
    )
  }

  /// Every appearance that must occupy its own cache entry: the base cell plus
  /// one variant per field the resolver reads.
  private var distinctAppearances: [GhosttyTerminalFrame.Cell] {
    [
      makeCell(),
      makeCell(foreground: .init(r: 201, g: 200, b: 200)),
      makeCell(background: .init(r: 11, g: 10, b: 10)),
      makeCell(faint: true),
      makeCell(inverse: true),
      makeCell(usesDefaultForeground: true),
      makeCell(usesDefaultBackground: true),
    ]
  }

  @Test func repeatedAppearanceIsResolvedOnce() {
    var memo = ResolvedColorMemo()
    for _ in 0..<200 {
      _ = memo.colors(for: makeCell(), palette: palette, isFocused: true)
    }
    #expect(memo.cachedEntryCount == 1)
  }

  @Test func everyResolverInputParticipatesInTheKey() {
    var memo = ResolvedColorMemo()
    for cell in distinctAppearances {
      _ = memo.colors(for: cell, palette: palette, isFocused: true)
    }
    #expect(memo.cachedEntryCount == distinctAppearances.count)

    // `isFocused` feeds the inactive-foreground blend, so it is part of the key.
    _ = memo.colors(for: makeCell(), palette: palette, isFocused: false)
    #expect(memo.cachedEntryCount == distinctAppearances.count + 1)
  }

  @Test func memoizedColorsMatchTheResolver() {
    var memo = ResolvedColorMemo()
    for cell in distinctAppearances {
      for isFocused in [true, false] {
        let memoized = memo.colors(for: cell, palette: palette, isFocused: isFocused)
        let direct = TerminalColorResolver.resolvedColors(
          for: cell,
          palette: palette,
          isFocused: isFocused
        )
        #expect(memoized.foreground == direct.foreground)
        #expect(memoized.background == direct.background)
      }
    }
  }

  @Test func paletteChangeClearsTheCache() {
    var memo = ResolvedColorMemo()
    _ = memo.colors(for: makeCell(), palette: .dark, isFocused: true)
    #expect(memo.cachedEntryCount == 1)

    _ = memo.colors(for: makeCell(), palette: .light, isFocused: true)
    #expect(memo.cachedEntryCount == 1)
    // A cell with default foreground/background takes its colors from the
    // palette, so switching themes must produce different colors.
    let darkCell = makeCell(usesDefaultForeground: true, usesDefaultBackground: true)
    let onDark = memo.colors(for: darkCell, palette: .dark, isFocused: true)
    let onLight = memo.colors(for: darkCell, palette: .light, isFocused: true)
    #expect(onDark.foreground != onLight.foreground)
  }
}

import AppKit

extension TerminalGridSizer {
  /// Grid size for the text-fallback surface, derived from font metrics.
  ///
  /// Owns the cell-metric math that previously lived in the App layer's
  /// fallback path (debt spec D3 smell fix): Core is the single owner of cell
  /// geometry, including the fallback derivation.
  public static func gridSize(
    for surfaceSize: CGSize,
    font: NSFont,
    textContainerInset: CGSize,
    scale: CGFloat
  ) -> TerminalGridSize {
    let sampleWidth = max(1, ceil(("W" as NSString).size(withAttributes: [.font: font]).width * scale))
    let lineHeight = max(1, ceil((font.ascender - font.descender + font.leading) * scale))
    let contentWidth = max(1, (surfaceSize.width - textContainerInset.width * 2) * scale)
    let contentHeight = max(1, (surfaceSize.height - textContainerInset.height * 2) * scale)
    return TerminalGridSize(
      rows: max(1, Int(contentHeight / lineHeight)),
      cols: max(2, Int(contentWidth / sampleWidth))
    )
  }

  /// Grid size for the initial PTY launch, matching the terminal's live cell
  /// metrics (content inset 14×12 + monospaced cell size). The shell's
  /// `$COLUMNS`/`$LINES` then match the real viewport from the first prompt,
  /// instead of the old hardcoded `24×80` placeholder that the shell used
  /// before the first resize (which wrapped prompt-clearing spaces on narrow
  /// windows and left blank rows at the top).
  public static func initialGridSize(
    surfaceSize: CGSize,
    fontFamily: String,
    fontSize: CGFloat,
    scale: CGFloat
  ) -> TerminalGridSize {
    let font = NSFont(name: fontFamily, size: fontSize)
      ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
    let cellWidth = max(1, ceil(("W" as NSString).size(withAttributes: [.font: font]).width))
    let cellHeight = max(1, ceil(font.ascender - font.descender + font.leading))
    return gridSize(
      for: surfaceSize,
      cellSize: CGSize(width: cellWidth, height: cellHeight),
      inset: CGSize(width: 14, height: 12),
      scale: scale
    )
  }
}

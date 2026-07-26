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
}

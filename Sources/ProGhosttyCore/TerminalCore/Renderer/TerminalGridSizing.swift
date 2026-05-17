import CoreGraphics

public struct TerminalGridSize: Equatable, Sendable {
  public var rows: Int
  public var cols: Int

  public init(rows: Int, cols: Int) {
    self.rows = rows
    self.cols = cols
  }
}

public enum TerminalGridSizer {
  public static func gridSize(
    for surfaceSize: CGSize,
    cellSize: CGSize,
    inset: CGSize,
    scale: CGFloat
  ) -> TerminalGridSize {
    let effectiveScale = max(1, scale)
    let contentWidth = max(1, (surfaceSize.width - inset.width * 2) * effectiveScale)
    let contentHeight = max(1, (surfaceSize.height - inset.height * 2) * effectiveScale)
    return TerminalGridSize(
      rows: max(1, Int(contentHeight / max(1, ceil(cellSize.height * effectiveScale)))),
      cols: max(2, Int(contentWidth / max(1, ceil(cellSize.width * effectiveScale))))
    )
  }
}

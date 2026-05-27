import AppKit
import Foundation

public struct MetalTerminalRenderPlan: Equatable, Sendable {
  public let presentation: TerminalRenderFramePresentation
  public let viewportRows: Int
  public let cols: Int
  public let overscanTopRows: Int
  public let overscanBottomRows: Int
  public let pixelRemainderY: CGFloat
  public let dirtyRows: Set<Int>
  public let dirtyCellRanges: [MetalCellDirtyRange]
  public let cellSize: CGSize
  public let backingScale: CGFloat
  public let isFocused: Bool

  public init(
    presentation: TerminalRenderFramePresentation,
    viewportRows: Int,
    cols: Int,
    overscanTopRows: Int,
    overscanBottomRows: Int,
    pixelRemainderY: CGFloat,
    dirtyRows: Set<Int>,
    dirtyCellRanges: [MetalCellDirtyRange] = [],
    cellSize: CGSize,
    backingScale: CGFloat,
    isFocused: Bool
  ) {
    self.presentation = presentation
    self.viewportRows = viewportRows
    self.cols = cols
    self.overscanTopRows = overscanTopRows
    self.overscanBottomRows = overscanBottomRows
    self.pixelRemainderY = pixelRemainderY
    self.dirtyRows = dirtyRows
    self.dirtyCellRanges = dirtyCellRanges
    self.cellSize = cellSize
    self.backingScale = backingScale
    self.isFocused = isFocused
  }
}

public enum MetalTerminalFrameEncoder {
  public static func encode(
    _ renderFrame: TerminalRenderFrame,
    pixelRemainderY: CGFloat,
    dirtyRows: Set<Int>,
    dirtyCellRanges: [MetalCellDirtyRange] = [],
    cellSize: CGSize,
    backingScale: CGFloat
  ) -> MetalTerminalRenderPlan {
    let frame = renderFrame.frame
    return MetalTerminalRenderPlan(
      presentation: renderFrame.presentation,
      viewportRows: frame.rows,
      cols: frame.cols,
      overscanTopRows: renderFrame.scrollFrame?.overscanTop.count ?? 0,
      overscanBottomRows: renderFrame.scrollFrame?.overscanBottom.count ?? 0,
      pixelRemainderY: pixelRemainderY,
      dirtyRows: dirtyRows,
      dirtyCellRanges: dirtyCellRanges,
      cellSize: cellSize,
      backingScale: backingScale,
      isFocused: renderFrame.isFocused
    )
  }
}

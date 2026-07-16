import AppKit
import Foundation

public enum MetalOverlayKind: Sendable {
  case cursor
  case selection
  case linkHover
  case markedText
}

public enum MetalOverlayPhase: Sendable {
  case beneathGlyphs
  case aboveGlyphs
}

public struct MetalOverlayPrimitive: Equatable, Sendable {
  public let kind: MetalOverlayKind
  public let phase: MetalOverlayPhase
  public let rect: CGRect
  public let color: SIMD4<Float>

  public init(kind: MetalOverlayKind, phase: MetalOverlayPhase, rect: CGRect, color: SIMD4<Float>) {
    self.kind = kind
    self.phase = phase
    self.rect = rect
    self.color = color
  }
}

public typealias MetalSelectionCellRange = GridSelectionCellRange
public typealias MetalLinkHoverCellRange = GridSelectionCellRange
public typealias MetalMarkedTextOverlay = GridMarkedTextOverlay

public enum MetalOverlayBuffer {
  public static func makeOverlays(
    renderFrame: TerminalRenderFrame,
    plan: MetalTerminalRenderPlan,
    palette: TerminalSurfacePalette = .dark,
    markedTextActive: Bool = false,
    selectedRows: Set<Int> = [],
    selectedCellRanges: [MetalSelectionCellRange] = [],
    selectionRowsOffset: Int = 0,
    linkHoverRows: Set<Int> = [],
    linkHoverCellRanges: [MetalLinkHoverCellRange] = [],
    cursorOverlay: MetalMarkedTextOverlay? = nil,
    markedTextOverlay: MetalMarkedTextOverlay? = nil,
    imeCompositionCursorOverlay: MetalMarkedTextOverlay? = nil,
    markedTextRowsOffset: Int = 0,
    contentInset: CGSize = CGSize(width: 14, height: 12),
    pixelRemainderY: CGFloat? = nil
  ) -> [MetalOverlayPrimitive] {
    let frame = renderFrame.expandedFrame
    let pixelScale = plan.backingScale
    let cellSize = CGSize(
      width: plan.cellSize.width * pixelScale,
      height: plan.cellSize.height * pixelScale
    )
    let inset = CGSize(
      width: contentInset.width * pixelScale,
      height: contentInset.height * pixelScale
    )
    let effectivePixelRemainderY = pixelRemainderY ?? plan.pixelRemainderY
    let translationY = -CGFloat(plan.overscanTopRows) * cellSize.height + effectivePixelRemainderY * pixelScale
    let cursorRow = cursorOverlay.map { $0.row + markedTextRowsOffset }
      ?? renderFrame.scrollFrame.map { $0.overscanTop.count + $0.viewport.cursorY }
      ?? frame.cursorY
    let cursorCol = cursorOverlay?.col ?? frame.cursorX
    var overlays: [MetalOverlayPrimitive] = []

    if frame.cursorVisible && renderFrame.isFocused && !markedTextActive {
      let cursorRect = cellRect(
        row: cursorRow,
        col: cursorCol,
        cellSize: cellSize,
        inset: inset,
        translationY: translationY
      )
      switch frame.cursorShape {
      case .block:
        overlays.append(
          MetalOverlayPrimitive(
            kind: .cursor,
            phase: .beneathGlyphs,
            rect: cursorRect,
            color: palette.cursorBackground.metalRGBA
          )
        )
      case .bar:
        overlays.append(
          MetalOverlayPrimitive(
            kind: .cursor,
            phase: .aboveGlyphs,
            rect: CGRect(
              x: cursorRect.minX,
              y: cursorRect.minY,
              width: max(1.5, cursorRect.width * 0.12),
              height: cursorRect.height
            ),
            color: palette.cursorBackground.metalRGBA
          )
        )
      case .underline:
        overlays.append(
          MetalOverlayPrimitive(
            kind: .cursor,
            phase: .aboveGlyphs,
            rect: CGRect(
              x: cursorRect.minX,
              y: cursorRect.maxY - max(1.5, cursorRect.height * 0.12),
              width: cursorRect.width,
              height: max(1.5, cursorRect.height * 0.12)
            ),
            color: palette.cursorBackground.metalRGBA
          )
        )
      case .hollowBlock:
        let stroke = max(1.5, cursorRect.width * 0.09)
        overlays.append(contentsOf: [
          MetalOverlayPrimitive(
            kind: .cursor,
            phase: .aboveGlyphs,
            rect: CGRect(x: cursorRect.minX, y: cursorRect.minY, width: cursorRect.width, height: stroke),
            color: palette.cursorBackground.metalRGBA
          ),
          MetalOverlayPrimitive(
            kind: .cursor,
            phase: .aboveGlyphs,
            rect: CGRect(x: cursorRect.minX, y: cursorRect.maxY - stroke, width: cursorRect.width, height: stroke),
            color: palette.cursorBackground.metalRGBA
          ),
          MetalOverlayPrimitive(
            kind: .cursor,
            phase: .aboveGlyphs,
            rect: CGRect(x: cursorRect.minX, y: cursorRect.minY, width: stroke, height: cursorRect.height),
            color: palette.cursorBackground.metalRGBA
          ),
          MetalOverlayPrimitive(
            kind: .cursor,
            phase: .aboveGlyphs,
            rect: CGRect(x: cursorRect.maxX - stroke, y: cursorRect.minY, width: stroke, height: cursorRect.height),
            color: palette.cursorBackground.metalRGBA
          ),
        ])
      }
    }

    if markedTextActive, let imeCompositionCursorOverlay {
      let cursorRect = cellRect(
        row: imeCompositionCursorOverlay.row + markedTextRowsOffset,
        col: imeCompositionCursorOverlay.col,
        cellSize: cellSize,
        inset: inset,
        translationY: translationY
      )
      overlays.append(
        MetalOverlayPrimitive(
          kind: .cursor,
          phase: .aboveGlyphs,
          rect: cursorRect,
          color: palette.background.metalRGBA
        )
      )
    }

    let resolvedSelectionRanges = selectedCellRanges.isEmpty
      ? selectedRows.sorted().map { row in
        MetalSelectionCellRange(row: row, cols: 0..<max(0, frame.cols))
      }
      : selectedCellRanges

    for range in resolvedSelectionRanges {
      guard !range.cols.isEmpty else { continue }
      let selectedRow = range.row + selectionRowsOffset
      let clampedLower = min(max(0, range.cols.lowerBound), max(0, frame.cols))
      let clampedUpper = min(max(clampedLower, range.cols.upperBound), max(0, frame.cols))
      guard clampedLower < clampedUpper else { continue }
      overlays.append(
        MetalOverlayPrimitive(
          kind: .selection,
          phase: .aboveGlyphs,
          rect: cellRangeRect(
            row: selectedRow,
            cols: clampedLower..<clampedUpper,
            cellSize: cellSize,
            inset: inset,
            translationY: translationY
          ),
          color: palette.cursorBackground.withAlphaComponent(0.18).metalRGBA
        )
      )
    }

    let resolvedLinkHoverRanges = linkHoverCellRanges.isEmpty
      ? linkHoverRows.sorted().map { row in
        MetalLinkHoverCellRange(row: row, cols: 0..<max(0, frame.cols))
      }
      : linkHoverCellRanges

    for range in resolvedLinkHoverRanges {
      guard !range.cols.isEmpty else { continue }
      let hoverRow = range.row + selectionRowsOffset
      let clampedLower = min(max(0, range.cols.lowerBound), max(0, frame.cols))
      let clampedUpper = min(max(clampedLower, range.cols.upperBound), max(0, frame.cols))
      guard clampedLower < clampedUpper else { continue }
      let hoverRect = cellRangeRect(
        row: hoverRow,
        cols: clampedLower..<clampedUpper,
        cellSize: cellSize,
        inset: inset,
        translationY: translationY
      )
      overlays.append(
        MetalOverlayPrimitive(
          kind: .linkHover,
          phase: .aboveGlyphs,
        rect: CGRect(
          x: hoverRect.minX,
          y: hoverRect.maxY - max(1, cellSize.height * 0.10),
          width: hoverRect.width,
          height: max(1, cellSize.height * 0.10)
          ),
          color: palette.cursorBackground.withAlphaComponent(0.32).metalRGBA
        )
      )
    }

    if let markedTextOverlay {
      let markedRow = markedTextOverlay.row + markedTextRowsOffset
      let origin = cellRect(
        row: markedRow,
        col: markedTextOverlay.col,
        cellSize: cellSize,
        inset: inset,
        translationY: translationY
      )
      let maxWidth = max(0, CGFloat(frame.cols) * cellSize.width - CGFloat(max(0, markedTextOverlay.col)) * cellSize.width)
      let width = min(maxWidth, max(cellSize.width, markedTextOverlay.width * pixelScale))
      if width > 0 {
        overlays.append(
          MetalOverlayPrimitive(
            kind: .markedText,
            phase: .aboveGlyphs,
            rect: CGRect(x: origin.minX, y: origin.minY, width: width, height: cellSize.height),
            color: palette.cursorBackground.withAlphaComponent(0.12).metalRGBA
          )
        )
        overlays.append(
          MetalOverlayPrimitive(
            kind: .markedText,
            phase: .aboveGlyphs,
            rect: CGRect(
              x: origin.minX + 2 * pixelScale,
              y: origin.maxY - max(1, cellSize.height * 0.10),
              width: max(0, width - 4 * pixelScale),
              height: max(1, cellSize.height * 0.10)
            ),
            color: palette.foreground.withAlphaComponent(plan.isFocused ? 0.92 : 0.62).metalRGBA
          )
        )
      }
    }

    return overlays
  }

  private static func cellRect(row: Int, col: Int, cellSize: CGSize, inset: CGSize) -> CGRect {
    cellRect(row: row, col: col, cellSize: cellSize, inset: inset, translationY: 0)
  }

  private static func cellRect(
    row: Int,
    col: Int,
    cellSize: CGSize,
    inset: CGSize,
    translationY: CGFloat
  ) -> CGRect {
    CGRect(
      x: inset.width + CGFloat(max(0, col)) * cellSize.width,
      y: inset.height + CGFloat(max(0, row)) * cellSize.height + translationY,
      width: cellSize.width,
      height: cellSize.height
    )
  }

  private static func rowRect(row: Int, cols: Int, cellSize: CGSize, inset: CGSize) -> CGRect {
    rowRect(row: row, cols: cols, cellSize: cellSize, inset: inset, translationY: 0)
  }

  private static func rowRect(row: Int, cols: Int, cellSize: CGSize, inset: CGSize, translationY: CGFloat) -> CGRect {
    CGRect(
      x: inset.width,
      y: inset.height + CGFloat(max(0, row)) * cellSize.height + translationY,
      width: CGFloat(max(0, cols)) * cellSize.width,
      height: cellSize.height
    )
  }

  private static func cellRangeRect(row: Int, cols: Range<Int>, cellSize: CGSize, inset: CGSize) -> CGRect {
    cellRangeRect(row: row, cols: cols, cellSize: cellSize, inset: inset, translationY: 0)
  }

  private static func cellRangeRect(
    row: Int,
    cols: Range<Int>,
    cellSize: CGSize,
    inset: CGSize,
    translationY: CGFloat
  ) -> CGRect {
    CGRect(
      x: inset.width + CGFloat(cols.lowerBound) * cellSize.width,
      y: inset.height + CGFloat(max(0, row)) * cellSize.height + translationY,
      width: CGFloat(max(0, cols.count)) * cellSize.width,
      height: cellSize.height
    )
  }
}

extension NSColor {
  var metalRGBA: SIMD4<Float> {
    let rgb = usingColorSpace(.deviceRGB) ?? self
    return SIMD4<Float>(
      Float(rgb.redComponent),
      Float(rgb.greenComponent),
      Float(rgb.blueComponent),
      Float(rgb.alphaComponent)
    )
  }

  var metalRed: CGFloat { (usingColorSpace(.deviceRGB) ?? self).redComponent }
  var metalGreen: CGFloat { (usingColorSpace(.deviceRGB) ?? self).greenComponent }
  var metalBlue: CGFloat { (usingColorSpace(.deviceRGB) ?? self).blueComponent }
}

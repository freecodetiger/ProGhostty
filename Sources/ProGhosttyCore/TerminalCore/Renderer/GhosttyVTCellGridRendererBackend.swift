import AppKit
import Foundation

@MainActor
public final class GhosttyVTCellGridRendererBackend: TerminalRendererBackend {
  public let gridView: PTYGridView
  private var model = CellGridModel()
  private var options: TerminalRendererOptions
  private var pendingFrame: GhosttyTerminalFrame?
  private var pendingScrollFrame: GhosttyTerminalScrollFrame?
  private var flushScheduled = false
  private var pendingFullRedraw = false
  private var diagnosticsState = TerminalRendererDiagnostics(backend: .ghosttyVTCellGrid)

  public init(options: TerminalRendererOptions = TerminalRendererOptions()) {
    self.options = options
    gridView = PTYGridView()
    gridView.applyRendererOptions(options)
  }

  public var view: NSView { gridView }
  public var selectedText: String? { gridView.selectedText }
  public var diagnostics: TerminalRendererDiagnostics {
    var state = diagnosticsState
    gridView.applyScrollDiagnostics(to: &state)
    return state
  }

  public func setInputHandler(_ handler: ((Data) -> Void)?) {
    gridView.inputHandler = handler
  }

  public func setActivationHandler(_ handler: (() -> Void)?) {
    gridView.activationHandler = handler
  }

  public func applyPalette(_ palette: TerminalSurfacePalette) {
    gridView.applyPalette(palette)
    requestFullRedraw()
  }

  public func applyFont(family: String, size: CGFloat) {
    gridView.applyFont(family: family, size: size)
    requestFullRedraw()
  }

  public func applyOptions(_ options: TerminalRendererOptions) {
    self.options = options
    gridView.applyRendererOptions(options)
    requestFullRedraw()
  }

  public func setFocused(_ isFocused: Bool) {
    guard gridView.isFocusedTerminal != isFocused else { return }
    gridView.setFocused(isFocused)
    requestFullRedraw()
  }

  public func render(frame: GhosttyTerminalFrame) {
    pendingScrollFrame = nil
    pendingFrame = frame
    scheduleFlush()
  }

  public func render(scrollFrame: GhosttyTerminalScrollFrame) {
    pendingScrollFrame = scrollFrame
    pendingFrame = scrollFrame.viewport
    scheduleFlush()
  }

  private func scheduleFlush() {
    if flushScheduled {
      diagnosticsState.coalescedFrames += 1
      return
    }
    flushScheduled = true
    DispatchQueue.main.async { [weak self] in
      Task { @MainActor in
        self?.flushPendingFrame()
      }
    }
  }

  public func flushPendingFrame() {
    flushScheduled = false
    guard let frame = pendingFrame else { return }
    let scrollFrame = pendingScrollFrame
    pendingFrame = nil
    pendingScrollFrame = nil
    let dirty = model.update(
      frame: frame,
      forceFullRedraw: options.forceFullRedrawEnabled || pendingFullRedraw,
      dirtyRowsEnabled: options.dirtyRowRenderingEnabled,
      selectionRows: gridView.currentSelectionRowSet
    )
    pendingFullRedraw = false
    if let scrollFrame {
      gridView.render(scrollFrame, isFocused: gridView.isFocusedTerminal, dirty: dirty)
      updateOverscanDiagnostics(
        topRows: scrollFrame.overscanTop.count,
        bottomRows: scrollFrame.overscanBottom.count
      )
    } else {
      gridView.render(frame, isFocused: gridView.isFocusedTerminal, dirty: dirty)
      updateOverscanDiagnostics(topRows: 0, bottomRows: 0)
    }
    diagnosticsState.backend = .ghosttyVTCellGrid
    diagnosticsState.dirtyRowCount = dirty.rows.count
    diagnosticsState.visibleRowCount = frame.rows
    diagnosticsState.redrawMode = dirty.mode
    diagnosticsState.cacheHitRate = model.cacheHitRate
    diagnosticsState.smoothScrollOffset = gridView.viewport.visualOffsetY
    diagnosticsState.averageDrawTime = gridView.averageDrawDuration
    diagnosticsState.maxDrawTime = gridView.maxDrawDuration
    diagnosticsState.alternateScreenActive = frame.isAlternateScreen
    diagnosticsState.resizeSensitiveScreen = frame.isAlternateScreen || Self.hasRenderedContentBelowCursor(in: frame)
    diagnosticsState.styleStats = TerminalCellStyleStats(frame: frame)
    gridView.applyScrollDiagnostics(to: &diagnosticsState)
  }

  private static func hasRenderedContentBelowCursor(in frame: GhosttyTerminalFrame) -> Bool {
    let firstRowBelowCursor = max(0, frame.cursorY + 1)
    guard firstRowBelowCursor < frame.rows else { return false }
    for row in firstRowBelowCursor..<frame.rows {
      let rowStart = row * frame.cols
      let rowEnd = min(rowStart + frame.cols, frame.cells.count)
      guard rowStart < rowEnd else { continue }
      if frame.cells[rowStart..<rowEnd].contains(where: { $0.scalar != " " || !$0.usesDefaultBackground }) {
        return true
      }
    }
    return false
  }

  public func updateOverscanDiagnostics(topRows: Int, bottomRows: Int) {
    diagnosticsState.overscanTopRows = max(0, topRows)
    diagnosticsState.overscanBottomRows = max(0, bottomRows)
    let hasOverscan = diagnosticsState.overscanTopRows > 0 || diagnosticsState.overscanBottomRows > 0
    diagnosticsState.pixelSmoothScroll = hasOverscan ? .experimental : .unavailable
    diagnosticsState.pixelSmoothScrollReason = hasOverscan
      ? TerminalRendererDiagnostics.overscanRowsAvailableReason
      : TerminalRendererDiagnostics.missingOverscanRowsReason
  }

  public func markResizePending() {
    diagnosticsState.pendingResize = true
  }

  public func applyResizeDiagnostics(_ diagnostics: TerminalResizeDiagnostics) {
    diagnosticsState.pendingResize = false
    diagnosticsState.lastResizeTotalDuration = diagnostics.totalDuration
    diagnosticsState.lastResizeVTDuration = diagnostics.vtDuration
    diagnosticsState.lastResizeSnapshotDuration = diagnostics.snapshotDuration
  }

  public func focus() {
    gridView.window?.makeFirstResponder(gridView)
  }

  public func resetViewportStartRowKeepingVisualOffset() {
    gridView.resetViewportStartRowKeepingVisualOffset()
  }

  public func resetPixelScroll(suppressMomentum: Bool = false) {
    gridView.resetPixelScroll(suppressMomentum: suppressMomentum)
    requestFullRedraw()
  }

  private func requestFullRedraw() {
    pendingFullRedraw = true
    diagnosticsState.redrawMode = .full
    diagnosticsState.dirtyRowCount = model.frame?.rows ?? 0
  }
}

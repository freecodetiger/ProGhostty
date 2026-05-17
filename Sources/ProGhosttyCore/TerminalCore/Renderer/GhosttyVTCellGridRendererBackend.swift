import AppKit
import Foundation

@MainActor
public final class GhosttyVTCellGridRendererBackend: TerminalRendererBackend {
  public let gridView: PTYGridView
  private var model = CellGridModel()
  private var options: TerminalRendererOptions
  private var pendingFrame: GhosttyTerminalFrame?
  private var flushScheduled = false
  private var pendingFullRedraw = false
  private var diagnosticsState = TerminalRendererDiagnostics(backend: .ghosttyVTCellGrid)

  public init(options: TerminalRendererOptions = TerminalRendererOptions()) {
    self.options = options
    gridView = PTYGridView()
  }

  public var view: NSView { gridView }
  public var selectedText: String? { gridView.selectedText }
  public var diagnostics: TerminalRendererDiagnostics { diagnosticsState }

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
    pendingFrame = frame
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
    pendingFrame = nil
    let dirty = model.update(
      frame: frame,
      forceFullRedraw: options.forceFullRedrawEnabled || pendingFullRedraw,
      dirtyRowsEnabled: options.dirtyRowRenderingEnabled,
      selectionRows: gridView.currentSelectionRowSet
    )
    pendingFullRedraw = false
    gridView.render(frame, isFocused: gridView.isFocusedTerminal, dirty: dirty)
    diagnosticsState.backend = .ghosttyVTCellGrid
    diagnosticsState.dirtyRowCount = dirty.rows.count
    diagnosticsState.visibleRowCount = frame.rows
    diagnosticsState.redrawMode = dirty.mode
    diagnosticsState.cacheHitRate = model.cacheHitRate
    diagnosticsState.smoothScrollOffset = gridView.viewport.visualOffsetY
    diagnosticsState.averageDrawTime = gridView.averageDrawDuration
    diagnosticsState.maxDrawTime = gridView.maxDrawDuration
    diagnosticsState.alternateScreenActive = frame.isAlternateScreen
    diagnosticsState.styleStats = TerminalCellStyleStats(frame: frame)
  }

  public func updateOverscanDiagnostics(topRows: Int, bottomRows: Int) {
    diagnosticsState.overscanTopRows = max(0, topRows)
    diagnosticsState.overscanBottomRows = max(0, bottomRows)
    let hasOverscan = diagnosticsState.overscanTopRows > 0 || diagnosticsState.overscanBottomRows > 0
    diagnosticsState.pixelSmoothScroll = hasOverscan && options.smoothPixelScrollingEnabled ? .experimental : .unavailable
    diagnosticsState.pixelSmoothScrollReason = hasOverscan
      ? TerminalRendererDiagnostics.overscanRowsAvailableReason
      : TerminalRendererDiagnostics.missingOverscanRowsReason
  }

  public func focus() {
    gridView.window?.makeFirstResponder(gridView)
  }

  public func resetViewportStartRowKeepingVisualOffset() {
    gridView.resetViewportStartRowKeepingVisualOffset()
  }

  private func requestFullRedraw() {
    pendingFullRedraw = true
    diagnosticsState.redrawMode = .full
    diagnosticsState.dirtyRowCount = model.frame?.rows ?? 0
  }
}

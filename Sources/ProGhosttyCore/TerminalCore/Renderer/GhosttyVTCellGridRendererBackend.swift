import AppKit
import Foundation

private func rowHasRenderedContent(_ frame: GhosttyTerminalFrame, row: Int) -> Bool {
  let rowStart = row * frame.cols
  let rowEnd = min(rowStart + frame.cols, frame.cells.count)
  guard rowStart < rowEnd else { return false }
  return frame.cells[rowStart..<rowEnd].contains(where: { $0.scalar != " " || !$0.usesDefaultBackground })
}

@MainActor
public final class GhosttyVTCellGridRendererBackend: TerminalLiveRendererBackend {
  public let gridView: PTYGridView
  private var model = CellGridModel()
  private var options: TerminalRendererOptions
  private var pendingFrame: GhosttyTerminalFrame?
  private var pendingScrollFrame: GhosttyTerminalScrollFrame?
  private var flushScheduled = false
  private var pendingFullRedraw = false
  private var diagnosticsState = TerminalRendererDiagnostics(backend: .ghosttyVTCellGrid)
  private var styleStatsCache = StyleStatsCache()
  private var resizeSensitivityCache = ResizeSensitivityCache()

  private struct StyleStatsCache {
    private(set) var rows: [TerminalCellStyleStats] = []
    private(set) var total = TerminalCellStyleStats()
    private(set) var cachedCols = 0
    private(set) var lastScanRowCount = 0
    private(set) var lastScanCellCount = 0

    mutating func update(frame: GhosttyTerminalFrame, dirtyRows: Set<Int>, redrawMode: TerminalRedrawMode) -> TerminalCellStyleStats {
      if redrawMode == .full || rows.count != frame.rows || cachedCols != frame.cols {
        rebuild(frame: frame)
        lastScanRowCount = frame.rows
        lastScanCellCount = frame.rows * frame.cols
        return total
      }

      var scannedRows = 0
      var scannedCells = 0
      for row in dirtyRows.sorted() {
        guard let newStats = stats(for: frame, row: row) else { continue }
        total.subtract(rows[row])
        rows[row] = newStats
        total.add(newStats)
        scannedRows += 1
        scannedCells += rowCellCount(frame, row: row)
      }
      lastScanRowCount = scannedRows
      lastScanCellCount = scannedCells
      return total
    }

    private mutating func rebuild(frame: GhosttyTerminalFrame) {
      cachedCols = frame.cols
      rows = Array(repeating: TerminalCellStyleStats(), count: frame.rows)
      total = TerminalCellStyleStats()
      guard frame.rows > 0, frame.cols > 0 else { return }
      for row in 0..<frame.rows {
        let stats = Self.stats(for: frame, row: row)
        rows[row] = stats
        total.add(stats)
      }
    }

    private static func stats(for frame: GhosttyTerminalFrame, row: Int) -> TerminalCellStyleStats {
      let rowStart = row * frame.cols
      let rowEnd = min(rowStart + frame.cols, frame.cells.count)
      guard rowStart < rowEnd else { return TerminalCellStyleStats() }
      return TerminalCellStyleStats(cells: frame.cells[rowStart..<rowEnd])
    }

    private func stats(for frame: GhosttyTerminalFrame, row: Int) -> TerminalCellStyleStats? {
      guard row >= 0, row < frame.rows, frame.cols > 0 else { return nil }
      let rowStart = row * frame.cols
      let rowEnd = min(rowStart + frame.cols, frame.cells.count)
      guard rowStart < rowEnd else { return nil }
      return TerminalCellStyleStats(cells: frame.cells[rowStart..<rowEnd])
    }

    private func rowCellCount(_ frame: GhosttyTerminalFrame, row: Int) -> Int {
      let rowStart = row * frame.cols
      let rowEnd = min(rowStart + frame.cols, frame.cells.count)
      guard rowStart < rowEnd else { return 0 }
      return rowEnd - rowStart
    }
  }

  private struct ResizeSensitivityCache {
    private(set) var rowContentBelowCursor: [Bool] = []
    private(set) var belowCursorContentCount = 0
    private(set) var cachedRows = 0
    private(set) var cachedCols = 0
    private(set) var cachedCursorY = -1
    private(set) var cachedAlternateScreen = false
    private(set) var lastScanRowCount = 0
    private(set) var lastScanCellCount = 0

    mutating func update(frame: GhosttyTerminalFrame, dirtyRows: Set<Int>, redrawMode: TerminalRedrawMode) -> Bool {
      if frame.isAlternateScreen {
        cachedAlternateScreen = true
        lastScanRowCount = 0
        lastScanCellCount = 0
        return true
      }

      let needsRebuild =
        redrawMode == .full ||
        cachedRows != frame.rows ||
        cachedCols != frame.cols ||
        cachedCursorY != frame.cursorY ||
        cachedAlternateScreen

      if needsRebuild {
        rebuild(frame: frame)
        return belowCursorContentCount > 0
      }

      let firstRowBelowCursor = max(0, frame.cursorY + 1)
      let dirtyBelowCursorRows = dirtyRows.filter { $0 >= firstRowBelowCursor && $0 < frame.rows }.sorted()
      var scannedRows = 0
      var scannedCells = 0
      for row in dirtyBelowCursorRows {
        guard row < rowContentBelowCursor.count else { continue }
        let current = rowContentBelowCursor[row]
        let updated = rowHasRenderedContent(frame, row: row)
        rowContentBelowCursor[row] = updated
        if current != updated {
          belowCursorContentCount += updated ? 1 : -1
        }
        scannedRows += 1
        scannedCells += rowCellCount(frame, row: row)
      }
      cachedAlternateScreen = false
      lastScanRowCount = scannedRows
      lastScanCellCount = scannedCells
      return belowCursorContentCount > 0
    }

    private mutating func rebuild(frame: GhosttyTerminalFrame) {
      cachedRows = frame.rows
      cachedCols = frame.cols
      cachedCursorY = frame.cursorY
      cachedAlternateScreen = false
      rowContentBelowCursor = Array(repeating: false, count: frame.rows)
      belowCursorContentCount = 0
      let rows = max(0, frame.cursorY + 1)..<frame.rows
      var scannedRows = 0
      var scannedCells = 0
      for row in rows {
        let hasContent = rowHasRenderedContent(frame, row: row)
        rowContentBelowCursor[row] = hasContent
        if hasContent {
          belowCursorContentCount += 1
        }
        scannedRows += 1
        scannedCells += rowCellCount(frame, row: row)
      }
      lastScanRowCount = scannedRows
      lastScanCellCount = scannedCells
    }

    private func rowCellCount(_ frame: GhosttyTerminalFrame, row: Int) -> Int {
      let rowStart = row * frame.cols
      let rowEnd = min(rowStart + frame.cols, frame.cells.count)
      guard rowStart < rowEnd else { return 0 }
      return rowEnd - rowStart
    }
  }

  public init(options: TerminalRendererOptions = TerminalRendererOptions()) {
    self.options = options
    Self.applyBackendSelectionDiagnostics(options: options, to: &diagnosticsState)
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
    Self.applyBackendSelectionDiagnostics(options: options, to: &diagnosticsState)
    gridView.applyRendererOptions(options)
    requestFullRedraw()
  }

  public func setFocused(_ isFocused: Bool) {
    guard gridView.isFocusedTerminal != isFocused else { return }
    gridView.setFocused(isFocused)
    requestFullRedraw()
  }

  public func render(frame: GhosttyTerminalFrame) {
    render(TerminalRenderFrame(frame: frame, isFocused: gridView.isFocusedTerminal))
  }

  public func render(scrollFrame: GhosttyTerminalScrollFrame) {
    render(TerminalRenderFrame(scrollFrame: scrollFrame, isFocused: gridView.isFocusedTerminal))
  }

  public func render(_ renderFrame: TerminalRenderFrame) {
    setFocused(renderFrame.isFocused)
    if let scrollFrame = renderFrame.scrollFrame {
      pendingScrollFrame = scrollFrame
      pendingFrame = scrollFrame.viewport
    } else {
      pendingScrollFrame = nil
      pendingFrame = renderFrame.frame
    }
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
    Self.applyBackendSelectionDiagnostics(options: options, to: &diagnosticsState)
    diagnosticsState.dirtyRowCount = dirty.rows.count
    diagnosticsState.visibleRowCount = frame.rows
    diagnosticsState.redrawMode = dirty.mode
    diagnosticsState.cacheHitRate = model.cacheHitRate
    diagnosticsState.smoothScrollOffset = gridView.viewport.visualOffsetY
    diagnosticsState.averageDrawTime = gridView.averageDrawDuration
    diagnosticsState.maxDrawTime = gridView.maxDrawDuration
    diagnosticsState.alternateScreenActive = frame.isAlternateScreen
    diagnosticsState.styleStats = styleStatsCache.update(frame: frame, dirtyRows: dirty.rows, redrawMode: dirty.mode)
    diagnosticsState.resizeSensitiveScreen = resizeSensitivityCache.update(frame: frame, dirtyRows: dirty.rows, redrawMode: dirty.mode)
    diagnosticsState.renderStyleScanRowCount = styleStatsCache.lastScanRowCount
    diagnosticsState.renderStyleScanCellCount = styleStatsCache.lastScanCellCount
    diagnosticsState.renderResizeSensitivityScanRowCount = resizeSensitivityCache.lastScanRowCount
    diagnosticsState.renderResizeSensitivityScanCellCount = resizeSensitivityCache.lastScanCellCount
    gridView.applyScrollDiagnostics(to: &diagnosticsState)
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

  private static func applyBackendSelectionDiagnostics(
    options: TerminalRendererOptions,
    to diagnostics: inout TerminalRendererDiagnostics
  ) {
    let selection = TerminalRendererPolicy.resolve(
      mode: options.mode,
      hasFrame: true,
      isMetalDirectAvailable: false
    )
    diagnostics.backend = .ghosttyVTCellGrid
    diagnostics.requestedBackend = selection.requestedBackend
    diagnostics.backendFallbackReason = selection.fallbackReason
  }
}

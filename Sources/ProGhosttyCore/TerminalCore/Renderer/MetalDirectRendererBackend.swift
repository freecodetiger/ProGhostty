import AppKit
import Foundation
import Metal

private func rowHasRenderedContent(_ frame: GhosttyTerminalFrame, row: Int) -> Bool {
  let rowStart = row * frame.cols
  let rowEnd = min(rowStart + frame.cols, frame.cells.count)
  guard rowStart < rowEnd else { return false }
  return frame.cells[rowStart..<rowEnd].contains(where: { $0.scalar != " " || !$0.usesDefaultBackground })
}

@MainActor
public final class MetalDirectRendererView: PTYGridView {
  public let metalDevice: MTLDevice?

  public init(device: MTLDevice? = MTLCreateSystemDefaultDevice(), options: TerminalRendererOptions = TerminalRendererOptions()) {
    metalDevice = device
    super.init(frame: .zero)
    wantsLayer = true
    layer = makeBackingLayer()
    applyRendererOptions(options)
  }

  @available(*, unavailable)
  public required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  /// Fired when view bounds size changes (split, divider drag, window resize).
  /// Args: previous size, new size.
  public var boundsSizeDidChangeHandler: ((CGSize, CGSize) -> Void)?

  private var lastLaidOutBoundsSize: CGSize = .zero

  public override func makeBackingLayer() -> CALayer {
    let layer = CAMetalLayer()
    layer.device = metalDevice
    layer.pixelFormat = .bgra8Unorm
    layer.framebufferOnly = false
    layer.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
    // Default is `.resize`, which STRETCHES the previous drawable whenever the
    // layer bounds change before the next Metal present (common on split /
    // divider drag because PTY resize is debounced ~80ms). Pin top-left so a
    // stale frame letterboxes instead of distorting glyphs (width changes).
    // Height changes clear to background instead — topLeft would look like a
    // vertical content jump before reflow.
    layer.contentsGravity = .topLeft
    return layer
  }

  public override func layout() {
    super.layout()
    if let metalLayer = layer as? CAMetalLayer {
      metalLayer.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
    }
    let size = bounds.size
    guard size.width > 0, size.height > 0 else { return }
    if size != lastLaidOutBoundsSize {
      let previous = lastLaidOutBoundsSize
      lastLaidOutBoundsSize = size
      boundsSizeDidChangeHandler?(previous, size)
    }
  }

  public override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if let metalLayer = layer as? CAMetalLayer {
      metalLayer.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
    }
  }

  public override func draw(_ dirtyRect: NSRect) {}

  public func present(_ renderFrame: TerminalRenderFrame) {
    if let scrollFrame = renderFrame.scrollFrame {
      super.render(
        scrollFrame,
        isFocused: renderFrame.isFocused,
        dirty: CellGridDirtyResult(
          mode: .full,
          rows: Set(0..<max(0, scrollFrame.viewport.rows))
        )
      )
    } else {
      super.render(renderFrame.frame, isFocused: renderFrame.isFocused)
    }
    if PTYRenderDebugLog.isEnabled {
      PTYRenderDebugLog.write(
        "metalDirectPresent gen=\(renderFrame.generation) presentation=\(renderFrame.presentation) focused=\(renderFrame.isFocused) frameCursor=(\(renderFrame.frame.cursorX),\(renderFrame.frame.cursorY)) overscanTop=\(renderFrame.scrollFrame?.overscanTop.count ?? 0) visualOffsetY=\(String(format: "%.2f", viewport.visualOffsetY)) cursorRect=\(Self.debugDescription(for: cursorCellRect)) cursorOverlay=\(Self.debugDescription(for: currentCursorOverlay)) markedOverlay=\(Self.debugDescription(for: currentMarkedTextOverlay))"
      )
    }
  }

  private static func debugDescription(for rect: NSRect?) -> String {
    rect.map(NSStringFromRect) ?? "nil"
  }

  private static func debugDescription(for overlay: GridMarkedTextOverlay?) -> String {
    guard let overlay else { return "nil" }
    return "(row:\(overlay.row),col:\(overlay.col),width:\(String(format: "%.1f", overlay.width)))"
  }
}

@MainActor
public final class MetalDirectRendererBackend: TerminalLiveRendererBackend {
  public static var isRuntimeAvailable: Bool {
    MTLCreateSystemDefaultDevice() != nil
  }

  public let directView: MetalDirectRendererView
  private let metalDevice: MTLDevice?
  private var options: TerminalRendererOptions
  private var palette = TerminalSurfacePalette.dark
  private var diagnosticsState = TerminalRendererDiagnostics(backend: .metalDirect)
  private var glyphAtlas = MetalGlyphAtlas(
    fontFamily: FontCatalog.defaultMonospacedFontName(),
    fontSize: 14,
    backingScale: NSScreen.main?.backingScaleFactor ?? 1
  )
  private var engine: (any MetalDirectRenderingEngine)?
  private var lastGlyphBackingScale: CGFloat = 0
  private var instanceBuffer = MetalCellInstanceBuffer(rows: 0, cols: 0)
  private var styleStatsCache = StyleStatsCache()
  private var resizeSensitivityCache = ResizeSensitivityCache()
  private var previousFrame: GhosttyTerminalFrame?
  private var previousExpandedFrame: GhosttyTerminalFrame?
  private var previousPresentation: TerminalRenderFramePresentation?
  private var previousIsFocused: Bool?
  private var previousOverscanTopRows = 0
  private var previousViewportRows = 0
  private var previousTransientOverlayRevision = 0
  private var pendingRenderFrame: TerminalRenderFrame?
  private var lastPresentedRenderFrame: TerminalRenderFrame?
  private var stagedResizeRenderFrame: TerminalRenderFrame?
  private var stagedResizeGeneration: Int = 0
  private var pendingRenderGeneration: Int = 0
  private var latestRenderGeneration: Int = 0
  private var latestPresentedGeneration: Int = 0
  private var nextAssignedRenderGeneration: Int = 0
  private var flushScheduled = false
  private var pendingFullRedraw = false

  private struct DirtyRowsEvaluation {
    let dirty: CellGridDirtyResult
    let fullRedrawReason: String
  }

  private struct StyleStatsCache {
    private(set) var rows: [TerminalCellStyleStats] = []
    private(set) var total = TerminalCellStyleStats()
    private(set) var cachedCols = 0
    private(set) var lastAggregateRowCount = 0

    mutating func update(
      frame: GhosttyTerminalFrame,
      dirtyRows: Set<Int>,
      redrawMode: TerminalRedrawMode
    ) -> (stats: TerminalCellStyleStats, scannedRows: Int, scannedCells: Int) {
      if redrawMode == .full || rows.count != frame.rows || cachedCols != frame.cols {
        rebuild(frame: frame)
        let scannedCellCount = scannedCellCount(for: frame, rows: 0..<frame.rows)
        lastAggregateRowCount = frame.rows
        return (total, frame.rows, scannedCellCount)
      }

      var scannedRowCount = 0
      var scannedCellCount = 0
      for row in dirtyRows.sorted() {
        guard let rowStats = stats(for: frame, row: row) else {
          continue
        }
        let oldStats = rows[row]
        total.subtract(oldStats)
        rows[row] = rowStats.stats
        total.add(rowStats.stats)
        scannedRowCount += 1
        scannedCellCount += rowStats.scannedCellCount
      }
      lastAggregateRowCount = scannedRowCount
      return (total, scannedRowCount, scannedCellCount)
    }

    private mutating func rebuild(frame: GhosttyTerminalFrame) {
      cachedCols = frame.cols
      rows = Array(repeating: TerminalCellStyleStats(), count: frame.rows)
      total = TerminalCellStyleStats()
      lastAggregateRowCount = 0
      guard frame.rows > 0, frame.cols > 0 else { return }
      for row in 0..<frame.rows {
        if let rowStats = stats(for: frame, row: row) {
          rows[row] = rowStats.stats
          total.add(rowStats.stats)
        }
      }
    }

    private func stats(
      for frame: GhosttyTerminalFrame,
      row: Int
    ) -> (stats: TerminalCellStyleStats, scannedCellCount: Int)? {
      guard row >= 0, row < frame.rows, frame.cols > 0 else {
        return nil
      }
      let rowStart = row * frame.cols
      let rowEnd = min(rowStart + frame.cols, frame.cells.count)
      guard rowStart < rowEnd else {
        return nil
      }
      return (
        stats: TerminalCellStyleStats(cells: frame.cells[rowStart..<rowEnd]),
        scannedCellCount: rowEnd - rowStart
      )
    }

    private func scannedCellCount(for frame: GhosttyTerminalFrame, rows: Range<Int>) -> Int {
      var count = 0
      for row in rows {
        let rowStart = row * frame.cols
        let rowEnd = min(rowStart + frame.cols, frame.cells.count)
        if rowStart < rowEnd {
          count += rowEnd - rowStart
        }
      }
      return count
    }
  }

  private struct ResizeSensitivityCache {
    private(set) var rowContentBelowCursor: [Bool] = []
    private(set) var belowCursorContentCount = 0
    private(set) var cachedRows = 0
    private(set) var cachedCols = 0
    private(set) var cachedCursorY = -1
    private(set) var cachedAlternateScreen = false

    mutating func update(
      frame: GhosttyTerminalFrame,
      dirtyRows: Set<Int>,
      redrawMode: TerminalRedrawMode
    ) -> (isResizeSensitive: Bool, scannedRows: Int, scannedCells: Int) {
      if frame.isAlternateScreen {
        cachedAlternateScreen = true
        return (true, 0, 0)
      }

      let needsRebuild =
        redrawMode == .full ||
        cachedRows != frame.rows ||
        cachedCols != frame.cols ||
        cachedCursorY != frame.cursorY ||
        cachedAlternateScreen

      if needsRebuild {
        rebuild(frame: frame)
        let rows = belowCursorRows(in: frame)
        return (belowCursorContentCount > 0, scanCount(rows: rows), scanCellCount(for: frame, rows: rows))
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
        scannedCells += rowCellCount(in: frame, row: row)
      }
      cachedAlternateScreen = false
      return (belowCursorContentCount > 0, scannedRows, scannedCells)
    }

    private mutating func rebuild(frame: GhosttyTerminalFrame) {
      cachedRows = frame.rows
      cachedCols = frame.cols
      cachedCursorY = frame.cursorY
      cachedAlternateScreen = false
      rowContentBelowCursor = Array(repeating: false, count: frame.rows)
      belowCursorContentCount = 0
      for row in belowCursorRows(in: frame) {
        let hasContent = rowHasRenderedContent(frame, row: row)
        rowContentBelowCursor[row] = hasContent
        if hasContent {
          belowCursorContentCount += 1
        }
      }
    }

    private func belowCursorRows(in frame: GhosttyTerminalFrame) -> Range<Int> {
      let start = max(0, frame.cursorY + 1)
      return start..<max(start, frame.rows)
    }

    private func rowCellCount(in frame: GhosttyTerminalFrame, row: Int) -> Int {
      let rowStart = row * frame.cols
      let rowEnd = min(rowStart + frame.cols, frame.cells.count)
      guard rowStart < rowEnd else { return 0 }
      return rowEnd - rowStart
    }

    private func scanCount(rows: Range<Int>) -> Int {
      rows.count
    }

    private func scanCellCount(for frame: GhosttyTerminalFrame, rows: Range<Int>) -> Int {
      var count = 0
      for row in rows {
        count += rowCellCount(in: frame, row: row)
      }
      return count
    }
  }

  public convenience init(options: TerminalRendererOptions = TerminalRendererOptions()) {
    self.init(options: options, engineFactory: { device in
      try? MetalDirectRenderEngine(device: device)
    })
  }

  init(
    options: TerminalRendererOptions = TerminalRendererOptions(),
    engineFactory: (MTLDevice) -> (any MetalDirectRenderingEngine)?
  ) {
    self.options = options
    metalDevice = MTLCreateSystemDefaultDevice()
    directView = MetalDirectRendererView(device: metalDevice, options: options)
    directView.viewportDidChangeHandler = { [weak self] in
      self?.presentViewportChange()
    }
    directView.transientOverlayDidChangeHandler = { [weak self] in
      self?.presentViewportChange()
    }
    directView.boundsSizeDidChangeHandler = { [weak self] previous, newSize in
      self?.presentForBoundsSizeChange(previous: previous, newSize: newSize)
    }
    directView.scrollActivityHandler = { [weak self] isScrolling in
      self?.engine?.prefersAsyncPresent = isScrolling
    }
    if let metalDevice {
      engine = engineFactory(metalDevice)
    }
    Self.applyBackendSelectionDiagnostics(options: options, to: &diagnosticsState)
    diagnosticsState.metalDirect.pipelineReady = engine?.pipelineReady == true
  }

  public var gridView: PTYGridView { directView }
  public var view: NSView { directView }
  public var selectedText: String? { directView.selectedText }

  public var diagnostics: TerminalRendererDiagnostics {
    var state = diagnosticsState
    state.metalDirect.presentedFrameCount = engine?.presentedFrameCount ?? state.metalDirect.presentedFrameCount
    state.metalDirect.drawPassCount = engine?.drawPassCount ?? state.metalDirect.drawPassCount
    state.metalDirect.pipelineReady = engine?.pipelineReady == true
    state.metalDirect.staleCompletionCount = engine?.staleCompletionCount ?? state.metalDirect.staleCompletionCount
    state.metalDirect.latestRenderGeneration = latestRenderGeneration
    state.metalDirect.latestSubmittedGeneration = engine?.latestSubmittedGeneration ?? state.metalDirect.latestSubmittedGeneration
    state.metalDirect.latestPresentedGeneration = engine?.latestPresentedGeneration ?? state.metalDirect.latestPresentedGeneration
    directView.applyScrollDiagnostics(to: &state)
    return state
  }

  public func setInputHandler(_ handler: ((Data) -> Void)?) {
    directView.inputHandler = handler
  }

  public func setActivationHandler(_ handler: (() -> Void)?) {
    directView.activationHandler = handler
  }

  public func applyPalette(_ palette: TerminalSurfacePalette) {
    self.palette = palette
    directView.applyPalette(palette)
    requestFullRedraw()
  }

  public func applyFont(family: String, size: CGFloat, cjkFallbackFamily: String? = nil) {
    directView.applyFont(family: family, size: size, cjkFallbackFamily: cjkFallbackFamily)
    glyphAtlas.applyFont(family: family, size: size, cjkFallbackFamily: cjkFallbackFamily)
    engine?.resetTextureCache()
    lastGlyphBackingScale = 0
    requestFullRedraw()
  }

  public func applyOptions(_ options: TerminalRendererOptions) {
    self.options = options
    Self.applyBackendSelectionDiagnostics(options: options, to: &diagnosticsState)
    directView.applyRendererOptions(options)
    requestFullRedraw()
  }

  public func setFocused(_ isFocused: Bool) {
    directView.setFocused(isFocused)
  }

  public func render(frame: GhosttyTerminalFrame) {
    render(TerminalRenderFrame(frame: frame, isFocused: gridView.isFocusedTerminal))
  }

  public func render(scrollFrame: GhosttyTerminalScrollFrame) {
    render(TerminalRenderFrame(scrollFrame: scrollFrame, isFocused: gridView.isFocusedTerminal))
  }

  public func render(_ renderFrame: TerminalRenderFrame) {
    let generation = normalizedGeneration(for: renderFrame)
    guard shouldAcceptRenderGeneration(generation) else {
      diagnosticsState.droppedFrames += 1
      latestRenderGeneration = max(latestRenderGeneration, generation)
      return
    }
    let normalizedFrame = normalizedRenderFrame(renderFrame, generation: generation)
    if diagnosticsState.pendingResize {
      if stagedResizeRenderFrame != nil {
        diagnosticsState.coalescedFrames += 1
        diagnosticsState.droppedFrames += 1
      }
      stagedResizeRenderFrame = normalizedFrame
      stagedResizeGeneration = generation
      latestRenderGeneration = generation
      return
    }
    if pendingRenderFrame != nil {
      diagnosticsState.coalescedFrames += 1
      diagnosticsState.droppedFrames += 1
    }
    pendingRenderFrame = normalizedFrame
    pendingRenderGeneration = generation
    latestRenderGeneration = generation
    scheduleFlush()
  }

  public func flushPendingFrame() {
    flushScheduled = false
    guard let renderFrame = pendingRenderFrame else { return }
    pendingRenderFrame = nil
    pendingRenderGeneration = 0
    directView.present(renderFrame)
    lastPresentedRenderFrame = renderFrame
    updateDiagnostics(from: renderFrame)
  }

  private func scheduleFlush() {
    guard !flushScheduled else { return }
    flushScheduled = true
    DispatchQueue.main.async { [weak self] in
      Task { @MainActor in
        self?.flushPendingFrame()
      }
    }
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
    if pendingRenderFrame != nil {
      diagnosticsState.droppedFrames += 1
    }
    // Drop unflushed work so a wrong-size frame cannot sneak out. Do NOT re-present
    // here: CAMetalLayer present always clears, which flashes (especially the focused
    // pane with a visible cursor). Leave the last drawable on screen; contentsGravity
    // is .topLeft so bounds changes letterbox instead of stretching until the staged
    // post-resize frame lands in applyResizeDiagnostics.
    pendingRenderFrame = nil
    pendingRenderGeneration = 0
    diagnosticsState.pendingResize = true
  }

  public func applyResizeDiagnostics(_ diagnostics: TerminalResizeDiagnostics) {
    diagnosticsState.pendingResize = false
    diagnosticsState.lastResizeTotalDuration = diagnostics.totalDuration
    diagnosticsState.lastResizeVTDuration = diagnostics.vtDuration
    diagnosticsState.lastResizeSnapshotDuration = diagnostics.snapshotDuration
    guard let stagedResizeRenderFrame else {
      stagedResizeGeneration = 0
      return
    }
    self.stagedResizeRenderFrame = nil
    stagedResizeGeneration = 0
    render(stagedResizeRenderFrame)
    flushPendingFrame()
  }

  public func resetViewportStartRowKeepingVisualOffset() {
    directView.resetViewportStartRowKeepingVisualOffset()
  }

  public func resetPixelScroll(suppressMomentum: Bool = false) {
    directView.resetPixelScroll(suppressMomentum: suppressMomentum)
  }

  public func focus() {
    directView.window?.makeFirstResponder(directView)
  }

  private func normalizedGeneration(for renderFrame: TerminalRenderFrame) -> Int {
    if renderFrame.generation > 0 {
      nextAssignedRenderGeneration = max(nextAssignedRenderGeneration, renderFrame.generation)
      return renderFrame.generation
    }
    nextAssignedRenderGeneration += 1
    return nextAssignedRenderGeneration
  }

  private func shouldAcceptRenderGeneration(_ generation: Int) -> Bool {
    if stagedResizeRenderFrame != nil {
      return generation >= stagedResizeGeneration
    }
    if pendingRenderFrame != nil {
      return generation >= pendingRenderGeneration
    }
    return generation > latestPresentedGeneration
  }

  private func normalizedRenderFrame(_ renderFrame: TerminalRenderFrame, generation: Int) -> TerminalRenderFrame {
    guard renderFrame.generation != generation else {
      return renderFrame
    }
    if let scrollFrame = renderFrame.scrollFrame {
      return TerminalRenderFrame(scrollFrame: scrollFrame, isFocused: renderFrame.isFocused, generation: generation)
    }
    return TerminalRenderFrame(frame: renderFrame.frame, isFocused: renderFrame.isFocused, generation: generation)
  }

  private func presentViewportChange() {
    // During VT resize, leave the last drawable alone — re-present would clear and
    // flash. New snapshots are staged until applyResizeDiagnostics.
    if diagnosticsState.pendingResize {
      return
    }
    guard let baseRenderFrame = pendingRenderFrame ?? lastPresentedRenderFrame else {
      return
    }
    let refreshedFrame = normalizedRenderFrame(
      baseRenderFrame,
      generation: 0
    )
    render(refreshedFrame)
  }

  /// Bounds changed (split / divider / window).
  /// - Width-only: leave the previous drawable (topLeft letterbox) until reflow.
  /// - Height change: clear to terminal background. Re-presenting old content
  ///   under topLeft looks like a vertical jump (compress-up / expand-down), and
  ///   re-drawing old cells at the new size is the wrong reflow. Solid clear
  ///   until the post-resize frame is the stable intermediate.
  private func presentForBoundsSizeChange(previous: CGSize, newSize: CGSize) {
    // First layout after attach has previous == .zero — not a divider jump.
    guard previous.width > 0, previous.height > 0 else { return }
    let heightChanged = abs(previous.height - newSize.height) > 0.5
    guard heightChanged else { return }
    _ = engine?.clearToBackground(view: directView, palette: palette)
  }

  private func updateDiagnostics(from renderFrame: TerminalRenderFrame) {
    let frame = renderFrame.frame
    let dirtyEvaluation = dirtyRows(
      for: renderFrame,
      transientOverlayRevision: directView.markedTextStateRevision
    )
    let dirty = dirtyEvaluation.dirty
    let plan = MetalTerminalFrameEncoder.encode(
      renderFrame,
      pixelRemainderY: directView.viewport.visualOffsetY,
      dirtyRows: dirty.rows,
      dirtyCellRanges: dirty.cellRanges,
      cellSize: directView.terminalCellSize,
      backingScale: directView.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1,
      transientOverlayRevision: directView.markedTextStateRevision
    )
    glyphAtlas.applyBackingScale(plan.backingScale)
    if lastGlyphBackingScale != plan.backingScale {
      engine?.resetTextureCache()
      lastGlyphBackingScale = plan.backingScale
    }
    let drawFrame = renderFrame.expandedFrame
    let renderCellRanges = MetalDirectRenderEngine.renderCellRanges(for: plan, drawFrameRows: drawFrame.rows)
    let glyphScanRowCount = Set(renderCellRanges.map(\.row)).count
    let glyphScanCellCount = updateGlyphAtlas(from: drawFrame, cellRanges: renderCellRanges)
    let instanceRanges = instanceRanges(for: frame, dirty: dirty)
    let styleStatsUpdate = styleStatsCache.update(
      frame: frame,
      dirtyRows: dirty.rows,
      redrawMode: dirty.mode
    )
    let resizeSensitivityUpdate = resizeSensitivityCache.update(
      frame: frame,
      dirtyRows: dirty.rows,
      redrawMode: dirty.mode
    )
    let didRender = engine?.render(
      renderFrame: renderFrame,
      plan: plan,
      view: directView,
      palette: palette,
      glyphAtlas: glyphAtlas
    ) ?? false
    let renderFailed = !didRender

    diagnosticsState.backend = .metalDirect
    diagnosticsState.usesBitmapCapture = false
    diagnosticsState.visibleRowCount = frame.rows
    diagnosticsState.dirtyRowCount = dirty.rows.count
    diagnosticsState.redrawMode = dirty.mode
    diagnosticsState.alternateScreenActive = frame.isAlternateScreen
    diagnosticsState.resizeSensitiveScreen = resizeSensitivityUpdate.isResizeSensitive
    diagnosticsState.styleStats = styleStatsUpdate.stats
    diagnosticsState.metalDirect.planRows = plan.viewportRows
    diagnosticsState.metalDirect.planCols = plan.cols
    diagnosticsState.metalDirect.uploadedRowCount = instanceRanges.count
    diagnosticsState.metalDirect.uploadedCellCount = instanceBuffer.uploadedCellCount(for: instanceRanges)
    diagnosticsState.metalDirect.dirtyCellCount = dirty.dirtyCellCount
    diagnosticsState.metalDirect.glyphAtlasEntryCount = glyphAtlas.entryCount
    diagnosticsState.metalDirect.glyphScanRowCount = glyphScanRowCount
    diagnosticsState.metalDirect.glyphScanCellCount = glyphScanCellCount
    diagnosticsState.metalDirect.styleScanRowCount = styleStatsUpdate.scannedRows
    diagnosticsState.metalDirect.styleScanCellCount = styleStatsUpdate.scannedCells
    diagnosticsState.metalDirect.resizeSensitivityScanRowCount = resizeSensitivityUpdate.scannedRows
    diagnosticsState.metalDirect.resizeSensitivityScanCellCount = resizeSensitivityUpdate.scannedCells
    diagnosticsState.metalDirect.styleAggregateRowCount = styleStatsCache.lastAggregateRowCount
    diagnosticsState.renderStyleScanRowCount = styleStatsUpdate.scannedRows
    diagnosticsState.renderStyleScanCellCount = styleStatsUpdate.scannedCells
    diagnosticsState.renderResizeSensitivityScanRowCount = resizeSensitivityUpdate.scannedRows
    diagnosticsState.renderResizeSensitivityScanCellCount = resizeSensitivityUpdate.scannedCells
    diagnosticsState.metalDirect.presentedFrameCount = didRender ? (engine?.presentedFrameCount ?? 0) : 0
    diagnosticsState.metalDirect.drawPassCount = didRender ? (engine?.drawPassCount ?? 0) : 0
    diagnosticsState.metalDirect.pipelineReady = engine?.pipelineReady == true
    diagnosticsState.metalDirect.drawnRowCount = didRender ? (engine?.lastRenderedRowCount ?? 0) : 0
    diagnosticsState.metalDirect.drawnCellCount = didRender ? (engine?.lastRenderedCellCount ?? 0) : 0
    diagnosticsState.metalDirect.drawRunCount = didRender ? (engine?.lastRenderedRunCount ?? 0) : 0
    diagnosticsState.metalDirect.renderPassLoadAction = didRender
      ? String(describing: engine?.lastRenderPassLoadPolicy ?? MetalDirectRenderPassLoadPolicy.clear)
      : "none"
    diagnosticsState.metalDirect.waitedForCompletion = didRender ? (engine?.lastWaitedForCompletion ?? false) : false
    diagnosticsState.metalDirect.gpuWaitReason = didRender ? (engine?.lastGPUWaitReason ?? "none") : "none"
    diagnosticsState.metalDirect.staleCompletionCount = didRender ? (engine?.staleCompletionCount ?? 0) : 0
    diagnosticsState.metalDirect.fullRedrawReason = dirtyEvaluation.fullRedrawReason
    diagnosticsState.metalDirect.expandedFrameCellCount = drawFrame.cells.count
    diagnosticsState.metalDirect.glyphTextureHitCount = didRender ? (engine?.lastGlyphTextureHitCount ?? 0) : 0
    diagnosticsState.metalDirect.glyphTextureMissCount = didRender ? (engine?.lastGlyphTextureMissCount ?? 0) : 0
    let textureLookupCount = diagnosticsState.metalDirect.glyphTextureHitCount + diagnosticsState.metalDirect.glyphTextureMissCount
    diagnosticsState.metalDirect.textureCacheHitRate = textureLookupCount > 0
      ? Double(diagnosticsState.metalDirect.glyphTextureHitCount) / Double(textureLookupCount)
      : 0
    if didRender {
      latestPresentedGeneration = renderFrame.generation
    }
    diagnosticsState.metalDirect.latestRenderGeneration = latestRenderGeneration
    diagnosticsState.metalDirect.latestSubmittedGeneration = engine?.latestSubmittedGeneration ?? latestPresentedGeneration
    diagnosticsState.metalDirect.latestPresentedGeneration = engine?.latestPresentedGeneration ?? latestPresentedGeneration
    if let scrollFrame = renderFrame.scrollFrame {
      updateOverscanDiagnostics(
        topRows: scrollFrame.overscanTop.count,
        bottomRows: scrollFrame.overscanBottom.count
      )
    } else {
      updateOverscanDiagnostics(topRows: 0, bottomRows: 0)
    }
    Self.applyBackendSelectionDiagnostics(options: options, to: &diagnosticsState)
    if renderFailed {
      diagnosticsState.backendFallbackReason = TerminalRendererDiagnostics.metalDirectRenderFailedFallbackReason
    }
    previousFrame = frame
    previousExpandedFrame = drawFrame
    previousPresentation = renderFrame.presentation
    previousIsFocused = renderFrame.isFocused
    previousOverscanTopRows = renderFrame.scrollFrame?.overscanTop.count ?? 0
    previousViewportRows = frame.rows
  }

  private func dirtyRows(
    for renderFrame: TerminalRenderFrame,
    transientOverlayRevision: Int
  ) -> DirtyRowsEvaluation {
    let frame = renderFrame.frame
    let gridUpdate = instanceBuffer.updateGridSize(rows: frame.rows, cols: frame.cols)
    if pendingFullRedraw {
      pendingFullRedraw = false
      previousTransientOverlayRevision = transientOverlayRevision
      return DirtyRowsEvaluation(
        dirty: CellGridDirtyTracker.fullDirtyResult(for: frame),
        fullRedrawReason: "pending-full-redraw"
      )
    }
    guard gridUpdate == .unchanged, let previousFrame else {
      return DirtyRowsEvaluation(
        dirty: CellGridDirtyTracker.fullDirtyResult(for: frame),
        fullRedrawReason: "grid-size-changed"
      )
    }
    if transientOverlayRevision != 0, transientOverlayRevision != previousTransientOverlayRevision {
      previousTransientOverlayRevision = transientOverlayRevision
      return DirtyRowsEvaluation(
        dirty: CellGridDirtyTracker.fullDirtyResult(for: frame),
        fullRedrawReason: "transient-overlay-changed"
      )
    }
    let diff = CellGridDirtyTracker.diff(
      previous: previousFrame,
      next: frame
    )
    if previousIsFocused != renderFrame.isFocused {
      return DirtyRowsEvaluation(
        dirty: CellGridDirtyTracker.fullDirtyResult(for: frame),
        fullRedrawReason: "focus-changed"
      )
    }
    if let reason = scrollFrameFullSceneRebuildReason(renderFrame) {
      return DirtyRowsEvaluation(
        dirty: CellGridDirtyTracker.fullDirtyResult(for: frame),
        fullRedrawReason: reason
      )
    }
    guard previousFrame.cursorShape != .block, frame.cursorShape != .block else {
      previousTransientOverlayRevision = transientOverlayRevision
      return DirtyRowsEvaluation(dirty: diff, fullRedrawReason: "none")
    }
    let result = CellGridDirtyTracker.diffIgnoringCursorOnlyChanges(
      previous: previousFrame,
      next: frame
    )
    previousTransientOverlayRevision = transientOverlayRevision
    return DirtyRowsEvaluation(dirty: result, fullRedrawReason: "none")
  }

  private func requestFullRedraw() {
    pendingFullRedraw = true
    diagnosticsState.redrawMode = .full
    diagnosticsState.dirtyRowCount = previousFrame?.rows ?? 0
  }

  private func scrollFrameFullSceneRebuildReason(_ renderFrame: TerminalRenderFrame) -> String? {
    guard renderFrame.presentation == .scrollFrame || previousPresentation == .scrollFrame else {
      return nil
    }
    guard let previousExpandedFrame else {
      return "missing-expanded-frame"
    }
    guard previousPresentation == renderFrame.presentation else {
      return "scroll-presentation-changed"
    }
    let expanded = renderFrame.expandedFrame
    guard previousExpandedFrame.rows == expanded.rows, previousExpandedFrame.cols == expanded.cols else {
      return "scroll-frame-shape-changed"
    }
    guard let scrollFrame = renderFrame.scrollFrame else {
      return nil
    }
    let overscanTopRows = scrollFrame.overscanTop.count
    let viewportRows = scrollFrame.viewport.rows
    guard previousOverscanTopRows == overscanTopRows, previousViewportRows == viewportRows else {
      return "scroll-frame-shape-changed"
    }
    return nil
  }

  private func instanceRanges(
    for frame: GhosttyTerminalFrame,
    dirty: CellGridDirtyResult
  ) -> [MetalCellInstanceRange] {
    _ = instanceBuffer.updateGridSize(rows: frame.rows, cols: frame.cols)
    if dirty.mode == .dirty, !dirty.cellRanges.isEmpty {
      return instanceBuffer.instanceRanges(forDirtyCellRanges: dirty.cellRanges)
    }
    return instanceBuffer.instanceRanges(forDirtyRows: dirty.rows)
  }

  private func updateGlyphAtlas(from frame: GhosttyTerminalFrame, cellRanges: [MetalCellDirtyRange]) -> Int {
    var scannedCellCount = 0
    for range in cellRanges {
      let row = range.row
      let rowStart = row * frame.cols
      let rowEnd = min(rowStart + frame.cols, frame.cells.count)
      guard row >= 0, row < frame.rows, rowStart < rowEnd else { continue }
      for col in range.cols {
        let index = rowStart + col
        guard col >= 0, col < frame.cols, index < rowEnd else { continue }
        scannedCellCount += 1
        let cell = frame.cells[index]
        guard cell.scalar != " ", cell.scalar != "\0" else { continue }
        _ = glyphAtlas.entry(
          for: String(cell.scalar),
          style: MetalGlyphStyle(bold: cell.bold, italic: cell.italic, underline: cell.underline)
        )
      }
    }
    return scannedCellCount
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

  private static func applyBackendSelectionDiagnostics(
    options: TerminalRendererOptions,
    to diagnostics: inout TerminalRendererDiagnostics
  ) {
    let selection = TerminalRendererPolicy.resolve(
      mode: options.mode,
      hasFrame: true,
      isMetalDirectAvailable: true
    )
    diagnostics.backend = .metalDirect
    diagnostics.requestedBackend = selection.requestedBackend
    diagnostics.backendFallbackReason = selection.fallbackReason
    diagnostics.usesBitmapCapture = false
  }
}

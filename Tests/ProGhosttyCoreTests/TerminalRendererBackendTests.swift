import AppKit
import MetalKit
import Testing

@testable import ProGhosttyCore

@Suite("Terminal renderer backend")
struct TerminalRendererBackendTests {
  @Test func terminalRenderFramePreservesScrollFrameAndFocus() {
    let scrollFrame = scrollFrame(
      viewportRows: ["two", "three"],
      overscanTop: ["one"],
      overscanBottom: ["four"],
      cols: 8
    )

    let renderFrame = TerminalRenderFrame(scrollFrame: scrollFrame, isFocused: true)

    #expect(renderFrame.presentation == .scrollFrame)
    #expect(renderFrame.frame == scrollFrame.viewport)
    #expect(renderFrame.scrollFrame == scrollFrame)
    #expect(renderFrame.isFocused)
  }

  @Test func terminalRenderFrameCarriesExplicitGeneration() {
    let frame = frame(rows: ["one"], cols: 8, cursorX: 0, cursorY: 0)
    let renderFrame = TerminalRenderFrame(frame: frame, isFocused: true, generation: 17)

    #expect(renderFrame.generation == 17)
    #expect(renderFrame.isFocused)
    #expect(renderFrame.presentation == .frame)
  }

  @MainActor @Test func cellGridBackendConsumesUnifiedRenderFrame() {
    let backend = GhosttyVTCellGridRendererBackend()
    let renderFrame = TerminalRenderFrame(
      scrollFrame: scrollFrame(
        viewportRows: ["two", "three"],
        overscanTop: ["one"],
        overscanBottom: ["four"],
        cols: 8
      ),
      isFocused: true
    )

    backend.render(renderFrame)
    backend.flushPendingFrame()

    #expect(backend.gridView.canRenderPixelScroll(for: 5))
    #expect(backend.diagnostics.overscanTopRows == 1)
    #expect(backend.diagnostics.overscanBottomRows == 1)
  }

  @Test func rendererBackendSelectionUsesTextFallbackWhenNoFrameExists() {
    let selection = TerminalRendererBackendSelection.resolve(
      mode: .metalDirect,
      hasFrame: false
    )

    #expect(selection.presentation == .textFallback)
    #expect(selection.activeBackend == .ghosttyVTTextFallback)
    #expect(selection.requestedBackend == .metalDirect)
  }

  @Test func rendererBackendSelectionResolvesAutoToBestAvailableBackend() {
    let directSelection = TerminalRendererBackendSelection.resolve(
      mode: .auto,
      hasFrame: true,
      isMetalDirectAvailable: true
    )
    let cellGridSelection = TerminalRendererBackendSelection.resolve(
      mode: .auto,
      hasFrame: true,
      isMetalDirectAvailable: false
    )

    #expect(directSelection.activeBackend == .metalDirect)
    #expect(directSelection.requestedBackend == nil)
    #expect(directSelection.fallbackReason == nil)
    #expect(cellGridSelection.activeBackend == .ghosttyVTCellGrid)
    #expect(cellGridSelection.requestedBackend == nil)
    #expect(cellGridSelection.fallbackReason == nil)
  }

  @Test func rendererPolicyResolvesAutoToDirectMetalWhenAvailable() {
    let selection = TerminalRendererPolicy.resolve(
      mode: .auto,
      hasFrame: true,
      isMetalDirectAvailable: true
    )

    #expect(selection.presentation == .liveCellGrid)
    #expect(selection.activeBackend == .metalDirect)
    #expect(selection.requestedBackend == nil)
    #expect(selection.fallbackReason == nil)
  }

  @Test func rendererPolicyFallsBackToCellGridWhenDirectMetalIsUnavailable() {
    let selection = TerminalRendererPolicy.resolve(
      mode: .auto,
      hasFrame: true,
      isMetalDirectAvailable: false
    )

    #expect(selection.presentation == .liveCellGrid)
    #expect(selection.activeBackend == .ghosttyVTCellGrid)
    #expect(selection.requestedBackend == nil)
    #expect(selection.fallbackReason == nil)
  }

  @Test func rendererPolicyResolvesDirectMetalRequestToCellGridFallback() {
    let selection = TerminalRendererPolicy.resolve(
      mode: .metalDirect,
      hasFrame: true,
      isMetalDirectAvailable: false
    )

    #expect(selection.presentation == .liveCellGrid)
    #expect(selection.activeBackend == .ghosttyVTCellGrid)
    #expect(selection.requestedBackend == .metalDirect)
    #expect(selection.fallbackReason == TerminalRendererDiagnostics.metalDirectUnavailableFallbackReason)
  }

  @Test func rendererBackendSelectionResolvesDirectMetalWhenAvailable() {
    let selection = TerminalRendererBackendSelection.resolve(
      mode: .metalDirect,
      hasFrame: true,
      isMetalDirectAvailable: true
    )

    #expect(selection.presentation == .liveCellGrid)
    #expect(selection.activeBackend == .metalDirect)
    #expect(selection.requestedBackend == .metalDirect)
    #expect(selection.fallbackReason == nil)
  }

  @Test func rendererBackendSelectionFallsBackFromDirectMetalWhenUnavailable() {
    let selection = TerminalRendererBackendSelection.resolve(
      mode: .metalDirect,
      hasFrame: true,
      isMetalDirectAvailable: false
    )

    #expect(selection.presentation == .liveCellGrid)
    #expect(selection.activeBackend == .ghosttyVTCellGrid)
    #expect(selection.requestedBackend == .metalDirect)
    #expect(selection.fallbackReason == TerminalRendererDiagnostics.metalDirectUnavailableFallbackReason)
  }

  @MainActor @Test func metalDirectRendererBackendReportsDirectBackendAndDoesNotUseBitmapCapture() {
    let backend = MetalDirectRendererBackend()

    #expect(backend.diagnostics.backend == .metalDirect)
    #expect(backend.diagnostics.usesBitmapCapture == false)
    #expect(backend.gridView is MetalDirectRendererView)
  }

  @MainActor @Test func metalDirectRendererBackendTracksLatestRenderGeneration() {
    let backend = MetalDirectRendererBackend()

    backend.render(TerminalRenderFrame(frame: frame(rows: ["one"], cols: 8, cursorX: 0, cursorY: 0), generation: 41))
    backend.render(TerminalRenderFrame(frame: frame(rows: ["two"], cols: 8, cursorX: 0, cursorY: 0), generation: 42))
    backend.flushPendingFrame()

    let diagnostics = backend.diagnostics
    #expect(diagnostics.coalescedFrames == 1)
    #expect(diagnostics.droppedFrames == 1)
    #expect(diagnostics.metalDirect.latestRenderGeneration == 42)
    #expect(diagnostics.metalDirect.latestSubmittedGeneration == 42)
    #expect(diagnostics.metalDirect.latestPresentedGeneration == 42)
  }

  @MainActor @Test func metalDirectRendererViewPresentDoesNotRequestAppKitDisplayRedraw() {
    let view = MetalDirectRendererView(device: nil)
    view.needsDisplay = false

    view.present(TerminalRenderFrame(frame: frame(rows: ["ab"], cols: 4, cursorX: 0, cursorY: 0)))

    #expect(view.needsDisplay == false)
  }

  @MainActor @Test func metalDirectDrawableTargetUsesViewBackingSizeNotTerminalContentSize() {
    let size = MetalDirectRenderEngine.drawableTargetSize(
      forViewBounds: CGSize(width: 503.5, height: 371.25),
      backingScale: 2
    )

    #expect(size == CGSize(width: 1007, height: 743))
  }

  @MainActor @Test func metalDirectLayerPinsContentsGravitySoBoundsChangeDoesNotStretch() {
    let view = MetalDirectRendererView(device: nil)
    let metalLayer = view.layer as? CAMetalLayer
    #expect(metalLayer != nil)
    // Default CALayer gravity is `.resize` (stretch). Terminal content must not
    // distort when the pane shrinks before the next Metal present.
    #expect(metalLayer?.contentsGravity == .topLeft)
  }

  @MainActor @Test func metalDirectHeightBoundsChangeClearsBackgroundWithoutOldContentJump() {
    final class RecordingClearEngine: MetalDirectRenderingEngine {
      let drawPassCount = 0
      var presentedFrameCount = 0
      let latestSubmittedGeneration = 0
      let latestPresentedGeneration = 0
      let pipelineReady = true
      var prefersAsyncPresent = false
      let lastRenderedRowCount = 0
      let lastRenderedCellCount = 0
      let lastRenderedRunCount = 0
      let lastRenderPassLoadPolicy = MetalDirectRenderPassLoadPolicy.clear
      let lastWaitedForCompletion = false
      let lastGPUWaitReason = "none"
      let lastGlyphTextureHitCount = 0
      let lastGlyphTextureMissCount = 0
      let staleCompletionCount = 0
      var clearCount = 0
      var renderCount = 0

      func resetTextureCache() {}
      func clearToBackground(view: MetalDirectRendererView, palette: TerminalSurfacePalette) -> Bool {
        clearCount += 1
        return true
      }
      func render(
        renderFrame: TerminalRenderFrame,
        plan: MetalTerminalRenderPlan,
        view: MetalDirectRendererView,
        palette: TerminalSurfacePalette,
        glyphAtlas: MetalGlyphAtlas
      ) -> Bool {
        renderCount += 1
        presentedFrameCount += 1
        return true
      }
    }

    let engine = RecordingClearEngine()
    let backend = MetalDirectRendererBackend(options: TerminalRendererOptions()) { _ in engine }
    let view = backend.directView
    view.frame = NSRect(x: 0, y: 0, width: 200, height: 400)
    view.layout() // seeds lastLaidOutBoundsSize

    // Width-only: must NOT clear (topLeft letterbox is fine).
    view.frame = NSRect(x: 0, y: 0, width: 160, height: 400)
    view.layout()
    #expect(engine.clearCount == 0)

    // Height change: clear background, do not re-present old cells.
    view.frame = NSRect(x: 0, y: 0, width: 160, height: 280)
    view.layout()
    #expect(engine.clearCount == 1)
    #expect(engine.renderCount == 0)
  }

  @MainActor @Test func metalDirectRenderRowsUsesFullRangeForFullRedraw() {
    let plan = MetalTerminalRenderPlan(
      presentation: .frame,
      viewportRows: 3,
      cols: 4,
      overscanTopRows: 0,
      overscanBottomRows: 0,
      pixelRemainderY: 0,
      dirtyRows: [0, 1, 2],
      cellSize: CGSize(width: 8, height: 16),
      backingScale: 2,
      isFocused: true
    )

    let rows = MetalDirectRenderEngine.renderRows(for: plan, drawFrameRows: 3)

    #expect(rows == 0..<3)
  }

  @MainActor @Test func metalDirectRenderRowsMapsViewportDirtyRowsThroughOverscan() {
    let plan = MetalTerminalRenderPlan(
      presentation: .scrollFrame,
      viewportRows: 2,
      cols: 4,
      overscanTopRows: 1,
      overscanBottomRows: 1,
      pixelRemainderY: 4,
      dirtyRows: [0],
      cellSize: CGSize(width: 8, height: 16),
      backingScale: 2,
      isFocused: true
    )

    let rows = MetalDirectRenderEngine.renderRows(for: plan, drawFrameRows: 4)

    #expect(rows == 1..<2)
  }

  @MainActor @Test func metalDirectRenderRowsClampsDirtyRowsToDrawFrame() {
    let plan = MetalTerminalRenderPlan(
      presentation: .scrollFrame,
      viewportRows: 3,
      cols: 4,
      overscanTopRows: 1,
      overscanBottomRows: 1,
      pixelRemainderY: 0,
      dirtyRows: [0, 2, 99],
      cellSize: CGSize(width: 8, height: 16),
      backingScale: 2,
      isFocused: true
    )

    let rows = MetalDirectRenderEngine.renderRows(for: plan, drawFrameRows: 5)

    #expect(rows == 1..<4)
  }

  @MainActor @Test func metalDirectRenderRowRunsKeepsSeparatedDirtyRowsSeparate() {
    let plan = MetalTerminalRenderPlan(
      presentation: .frame,
      viewportRows: 3,
      cols: 4,
      overscanTopRows: 0,
      overscanBottomRows: 0,
      pixelRemainderY: 0,
      dirtyRows: [0, 2],
      cellSize: CGSize(width: 8, height: 16),
      backingScale: 2,
      isFocused: true
    )

    let runs = MetalDirectRenderEngine.renderRowRuns(for: plan, drawFrameRows: 3)

    #expect(runs == [0..<1, 2..<3])
  }

  @MainActor @Test func metalDirectRenderRowRunsAreEmptyForCleanOverlayOnlyFrame() {
    let plan = MetalTerminalRenderPlan(
      presentation: .frame,
      viewportRows: 3,
      cols: 4,
      overscanTopRows: 0,
      overscanBottomRows: 0,
      pixelRemainderY: 0,
      dirtyRows: [],
      cellSize: CGSize(width: 8, height: 16),
      backingScale: 2,
      isFocused: true
    )

    let runs = MetalDirectRenderEngine.renderRowRuns(for: plan, drawFrameRows: 3)

    #expect(runs.isEmpty)
  }

  @MainActor @Test func metalDirectRenderPassClearsFirstFrame() {
    let policy = MetalDirectRenderEngine.renderPassLoadPolicy(
      isFirstFrame: true,
      didResizeTexture: false,
      redrawMode: .dirty,
      renderRows: 1..<2,
      drawFrameRows: 3
    )

    #expect(policy == .clear)
  }

  @MainActor @Test func metalDirectRenderPassClearsAfterResize() {
    let policy = MetalDirectRenderEngine.renderPassLoadPolicy(
      isFirstFrame: false,
      didResizeTexture: true,
      redrawMode: .dirty,
      renderRows: 1..<2,
      drawFrameRows: 3
    )

    #expect(policy == .clear)
  }

  @MainActor @Test func metalDirectRenderPassLoadsForPartialDirtyRows() {
    let policy = MetalDirectRenderEngine.renderPassLoadPolicy(
      isFirstFrame: false,
      didResizeTexture: false,
      redrawMode: .dirty,
      renderRows: 1..<2,
      drawFrameRows: 3
    )

    #expect(policy == .load)
  }

  @MainActor @Test func metalDirectRenderPassLoadsForSparseSeparatedDirtyRows() {
    let policy = MetalDirectRenderEngine.renderPassLoadPolicy(
      isFirstFrame: false,
      didResizeTexture: false,
      redrawMode: .dirty,
      renderRowRuns: [0..<1, 2..<3],
      drawFrameRows: 3
    )

    #expect(policy == .load)
  }

  @MainActor @Test func metalDirectWaitsForCompletionOnFirstFrame() {
    let waits = MetalDirectRenderEngine.shouldWaitForCommandCompletion(
      isFirstFrame: true,
      didResizeTexture: false,
      redrawMode: .dirty,
      loadPolicy: .clear,
      cursorRowDirty: false
    )

    #expect(waits)
  }

  @MainActor @Test func metalDirectWaitsForCompletionOnPartialDirtySceneFrame() {
    let waits = MetalDirectRenderEngine.shouldWaitForCommandCompletion(
      isFirstFrame: false,
      didResizeTexture: false,
      redrawMode: .dirty,
      loadPolicy: .load,
      cursorRowDirty: false,
      rendersScene: true
    )

    #expect(waits)
  }

  @MainActor @Test func metalDirectDoesNotWaitForCompletionOnDrawableOnlyFrame() {
    let waits = MetalDirectRenderEngine.shouldWaitForCommandCompletion(
      isFirstFrame: false,
      didResizeTexture: false,
      redrawMode: .clean,
      loadPolicy: .load,
      cursorRowDirty: false,
      rendersScene: false,
      hasDrawableTransientOverlays: false
    )

    #expect(!waits)
  }

  @MainActor @Test func metalDirectWaitsForCompletionOnDrawableOnlyTransientOverlayFrame() {
    let waits = MetalDirectRenderEngine.shouldWaitForCommandCompletion(
      isFirstFrame: false,
      didResizeTexture: false,
      redrawMode: .clean,
      loadPolicy: .load,
      cursorRowDirty: false,
      rendersScene: false,
      hasDrawableTransientOverlays: true
    )

    #expect(waits)
  }

  @Test func metalDirectFrameCompletionTrackerIgnoresStaleCompletions() {
    var tracker = MetalDirectFrameCompletionTracker()

    let first = tracker.submit(1)
    let second = tracker.submit(2)

    #expect(tracker.complete(first) == false)
    #expect(tracker.completedGeneration == 0)
    #expect(tracker.staleCompletionCount == 1)
    #expect(tracker.complete(second) == true)
    #expect(tracker.completedGeneration == second)
    #expect(tracker.presentedFrameCount == 1)
  }

  @MainActor @Test func metalDirectRendererBackendCoalescesAndDropsPendingFrames() {
    let backend = MetalDirectRendererBackend()

    backend.render(TerminalRenderFrame(frame: frame(rows: ["one"], cols: 8, cursorX: 0, cursorY: 0)))
    backend.render(TerminalRenderFrame(frame: frame(rows: ["two"], cols: 8, cursorX: 0, cursorY: 0)))
    backend.flushPendingFrame()

    #expect(backend.diagnostics.backend == .metalDirect)
    #expect(backend.diagnostics.coalescedFrames == 1)
    #expect(backend.diagnostics.droppedFrames == 1)
    #expect(backend.diagnostics.usesBitmapCapture == false)
  }

  @MainActor @Test func metalDirectRendererBackendEncodesPlanAndUploadsGlyphsAndInstances() {
    let backend = MetalDirectRendererBackend()

    backend.render(TerminalRenderFrame(frame: frame(rows: ["ab", "cd"], cols: 4, cursorX: 0, cursorY: 0)))
    backend.flushPendingFrame()

    let diagnostics = backend.diagnostics
    #expect(diagnostics.backend == .metalDirect)
    #expect(diagnostics.metalDirect.planRows == 2)
    #expect(diagnostics.metalDirect.planCols == 4)
    #expect(diagnostics.metalDirect.uploadedRowCount == 2)
    #expect(diagnostics.metalDirect.uploadedCellCount == 8)
    #expect(diagnostics.metalDirect.glyphAtlasEntryCount == 4)
  }

  @MainActor @Test func metalDirectRendererBackendCachesSameScalarWithDifferentStylesSeparately() {
    let backend = MetalDirectRendererBackend()
    var styledFrame = frame(rows: ["AA"], cols: 2, cursorX: 0, cursorY: 0)
    styledFrame.cells[1] = cell("A", bold: true)

    backend.render(TerminalRenderFrame(frame: styledFrame))
    backend.flushPendingFrame()

    #expect(backend.diagnostics.metalDirect.glyphAtlasEntryCount == 2)
  }

  @MainActor @Test func metalDirectRendererBackendUploadsOnlyDirtyRowsAfterInitialFrame() {
    let backend = MetalDirectRendererBackend()

    backend.render(TerminalRenderFrame(frame: frame(rows: ["abc", "def"], cols: 4, cursorX: 0, cursorY: 0)))
    backend.flushPendingFrame()
    backend.render(TerminalRenderFrame(frame: frame(rows: ["abc", "dxf"], cols: 4, cursorX: 0, cursorY: 0)))
    backend.flushPendingFrame()

    let diagnostics = backend.diagnostics
    #expect(diagnostics.metalDirect.uploadedRowCount == 1)
    #expect(diagnostics.metalDirect.uploadedCellCount == 1)
    #expect(diagnostics.dirtyRowCount == 1)
    #expect(diagnostics.metalDirect.dirtyCellCount == 1)
    #expect(diagnostics.redrawMode == .dirty)
  }

  @MainActor @Test func metalDirectRendererBackendUploadsOnlyDirtyCellRangesAfterInitialFrame() {
    let backend = MetalDirectRendererBackend()
    let initial = frame(rows: ["abcd", "efgh"], cols: 4, cursorX: 0, cursorY: 0)
    var changed = initial
    changed.cells[5] = cell("x")
    changed.cells[6] = cell("y")

    backend.render(TerminalRenderFrame(frame: initial))
    backend.flushPendingFrame()
    backend.render(TerminalRenderFrame(frame: changed))
    backend.flushPendingFrame()

    let diagnostics = backend.diagnostics
    #expect(diagnostics.dirtyRowCount == 1)
    #expect(diagnostics.metalDirect.uploadedRowCount == 1)
    #expect(diagnostics.metalDirect.uploadedCellCount == 2)
    #expect(diagnostics.metalDirect.dirtyCellCount == 2)
  }

  @MainActor @Test func metalDirectRendererBackendDrawsOnlyDirtyRowsAfterInitialFrame() {
    let backend = MetalDirectRendererBackend()

    backend.render(TerminalRenderFrame(frame: frame(rows: ["abc", "def", "ghi"], cols: 4, cursorX: 0, cursorY: 0)))
    backend.flushPendingFrame()
    backend.render(TerminalRenderFrame(frame: frame(rows: ["abc", "dxf", "ghi"], cols: 4, cursorX: 0, cursorY: 0)))
    backend.flushPendingFrame()

    let diagnostics = backend.diagnostics
    // Pattern 2: the backend still diffs and scans only the dirty row/cell for
    // glyph rasterization (uploadedRowCount/dirtyRowCount below), but the GPU
    // draw itself is always the full grid to a freshly cleared drawable — there
    // is no retained offscreen to load partial rows into.
    #expect(diagnostics.redrawMode == .dirty)
    #expect(diagnostics.metalDirect.uploadedRowCount == 1)
    #expect(diagnostics.metalDirect.drawnRowCount == 3)
    #expect(diagnostics.metalDirect.drawnCellCount == 12)
    #expect(diagnostics.metalDirect.renderPassLoadAction == "clear")
    #expect(diagnostics.metalDirect.waitedForCompletion == true)
  }

  @MainActor @Test func metalDirectRendererBackendFullRedrawsAfterThemeChanges() {
    let backend = MetalDirectRendererBackend()
    let snapshot = frame(rows: ["abc", "def"], cols: 4, cursorX: 0, cursorY: 0)

    backend.render(TerminalRenderFrame(frame: snapshot))
    backend.flushPendingFrame()
    backend.applyPalette(.light)
    backend.render(TerminalRenderFrame(frame: snapshot))
    backend.flushPendingFrame()

    let diagnostics = backend.diagnostics
    #expect(diagnostics.redrawMode == .full)
    #expect(diagnostics.dirtyRowCount == 2)
    #expect(diagnostics.metalDirect.drawnRowCount == 2)
  }

  @MainActor @Test func metalDirectRendererBackendUpdatesCursorWithoutDrawingTextRows() {
    let backend = MetalDirectRendererBackend()
    let initial = frame(rows: ["abc", "def", "ghi"], cols: 4, cursorX: 0, cursorY: 0)
    var cursorMoved = initial
    cursorMoved.cursorY = 2

    backend.render(TerminalRenderFrame(frame: initial))
    backend.flushPendingFrame()
    backend.render(TerminalRenderFrame(frame: cursorMoved))
    backend.flushPendingFrame()

    let diagnostics = backend.diagnostics
    // The frame diff is still clean (no text row changed) and no glyph is
    // re-rasterized, but pattern 2 always redraws the full grid to the drawable.
    #expect(diagnostics.redrawMode == .clean)
    #expect(diagnostics.dirtyRowCount == 0)
    #expect(diagnostics.metalDirect.glyphScanRowCount == 0)
    #expect(diagnostics.metalDirect.drawnRowCount == 3)
    #expect(diagnostics.metalDirect.renderPassLoadAction == "clear")
    #expect(diagnostics.metalDirect.waitedForCompletion == true)
  }

  @MainActor @Test func metalDirectRendererBackendRebuildsSceneWhenFocusChanges() {
    let backend = MetalDirectRendererBackend()
    let snapshot = frame(rows: ["abc", "def"], cols: 4, cursorX: 0, cursorY: 0)

    backend.render(TerminalRenderFrame(frame: snapshot, isFocused: true))
    backend.flushPendingFrame()
    backend.render(TerminalRenderFrame(frame: snapshot, isFocused: false))
    backend.flushPendingFrame()

    let diagnostics = backend.diagnostics
    #expect(diagnostics.redrawMode == .full)
    #expect(diagnostics.metalDirect.drawnRowCount == 2)
    #expect(diagnostics.metalDirect.renderPassLoadAction == "clear")
  }

  @MainActor @Test func metalDirectRendererBackendKeepsBlockCursorRowsDirty() {
    let backend = MetalDirectRendererBackend()
    var initial = frame(rows: ["abc", "def", "ghi"], cols: 4, cursorX: 0, cursorY: 0)
    initial.cursorShape = .block
    var cursorMoved = initial
    cursorMoved.cursorY = 2

    backend.render(TerminalRenderFrame(frame: initial))
    backend.flushPendingFrame()
    backend.render(TerminalRenderFrame(frame: cursorMoved))
    backend.flushPendingFrame()

    let diagnostics = backend.diagnostics
    #expect(diagnostics.redrawMode == .dirty)
    #expect(diagnostics.dirtyRowCount == 2)
    #expect(diagnostics.metalDirect.glyphScanRowCount == 2)
    // Pattern 2 always draws the full grid (3 rows) regardless of dirty count.
    #expect(diagnostics.metalDirect.drawnRowCount == 3)
  }

  @MainActor @Test func metalDirectRenderWaitsForCompletionWhenCursorRowIsDirty() {
    let shouldWait = MetalDirectRenderEngine.shouldWaitForCommandCompletion(
      isFirstFrame: false,
      didResizeTexture: false,
      redrawMode: .dirty,
      loadPolicy: .load,
      cursorRowDirty: true,
      rendersScene: true
    )

    #expect(shouldWait)
  }

  @MainActor @Test func metalDirectRendererBackendKeepsSeparatedRunsButDrawsOnlyChangedCells() {
    let backend = MetalDirectRendererBackend()
    let initial = frame(rows: ["abc", "def", "ghi"], cols: 4, cursorX: 0, cursorY: 0)
    var changed = initial
    changed.cursorY = 2
    changed.cells[8] = cell("x")

    backend.render(TerminalRenderFrame(frame: initial))
    backend.flushPendingFrame()
    backend.render(TerminalRenderFrame(frame: changed))
    backend.flushPendingFrame()

    let diagnostics = backend.diagnostics
    // The diff still classifies this as a partial dirty update, but pattern 2's
    // GPU draw is one full-grid pass to a cleared drawable.
    #expect(diagnostics.redrawMode == .dirty)
    #expect(diagnostics.metalDirect.drawRunCount == 1)
    #expect(diagnostics.metalDirect.drawnRowCount == 3)
    #expect(diagnostics.metalDirect.drawnCellCount == 12)
    #expect(diagnostics.metalDirect.renderPassLoadAction == "clear")
  }

  @MainActor @Test func metalDirectRendererBackendScansGlyphsOnlyForDirtyRowsAfterInitialFrame() {
    let backend = MetalDirectRendererBackend()

    backend.render(TerminalRenderFrame(frame: frame(rows: ["abc", "def", "ghi"], cols: 4, cursorX: 0, cursorY: 0)))
    backend.flushPendingFrame()
    backend.render(TerminalRenderFrame(frame: frame(rows: ["abc", "dxf", "ghi"], cols: 4, cursorX: 0, cursorY: 0)))
    backend.flushPendingFrame()

    let diagnostics = backend.diagnostics
    #expect(diagnostics.redrawMode == .dirty)
    #expect(diagnostics.metalDirect.glyphScanRowCount == 1)
    #expect(diagnostics.metalDirect.glyphScanCellCount == 1)
  }

  @MainActor @Test func metalDirectRendererBackendScansStyleStatsOnlyForDirtyRowsAfterInitialFrame() {
    let backend = MetalDirectRendererBackend()
    let initial = frame(rows: ["abc", "def", "ghi"], cols: 4, cursorX: 0, cursorY: 0)
    var changed = initial
    changed.cells[4] = cell("d", bold: true)

    backend.render(TerminalRenderFrame(frame: initial))
    backend.flushPendingFrame()
    backend.render(TerminalRenderFrame(frame: changed))
    backend.flushPendingFrame()

    let diagnostics = backend.diagnostics
    #expect(diagnostics.redrawMode == .dirty)
    #expect(diagnostics.styleStats.boldCells == 1)
    #expect(diagnostics.metalDirect.styleScanRowCount == 1)
    #expect(diagnostics.metalDirect.styleScanCellCount == 4)
  }

  @MainActor @Test func metalDirectRendererBackendAggregatesStyleStatsIncrementallyForDirtyRowsAfterInitialFrame() {
    let backend = MetalDirectRendererBackend()
    let initial = frame(rows: ["abc", "def", "ghi"], cols: 4, cursorX: 0, cursorY: 0)
    var changed = initial
    changed.cells[4] = cell("d", italic: true)

    backend.render(TerminalRenderFrame(frame: initial))
    backend.flushPendingFrame()
    backend.render(TerminalRenderFrame(frame: changed))
    backend.flushPendingFrame()

    let diagnostics = backend.diagnostics
    #expect(diagnostics.styleStats.italicCells == 1)
    #expect(diagnostics.metalDirect.styleAggregateRowCount == 1)
  }

  @MainActor @Test func metalDirectRendererBackendScansResizeSensitivityOnlyForDirtyRowsBelowCursorAfterInitialFrame() {
    let backend = MetalDirectRendererBackend()
    let initial = frame(rows: ["abc", "def", "ghi"], cols: 4, cursorX: 0, cursorY: 1)
    var changed = initial
    changed.cells[0] = cell("x")

    backend.render(TerminalRenderFrame(frame: initial))
    backend.flushPendingFrame()
    backend.render(TerminalRenderFrame(frame: changed))
    backend.flushPendingFrame()

    let diagnostics = backend.diagnostics
    #expect(diagnostics.resizeSensitiveScreen == true)
    #expect(diagnostics.metalDirect.resizeSensitivityScanRowCount == 0)
    #expect(diagnostics.metalDirect.resizeSensitivityScanCellCount == 0)
  }

  @MainActor @Test func metalDirectRendererBackendRecordsMetalPresentations() {
    let backend = MetalDirectRendererBackend()

    backend.render(TerminalRenderFrame(frame: frame(rows: ["ab", "cd"], cols: 4, cursorX: 0, cursorY: 0)))
    backend.flushPendingFrame()

    let diagnostics = backend.diagnostics
    #expect(diagnostics.backend == .metalDirect)
    #expect(diagnostics.metalDirect.presentedFrameCount == 1)
    #expect(diagnostics.metalDirect.drawPassCount == 1)
    #expect(diagnostics.metalDirect.pipelineReady == true)
    #expect(diagnostics.metalDirect.staleCompletionCount == 0)
  }

  @MainActor @Test func metalDirectRendererBackendReframesOnViewportChangesWithoutRedrawingText() {
    let backend = MetalDirectRendererBackend()
    let scrollFrame = scrollFrame(
      viewportRows: ["two", "three"],
      overscanTop: ["one"],
      overscanBottom: ["four"],
      cols: 8
    )

    backend.render(TerminalRenderFrame(scrollFrame: scrollFrame, isFocused: true, generation: 17))
    backend.flushPendingFrame()
    backend.gridView.testScrollWheelDeltaY(5)
    backend.flushPendingFrame()

    let diagnostics = backend.diagnostics
    #expect(diagnostics.pixelRemainderY == 5)
    #expect(diagnostics.metalDirect.drawPassCount == 2)
    #expect(diagnostics.metalDirect.latestSubmittedGeneration == 18)
    // A reframe on scroll redraws the whole expanded grid (viewport+overscan = 4
    // rows × 8 cols) shifted by the new pixel remainder.
    #expect(diagnostics.metalDirect.drawnCellCount == 32)
    #expect(diagnostics.metalDirect.renderPassLoadAction == "clear")
  }

  @MainActor @Test func metalDirectRendererBackendKeepsScrollOverscanChangesDirty() {
    let backend = MetalDirectRendererBackend()
    let initial = scrollFrame(
      viewportRows: ["two", "three"],
      overscanTop: ["one"],
      overscanBottom: ["four"],
      cols: 8
    )
    let changedOverscan = scrollFrame(
      viewportRows: ["two", "three"],
      overscanTop: ["zero"],
      overscanBottom: ["four"],
      cols: 8
    )

    backend.render(TerminalRenderFrame(scrollFrame: initial, isFocused: true))
    backend.flushPendingFrame()
    backend.render(TerminalRenderFrame(scrollFrame: changedOverscan, isFocused: true))
    backend.flushPendingFrame()

    let diagnostics = backend.diagnostics
    #expect(diagnostics.redrawMode != .full)
    #expect(diagnostics.metalDirect.fullRedrawReason == "none")
    // Pattern 2 draws the full expanded grid (4 rows) every frame with a clear.
    #expect(diagnostics.metalDirect.drawnRowCount == 4)
    #expect(diagnostics.metalDirect.renderPassLoadAction == "clear")
  }

  @MainActor @Test func metalDirectRendererBackendStagesResizeFramesUntilDiagnosticsComplete() {
    let backend = MetalDirectRendererBackend()

    backend.render(TerminalRenderFrame(frame: frame(rows: ["old"], cols: 4, cursorX: 0, cursorY: 0), generation: 10))
    backend.flushPendingFrame()
    backend.markResizePending()
    backend.render(TerminalRenderFrame(frame: frame(rows: ["new", "wide"], cols: 8, cursorX: 0, cursorY: 0), generation: 11))
    backend.flushPendingFrame()

    var diagnostics = backend.diagnostics
    #expect(diagnostics.pendingResize)
    #expect(diagnostics.metalDirect.planRows == 1)
    #expect(diagnostics.metalDirect.planCols == 4)
    #expect(diagnostics.metalDirect.latestSubmittedGeneration == 10)

    backend.applyResizeDiagnostics(TerminalResizeDiagnostics(
      totalDuration: 0.3,
      vtDuration: 0.1,
      snapshotDuration: 0.2
    ))

    diagnostics = backend.diagnostics
    #expect(!diagnostics.pendingResize)
    #expect(diagnostics.metalDirect.planRows == 2)
    #expect(diagnostics.metalDirect.planCols == 8)
    #expect(diagnostics.metalDirect.latestSubmittedGeneration == 11)
    #expect(diagnostics.lastResizeTotalDuration == 0.3)
  }

  @MainActor @Test func metalDirectRendererBackendDropsPendingFrameWhenResizeBegins() {
    let backend = MetalDirectRendererBackend()

    backend.render(TerminalRenderFrame(frame: frame(rows: ["old"], cols: 4, cursorX: 0, cursorY: 0), generation: 10))
    backend.flushPendingFrame()
    backend.render(TerminalRenderFrame(frame: frame(rows: ["stale"], cols: 4, cursorX: 0, cursorY: 0), generation: 11))
    backend.markResizePending()
    backend.flushPendingFrame()

    let diagnostics = backend.diagnostics
    // Unflushed gen 11 is dropped; last good gen 10 is re-painted for the blackout.
    #expect(diagnostics.metalDirect.latestPresentedGeneration == 10)
    #expect(diagnostics.metalDirect.planRows == 1)
    #expect(diagnostics.metalDirect.planCols == 4)
    #expect(diagnostics.droppedFrames >= 1)
    #expect(diagnostics.pendingResize)
  }

  @MainActor @Test func metalDirectRendererBackendKeepsLastFramePaintedWhileResizePending() {
    let backend = MetalDirectRendererBackend()

    backend.render(TerminalRenderFrame(frame: frame(rows: ["old"], cols: 4, cursorX: 0, cursorY: 0), generation: 10))
    backend.flushPendingFrame()
    backend.markResizePending()

    // New VT-sized frames stage only — must not replace the on-screen old frame yet.
    backend.render(TerminalRenderFrame(frame: frame(rows: ["new", "wide"], cols: 8, cursorX: 0, cursorY: 0), generation: 11))
    backend.flushPendingFrame()

    var diagnostics = backend.diagnostics
    #expect(diagnostics.pendingResize)
    #expect(diagnostics.metalDirect.planRows == 1)
    #expect(diagnostics.metalDirect.planCols == 4)
    #expect(diagnostics.metalDirect.latestPresentedGeneration == 10)

    backend.applyResizeDiagnostics(TerminalResizeDiagnostics(
      totalDuration: 0.2,
      vtDuration: 0.1,
      snapshotDuration: 0.1
    ))

    diagnostics = backend.diagnostics
    #expect(!diagnostics.pendingResize)
    #expect(diagnostics.metalDirect.planRows == 2)
    #expect(diagnostics.metalDirect.planCols == 8)
    #expect(diagnostics.metalDirect.latestPresentedGeneration == 11)
  }

  @MainActor @Test func metalDirectRendererBackendKeepsLatestResizeStageGeneration() {
    let backend = MetalDirectRendererBackend()

    backend.render(TerminalRenderFrame(frame: frame(rows: ["old"], cols: 4, cursorX: 0, cursorY: 0), generation: 10))
    backend.flushPendingFrame()
    backend.markResizePending()
    backend.render(TerminalRenderFrame(frame: frame(rows: ["new", "wide"], cols: 8, cursorX: 0, cursorY: 0), generation: 12))
    backend.render(TerminalRenderFrame(frame: frame(rows: ["stale"], cols: 6, cursorX: 0, cursorY: 0), generation: 11))

    backend.applyResizeDiagnostics(TerminalResizeDiagnostics(
      totalDuration: 0.3,
      vtDuration: 0.1,
      snapshotDuration: 0.2
    ))

    let diagnostics = backend.diagnostics
    #expect(diagnostics.metalDirect.planRows == 2)
    #expect(diagnostics.metalDirect.planCols == 8)
    #expect(diagnostics.metalDirect.latestSubmittedGeneration == 12)
    #expect(diagnostics.metalDirect.latestPresentedGeneration == 12)
  }

  @MainActor @Test func metalDirectRendererBackendDiagnosticsReadLatestEngineCompletionCounters() {
    let engine = MutableMetalDirectRenderingEngine()
    let backend = MetalDirectRendererBackend(options: TerminalRendererOptions()) { _ in engine }

    backend.render(TerminalRenderFrame(frame: frame(rows: ["ab"], cols: 4, cursorX: 0, cursorY: 0)))
    backend.flushPendingFrame()
    engine.presentedFrameCount = 3
    engine.staleCompletionCount = 2

    let diagnostics = backend.diagnostics
    #expect(diagnostics.metalDirect.presentedFrameCount == 3)
    #expect(diagnostics.metalDirect.staleCompletionCount == 2)
  }

  @MainActor @Test func metalDirectRendererBackendReportsFullRedrawReasonAndExpandedFrameCellCount() {
    let backend = MetalDirectRendererBackend()

    backend.render(TerminalRenderFrame(frame: frame(rows: ["ab", "cd"], cols: 4, cursorX: 0, cursorY: 0)))
    backend.flushPendingFrame()

    let diagnostics = backend.diagnostics
    #expect(diagnostics.metalDirect.fullRedrawReason == "grid-size-changed")
    #expect(diagnostics.metalDirect.expandedFrameCellCount == 8)
    #expect(diagnostics.debugSummary.contains("metalDirectFullRedrawReason=\"grid-size-changed\""))
    #expect(diagnostics.debugSummary.contains("metalDirectExpandedFrameCells=8"))
  }

  @MainActor @Test func metalDirectRendererBackendReportsTextureCacheAndGPUWaitDiagnosticsFromEngine() {
    let engine = MutableMetalDirectRenderingEngine()
    engine.lastGlyphTextureHitCount = 9
    engine.lastGlyphTextureMissCount = 3
    engine.lastGPUWaitReason = "full-redraw"
    let backend = MetalDirectRendererBackend(options: TerminalRendererOptions()) { _ in engine }

    backend.render(TerminalRenderFrame(frame: frame(rows: ["ab"], cols: 4, cursorX: 0, cursorY: 0)))
    backend.flushPendingFrame()

    let diagnostics = backend.diagnostics
    #expect(diagnostics.metalDirect.glyphTextureHitCount == 9)
    #expect(diagnostics.metalDirect.glyphTextureMissCount == 3)
    #expect(diagnostics.metalDirect.textureCacheHitRate == 0.75)
    #expect(diagnostics.metalDirect.gpuWaitReason == "full-redraw")
    #expect(diagnostics.debugSummary.contains("metalDirectGlyphTextureHits=9"))
    #expect(diagnostics.debugSummary.contains("metalDirectGlyphTextureMisses=3"))
    #expect(diagnostics.debugSummary.contains("metalDirectTextureHitRate=0.750"))
    #expect(diagnostics.debugSummary.contains("metalDirectGPUWaitReason=\"full-redraw\""))
  }

  @MainActor @Test func metalDirectRendererBackendReportsFallbackReasonWhenRenderFails() {
    let backend = MetalDirectRendererBackend(options: TerminalRendererOptions()) { _ in
      FailingMetalDirectRenderingEngine()
    }

    backend.render(TerminalRenderFrame(frame: frame(rows: ["ab"], cols: 4, cursorX: 0, cursorY: 0)))
    backend.flushPendingFrame()

    let diagnostics = backend.diagnostics
    #expect(diagnostics.backend == .metalDirect)
    #expect(diagnostics.backendFallbackReason == TerminalRendererDiagnostics.metalDirectRenderFailedFallbackReason)
  }

  @MainActor @Test func metalDirectRendererBackendPresentsSelectionOverlayChanges() throws {
    let engine = MutableMetalDirectRenderingEngine()
    let backend = MetalDirectRendererBackend(options: TerminalRendererOptions()) { _ in engine }
    backend.directView.frame = NSRect(x: 0, y: 0, width: 320, height: 160)
    backend.directView.bounds = backend.directView.frame
    backend.render(TerminalRenderFrame(frame: frame(rows: ["abcd", "efgh"], cols: 4, cursorX: 0, cursorY: 0)))
    backend.flushPendingFrame()
    let initialPresentedFrameCount = engine.presentedFrameCount

    let cellSize = backend.directView.terminalCellSize
    let inset = backend.directView.terminalContentInset
    let start = NSPoint(x: inset.width + cellSize.width * 0.5, y: inset.height + cellSize.height * 0.5)
    let end = NSPoint(x: inset.width + cellSize.width * 2.5, y: inset.height + cellSize.height * 1.5)
    backend.directView.mouseDown(with: try mouseEvent(.leftMouseDown, viewPoint: start, in: backend.directView))
    backend.directView.mouseDragged(with: try mouseEvent(.leftMouseDragged, viewPoint: end, in: backend.directView))
    backend.flushPendingFrame()

    #expect(engine.presentedFrameCount > initialPresentedFrameCount)
    #expect(engine.lastSelectionCellRanges.contains(GridSelectionCellRange(row: 0, cols: 0..<4)))
    #expect(engine.lastSelectionCellRanges.contains(GridSelectionCellRange(row: 1, cols: 0..<3)))
  }

  @MainActor @Test func metalDirectRenderEngineForcesFullRebuildWhenImeMarkedTextChanges() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let engine = try MetalDirectRenderEngine(device: device)
    let view = MetalDirectRendererView(device: device)
    let glyphAtlas = MetalGlyphAtlas(
      fontFamily: FontManager.defaultMonospacedFontName(),
      fontSize: 14,
      backingScale: 1
    )
    let frame = frame(rows: ["abcdef"], cols: 6, cursorX: 2, cursorY: 0)
    let renderFrame = TerminalRenderFrame(frame: frame, isFocused: true)
    let cellSize = view.terminalCellSize
    let backingScale = view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
    let plan = MetalTerminalFrameEncoder.encode(
      renderFrame,
      pixelRemainderY: 0,
      dirtyRows: [],
      dirtyCellRanges: [],
      cellSize: cellSize,
      backingScale: backingScale,
      transientOverlayRevision: 0
    )

    view.frame = NSRect(
      x: 0,
      y: 0,
      width: view.terminalContentInset.width * 2 + CGFloat(frame.cols) * cellSize.width,
      height: view.terminalContentInset.height * 2 + CGFloat(frame.rows) * cellSize.height
    )
    view.bounds = view.frame
    view.render(frame, isFocused: true)

    #expect(engine.render(
      renderFrame: renderFrame,
      plan: plan,
      view: view,
      palette: .dark,
      glyphAtlas: glyphAtlas
    ))
    #expect(engine.lastRenderPassLoadPolicy == .clear)
    #expect(engine.lastRenderedRowCount == frame.rows)

    let idlePlan = MetalTerminalFrameEncoder.encode(
      renderFrame,
      pixelRemainderY: 0,
      dirtyRows: [],
      dirtyCellRanges: [],
      cellSize: cellSize,
      backingScale: backingScale,
      transientOverlayRevision: 0
    )

    #expect(engine.render(
      renderFrame: renderFrame,
      plan: idlePlan,
      view: view,
      palette: .dark,
      glyphAtlas: glyphAtlas
    ))
    #expect(engine.lastRenderPassLoadPolicy == .clear)
    #expect(engine.lastRenderedRowCount == frame.rows)

    view.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
    let markedPlan = MetalTerminalFrameEncoder.encode(
      renderFrame,
      pixelRemainderY: 0,
      dirtyRows: [],
      dirtyCellRanges: [],
      cellSize: cellSize,
      backingScale: backingScale,
      transientOverlayRevision: view.markedTextStateRevision
    )

    #expect(engine.render(
      renderFrame: renderFrame,
      plan: markedPlan,
      view: view,
      palette: .dark,
      glyphAtlas: glyphAtlas
    ))
    #expect(engine.lastRenderPassLoadPolicy == .clear)
    #expect(engine.lastRenderedRowCount == frame.rows)

    view.unmarkText()
    let clearedPlan = MetalTerminalFrameEncoder.encode(
      renderFrame,
      pixelRemainderY: 0,
      dirtyRows: [],
      dirtyCellRanges: [],
      cellSize: cellSize,
      backingScale: backingScale,
      transientOverlayRevision: view.markedTextStateRevision
    )

    #expect(engine.render(
      renderFrame: renderFrame,
      plan: clearedPlan,
      view: view,
      palette: .dark,
      glyphAtlas: glyphAtlas
    ))
    #expect(engine.lastRenderPassLoadPolicy == .clear)
    #expect(engine.lastRenderedRowCount == frame.rows)
  }

  @MainActor @Test func metalDirectBlockCursorGlyphLayoutDrawsCursorCellTextOnDrawable() {
    var snapshot = frame(rows: ["abc"], cols: 3, cursorX: 1, cursorY: 0)
    snapshot.cursorShape = .block
    let plan = MetalTerminalRenderPlan(
      presentation: .frame,
      viewportRows: 1,
      cols: 3,
      overscanTopRows: 0,
      overscanBottomRows: 0,
      pixelRemainderY: 0,
      dirtyRows: [],
      cellSize: CGSize(width: 8, height: 16),
      backingScale: 2,
      isFocused: true
    )

    let glyph = MetalDirectRenderEngine.cursorGlyphLayout(
      renderFrame: TerminalRenderFrame(frame: snapshot, isFocused: true),
      plan: plan,
      contentInset: CGSize(width: 14, height: 12),
      markedTextActive: false
    )

    #expect(glyph?.scalar == "b")
    #expect(glyph?.rect.minX == CGFloat(14 * 2 + 1 * 8 * 2))
  }

  @Test func metalOverlayBufferBuildsCursorAndSelectionPrimitives() {
    let plan = MetalTerminalRenderPlan(
      presentation: .scrollFrame,
      viewportRows: 2,
      cols: 4,
      overscanTopRows: 1,
      overscanBottomRows: 1,
      pixelRemainderY: 5,
      dirtyRows: [0, 1],
      cellSize: CGSize(width: 8, height: 16),
      backingScale: 2,
      isFocused: true
    )
    let frame = TerminalRenderFrame(
      scrollFrame: scrollFrame(
        viewportRows: ["ab", "cd"],
        overscanTop: ["xx"],
        overscanBottom: ["yy"],
        cols: 4
      ),
      isFocused: true
    )
    let overlays = MetalOverlayBuffer.makeOverlays(
      renderFrame: frame,
      plan: plan,
      selectedRows: [1],
      selectionRowsOffset: 1,
      linkHoverRows: [2]
    )

    #expect(overlays.contains(where: { $0.kind == .cursor }))
    #expect(overlays.contains(where: { $0.kind == .selection }))
    #expect(overlays.contains(where: { $0.kind == .linkHover }))
    #expect(overlays.filter({ $0.kind == .selection }).count == 1)
    #expect(overlays.filter({ $0.kind == .cursor }).count == 1)
  }

  @Test func metalOverlayBufferSuppressesCursorWhileMarkedTextCompositionIsActive() {
    let plan = MetalTerminalRenderPlan(
      presentation: .frame,
      viewportRows: 1,
      cols: 4,
      overscanTopRows: 0,
      overscanBottomRows: 0,
      pixelRemainderY: 0,
      dirtyRows: [0],
      cellSize: CGSize(width: 8, height: 16),
      backingScale: 2,
      isFocused: true
    )
    let frame = TerminalRenderFrame(
      frame: frame(rows: ["abcd"], cols: 4, cursorX: 1, cursorY: 0),
      isFocused: true
    )

    let overlays = MetalOverlayBuffer.makeOverlays(
      renderFrame: frame,
      plan: plan,
      markedTextActive: true
    )

    #expect(!overlays.contains(where: { $0.kind == .cursor }))
  }

  @Test func metalOverlayBufferCoversIMECompositionCursorCellWhileMarkedTextCompositionIsActive() {
    let plan = MetalTerminalRenderPlan(
      presentation: .frame,
      viewportRows: 1,
      cols: 4,
      overscanTopRows: 0,
      overscanBottomRows: 0,
      pixelRemainderY: 0,
      dirtyRows: [0],
      cellSize: CGSize(width: 8, height: 16),
      backingScale: 2,
      isFocused: true
    )
    let frame = TerminalRenderFrame(
      frame: frame(rows: ["abcd"], cols: 4, cursorX: 1, cursorY: 0),
      isFocused: true
    )

    let overlays = MetalOverlayBuffer.makeOverlays(
      renderFrame: frame,
      plan: plan,
      palette: .dark,
      markedTextActive: true,
      imeCompositionCursorOverlay: MetalMarkedTextOverlay(row: 0, col: 2, width: 8)
    )

    let cursorCover = overlays.first(where: { $0.kind == .cursor })
    #expect(cursorCover?.phase == .aboveGlyphs)
    #expect(cursorCover?.rect.minX == CGFloat(14 * 2 + 2 * 8 * 2))
    #expect(cursorCover?.rect.width == CGFloat(8 * 2))
  }

  @Test func metalOverlayBufferScopesSelectionToCellRanges() {
    let plan = MetalTerminalRenderPlan(
      presentation: .frame,
      viewportRows: 2,
      cols: 8,
      overscanTopRows: 0,
      overscanBottomRows: 0,
      pixelRemainderY: 0,
      dirtyRows: [0, 1],
      cellSize: CGSize(width: 8, height: 16),
      backingScale: 2,
      isFocused: true
    )
    let renderFrame = TerminalRenderFrame(
      frame: frame(rows: ["abcdefgh", "ijklmnop"], cols: 8, cursorX: 0, cursorY: 0),
      isFocused: true
    )

    let overlays = MetalOverlayBuffer.makeOverlays(
      renderFrame: renderFrame,
      plan: plan,
      selectedCellRanges: [
        MetalSelectionCellRange(row: 1, cols: 2..<5),
      ]
    )

    let selection = overlays.first(where: { $0.kind == .selection })
    let expectedMinX = CGFloat(14 * 2 + 2 * 8 * 2)
    let expectedWidth = CGFloat(3 * 8 * 2)
    #expect(selection?.rect.minX == expectedMinX)
    #expect(selection?.rect.width == expectedWidth)
  }

  @Test func metalOverlayBufferScopesLinkHoverToCellRange() {
    let plan = MetalTerminalRenderPlan(
      presentation: .frame,
      viewportRows: 1,
      cols: 12,
      overscanTopRows: 0,
      overscanBottomRows: 0,
      pixelRemainderY: 0,
      dirtyRows: [0],
      cellSize: CGSize(width: 8, height: 16),
      backingScale: 2,
      isFocused: true
    )
    let renderFrame = TerminalRenderFrame(
      frame: frame(rows: ["hello world"], cols: 12, cursorX: 0, cursorY: 0),
      isFocused: true
    )

    let overlays = MetalOverlayBuffer.makeOverlays(
      renderFrame: renderFrame,
      plan: plan,
      linkHoverCellRanges: [
        MetalLinkHoverCellRange(row: 0, cols: 6..<11),
      ]
    )

    let hover = overlays.first(where: { $0.kind == .linkHover })
    let expectedMinX = CGFloat(14 * 2 + 6 * 8 * 2)
    let expectedWidth = CGFloat(5 * 8 * 2)
    #expect(hover?.rect.minX == expectedMinX)
    #expect(hover?.rect.width == expectedWidth)
  }

  @Test func metalOverlayBufferBuildsMarkedTextPrimitive() {
    let plan = MetalTerminalRenderPlan(
      presentation: .frame,
      viewportRows: 1,
      cols: 12,
      overscanTopRows: 0,
      overscanBottomRows: 0,
      pixelRemainderY: 0,
      dirtyRows: [0],
      cellSize: CGSize(width: 8, height: 16),
      backingScale: 2,
      isFocused: true
    )
    let renderFrame = TerminalRenderFrame(
      frame: frame(rows: ["            "], cols: 12, cursorX: 2, cursorY: 0),
      isFocused: true
    )

    let overlays = MetalOverlayBuffer.makeOverlays(
      renderFrame: renderFrame,
      plan: plan,
      markedTextActive: true,
      markedTextOverlay: MetalMarkedTextOverlay(row: 0, col: 2, width: 44)
    )

    let markedText = overlays.first(where: { $0.kind == .markedText })
    let expectedMinX = CGFloat(14 * 2 + 2 * 8 * 2)
    #expect(markedText?.rect.minX == expectedMinX)
    #expect(markedText?.rect.width == CGFloat(44 * 2))
  }

  @Test func metalOverlayBufferUsesResolvedCursorOverlayForTransientHomeCursor() {
    let plan = MetalTerminalRenderPlan(
      presentation: .frame,
      viewportRows: 12,
      cols: 12,
      overscanTopRows: 0,
      overscanBottomRows: 0,
      pixelRemainderY: 0,
      dirtyRows: [0, 9],
      cellSize: CGSize(width: 8, height: 16),
      backingScale: 2,
      isFocused: true
    )
    let renderFrame = TerminalRenderFrame(
      frame: frame(rows: [
        "history 1",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "> /res",
        "/resume",
        "",
      ], cols: 12, cursorX: 0, cursorY: 0),
      isFocused: true
    )

    let overlays = MetalOverlayBuffer.makeOverlays(
      renderFrame: renderFrame,
      plan: plan,
      cursorOverlay: MetalMarkedTextOverlay(row: 9, col: 6, width: 8)
    )

    let cursor = overlays.first(where: { $0.kind == .cursor })
    #expect(cursor?.rect.minX == CGFloat(14 * 2 + 6 * 8 * 2))
    #expect(cursor?.rect.minY == CGFloat(12 * 2 + 9 * 16 * 2))
  }

  @Test func metalOverlayBufferSuppressesCursorWhileMarkedTextIsActive() {
    let plan = MetalTerminalRenderPlan(
      presentation: .frame,
      viewportRows: 1,
      cols: 12,
      overscanTopRows: 0,
      overscanBottomRows: 0,
      pixelRemainderY: 0,
      dirtyRows: [0],
      cellSize: CGSize(width: 8, height: 16),
      backingScale: 2,
      isFocused: true
    )
    let renderFrame = TerminalRenderFrame(
      frame: frame(rows: ["            "], cols: 12, cursorX: 2, cursorY: 0),
      isFocused: true
    )

    let overlays = MetalOverlayBuffer.makeOverlays(
      renderFrame: renderFrame,
      plan: plan,
      markedTextActive: true,
      markedTextOverlay: MetalMarkedTextOverlay(row: 0, col: 2, width: 44)
    )

    #expect(!overlays.contains(where: { $0.kind == .cursor }))
    #expect(overlays.contains(where: { $0.kind == .markedText }))
  }

  @MainActor @Test func metalDirectCursorGlyphLayoutUsesResolvedCursorOverlayForTransientHomeCursor() {
    var snapshot = frame(rows: ["h", "", "> /res"], cols: 12, cursorX: 0, cursorY: 0)
    snapshot.cursorShape = .block
    let plan = MetalTerminalRenderPlan(
      presentation: .frame,
      viewportRows: 3,
      cols: 12,
      overscanTopRows: 0,
      overscanBottomRows: 0,
      pixelRemainderY: 0,
      dirtyRows: [0, 2],
      cellSize: CGSize(width: 8, height: 16),
      backingScale: 2,
      isFocused: true
    )

    let glyph = MetalDirectRenderEngine.cursorGlyphLayout(
      renderFrame: TerminalRenderFrame(frame: snapshot, isFocused: true),
      plan: plan,
      contentInset: CGSize(width: 14, height: 12),
      markedTextActive: false,
      cursorOverlay: MetalMarkedTextOverlay(row: 2, col: 6, width: 8)
    )

    #expect(glyph == nil)
  }

  @MainActor @Test func metalDirectMarkedTextGlyphLayoutDrawsCompositionStringAtOverlayOrigin() {
    let plan = MetalTerminalRenderPlan(
      presentation: .frame,
      viewportRows: 1,
      cols: 12,
      overscanTopRows: 0,
      overscanBottomRows: 0,
      pixelRemainderY: 0,
      dirtyRows: [0],
      cellSize: CGSize(width: 8, height: 16),
      backingScale: 2,
      isFocused: true
    )
    let renderFrame = TerminalRenderFrame(
      frame: frame(rows: ["            "], cols: 12, cursorX: 2, cursorY: 0),
      isFocused: true
    )

    let glyphs = MetalDirectRenderEngine.markedTextGlyphLayout(
      text: "zhong",
      overlay: MetalMarkedTextOverlay(row: 0, col: 2, width: 44),
      renderFrame: renderFrame,
      plan: plan,
      contentInset: CGSize(width: 14, height: 12)
    )

    #expect(glyphs.map(\.scalar) == ["z", "h", "o", "n", "g"])
    #expect(glyphs.first?.rect.minX == CGFloat(14 * 2 + 2 * 8 * 2))
    #expect(glyphs.last?.rect.minX == CGFloat(14 * 2 + 6 * 8 * 2))
  }

  @Test func metalOverlayBufferAppliesPixelScrollTranslationToSelectionGeometry() {
    let plan = MetalTerminalRenderPlan(
      presentation: .scrollFrame,
      viewportRows: 2,
      cols: 8,
      overscanTopRows: 1,
      overscanBottomRows: 1,
      pixelRemainderY: 5,
      dirtyRows: [0, 1],
      cellSize: CGSize(width: 8, height: 16),
      backingScale: 2,
      isFocused: true
    )
    let renderFrame = TerminalRenderFrame(
      scrollFrame: scrollFrame(
        viewportRows: ["two", "three"],
        overscanTop: ["one"],
        overscanBottom: ["four"],
        cols: 8
      ),
      isFocused: true
    )

    let overlays = MetalOverlayBuffer.makeOverlays(
      renderFrame: renderFrame,
      plan: plan,
      selectedCellRanges: [
        MetalSelectionCellRange(row: 1, cols: 0..<2),
      ]
    )

    let selection = overlays.first(where: { $0.kind == .selection })
    let expectedTranslationY = CGFloat(-1 * 16 * 2 + 5 * 2)
    let expectedMinY = CGFloat(12 * 2) + CGFloat(1 * 16 * 2) + expectedTranslationY
    #expect(selection?.rect.minY == expectedMinY)
  }

  /// PTYGridView selection ranges are already in expanded-frame row space
  /// (overscanTop + viewport). MetalDirectRenderEngine must pass
  /// `selectionRowsOffset: 0`. Adding overscanTop again double-shifts the
  /// highlight (browse: +1 row; live large overscan: highlight off-screen).
  @Test func metalOverlayBufferExpandedFrameSelectionNeedsZeroRowsOffset() {
    let plan = MetalTerminalRenderPlan(
      presentation: .scrollFrame,
      viewportRows: 2,
      cols: 8,
      overscanTopRows: 1,
      overscanBottomRows: 1,
      pixelRemainderY: 0,
      dirtyRows: [0, 1],
      cellSize: CGSize(width: 8, height: 16),
      backingScale: 1,
      isFocused: true
    )
    let renderFrame = TerminalRenderFrame(
      scrollFrame: scrollFrame(
        viewportRows: ["two", "three"],
        overscanTop: ["one"],
        overscanBottom: ["four"],
        cols: 8
      ),
      isFocused: true
    )

    // First viewport row is expanded index 1 (after 1 overscan top row).
    let correct = MetalOverlayBuffer.makeOverlays(
      renderFrame: renderFrame,
      plan: plan,
      selectedCellRanges: [MetalSelectionCellRange(row: 1, cols: 0..<2)],
      selectionRowsOffset: 0
    ).first(where: { $0.kind == .selection })
    let wrong = MetalOverlayBuffer.makeOverlays(
      renderFrame: renderFrame,
      plan: plan,
      selectedCellRanges: [MetalSelectionCellRange(row: 1, cols: 0..<2)],
      selectionRowsOffset: 1
    ).first(where: { $0.kind == .selection })

    let translationY = CGFloat(-1 * 16)
    let expectedMinY = CGFloat(12) + CGFloat(1 * 16) + translationY
    #expect(correct?.rect.minY == expectedMinY)
    #expect(wrong?.rect.minY == expectedMinY + 16)
  }

  @Test func metalOverlayBufferAppliesPixelScrollTranslationToLinkHoverGeometry() {
    let plan = MetalTerminalRenderPlan(
      presentation: .scrollFrame,
      viewportRows: 2,
      cols: 8,
      overscanTopRows: 1,
      overscanBottomRows: 1,
      pixelRemainderY: 5,
      dirtyRows: [0, 1],
      cellSize: CGSize(width: 8, height: 16),
      backingScale: 2,
      isFocused: true
    )
    let renderFrame = TerminalRenderFrame(
      scrollFrame: scrollFrame(
        viewportRows: ["two", "three"],
        overscanTop: ["one"],
        overscanBottom: ["four"],
        cols: 8
      ),
      isFocused: true
    )

    let overlays = MetalOverlayBuffer.makeOverlays(
      renderFrame: renderFrame,
      plan: plan,
      linkHoverCellRanges: [
        MetalLinkHoverCellRange(row: 1, cols: 0..<2),
      ]
    )

    let hover = overlays.first(where: { $0.kind == .linkHover })
    let expectedTranslationY = CGFloat(-1 * 16 * 2 + 5 * 2)
    let expectedRowMinY = CGFloat(12 * 2) + CGFloat(1 * 16 * 2) + expectedTranslationY
    let expectedUnderlineTop = expectedRowMinY + CGFloat(16 * 2) - max(1, CGFloat(16 * 2) * 0.10)
    #expect(hover?.rect.minY == expectedUnderlineTop)
  }

  @Test func metalTerminalFrameEncoderPreservesOverscanPixelRemainderAndDirtyRows() {
    let scrollFrame = scrollFrame(
      viewportRows: ["two", "three"],
      overscanTop: ["one"],
      overscanBottom: ["four"],
      cols: 8
    )

    let plan = MetalTerminalFrameEncoder.encode(
      TerminalRenderFrame(scrollFrame: scrollFrame, isFocused: true),
      pixelRemainderY: 5,
      dirtyRows: [1],
      cellSize: CGSize(width: 8, height: 16),
      backingScale: 2
    )

    #expect(plan.presentation == .scrollFrame)
    #expect(plan.viewportRows == 2)
    #expect(plan.cols == 8)
    #expect(plan.overscanTopRows == 1)
    #expect(plan.overscanBottomRows == 1)
    #expect(plan.pixelRemainderY == 5)
    #expect(plan.dirtyRows == [1])
    #expect(plan.cellSize == CGSize(width: 8, height: 16))
    #expect(plan.backingScale == 2)
    #expect(plan.isFocused == true)
  }

  @MainActor @Test func metalGlyphAtlasReusesRepeatedGlyphEntries() {
    let atlas = MetalGlyphAtlas(fontFamily: "Menlo", fontSize: 14, backingScale: 2)

    let first = atlas.entry(for: "A")
    let second = atlas.entry(for: "A")

    #expect(first.id == second.id)
    #expect(first.generation == second.generation)
    #expect(atlas.entryCount == 1)
  }

  @MainActor @Test func metalGlyphAtlasCachesStyledGlyphsSeparately() {
    let atlas = MetalGlyphAtlas(fontFamily: "Menlo", fontSize: 14, backingScale: 2)

    let regular = atlas.entry(for: "A")
    let bold = atlas.entry(for: "A", style: MetalGlyphStyle(bold: true))
    let italic = atlas.entry(for: "A", style: MetalGlyphStyle(italic: true))

    #expect(regular.id != bold.id)
    #expect(regular.id != italic.id)
    #expect(bold.id != italic.id)
    #expect(atlas.entryCount == 3)
  }

  @MainActor @Test func metalGlyphAtlasRendersBoldGlyphWithMoreInkThanRegular() throws {
    let atlas = MetalGlyphAtlas(fontFamily: "Menlo", fontSize: 14, backingScale: 2)

    let regular = try #require(atlas.renderedImage(for: "A"))
    let bold = try #require(atlas.renderedImage(for: "A", style: MetalGlyphStyle(bold: true)))

    #expect(alphaSum(in: bold) > alphaSum(in: regular))
  }

  @MainActor @Test func metalGlyphAtlasTracksInkBoundsInsideTightBitmap() {
    let atlas = MetalGlyphAtlas(fontFamily: "Menlo", fontSize: 14, backingScale: 2)

    let entry = atlas.entry(for: "A")

    #expect(entry.inkBounds.width > 0)
    #expect(entry.inkBounds.height > 0)
    #expect(entry.inkBounds.minX >= 0)
    #expect(entry.inkBounds.minY >= 0)
    #expect(entry.inkBounds.maxX <= entry.bitmapSize.width)
    #expect(entry.inkBounds.maxY <= entry.bitmapSize.height)
  }

  @MainActor @Test func metalGlyphAtlasRendersGlyphIntoTightMetricBitmap() throws {
    let atlas = MetalGlyphAtlas(fontFamily: "Menlo", fontSize: 14, backingScale: 2)

    let image = try #require(atlas.renderedImage(for: "A"))
    let cellSize = atlas.renderCellSize

    #expect(CGFloat(image.width * image.height) < cellSize.width * cellSize.height)
    #expect(CGFloat(image.height) < cellSize.height)
  }

  @MainActor @Test func metalGlyphAtlasDoesNotThickenRegularGlyphsByDefault() throws {
    let atlas = MetalGlyphAtlas(fontFamily: "Menlo", fontSize: 14, backingScale: 2)

    let image = try #require(atlas.renderedImage(for: "A"))
    let cellSize = atlas.renderCellSize

    #expect(CGFloat(image.width) <= cellSize.width)
  }

  @MainActor @Test func metalDirectGlyphQuadUsesTightInkBoundsInsideCell() {
    let entry = MetalGlyphAtlasEntry(
      id: 1,
      generation: 0,
      scalar: "A",
      style: .regular,
      bitmapSize: CGSize(width: 20, height: 40),
      inkBounds: CGRect(x: 3, y: 5, width: 12, height: 18),
      drawOffset: CGPoint(x: 2, y: 6),
      drawSize: CGSize(width: 14, height: 20)
    )
    let cellRect = CGRect(x: 28, y: 24, width: 20, height: 40)

    let rect = MetalDirectRenderEngine.glyphDrawRect(for: entry, in: cellRect)
    let textureRect = MetalDirectRenderEngine.glyphTextureRect(for: entry)

    #expect(rect == CGRect(x: 30, y: 30, width: 14, height: 20))
    #expect(textureRect == CGRect(x: 0, y: 0, width: 1, height: 1))
  }

  @MainActor @Test func metalDirectWideGlyphCellRectSpansTwoTerminalColumns() {
    let wideCell = cell("界", width: .wide)
    let rect = MetalDirectRenderEngine.glyphCellRect(
      row: 2,
      col: 3,
      cell: wideCell,
      cellSize: CGSize(width: 18, height: 34),
      inset: CGSize(width: 4, height: 6),
      translationY: 8
    )

    #expect(rect == CGRect(x: 58, y: 82, width: 36, height: 34))
  }

  @MainActor @Test func metalDirectGlyphTexturesUseCoreGraphicsTopLeftOrigin() {
    let options = MetalDirectRenderEngine.glyphTextureLoaderOptions()

    #expect(options[.SRGB] as? Bool == false)
    #expect(options[.origin] as? MTKTextureLoader.Origin == .topLeft)
  }

  @MainActor @Test func metalDirectGlyphShaderSamplesGlyphAtlasWithoutLinearFiltering() throws {
    let source = MetalDirectRenderEngine.shaderSource
    let glyphFragment = try #require(source.range(of: "metal_direct_glyph_fragment"))
    let fragmentSource = source[glyphFragment.lowerBound...]

    #expect(fragmentSource.contains("filter::nearest"))
    #expect(!fragmentSource.contains("filter::linear"))
  }

  @MainActor @Test func metalGlyphAtlasInvalidatesEntriesWhenFontChanges() {
    let atlas = MetalGlyphAtlas(fontFamily: "Menlo", fontSize: 14, backingScale: 2)
    let first = atlas.entry(for: "A")

    atlas.applyFont(family: "Menlo", size: 16)
    let second = atlas.entry(for: "A")

    #expect(second.generation > first.generation)
    #expect(atlas.entryCount == 1)
  }

  @MainActor @Test func metalGlyphAtlasInvalidatesEntriesWhenCJKFallbackChanges() {
    let atlas = MetalGlyphAtlas(fontFamily: "Menlo", fontSize: 14, backingScale: 2)
    let first = atlas.entry(for: "界")

    atlas.applyFont(family: "Menlo", size: 14, cjkFallbackFamily: "PingFang SC")
    let second = atlas.entry(for: "界")

    #expect(second.generation > first.generation)
    #expect(atlas.entryCount == 1)
  }

  @MainActor @Test func metalGlyphAtlasCellSizeIgnoresCJKFallback() {
    let atlas = MetalGlyphAtlas(fontFamily: "Menlo", fontSize: 14, backingScale: 2)
    let before = atlas.renderCellSize

    atlas.applyFont(family: "Menlo", size: 14, cjkFallbackFamily: "PingFang SC")
    let after = atlas.renderCellSize

    #expect(after == before)
  }

  @MainActor @Test func metalGlyphAtlasInvalidatesEntriesWhenBackingScaleChanges() {
    let atlas = MetalGlyphAtlas(fontFamily: "Menlo", fontSize: 14, backingScale: 1)
    let first = atlas.entry(for: "A")

    atlas.applyBackingScale(2)
    let second = atlas.entry(for: "A")

    #expect(second.generation > first.generation)
    #expect(atlas.entryCount == 1)
  }

  @MainActor @Test func metalGlyphAtlasCachesMeasurableCJKGlyphs() {
    let atlas = MetalGlyphAtlas(fontFamily: "Menlo", fontSize: 14, backingScale: 2)

    let entry = atlas.entry(for: "界")

    #expect(entry.bitmapSize.width > 0)
    #expect(entry.bitmapSize.height > 0)
    #expect(atlas.entryCount == 1)
  }

  @MainActor @Test func metalGlyphAtlasUsesCoreTextFallbackMetricsForCJKGlyphs() throws {
    let atlas = MetalGlyphAtlas(fontFamily: "Menlo", fontSize: 14, backingScale: 2)

    let image = try #require(atlas.renderedImage(for: "界"))
    let cellSize = atlas.renderCellSize

    #expect(CGSize(width: image.width, height: image.height) != cellSize)
  }

  @MainActor @Test func metalGlyphAtlasUsesCoreTextMetricsForSurrogatePairGlyphs() throws {
    let atlas = MetalGlyphAtlas(fontFamily: "Menlo", fontSize: 14, backingScale: 2)

    let image = try #require(atlas.renderedImage(for: "😀"))
    let cellSize = atlas.renderCellSize

    #expect(CGSize(width: image.width, height: image.height) != cellSize)
  }

  @MainActor @Test func metalGlyphAtlasRendersInkAtBackingScale() throws {
    let oneX = MetalGlyphAtlas(fontFamily: "Menlo", fontSize: 14, backingScale: 1)
    let twoX = MetalGlyphAtlas(fontFamily: "Menlo", fontSize: 14, backingScale: 2)
    let oneXImage = try #require(oneX.renderedImage(for: "A"))
    let twoXImage = try #require(twoX.renderedImage(for: "A"))

    let oneXInk = try #require(alphaBounds(in: oneXImage))
    let twoXInk = try #require(alphaBounds(in: twoXImage))

    #expect(twoX.renderCellSize.width >= oneX.renderCellSize.width * 2 - 1)
    #expect(twoX.renderCellSize.height >= oneX.renderCellSize.height * 2 - 1)
    #expect(twoXImage.width > oneXImage.width)
    #expect(twoXImage.height > oneXImage.height)
    #expect(twoXInk.height > oneXInk.height)
  }

  @Test func metalCellInstanceBufferMapsDirtyRowsToStableRanges() {
    let buffer = MetalCellInstanceBuffer(rows: 4, cols: 8)

    let ranges = buffer.instanceRanges(forDirtyRows: [0, 2])

    #expect(ranges.map(\.row) == [0, 2])
    #expect(ranges.map(\.range) == [0..<8, 16..<24])
    #expect(buffer.uploadedCellCount(for: ranges) == 16)
  }

  @Test func metalCellInstanceBufferMapsDirtyCellRangesToStableRanges() {
    let buffer = MetalCellInstanceBuffer(rows: 4, cols: 8)

    let ranges = buffer.instanceRanges(forDirtyCellRanges: [
      MetalCellDirtyRange(row: 1, cols: 2..<4),
      MetalCellDirtyRange(row: 3, cols: 0..<1),
    ])

    #expect(ranges.map(\.row) == [1, 3])
    #expect(ranges.map(\.range) == [10..<12, 24..<25])
    #expect(buffer.uploadedCellCount(for: ranges) == 3)
  }

  @Test func metalCellInstanceBufferIgnoresOutOfBoundsDirtyRows() {
    let buffer = MetalCellInstanceBuffer(rows: 2, cols: 8)

    let ranges = buffer.instanceRanges(forDirtyRows: [-1, 0, 2])

    #expect(ranges.map(\.row) == [0])
    #expect(ranges.map(\.range) == [0..<8])
  }

  @Test func metalCellInstanceBufferReportsFullRebuildWhenGridSizeChanges() {
    var buffer = MetalCellInstanceBuffer(rows: 2, cols: 8)

    let unchanged = buffer.updateGridSize(rows: 2, cols: 8)
    let changed = buffer.updateGridSize(rows: 3, cols: 8)

    #expect(unchanged == .unchanged)
    #expect(changed == .fullRebuild)
    #expect(buffer.rows == 3)
    #expect(buffer.cols == 8)
  }

  @Test func cellGridDirtyTrackerScopesSingleCharacterChangeToOneRow() {
    let old = frame(rows: ["abc", "def"], cols: 8, cursorX: 1, cursorY: 0)
    let new = frame(rows: ["abc", "dxf"], cols: 8, cursorX: 1, cursorY: 0)

    let result = CellGridDirtyTracker.diff(previous: old, next: new)

    #expect(result.mode == .dirty)
    #expect(result.rows == [1])
    #expect(result.cellRanges == [CellGridDirtyRange(row: 1, cols: 1..<2)])
    #expect(result.dirtyCellCount == 1)
  }

  @Test func cellGridDirtyTrackerMergesAdjacentDirtyCellsWithinRow() {
    let old = frame(rows: ["abcd", "efgh"], cols: 8, cursorX: 1, cursorY: 0)
    let new = frame(rows: ["abcd", "exyh"], cols: 8, cursorX: 1, cursorY: 0)

    let result = CellGridDirtyTracker.diff(previous: old, next: new)

    #expect(result.mode == .dirty)
    #expect(result.rows == [1])
    #expect(result.cellRanges == [CellGridDirtyRange(row: 1, cols: 1..<3)])
    #expect(result.dirtyCellCount == 2)
  }

  @Test func cellGridDirtyTrackerExpandsNonASCIICellChangesToAdjacentCells() {
    let old = frame(rows: ["abcd", "e你gh"], cols: 8, cursorX: 1, cursorY: 0)
    let new = frame(rows: ["abcd", "e gh"], cols: 8, cursorX: 1, cursorY: 0)

    let result = CellGridDirtyTracker.diff(previous: old, next: new)

    #expect(result.mode == .dirty)
    #expect(result.rows == [1])
    #expect(result.cellRanges == [CellGridDirtyRange(row: 1, cols: 0..<3)])
    #expect(result.dirtyCellCount == 3)
  }

  @Test func cellGridDirtyTrackerRedrawsNonASCIINeighborWhenAdjacentCellChanges() {
    let old = frame(rows: ["abcd", "你   "], cols: 8, cursorX: 1, cursorY: 0)
    var new = old
    let changedIndex = 1 * old.cols + 1
    new.cells[changedIndex].inverse = true

    let result = CellGridDirtyTracker.diff(previous: old, next: new)

    #expect(result.mode == .dirty)
    #expect(result.rows == [1])
    #expect(result.cellRanges == [CellGridDirtyRange(row: 1, cols: 0..<2)])
    #expect(result.dirtyCellCount == 2)
  }

  @Test func cellGridDirtyTrackerScopesCursorMoveToOldAndNewRows() {
    let old = frame(rows: ["abc", "def", "ghi"], cols: 8, cursorX: 1, cursorY: 0)
    let new = frame(rows: ["abc", "def", "ghi"], cols: 8, cursorX: 1, cursorY: 2)

    let result = CellGridDirtyTracker.diff(previous: old, next: new)

    #expect(result.mode == .dirty)
    #expect(result.rows == [0, 2])
  }

  @Test func cellGridDirtyTrackerCanIgnoreCursorOnlyRowsForOverlayRenderers() {
    let old = frame(rows: ["abc", "def", "ghi"], cols: 8, cursorX: 1, cursorY: 0)
    let new = frame(rows: ["abc", "def", "ghi"], cols: 8, cursorX: 1, cursorY: 2)

    let result = CellGridDirtyTracker.diffIgnoringCursorOnlyChanges(previous: old, next: new)

    #expect(result.mode == .clean)
    #expect(result.rows.isEmpty)
  }

  @Test func cellGridDirtyTrackerIncludesSelectionRows() {
    let old = frame(rows: ["abc", "def", "ghi"], cols: 8, cursorX: 1, cursorY: 0)
    let new = frame(rows: ["abc", "def", "ghi"], cols: 8, cursorX: 1, cursorY: 0)

    let result = CellGridDirtyTracker.diff(
      previous: old,
      next: new,
      previousSelectionRows: [1],
      nextSelectionRows: [2]
    )

    #expect(result.mode == .dirty)
    #expect(result.rows == [1, 2])
  }

  @Test func cellGridDirtyTrackerMarksFullDirtyWhenGridSizeChanges() {
    let old = frame(rows: ["abc", "def"], cols: 8, cursorX: 1, cursorY: 0)
    let new = frame(rows: ["abc", "def", "ghi"], cols: 8, cursorX: 1, cursorY: 0)

    let result = CellGridDirtyTracker.diff(previous: old, next: new)

    #expect(result.mode == .full)
    #expect(result.rows == [0, 1, 2])
  }

  @MainActor
  private final class MutableMetalDirectRenderingEngine: MetalDirectRenderingEngine {
    let drawPassCount = 1
    var presentedFrameCount = 0
    var latestSubmittedGeneration = 0
    var latestPresentedGeneration = 0
    let pipelineReady = true
    var prefersAsyncPresent = false
    let lastRenderedRowCount = 1
    let lastRenderedCellCount = 1
    let lastRenderedRunCount = 1
    let lastRenderPassLoadPolicy = MetalDirectRenderPassLoadPolicy.clear
    let lastWaitedForCompletion = true
    var lastGPUWaitReason = "none"
    var lastGlyphTextureHitCount = 0
    var lastGlyphTextureMissCount = 0
    var staleCompletionCount = 0
    var lastSelectionCellRanges: [GridSelectionCellRange] = []

    func resetTextureCache() {}

    func clearToBackground(
      view: MetalDirectRendererView,
      palette: TerminalSurfacePalette
    ) -> Bool {
      true
    }

    func render(
      renderFrame: TerminalRenderFrame,
      plan: MetalTerminalRenderPlan,
      view: MetalDirectRendererView,
      palette: TerminalSurfacePalette,
      glyphAtlas: MetalGlyphAtlas
    ) -> Bool {
      latestSubmittedGeneration = renderFrame.generation
      latestPresentedGeneration = renderFrame.generation
      presentedFrameCount += 1
      lastSelectionCellRanges = view.currentSelectionCellRanges
      return true
    }
  }

  @MainActor
  private final class FailingMetalDirectRenderingEngine: MetalDirectRenderingEngine {
    let drawPassCount = 0
    let presentedFrameCount = 0
    let latestSubmittedGeneration = 0
    let latestPresentedGeneration = 0
    let pipelineReady = true
    var prefersAsyncPresent = false
    let lastRenderedRowCount = 0
    let lastRenderedCellCount = 0
    let lastRenderedRunCount = 0
    let lastRenderPassLoadPolicy = MetalDirectRenderPassLoadPolicy.clear
    let lastWaitedForCompletion = false
    let lastGPUWaitReason = "none"
    let lastGlyphTextureHitCount = 0
    let lastGlyphTextureMissCount = 0
    let staleCompletionCount = 0

    func resetTextureCache() {}

    func clearToBackground(
      view: MetalDirectRendererView,
      palette: TerminalSurfacePalette
    ) -> Bool {
      false
    }

    func render(
      renderFrame: TerminalRenderFrame,
      plan: MetalTerminalRenderPlan,
      view: MetalDirectRendererView,
      palette: TerminalSurfacePalette,
      glyphAtlas: MetalGlyphAtlas
    ) -> Bool {
      false
    }
  }

  @Test func paneScrollCoordinatorConvertsWheelDeltaIntoCommittedRowsAndSubRowRemainder() {
    var coordinator = PaneScrollCoordinator()

    let decision = coordinator.scroll(
      deltaY: 37,
      cellHeight: 16,
      alternateScreen: false,
      smoothPixelScrollingEnabled: true,
      hasOverscanRowsForProjectedRemainder: true
    )

    #expect(decision == .consumed(rowDelta: 2, pixelRemainderY: 5))
    #expect(coordinator.pixelRemainderY == 5)
    #expect(coordinator.lastCommittedRowDelta == 2)
    #expect(coordinator.coalescedWheelEvents == 1)
    #expect(coordinator.isPixelScrollActive)
  }

  @Test func paneScrollCoordinatorKeepsOnlyOneLineOfPixelRemainderAcrossEvents() {
    var coordinator = PaneScrollCoordinator()

    _ = coordinator.scroll(
      deltaY: 10,
      cellHeight: 16,
      alternateScreen: false,
      smoothPixelScrollingEnabled: true,
      hasOverscanRowsForProjectedRemainder: true
    )
    let decision = coordinator.scroll(
      deltaY: 12,
      cellHeight: 16,
      alternateScreen: false,
      smoothPixelScrollingEnabled: true,
      hasOverscanRowsForProjectedRemainder: true
    )

    #expect(decision == .consumed(rowDelta: 1, pixelRemainderY: 6))
    #expect(coordinator.pixelRemainderY == 6)
    #expect(coordinator.lastCommittedRowDelta == 1)
    #expect(coordinator.coalescedWheelEvents == 2)
  }

  @Test func paneScrollCoordinatorForwardsAlternateScreenWheelInputToPTY() {
    var coordinator = PaneScrollCoordinator()

    let decision = coordinator.scroll(
      deltaY: 37,
      cellHeight: 16,
      alternateScreen: true,
      smoothPixelScrollingEnabled: true,
      hasOverscanRowsForProjectedRemainder: true
    )

    #expect(decision == .forwardToPTY)
    #expect(coordinator.pixelRemainderY == 0)
    #expect(coordinator.lastDisabledReason == TerminalRendererDiagnostics.alternateScreenScrollReason)
  }

  @Test func paneScrollCoordinatorFallsBackToRowScrollWithoutOverscanRows() {
    var coordinator = PaneScrollCoordinator()

    let decision = coordinator.scroll(
      deltaY: 5,
      cellHeight: 16,
      alternateScreen: false,
      smoothPixelScrollingEnabled: true,
      hasOverscanRowsForProjectedRemainder: false
    )

    #expect(decision == .consumed(rowDelta: 1, pixelRemainderY: 0))
    #expect(coordinator.pixelRemainderY == 0)
    #expect(coordinator.lastCommittedRowDelta == 1)
    #expect(coordinator.lastDisabledReason == TerminalRendererDiagnostics.missingOverscanRowsReason)
  }

  @Test func scrollCommitCoordinatorCoalescesRowDeltasUntilDrained() {
    var coordinator = ScrollCommitCoordinator()

    let firstSchedule = coordinator.enqueue(rowDelta: 1)
    let secondSchedule = coordinator.enqueue(rowDelta: 2)
    let thirdSchedule = coordinator.enqueue(rowDelta: -1)

    #expect(firstSchedule)
    #expect(!secondSchedule)
    #expect(!thirdSchedule)
    #expect(coordinator.pendingRowDelta == 2)
    #expect(coordinator.pendingWheelEvents == 3)

    let batch = coordinator.drain()

    #expect(batch?.rowDelta == 2)
    #expect(batch?.wheelEvents == 3)
    #expect(coordinator.pendingRowDelta == 0)
    #expect(coordinator.pendingWheelEvents == 0)
  }

  @MainActor @Test func liveGridDefersHighFrequencyWheelCommitsUntilFlush() {
    let backend = GhosttyVTCellGridRendererBackend(
      options: TerminalRendererOptions(smoothPixelScrollingEnabled: true)
    )
    backend.render(scrollFrame: scrollFrame(
      viewportRows: ["two", "three"],
      overscanTop: ["one"],
      overscanBottom: ["four"],
      cols: 8
    ))
    backend.flushPendingFrame()
    var committedRowDeltas: [Int] = []
    backend.gridView.viewportScrollHandler = { rowDelta in
      committedRowDeltas.append(rowDelta)
      return true
    }

    for _ in 0..<20 {
      backend.gridView.testScrollWheelDeltaY(18)
    }

    #expect(committedRowDeltas.isEmpty)
    #expect(backend.diagnostics.pendingScrollWheelEvents == 20)

    backend.gridView.flushPendingScrollCommit()

    #expect(committedRowDeltas.count == 1)
    #expect(committedRowDeltas[0] > 1)
    #expect(backend.diagnostics.pendingScrollWheelEvents == 0)
  }

  @MainActor @Test func liveGridCommitsAccumulatedSlowTrackpadRowBeforeRemainderWraps() {
    let backend = GhosttyVTCellGridRendererBackend(
      options: TerminalRendererOptions(smoothPixelScrollingEnabled: true)
    )
    backend.render(scrollFrame: scrollFrame(
      viewportRows: ["two", "three"],
      overscanTop: ["one"],
      overscanBottom: ["four"],
      cols: 8
    ))
    backend.flushPendingFrame()
    var committedRowDeltas: [Int] = []
    backend.gridView.viewportScrollHandler = { rowDelta in
      committedRowDeltas.append(rowDelta)
      return true
    }

    backend.gridView.testScrollWheelDeltaY(15)
    #expect(backend.gridView.viewport.visualOffsetY == 15)

    backend.gridView.testScrollWheelDeltaY(2)

    #expect(committedRowDeltas == [1])
    #expect(backend.gridView.viewport.visualOffsetY == 1)
    #expect(backend.diagnostics.pendingScrollRowDelta == 0)
  }

  @MainActor @Test func liveGridVisualScrollTranslationMatchesViewportDirection() {
    #expect(PTYGridView.visualScrollTranslationY(for: TerminalViewport(visualOffsetY: 5)) == 0)
    #expect(PTYGridView.visualScrollTranslationY(for: TerminalViewport(visualOffsetY: -5)) == 0)
    #expect(
      PTYGridView.visualScrollTranslationY(
        for: TerminalViewport(visualOffsetY: 5),
        hasOverscanRows: true,
        cellHeight: 16
      ) == 5
    )
    // Baseline: sub-row offset is clamped to ±cellHeight (event-driven scroll
    // commits a whole row past that). The unclamp lands with R1.2 display-link.
    #expect(
      PTYGridView.visualScrollTranslationY(
        for: TerminalViewport(visualOffsetY: 24),
        hasOverscanRows: true,
        cellHeight: 16
      ) == 16
    )
  }

  @MainActor @Test func liveGridDirtyRectCullingAccountsForVisualScrollTransform() {
    let dirtyRect = NSRect(x: 0, y: 20, width: 80, height: 16)

    #expect(
      PTYGridView.contentDirtyRect(
        forDrawing: dirtyRect,
        viewport: TerminalViewport(visualOffsetY: 5)
      ) == NSRect(x: 0, y: 20, width: 80, height: 16)
    )
    #expect(
      PTYGridView.contentDirtyRect(
        forDrawing: dirtyRect,
        viewport: TerminalViewport(visualOffsetY: -5)
      ) == NSRect(x: 0, y: 20, width: 80, height: 16)
    )
    #expect(
      PTYGridView.contentDirtyRect(
        forDrawing: dirtyRect,
        viewport: TerminalViewport(visualOffsetY: 5),
        hasOverscanRows: true,
        cellHeight: 16
      ) == NSRect(x: 0, y: 15, width: 80, height: 16)
    )
  }

  @MainActor @Test func liveGridContentClipRectMatchesTerminalColumns() {
    let rect = PTYGridView.terminalContentClipRect(
      cols: 80,
      rows: 24,
      cellSize: CGSize(width: 9, height: 18),
      inset: CGSize(width: 14, height: 12)
    )

    #expect(rect == NSRect(x: 14, y: 12, width: 720, height: 432))
    #expect(rect.maxX == 734)
  }

  @MainActor @Test func liveGridTextGlyphRectsStayPinnedToTerminalColumns() {
    let run = CellDrawRun(
      range: 77..<80,
      text: "──│",
      style: frame(rows: ["   "], cols: 3, cursorX: 0, cursorY: 0).cells[0]
    )

    let rects = PTYGridView.textGlyphRects(
      for: run,
      row: 4,
      cellSize: CGSize(width: 9, height: 18),
      inset: CGSize(width: 14, height: 12)
    )

    #expect(rects.map(\.minX) == [707, 716, 725])
    #expect(rects.last?.maxX == 734)
  }

  @Test func rendererDiagnosticsExposeRowBasedScrollingAndPixelScrollReason() {
    let diagnostics = TerminalRendererDiagnostics(backend: .ghosttyVTCellGrid)

    #expect(diagnostics.scrollMode == .rowBased)
    #expect(diagnostics.overscanTopRows == 0)
    #expect(diagnostics.overscanBottomRows == 0)
    #expect(diagnostics.pixelSmoothScroll == .unavailable)
    #expect(diagnostics.pixelSmoothScrollReason == TerminalRendererDiagnostics.missingOverscanRowsReason)
    #expect(diagnostics.debugSummary.contains("scrollMode=row-based"))
    #expect(diagnostics.debugSummary.contains("overscanTop=0"))
    #expect(diagnostics.debugSummary.contains("overscanBottom=0"))
    #expect(diagnostics.debugSummary.contains("pixelSmoothScroll=unavailable"))
    #expect(diagnostics.debugSummary.contains("missing overscan rows from libghostty-vt snapshot"))
    #expect(diagnostics.debugSummary.contains("scrollCommitMode=immediate"))
    #expect(diagnostics.debugSummary.contains("pendingScrollRowDelta=0"))
    #expect(diagnostics.debugSummary.contains("scrollCommitMs=0.000"))
    #expect(diagnostics.debugSummary.contains("scrollRenderMs=0.000"))
    #expect(diagnostics.debugSummary.contains("bridgeScrollViewportMs=0.000"))
    #expect(diagnostics.debugSummary.contains("bridgeScrollbarSnapshotMs=0.000"))
    #expect(diagnostics.debugSummary.contains("bridgeFrameSnapshotMs=0.000"))
    #expect(diagnostics.debugSummary.contains("bridgeScrollFrameSnapshotMs=0.000"))
    #expect(diagnostics.debugSummary.contains("bridgeSnapshotCells=0"))
    #expect(diagnostics.debugSummary.contains("metalDirectFullRedrawReason=\"none\""))
    #expect(diagnostics.debugSummary.contains("metalDirectExpandedFrameCells=0"))
    #expect(diagnostics.debugSummary.contains("metalDirectGlyphTextureHits=0"))
    #expect(diagnostics.debugSummary.contains("metalDirectGlyphTextureMisses=0"))
    #expect(diagnostics.debugSummary.contains("metalDirectTextureHitRate=0.000"))
    #expect(diagnostics.debugSummary.contains("metalDirectGPUWaitReason=\"none\""))
  }

  @Test func rendererDiagnosticsReportOverscanRows() {
    var diagnostics = TerminalRendererDiagnostics(backend: .ghosttyVTCellGrid)

    diagnostics.overscanTopRows = 1
    diagnostics.overscanBottomRows = 1
    diagnostics.pixelSmoothScroll = .experimental
    diagnostics.pixelSmoothScrollReason = TerminalRendererDiagnostics.overscanRowsAvailableReason

    #expect(diagnostics.debugSummary.contains("overscanTop=1"))
    #expect(diagnostics.debugSummary.contains("overscanBottom=1"))
    #expect(diagnostics.debugSummary.contains("pixelSmoothScroll=experimental"))
    #expect(diagnostics.debugSummary.contains("overscan rows available from libghostty-vt snapshot"))
  }

  @MainActor @Test func cellGridBackendReportsExperimentalPixelScrollWhenOverscanExistsAndOptionIsEnabled() {
    let backend = GhosttyVTCellGridRendererBackend(
      options: TerminalRendererOptions(smoothPixelScrollingEnabled: true)
    )

    backend.updateOverscanDiagnostics(topRows: 1, bottomRows: 1)

    #expect(backend.diagnostics.overscanTopRows == 1)
    #expect(backend.diagnostics.overscanBottomRows == 1)
    #expect(backend.diagnostics.pixelSmoothScroll == .experimental)
    #expect(backend.diagnostics.pixelSmoothScrollReason == TerminalRendererDiagnostics.smoothScrollEnabledReason)
  }

  @MainActor @Test func cellGridBackendReportsDisabledPixelScrollWhenOptionIsDisabled() {
    let backend = GhosttyVTCellGridRendererBackend(
      options: TerminalRendererOptions(smoothPixelScrollingEnabled: false)
    )

    backend.updateOverscanDiagnostics(topRows: 1, bottomRows: 1)

    #expect(backend.diagnostics.overscanTopRows == 1)
    #expect(backend.diagnostics.overscanBottomRows == 1)
    #expect(backend.diagnostics.pixelSmoothScroll == .unavailable)
    #expect(backend.diagnostics.pixelSmoothScrollReason == TerminalRendererDiagnostics.smoothScrollDisabledReason)
  }

  @MainActor @Test func cellGridBackendReportsUnavailablePixelScrollWithoutOverscanRows() {
    let backend = GhosttyVTCellGridRendererBackend(
      options: TerminalRendererOptions(smoothPixelScrollingEnabled: true)
    )

    backend.updateOverscanDiagnostics(topRows: 0, bottomRows: 0)

    #expect(backend.diagnostics.pixelSmoothScroll == .unavailable)
    #expect(backend.diagnostics.pixelSmoothScrollReason == TerminalRendererDiagnostics.missingOverscanRowsReason)
  }

  @MainActor @Test func cellGridBackendPassesScrollFrameToGridView() {
    let backend = GhosttyVTCellGridRendererBackend()
    let scrollFrame = scrollFrame(
      viewportRows: ["two", "three"],
      overscanTop: ["one"],
      overscanBottom: ["four"],
      cols: 8
    )

    backend.render(scrollFrame: scrollFrame)
    backend.flushPendingFrame()

    #expect(backend.gridView.canRenderPixelScroll(for: 5))
    #expect(backend.diagnostics.overscanTopRows == 1)
    #expect(backend.diagnostics.overscanBottomRows == 1)
  }

  @MainActor @Test func liveGridDrawsBottomViewportRowWhenTopOverscanIsPresent() throws {
    let backend = GhosttyVTCellGridRendererBackend()
    let gridView = backend.gridView
    let cols = 12
    let rows = 2
    let cellSize = gridView.terminalCellSize
    let inset = gridView.terminalContentInset
    gridView.frame = NSRect(
      x: 0,
      y: 0,
      width: inset.width * 2 + CGFloat(cols) * cellSize.width,
      height: inset.height * 2 + CGFloat(rows) * cellSize.height
    )
    var scrollFrame = scrollFrame(
      viewportRows: ["top", "BOTTOM"],
      overscanTop: ["history"],
      overscanBottom: [],
      cols: cols
    )
    scrollFrame.viewport.cursorVisible = false

    backend.render(scrollFrame: scrollFrame)
    backend.flushPendingFrame()

    let image = try #require(gridView.bitmapImageRepForCachingDisplay(in: gridView.bounds))
    gridView.cacheDisplay(in: gridView.bounds, to: image)

    let bottomRowTextRect = bitmapRect(
      PTYGridView.textGlyphRect(
      row: 1,
      col: 0,
      cellSize: cellSize,
      inset: inset
      )
      .union(PTYGridView.textGlyphRect(row: 1, col: 5, cellSize: cellSize, inset: inset)),
      imageHeight: image.pixelsHigh
    )
    let foregroundPixelCount = nonBackgroundPixelCount(
      in: bottomRowTextRect,
      image: image,
      background: TerminalSurfacePalette.dark.background
    )

    #expect(foregroundPixelCount > 0)
  }

  @MainActor @Test func paneScrollCoordinatorStateIsIndependentPerGridView() {
    let first = GhosttyVTCellGridRendererBackend(
      options: TerminalRendererOptions(smoothPixelScrollingEnabled: true)
    )
    let second = GhosttyVTCellGridRendererBackend(
      options: TerminalRendererOptions(smoothPixelScrollingEnabled: true)
    )
    let frame = scrollFrame(
      viewportRows: ["two", "three"],
      overscanTop: ["one"],
      overscanBottom: ["four"],
      cols: 8
    )
    first.render(scrollFrame: frame)
    second.render(scrollFrame: frame)
    first.flushPendingFrame()
    second.flushPendingFrame()

    first.gridView.testScrollWheelDeltaY(5)

    #expect(first.gridView.viewport.visualOffsetY == 5)
    #expect(first.diagnostics.pixelRemainderY == 5)
    #expect(second.gridView.viewport.visualOffsetY == 0)
    #expect(second.diagnostics.pixelRemainderY == 0)
  }

  @MainActor @Test func liveGridUsesProjectedRemainderOverscanWhenWheelDirectionReverses() {
    let backend = GhosttyVTCellGridRendererBackend(
      options: TerminalRendererOptions(smoothPixelScrollingEnabled: true)
    )
    backend.render(scrollFrame: scrollFrame(
      viewportRows: ["two", "three"],
      overscanTop: ["one"],
      overscanBottom: [],
      cols: 8
    ))
    backend.flushPendingFrame()

    backend.gridView.testScrollWheelDeltaY(10)
    backend.gridView.testScrollWheelDeltaY(-3)

    #expect(backend.gridView.viewport.visualOffsetY == 7)
    #expect(backend.diagnostics.pixelRemainderY == 7)
    #expect(backend.diagnostics.pixelSmoothScrollReason == TerminalRendererDiagnostics.smoothScrollEnabledReason)
  }

  @MainActor @Test func liveGridIgnoresResidualMomentumAfterUserInputReset() {
    let backend = GhosttyVTCellGridRendererBackend(
      options: TerminalRendererOptions(smoothPixelScrollingEnabled: true)
    )
    backend.render(scrollFrame: scrollFrame(
      viewportRows: ["two", "three"],
      overscanTop: ["one"],
      overscanBottom: ["four"],
      cols: 8
    ))
    backend.flushPendingFrame()

    backend.gridView.testScrollWheelDeltaY(10)
    backend.resetPixelScroll(suppressMomentum: true)
    backend.gridView.testMomentumScrollWheelDeltaY(10)

    #expect(backend.gridView.viewport == TerminalViewport())
    #expect(backend.diagnostics.pixelRemainderY == 0)
  }

  @MainActor @Test func liveGridForwardsAlternateScreenWheelInputToPTYWithoutPixelScroll() {
    let backend = GhosttyVTCellGridRendererBackend(
      options: TerminalRendererOptions(smoothPixelScrollingEnabled: true)
    )
    var alternate = frame(rows: ["tui", "view"], cols: 8, cursorX: 0, cursorY: 0)
    alternate.isAlternateScreen = true
    backend.render(frame: alternate)
    backend.flushPendingFrame()
    var forwarded = false

    backend.gridView.testScrollWheelDeltaY(5) {
      forwarded = true
    }

    #expect(forwarded)
    #expect(backend.gridView.viewport.visualOffsetY == 0)
    #expect(backend.diagnostics.pixelSmoothScroll == .unavailable)
    #expect(backend.diagnostics.pixelSmoothScrollReason == TerminalRendererDiagnostics.alternateScreenScrollReason)
  }

  @Test func viewportControllerDrawsVisibleRowsWithOverscan() {
    let controller = ViewportController(
      viewport: TerminalViewport(startRow: 3, visualOffsetY: 4),
      visibleRowCount: 5,
      overscan: 1
    )

    #expect(controller.rowRange(totalRows: 20) == 2..<10)
  }

  @Test func cellRunBuilderMergesAdjacentCellsWithSameStyle() {
    let cells = Array(frame(rows: ["aaab"], cols: 4, cursorX: 0, cursorY: 0).cells)

    let runs = CellRunBuilder.runs(for: cells)

    #expect(runs.map(\.text) == ["aaab"])
    #expect(runs.map(\.range) == [0..<4])
  }

  @MainActor @Test func cellGridBackendCoalescesManyWritesIntoOneFlush() {
    let backend = GhosttyVTCellGridRendererBackend()

    backend.render(frame: frame(rows: ["one"], cols: 8, cursorX: 0, cursorY: 0))
    backend.render(frame: frame(rows: ["two"], cols: 8, cursorX: 0, cursorY: 0))
    backend.render(frame: frame(rows: ["tri"], cols: 8, cursorX: 0, cursorY: 0))

    #expect(backend.diagnostics.coalescedFrames == 2)
    backend.flushPendingFrame()
    #expect(backend.gridView.renderedText.hasPrefix("tri"))
  }

  @MainActor @Test func cellGridBackendDiagnosticsExposeDirtyAndAlternateScreenState() {
    let backend = GhosttyVTCellGridRendererBackend()
    var next = frame(rows: ["one", "two"], cols: 8, cursorX: 0, cursorY: 0)
    next.isAlternateScreen = true

    backend.render(frame: next)
    backend.flushPendingFrame()

    #expect(backend.diagnostics.backend == .ghosttyVTCellGrid)
    #expect(backend.diagnostics.dirtyRowCount == 2)
    #expect(backend.diagnostics.visibleRowCount == 2)
    #expect(backend.diagnostics.redrawMode == .full)
    #expect(backend.diagnostics.alternateScreenActive == true)
  }

  @MainActor @Test func cellGridBackendMarksLiveScreensWithContentBelowCursorAsResizeSensitive() {
    let backend = GhosttyVTCellGridRendererBackend()
    let next = frame(rows: ["prompt", "menu"], cols: 8, cursorX: 0, cursorY: 0)

    backend.render(frame: next)
    backend.flushPendingFrame()

    #expect(backend.diagnostics.alternateScreenActive == false)
    #expect(backend.diagnostics.resizeSensitiveScreen == true)
  }

  @MainActor @Test func cellGridBackendDiagnosticsExposeStyleCoverage() {
    let backend = GhosttyVTCellGridRendererBackend()
    let styled = GhosttyTerminalFrame(
      cols: 4,
      rows: 1,
      cursorVisible: true,
      cursorX: 0,
      cursorY: 0,
      cursorShape: .bar,
      cursorBlinking: false,
      isAlternateScreen: true,
      cells: [
        cell("a", foreground: .init(r: 220, g: 30, b: 40), usesDefaultForeground: false),
        cell("b", background: .init(r: 20, g: 80, b: 120), usesDefaultBackground: false),
        cell("c", bold: true, faint: true, underline: true),
        cell("d", inverse: true),
      ]
    )

    backend.render(frame: styled)
    backend.flushPendingFrame()

    #expect(backend.diagnostics.styleStats.explicitForegroundCells == 1)
    #expect(backend.diagnostics.styleStats.explicitBackgroundCells == 1)
    #expect(backend.diagnostics.styleStats.boldCells == 1)
    #expect(backend.diagnostics.styleStats.faintCells == 1)
    #expect(backend.diagnostics.styleStats.underlineCells == 1)
    #expect(backend.diagnostics.styleStats.inverseCells == 1)
    #expect(backend.diagnostics.debugSummary.contains("styleFg=1"))
    #expect(backend.diagnostics.debugSummary.contains("styleInverse=1"))
  }

  @MainActor @Test func cellGridBackendScansStyleStatsIncrementallyForDirtyRowsAfterInitialFrame() {
    let backend = GhosttyVTCellGridRendererBackend()
    let initial = frame(rows: ["abc", "def", "ghi"], cols: 4, cursorX: 0, cursorY: 0)
    var changed = initial
    changed.cells[4] = cell("d", bold: true)

    backend.render(frame: initial)
    backend.flushPendingFrame()
    backend.render(frame: changed)
    backend.flushPendingFrame()

    let diagnostics = backend.diagnostics
    #expect(diagnostics.styleStats.boldCells == 1)
    #expect(diagnostics.renderStyleScanRowCount == 1)
    #expect(diagnostics.renderStyleScanCellCount == 4)
  }

  @MainActor @Test func cellGridBackendScansResizeSensitivityIncrementallyForDirtyRowsBelowCursorAfterInitialFrame() {
    let backend = GhosttyVTCellGridRendererBackend()
    let initial = frame(rows: ["abc", "def", "ghi"], cols: 4, cursorX: 0, cursorY: 1)
    var changed = initial
    changed.cells[0] = cell("x")

    backend.render(frame: initial)
    backend.flushPendingFrame()
    backend.render(frame: changed)
    backend.flushPendingFrame()

    let diagnostics = backend.diagnostics
    #expect(diagnostics.resizeSensitiveScreen == true)
    #expect(diagnostics.renderResizeSensitivityScanRowCount == 0)
    #expect(diagnostics.renderResizeSensitivityScanCellCount == 0)
  }

  @MainActor @Test func cellGridBackendReportsCacheHitRateForUnchangedFrames() {
    let backend = GhosttyVTCellGridRendererBackend()
    let snapshot = frame(rows: ["same"], cols: 8, cursorX: 0, cursorY: 0)

    backend.render(frame: snapshot)
    backend.flushPendingFrame()
    backend.render(frame: snapshot)
    backend.flushPendingFrame()

    #expect(backend.diagnostics.cacheHitRate > 0)
    #expect(backend.diagnostics.redrawMode == .clean)
  }

  @MainActor @Test func cellGridBackendOnlyFullRedrawsWhenFocusActuallyChanges() {
    let backend = GhosttyVTCellGridRendererBackend()

    backend.setFocused(true)
    backend.render(frame: frame(rows: ["one", "two"], cols: 8, cursorX: 0, cursorY: 0))
    backend.flushPendingFrame()
    backend.setFocused(true)
    backend.render(frame: frame(rows: ["one", "twx"], cols: 8, cursorX: 0, cursorY: 0))
    backend.flushPendingFrame()

    #expect(backend.diagnostics.redrawMode == .dirty)
    #expect(backend.diagnostics.dirtyRowCount == 1)

    backend.setFocused(false)
    backend.render(frame: frame(rows: ["one", "twx"], cols: 8, cursorX: 0, cursorY: 0))
    backend.flushPendingFrame()

    #expect(backend.diagnostics.redrawMode == .full)
    #expect(backend.diagnostics.dirtyRowCount == 2)
  }

  @MainActor @Test func cellGridBackendMarksFullRedrawAfterThemeAndFontChanges() {
    let backend = GhosttyVTCellGridRendererBackend()
    let snapshot = frame(rows: ["one", "two"], cols: 8, cursorX: 0, cursorY: 0)

    backend.render(frame: snapshot)
    backend.flushPendingFrame()
    backend.applyPalette(.light)
    backend.render(frame: snapshot)
    backend.flushPendingFrame()

    #expect(backend.diagnostics.redrawMode == .full)
    #expect(backend.diagnostics.dirtyRowCount == 2)

    backend.applyFont(family: "Menlo", size: 16)
    backend.render(frame: snapshot)
    backend.flushPendingFrame()

    #expect(backend.diagnostics.redrawMode == .full)
    #expect(backend.diagnostics.dirtyRowCount == 2)
  }

  @MainActor @Test func cellGridViewTypeNameIsAvailableForBackendArchitecture() {
    let backend = GhosttyVTCellGridRendererBackend()

    #expect(backend.view is CellGridView)
  }

  @MainActor @Test func cellGridViewTracksSelectionRowsForDirtyInvalidation() {
    let view = CellGridView()
    view.render(frame(rows: ["one", "two", "three"], cols: 8, cursorX: 0, cursorY: 0), isFocused: true)

    view.testSetSelection(anchor: GridSelectionCoordinate(row: 0, col: 0), head: GridSelectionCoordinate(row: 2, col: 1))

    #expect(view.currentSelectionRowSet == [0, 1, 2])
  }

  private func frame(rows: [String], cols: Int, cursorX: Int, cursorY: Int) -> GhosttyTerminalFrame {
    let cells = rows.flatMap { row in
      let padded = row.padding(toLength: cols, withPad: " ", startingAt: 0)
      return padded.unicodeScalars.prefix(cols).map {
        GhosttyTerminalFrame.Cell(
          scalar: $0,
          foreground: GhosttyTerminalFrame.RGB(r: 255, g: 255, b: 255),
          background: GhosttyTerminalFrame.RGB(r: 0, g: 0, b: 0),
          bold: false,
          italic: false,
          faint: false,
          underline: false,
          inverse: false,
          usesDefaultForeground: true,
          usesDefaultBackground: true
        )
      }
    }
    return GhosttyTerminalFrame(
      cols: cols,
      rows: rows.count,
      cursorVisible: true,
      cursorX: cursorX,
      cursorY: cursorY,
      cursorShape: .bar,
      cursorBlinking: false,
      isAlternateScreen: false,
      cells: cells
    )
  }

  private func scrollFrame(
    viewportRows: [String],
    overscanTop: [String],
    overscanBottom: [String],
    cols: Int
  ) -> GhosttyTerminalScrollFrame {
    GhosttyTerminalScrollFrame(
      viewport: frame(rows: viewportRows, cols: cols, cursorX: 0, cursorY: max(0, viewportRows.count - 1)),
      overscanTop: overscanTop.map { cellRow($0, cols: cols) },
      overscanBottom: overscanBottom.map { cellRow($0, cols: cols) },
      requestedOverscanTop: overscanTop.count,
      requestedOverscanBottom: overscanBottom.count,
      viewportStartRow: UInt64(overscanTop.count)
    )
  }

  private func cellRow(_ text: String, cols: Int) -> GhosttyTerminalCellRow {
    let padded = text.padding(toLength: cols, withPad: " ", startingAt: 0)
    return GhosttyTerminalCellRow(cells: padded.unicodeScalars.prefix(cols).map {
      cell($0)
    })
  }

  private func cell(
    _ scalar: UnicodeScalar,
    width: TerminalCellWidth = .narrow,
    foreground: GhosttyTerminalFrame.RGB = .init(r: 255, g: 255, b: 255),
    background: GhosttyTerminalFrame.RGB = .init(r: 0, g: 0, b: 0),
    bold: Bool = false,
    italic: Bool = false,
    faint: Bool = false,
    underline: Bool = false,
    inverse: Bool = false,
    usesDefaultForeground: Bool = true,
    usesDefaultBackground: Bool = true
  ) -> GhosttyTerminalFrame.Cell {
    GhosttyTerminalFrame.Cell(
      scalar: scalar,
      width: width,
      foreground: foreground,
      background: background,
      bold: bold,
      italic: italic,
      faint: faint,
      underline: underline,
      inverse: inverse,
      usesDefaultForeground: usesDefaultForeground,
      usesDefaultBackground: usesDefaultBackground
    )
  }

  private func nonBackgroundPixelCount(
    in rect: NSRect,
    image: NSBitmapImageRep,
    background: NSColor
  ) -> Int {
    let backgroundRGB = background.usingColorSpace(.deviceRGB) ?? background
    let minX = max(0, Int(floor(rect.minX)))
    let maxX = min(image.pixelsWide - 1, Int(ceil(rect.maxX)))
    let minY = max(0, Int(floor(rect.minY)))
    let maxY = min(image.pixelsHigh - 1, Int(ceil(rect.maxY)))
    guard minX <= maxX, minY <= maxY else { return 0 }

    var count = 0
    for x in minX...maxX {
      for y in minY...maxY {
        guard let color = image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
        let distance = abs(color.redComponent - backgroundRGB.redComponent)
          + abs(color.greenComponent - backgroundRGB.greenComponent)
          + abs(color.blueComponent - backgroundRGB.blueComponent)
        if distance > 0.08 {
          count += 1
        }
      }
    }
    return count
  }

  private func bitmapRect(_ viewRect: NSRect, imageHeight: Int) -> NSRect {
    NSRect(
      x: viewRect.minX,
      y: CGFloat(imageHeight) - viewRect.maxY,
      width: viewRect.width,
      height: viewRect.height
    )
  }

  private func alphaBounds(in image: CGImage) -> CGRect? {
    let width = image.width
    let height = image.height
    guard width > 0, height > 0 else { return nil }
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    guard let context = CGContext(
      data: &bytes,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: width * 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
      return nil
    }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

    var minX = width
    var minY = height
    var maxX = -1
    var maxY = -1
    for y in 0..<height {
      for x in 0..<width {
        let alpha = bytes[(y * width + x) * 4 + 3]
        guard alpha > 0 else { continue }
        minX = min(minX, x)
        minY = min(minY, y)
        maxX = max(maxX, x)
        maxY = max(maxY, y)
      }
    }
    guard maxX >= minX, maxY >= minY else { return nil }
    return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
  }

  private func alphaSum(in image: CGImage) -> Int {
    let width = image.width
    let height = image.height
    guard width > 0, height > 0 else { return 0 }
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    guard let context = CGContext(
      data: &bytes,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: width * 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
      return 0
    }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    var sum = 0
    for index in stride(from: 3, to: bytes.count, by: 4) {
      sum += Int(bytes[index])
    }
    return sum
  }

  @MainActor private func mouseEvent(_ type: NSEvent.EventType, viewPoint: NSPoint, in view: NSView) throws -> NSEvent {
    try #require(NSEvent.mouseEvent(
      with: type,
      location: view.convert(viewPoint, to: nil),
      modifierFlags: [],
      timestamp: 0,
      windowNumber: view.window?.windowNumber ?? 0,
      context: nil,
      eventNumber: 0,
      clickCount: 1,
      pressure: 1
    ))
  }
}

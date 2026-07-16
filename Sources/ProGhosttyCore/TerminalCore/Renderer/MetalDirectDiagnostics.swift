import CoreGraphics
import Foundation

/// Metal-direct-renderer-specific diagnostics.
///
/// Only `MetalDirectRendererBackend` populates these; the AppKit cell-grid and
/// text-fallback backends leave them at defaults. Kept as a nested value on
/// `TerminalRendererDiagnostics` so the shared struct is not cluttered with
/// backend-specific counters and adding a Metal metric touches one place.
public struct MetalDirectDiagnostics: Equatable, Sendable {
  public var planRows: Int
  public var planCols: Int
  public var uploadedRowCount: Int
  public var uploadedCellCount: Int
  public var dirtyCellCount: Int
  public var glyphAtlasEntryCount: Int
  public var presentedFrameCount: Int
  public var drawPassCount: Int
  public var pipelineReady: Bool
  public var drawnRowCount: Int
  public var drawnCellCount: Int
  public var drawRunCount: Int
  public var renderPassLoadAction: String
  public var waitedForCompletion: Bool
  public var gpuWaitReason: String
  public var staleCompletionCount: Int
  public var latestRenderGeneration: Int
  public var latestSubmittedGeneration: Int
  public var latestPresentedGeneration: Int
  public var fullRedrawReason: String
  public var expandedFrameCellCount: Int
  public var glyphTextureHitCount: Int
  public var glyphTextureMissCount: Int
  public var textureCacheHitRate: Double
  public var glyphScanRowCount: Int
  public var glyphScanCellCount: Int
  public var styleScanRowCount: Int
  public var styleScanCellCount: Int
  public var resizeSensitivityScanRowCount: Int
  public var resizeSensitivityScanCellCount: Int
  public var styleAggregateRowCount: Int

  public init(
    planRows: Int = 0,
    planCols: Int = 0,
    uploadedRowCount: Int = 0,
    uploadedCellCount: Int = 0,
    dirtyCellCount: Int = 0,
    glyphAtlasEntryCount: Int = 0,
    presentedFrameCount: Int = 0,
    drawPassCount: Int = 0,
    pipelineReady: Bool = false,
    drawnRowCount: Int = 0,
    drawnCellCount: Int = 0,
    drawRunCount: Int = 0,
    renderPassLoadAction: String = "none",
    waitedForCompletion: Bool = false,
    gpuWaitReason: String = "none",
    staleCompletionCount: Int = 0,
    latestRenderGeneration: Int = 0,
    latestSubmittedGeneration: Int = 0,
    latestPresentedGeneration: Int = 0,
    fullRedrawReason: String = "none",
    expandedFrameCellCount: Int = 0,
    glyphTextureHitCount: Int = 0,
    glyphTextureMissCount: Int = 0,
    textureCacheHitRate: Double = 0,
    glyphScanRowCount: Int = 0,
    glyphScanCellCount: Int = 0,
    styleScanRowCount: Int = 0,
    styleScanCellCount: Int = 0,
    resizeSensitivityScanRowCount: Int = 0,
    resizeSensitivityScanCellCount: Int = 0,
    styleAggregateRowCount: Int = 0
  ) {
    self.planRows = planRows
    self.planCols = planCols
    self.uploadedRowCount = uploadedRowCount
    self.uploadedCellCount = uploadedCellCount
    self.dirtyCellCount = dirtyCellCount
    self.glyphAtlasEntryCount = glyphAtlasEntryCount
    self.presentedFrameCount = presentedFrameCount
    self.drawPassCount = drawPassCount
    self.pipelineReady = pipelineReady
    self.drawnRowCount = drawnRowCount
    self.drawnCellCount = drawnCellCount
    self.drawRunCount = drawRunCount
    self.renderPassLoadAction = renderPassLoadAction
    self.waitedForCompletion = waitedForCompletion
    self.gpuWaitReason = gpuWaitReason
    self.staleCompletionCount = staleCompletionCount
    self.latestRenderGeneration = latestRenderGeneration
    self.latestSubmittedGeneration = latestSubmittedGeneration
    self.latestPresentedGeneration = latestPresentedGeneration
    self.fullRedrawReason = fullRedrawReason
    self.expandedFrameCellCount = expandedFrameCellCount
    self.glyphTextureHitCount = glyphTextureHitCount
    self.glyphTextureMissCount = glyphTextureMissCount
    self.textureCacheHitRate = textureCacheHitRate
    self.glyphScanRowCount = glyphScanRowCount
    self.glyphScanCellCount = glyphScanCellCount
    self.styleScanRowCount = styleScanRowCount
    self.styleScanCellCount = styleScanCellCount
    self.resizeSensitivityScanRowCount = resizeSensitivityScanRowCount
    self.resizeSensitivityScanCellCount = resizeSensitivityScanCellCount
    self.styleAggregateRowCount = styleAggregateRowCount
  }

  /// Metal-specific portion of the diagnostics debug summary.
  public var debugSummary: String {
    "metalDirectPlanRows=\(planRows) metalDirectPlanCols=\(planCols) metalDirectUploadedRows=\(uploadedRowCount) metalDirectUploadedCells=\(uploadedCellCount) metalDirectDirtyCells=\(dirtyCellCount) metalDirectDrawnRows=\(drawnRowCount) metalDirectDrawnCells=\(drawnCellCount) metalDirectDrawRuns=\(drawRunCount) metalDirectLoadAction=\(renderPassLoadAction) metalDirectWaited=\(waitedForCompletion) metalDirectGPUWaitReason=\"\(gpuWaitReason)\" metalDirectStaleCompletions=\(staleCompletionCount) metalDirectLatestRenderGeneration=\(latestRenderGeneration) metalDirectLatestSubmittedGeneration=\(latestSubmittedGeneration) metalDirectLatestPresentedGeneration=\(latestPresentedGeneration) metalDirectFullRedrawReason=\"\(fullRedrawReason)\" metalDirectExpandedFrameCells=\(expandedFrameCellCount) metalDirectGlyphTextureHits=\(glyphTextureHitCount) metalDirectGlyphTextureMisses=\(glyphTextureMissCount) metalDirectTextureHitRate=\(String(format: "%.3f", textureCacheHitRate)) metalDirectGlyphScanRows=\(glyphScanRowCount) metalDirectGlyphScanCells=\(glyphScanCellCount) metalDirectStyleScanRows=\(styleScanRowCount) metalDirectStyleScanCells=\(styleScanCellCount) metalDirectResizeSensitivityScanRows=\(resizeSensitivityScanRowCount) metalDirectResizeSensitivityScanCells=\(resizeSensitivityScanCellCount) metalDirectStyleAggregateRows=\(styleAggregateRowCount) metalDirectGlyphs=\(glyphAtlasEntryCount) metalDirectPresented=\(presentedFrameCount) metalDirectDrawPasses=\(drawPassCount) metalDirectPipelineReady=\(pipelineReady)"
  }
}

import AppKit
import Foundation

public enum TerminalRendererMode: String, CaseIterable, Codable, Sendable, Identifiable {
  case auto
  case metalDirect
  case ghosttyVTCellGrid
  case ghosttyVTTextFallback

  public var id: String { rawValue }
}

public struct TerminalRendererOptions: Equatable, Sendable {
  public var mode: TerminalRendererMode
  public var smoothPixelScrollingEnabled: Bool
  public var dirtyRowRenderingEnabled: Bool
  public var forceFullRedrawEnabled: Bool

  public init(
    mode: TerminalRendererMode = .auto,
    smoothPixelScrollingEnabled: Bool = true,
    dirtyRowRenderingEnabled: Bool = true,
    forceFullRedrawEnabled: Bool = false
  ) {
    self.mode = mode
    self.smoothPixelScrollingEnabled = smoothPixelScrollingEnabled
    self.dirtyRowRenderingEnabled = dirtyRowRenderingEnabled
    self.forceFullRedrawEnabled = forceFullRedrawEnabled
  }
}

public enum TerminalRenderFramePresentation: Equatable, Sendable {
  case frame
  case scrollFrame
}

public struct TerminalRenderFrame: Sendable, Equatable {
  public let frame: GhosttyTerminalFrame
  public let scrollFrame: GhosttyTerminalScrollFrame?
  public let isFocused: Bool
  public let presentation: TerminalRenderFramePresentation
  public let generation: Int

  public init(frame: GhosttyTerminalFrame, isFocused: Bool = false) {
    self.init(frame: frame, isFocused: isFocused, generation: 0)
  }

  public init(frame: GhosttyTerminalFrame, isFocused: Bool = false, generation: Int) {
    self.frame = frame
    scrollFrame = nil
    self.isFocused = isFocused
    presentation = .frame
    self.generation = generation
  }

  public init(scrollFrame: GhosttyTerminalScrollFrame, isFocused: Bool = false) {
    self.init(scrollFrame: scrollFrame, isFocused: isFocused, generation: 0)
  }

  public init(scrollFrame: GhosttyTerminalScrollFrame, isFocused: Bool = false, generation: Int) {
    frame = scrollFrame.viewport
    self.scrollFrame = scrollFrame
    self.isFocused = isFocused
    presentation = .scrollFrame
    self.generation = generation
  }

  /// The frame to draw, with any overscan rows flattened into a single cell
  /// grid. For scroll frames this stitches `overscanTop + viewport +
  /// overscanBottom` into one frame and offsets the cursor accordingly; for
  /// plain frames it is just `frame`.
  public var expandedFrame: GhosttyTerminalFrame {
    guard let scrollFrame else {
      return frame
    }
    var expanded = scrollFrame.viewport
    expanded.rows = scrollFrame.overscanTop.count + scrollFrame.viewport.rows + scrollFrame.overscanBottom.count
    expanded.cursorY += scrollFrame.overscanTop.count
    expanded.cells = scrollFrame.overscanTop.flatMap(\.cells)
      + scrollFrame.viewport.cells
      + scrollFrame.overscanBottom.flatMap(\.cells)
    return expanded
  }
}

public enum RendererDebug {
  public static let enableExperimentalPixelScroll =
    ProcessInfo.processInfo.environment["PROGHOSTTY_EXPERIMENTAL_PIXEL_SCROLL"] != "0"
}

public extension AppSettings {
  var terminalRendererOptions: TerminalRendererOptions {
    TerminalRendererOptions(
      mode: rendererMode,
      smoothPixelScrollingEnabled: RendererDebug.enableExperimentalPixelScroll && smoothPixelScrollingEnabled,
      dirtyRowRenderingEnabled: dirtyRowRenderingEnabled,
      forceFullRedrawEnabled: forceFullRedrawEnabled
    )
  }
}

public enum TerminalRendererBackendKind: String, Sendable {
  case metalDirect = "MetalDirect"
  case ghosttyVTCellGrid = "GhosttyVTCellGrid"
  case ghosttyVTTextFallback = "GhosttyVTTextFallback"
}

public enum TerminalRendererSurfacePresentation: Equatable, Sendable {
  case liveCellGrid
  case textFallback
}

public struct TerminalRendererBackendSelection: Equatable, Sendable {
  public let presentation: TerminalRendererSurfacePresentation
  public let activeBackend: TerminalRendererBackendKind
  public let requestedBackend: TerminalRendererBackendKind?
  public let fallbackReason: String?

  public static func resolve(
    mode: TerminalRendererMode,
    hasFrame: Bool,
    isMetalDirectAvailable: Bool = false
  ) -> TerminalRendererBackendSelection {
    TerminalRendererPolicy.resolve(
      mode: mode,
      hasFrame: hasFrame,
      isMetalDirectAvailable: isMetalDirectAvailable
    )
  }
}

public enum TerminalRedrawMode: String, Sendable {
  case dirty
  case full
  case clean
}

public enum TerminalScrollMode: String, Sendable {
  case rowBased = "row-based"
}

public enum TerminalPixelSmoothScrollAvailability: String, Sendable {
  case unavailable
  case experimental
}

public enum TerminalScrollCommitMode: String, Sendable {
  case immediate
  case coalesced
}

public struct TerminalCellStyleStats: Equatable, Sendable {
  public var explicitForegroundCells: Int
  public var explicitBackgroundCells: Int
  public var boldCells: Int
  public var italicCells: Int
  public var faintCells: Int
  public var underlineCells: Int
  public var inverseCells: Int

  public init(
    explicitForegroundCells: Int = 0,
    explicitBackgroundCells: Int = 0,
    boldCells: Int = 0,
    italicCells: Int = 0,
    faintCells: Int = 0,
    underlineCells: Int = 0,
    inverseCells: Int = 0
  ) {
    self.explicitForegroundCells = explicitForegroundCells
    self.explicitBackgroundCells = explicitBackgroundCells
    self.boldCells = boldCells
    self.italicCells = italicCells
    self.faintCells = faintCells
    self.underlineCells = underlineCells
    self.inverseCells = inverseCells
  }

  public init(frame: GhosttyTerminalFrame) {
    self.init()
    accumulate(frame.cells)
  }

  public init<S: Sequence>(cells: S) where S.Element == GhosttyTerminalFrame.Cell {
    self.init()
    accumulate(cells)
  }

  public mutating func add(_ other: TerminalCellStyleStats) {
    explicitForegroundCells += other.explicitForegroundCells
    explicitBackgroundCells += other.explicitBackgroundCells
    boldCells += other.boldCells
    italicCells += other.italicCells
    faintCells += other.faintCells
    underlineCells += other.underlineCells
    inverseCells += other.inverseCells
  }

  public mutating func subtract(_ other: TerminalCellStyleStats) {
    explicitForegroundCells -= other.explicitForegroundCells
    explicitBackgroundCells -= other.explicitBackgroundCells
    boldCells -= other.boldCells
    italicCells -= other.italicCells
    faintCells -= other.faintCells
    underlineCells -= other.underlineCells
    inverseCells -= other.inverseCells
  }

  public mutating func accumulate<S: Sequence>(_ cells: S) where S.Element == GhosttyTerminalFrame.Cell {
    for cell in cells where cell.scalar != " " || !cell.usesDefaultBackground {
      if !cell.usesDefaultForeground {
        explicitForegroundCells += 1
      }
      if !cell.usesDefaultBackground {
        explicitBackgroundCells += 1
      }
      if cell.bold {
        boldCells += 1
      }
      if cell.italic {
        italicCells += 1
      }
      if cell.faint {
        faintCells += 1
      }
      if cell.underline {
        underlineCells += 1
      }
      if cell.inverse {
        inverseCells += 1
      }
    }
  }
}

public struct TerminalRendererDiagnostics: Equatable, Sendable {
  public static let missingOverscanRowsReason = "missing overscan rows from libghostty-vt snapshot"
  public static let overscanRowsAvailableReason = "overscan rows available from libghostty-vt snapshot"
  public static let smoothScrollEnabledReason = "normal scrollback overscan pixel scroll enabled"
  public static let smoothScrollDisabledReason = "smooth pixel scroll disabled"
  public static let alternateScreenScrollReason = "alternate screen forwards wheel input to TUI"
  public static let invalidCellHeightReason = "invalid cell height"
  public static let metalDirectUnavailableFallbackReason = "Metal direct renderer unavailable; using AppKit cell grid"
  public static let metalDirectRenderFailedFallbackReason = "Metal direct renderer failed during presentation; keeping AppKit cell grid state"

  public var backend: TerminalRendererBackendKind
  public var requestedBackend: TerminalRendererBackendKind?
  public var backendFallbackReason: String?
  public var usesBitmapCapture: Bool
  public var dirtyRowCount: Int
  public var visibleRowCount: Int
  public var cacheHitRate: Double
  public var averageDrawTime: TimeInterval
  public var maxDrawTime: TimeInterval
  public var redrawMode: TerminalRedrawMode
  public var smoothScrollOffset: CGFloat
  public var coalescedFrames: Int
  public var droppedFrames: Int
  public var alternateScreenActive: Bool
  public var resizeSensitiveScreen: Bool
  public var scrollMode: TerminalScrollMode
  public var overscanTopRows: Int
  public var overscanBottomRows: Int
  public var pixelSmoothScroll: TerminalPixelSmoothScrollAvailability
  public var pixelSmoothScrollReason: String
  public var pixelRemainderY: CGFloat
  public var committedRowDelta: Int
  public var coalescedWheelEvents: Int
  public var scrollCommitMode: TerminalScrollCommitMode
  public var pendingScrollRowDelta: Int
  public var pendingScrollWheelEvents: Int
  public var lastScrollCommitDuration: TimeInterval
  public var lastScrollRenderDuration: TimeInterval
  public var bridgeScrollViewportDuration: TimeInterval
  public var bridgeScrollbarSnapshotDuration: TimeInterval
  public var bridgeFrameSnapshotDuration: TimeInterval
  public var bridgeScrollFrameSnapshotDuration: TimeInterval
  public var bridgeSnapshotCellCount: Int
  public var lastResizeTotalDuration: TimeInterval
  public var lastResizeVTDuration: TimeInterval
  public var lastResizeSnapshotDuration: TimeInterval
  public var pendingResize: Bool
  public var metalDirect: MetalDirectDiagnostics
  public var renderStyleScanRowCount: Int
  public var renderStyleScanCellCount: Int
  public var renderResizeSensitivityScanRowCount: Int
  public var renderResizeSensitivityScanCellCount: Int
  public var styleStats: TerminalCellStyleStats

  public init(
    backend: TerminalRendererBackendKind,
    requestedBackend: TerminalRendererBackendKind? = nil,
    backendFallbackReason: String? = nil,
    usesBitmapCapture: Bool = false,
    dirtyRowCount: Int = 0,
    visibleRowCount: Int = 0,
    cacheHitRate: Double = 0,
    averageDrawTime: TimeInterval = 0,
    maxDrawTime: TimeInterval = 0,
    redrawMode: TerminalRedrawMode = .clean,
    smoothScrollOffset: CGFloat = 0,
    coalescedFrames: Int = 0,
    droppedFrames: Int = 0,
    alternateScreenActive: Bool = false,
    resizeSensitiveScreen: Bool = false,
    scrollMode: TerminalScrollMode = .rowBased,
    overscanTopRows: Int = 0,
    overscanBottomRows: Int = 0,
    pixelSmoothScroll: TerminalPixelSmoothScrollAvailability = .unavailable,
    pixelSmoothScrollReason: String = TerminalRendererDiagnostics.missingOverscanRowsReason,
    pixelRemainderY: CGFloat = 0,
    committedRowDelta: Int = 0,
    coalescedWheelEvents: Int = 0,
    scrollCommitMode: TerminalScrollCommitMode = .immediate,
    pendingScrollRowDelta: Int = 0,
    pendingScrollWheelEvents: Int = 0,
    lastScrollCommitDuration: TimeInterval = 0,
    lastScrollRenderDuration: TimeInterval = 0,
    bridgeScrollViewportDuration: TimeInterval = 0,
    bridgeScrollbarSnapshotDuration: TimeInterval = 0,
    bridgeFrameSnapshotDuration: TimeInterval = 0,
    bridgeScrollFrameSnapshotDuration: TimeInterval = 0,
    bridgeSnapshotCellCount: Int = 0,
    lastResizeTotalDuration: TimeInterval = 0,
    lastResizeVTDuration: TimeInterval = 0,
    lastResizeSnapshotDuration: TimeInterval = 0,
    pendingResize: Bool = false,
    metalDirect: MetalDirectDiagnostics = MetalDirectDiagnostics(),
    renderStyleScanRowCount: Int = 0,
    renderStyleScanCellCount: Int = 0,
    renderResizeSensitivityScanRowCount: Int = 0,
    renderResizeSensitivityScanCellCount: Int = 0,
    styleStats: TerminalCellStyleStats = TerminalCellStyleStats()
  ) {
    self.backend = backend
    self.requestedBackend = requestedBackend
    self.backendFallbackReason = backendFallbackReason
    self.usesBitmapCapture = usesBitmapCapture
    self.dirtyRowCount = dirtyRowCount
    self.visibleRowCount = visibleRowCount
    self.cacheHitRate = cacheHitRate
    self.averageDrawTime = averageDrawTime
    self.maxDrawTime = maxDrawTime
    self.redrawMode = redrawMode
    self.smoothScrollOffset = smoothScrollOffset
    self.coalescedFrames = coalescedFrames
    self.droppedFrames = droppedFrames
    self.alternateScreenActive = alternateScreenActive
    self.resizeSensitiveScreen = resizeSensitiveScreen
    self.scrollMode = scrollMode
    self.overscanTopRows = overscanTopRows
    self.overscanBottomRows = overscanBottomRows
    self.pixelSmoothScroll = pixelSmoothScroll
    self.pixelSmoothScrollReason = pixelSmoothScrollReason
    self.pixelRemainderY = pixelRemainderY
    self.committedRowDelta = committedRowDelta
    self.coalescedWheelEvents = coalescedWheelEvents
    self.scrollCommitMode = scrollCommitMode
    self.pendingScrollRowDelta = pendingScrollRowDelta
    self.pendingScrollWheelEvents = pendingScrollWheelEvents
    self.lastScrollCommitDuration = lastScrollCommitDuration
    self.lastScrollRenderDuration = lastScrollRenderDuration
    self.bridgeScrollViewportDuration = bridgeScrollViewportDuration
    self.bridgeScrollbarSnapshotDuration = bridgeScrollbarSnapshotDuration
    self.bridgeFrameSnapshotDuration = bridgeFrameSnapshotDuration
    self.bridgeScrollFrameSnapshotDuration = bridgeScrollFrameSnapshotDuration
    self.bridgeSnapshotCellCount = bridgeSnapshotCellCount
    self.lastResizeTotalDuration = lastResizeTotalDuration
    self.lastResizeVTDuration = lastResizeVTDuration
    self.lastResizeSnapshotDuration = lastResizeSnapshotDuration
    self.pendingResize = pendingResize
    self.metalDirect = metalDirect
    self.renderStyleScanRowCount = renderStyleScanRowCount
    self.renderStyleScanCellCount = renderStyleScanCellCount
    self.renderResizeSensitivityScanRowCount = renderResizeSensitivityScanRowCount
    self.renderResizeSensitivityScanCellCount = renderResizeSensitivityScanCellCount
    self.styleStats = styleStats
  }

  public var debugSummary: String {
    let shared = "backend=\(backend.rawValue) requestedBackend=\(requestedBackend?.rawValue ?? "none") fallbackReason=\"\(backendFallbackReason ?? "none")\" usesBitmapCapture=\(usesBitmapCapture) dirtyRows=\(dirtyRowCount) visibleRows=\(visibleRowCount) cacheHitRate=\(String(format: "%.3f", cacheHitRate)) avgDrawMs=\(String(format: "%.3f", averageDrawTime * 1000)) maxDrawMs=\(String(format: "%.3f", maxDrawTime * 1000)) redraw=\(redrawMode.rawValue) scrollMode=\(scrollMode.rawValue) overscanTop=\(overscanTopRows) overscanBottom=\(overscanBottomRows) pixelSmoothScroll=\(pixelSmoothScroll.rawValue) pixelSmoothScrollReason=\"\(pixelSmoothScrollReason)\" pixelRemainderY=\(String(format: "%.2f", pixelRemainderY)) committedRowDelta=\(committedRowDelta) coalescedWheelEvents=\(coalescedWheelEvents) scrollCommitMode=\(scrollCommitMode.rawValue) pendingScrollRowDelta=\(pendingScrollRowDelta) pendingScrollWheelEvents=\(pendingScrollWheelEvents) scrollCommitMs=\(String(format: "%.3f", lastScrollCommitDuration * 1000)) scrollRenderMs=\(String(format: "%.3f", lastScrollRenderDuration * 1000)) bridgeScrollViewportMs=\(String(format: "%.3f", bridgeScrollViewportDuration * 1000)) bridgeScrollbarSnapshotMs=\(String(format: "%.3f", bridgeScrollbarSnapshotDuration * 1000)) bridgeFrameSnapshotMs=\(String(format: "%.3f", bridgeFrameSnapshotDuration * 1000)) bridgeScrollFrameSnapshotMs=\(String(format: "%.3f", bridgeScrollFrameSnapshotDuration * 1000)) bridgeSnapshotCells=\(bridgeSnapshotCellCount) resizePending=\(pendingResize) resizeTotalMs=\(String(format: "%.3f", lastResizeTotalDuration * 1000)) resizeVTMs=\(String(format: "%.3f", lastResizeVTDuration * 1000)) resizeSnapshotMs=\(String(format: "%.3f", lastResizeSnapshotDuration * 1000)) scrollOffset=\(String(format: "%.2f", smoothScrollOffset)) coalesced=\(coalescedFrames) dropped=\(droppedFrames) alt=\(alternateScreenActive) resizeSensitive=\(resizeSensitiveScreen)"
    let render = "renderStyleScanRows=\(renderStyleScanRowCount) renderStyleScanCells=\(renderStyleScanCellCount) renderResizeSensitivityScanRows=\(renderResizeSensitivityScanRowCount) renderResizeSensitivityScanCells=\(renderResizeSensitivityScanCellCount) styleFg=\(styleStats.explicitForegroundCells) styleBg=\(styleStats.explicitBackgroundCells) styleBold=\(styleStats.boldCells) styleFaint=\(styleStats.faintCells) styleUnderline=\(styleStats.underlineCells) styleInverse=\(styleStats.inverseCells)"
    return "\(shared) \(metalDirect.debugSummary) \(render)"
  }
}

@MainActor
public protocol TerminalRendererBackend: AnyObject {
  var view: NSView { get }
  var diagnostics: TerminalRendererDiagnostics { get }
  var selectedText: String? { get }

  func setInputHandler(_ handler: ((Data) -> Void)?)
  func setActivationHandler(_ handler: (() -> Void)?)
  func applyPalette(_ palette: TerminalSurfacePalette)
  func applyFont(family: String, size: CGFloat, cjkFallbackFamily: String?)
  func setFocused(_ isFocused: Bool)
  func render(frame: GhosttyTerminalFrame)
  func focus()
}

@MainActor
public protocol TerminalLiveRendererBackend: TerminalRendererBackend {
  var gridView: PTYGridView { get }

  func applyOptions(_ options: TerminalRendererOptions)
  func render(_ renderFrame: TerminalRenderFrame)
  func flushPendingFrame()
  func updateOverscanDiagnostics(topRows: Int, bottomRows: Int)
  func markResizePending()
  func applyResizeDiagnostics(_ diagnostics: TerminalResizeDiagnostics)
  func resetViewportStartRowKeepingVisualOffset()
  func resetPixelScroll(suppressMomentum: Bool)
}

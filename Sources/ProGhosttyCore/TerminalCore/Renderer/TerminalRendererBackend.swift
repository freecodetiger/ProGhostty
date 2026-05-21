import AppKit
import Foundation

public enum TerminalRendererMode: String, CaseIterable, Codable, Sendable, Identifiable {
  case auto
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
  case ghosttyVTCellGrid = "GhosttyVTCellGrid"
  case ghosttyVTTextFallback = "GhosttyVTTextFallback"
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
    for cell in frame.cells where cell.scalar != " " || !cell.usesDefaultBackground {
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

  public var backend: TerminalRendererBackendKind
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
  public var lastResizeTotalDuration: TimeInterval
  public var lastResizeVTDuration: TimeInterval
  public var lastResizeSnapshotDuration: TimeInterval
  public var pendingResize: Bool
  public var styleStats: TerminalCellStyleStats

  public init(
    backend: TerminalRendererBackendKind,
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
    lastResizeTotalDuration: TimeInterval = 0,
    lastResizeVTDuration: TimeInterval = 0,
    lastResizeSnapshotDuration: TimeInterval = 0,
    pendingResize: Bool = false,
    styleStats: TerminalCellStyleStats = TerminalCellStyleStats()
  ) {
    self.backend = backend
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
    self.lastResizeTotalDuration = lastResizeTotalDuration
    self.lastResizeVTDuration = lastResizeVTDuration
    self.lastResizeSnapshotDuration = lastResizeSnapshotDuration
    self.pendingResize = pendingResize
    self.styleStats = styleStats
  }

  public var debugSummary: String {
    "backend=\(backend.rawValue) dirtyRows=\(dirtyRowCount) visibleRows=\(visibleRowCount) cacheHitRate=\(String(format: "%.3f", cacheHitRate)) avgDrawMs=\(String(format: "%.3f", averageDrawTime * 1000)) maxDrawMs=\(String(format: "%.3f", maxDrawTime * 1000)) redraw=\(redrawMode.rawValue) scrollMode=\(scrollMode.rawValue) overscanTop=\(overscanTopRows) overscanBottom=\(overscanBottomRows) pixelSmoothScroll=\(pixelSmoothScroll.rawValue) pixelSmoothScrollReason=\"\(pixelSmoothScrollReason)\" pixelRemainderY=\(String(format: "%.2f", pixelRemainderY)) committedRowDelta=\(committedRowDelta) coalescedWheelEvents=\(coalescedWheelEvents) scrollCommitMode=\(scrollCommitMode.rawValue) pendingScrollRowDelta=\(pendingScrollRowDelta) pendingScrollWheelEvents=\(pendingScrollWheelEvents) scrollCommitMs=\(String(format: "%.3f", lastScrollCommitDuration * 1000)) scrollRenderMs=\(String(format: "%.3f", lastScrollRenderDuration * 1000)) resizePending=\(pendingResize) resizeTotalMs=\(String(format: "%.3f", lastResizeTotalDuration * 1000)) resizeVTMs=\(String(format: "%.3f", lastResizeVTDuration * 1000)) resizeSnapshotMs=\(String(format: "%.3f", lastResizeSnapshotDuration * 1000)) scrollOffset=\(String(format: "%.2f", smoothScrollOffset)) coalesced=\(coalescedFrames) dropped=\(droppedFrames) alt=\(alternateScreenActive) resizeSensitive=\(resizeSensitiveScreen) styleFg=\(styleStats.explicitForegroundCells) styleBg=\(styleStats.explicitBackgroundCells) styleBold=\(styleStats.boldCells) styleFaint=\(styleStats.faintCells) styleUnderline=\(styleStats.underlineCells) styleInverse=\(styleStats.inverseCells)"
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
  func applyFont(family: String, size: CGFloat)
  func setFocused(_ isFocused: Bool)
  func render(frame: GhosttyTerminalFrame)
  func focus()
}

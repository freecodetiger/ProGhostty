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
    smoothPixelScrollingEnabled: Bool = false,
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
    ProcessInfo.processInfo.environment["PROGHOSTTY_EXPERIMENTAL_PIXEL_SCROLL"] == "1"
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
  public var scrollMode: TerminalScrollMode
  public var pixelSmoothScroll: TerminalPixelSmoothScrollAvailability
  public var pixelSmoothScrollReason: String
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
    scrollMode: TerminalScrollMode = .rowBased,
    pixelSmoothScroll: TerminalPixelSmoothScrollAvailability = .unavailable,
    pixelSmoothScrollReason: String = TerminalRendererDiagnostics.missingOverscanRowsReason,
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
    self.scrollMode = scrollMode
    self.pixelSmoothScroll = pixelSmoothScroll
    self.pixelSmoothScrollReason = pixelSmoothScrollReason
    self.styleStats = styleStats
  }

  public var debugSummary: String {
    "backend=\(backend.rawValue) dirtyRows=\(dirtyRowCount) visibleRows=\(visibleRowCount) cacheHitRate=\(String(format: "%.3f", cacheHitRate)) avgDrawMs=\(String(format: "%.3f", averageDrawTime * 1000)) maxDrawMs=\(String(format: "%.3f", maxDrawTime * 1000)) redraw=\(redrawMode.rawValue) scrollMode=\(scrollMode.rawValue) pixelSmoothScroll=\(pixelSmoothScroll.rawValue) pixelSmoothScrollReason=\"\(pixelSmoothScrollReason)\" scrollOffset=\(String(format: "%.2f", smoothScrollOffset)) coalesced=\(coalescedFrames) dropped=\(droppedFrames) alt=\(alternateScreenActive) styleFg=\(styleStats.explicitForegroundCells) styleBg=\(styleStats.explicitBackgroundCells) styleBold=\(styleStats.boldCells) styleFaint=\(styleStats.faintCells) styleUnderline=\(styleStats.underlineCells) styleInverse=\(styleStats.inverseCells)"
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

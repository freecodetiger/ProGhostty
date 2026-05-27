import AppKit
import Foundation

public struct TerminalViewport: Equatable, Sendable {
  public var startRow: Int
  public var visualOffsetY: CGFloat

  public init(startRow: Int = 0, visualOffsetY: CGFloat = 0) {
    self.startRow = startRow
    self.visualOffsetY = visualOffsetY
  }
}

public struct ViewportController: Equatable, Sendable {
  public var viewport: TerminalViewport
  public var visibleRowCount: Int
  public var overscan: Int

  public init(
    viewport: TerminalViewport = TerminalViewport(),
    visibleRowCount: Int = 0,
    overscan: Int = 1
  ) {
    self.viewport = viewport
    self.visibleRowCount = visibleRowCount
    self.overscan = overscan
  }

  public func rowRange(totalRows: Int) -> Range<Int> {
    guard totalRows > 0, visibleRowCount > 0 else { return 0..<0 }
    let lower = max(0, viewport.startRow - overscan)
    let upper = min(totalRows, viewport.startRow + visibleRowCount + overscan + 1)
    return lower..<max(lower, upper)
  }
}

public struct SelectionController: Sendable {
  public private(set) var selectedRows = Set<Int>()

  public init() {}

  public mutating func update(selectionRows: Set<Int>) -> Set<Int> {
    let changed = selectedRows.symmetricDifference(selectionRows)
    selectedRows = selectionRows
    return changed
  }
}

public struct CellGridModel: Sendable {
  public private(set) var frame: GhosttyTerminalFrame?
  public private(set) var previousFrame: GhosttyTerminalFrame?
  public private(set) var lastDirtyResult = CellGridDirtyResult(mode: .clean, rows: [])
  public private(set) var cacheHits = 0
  public private(set) var cacheMisses = 0
  private var selectionController = SelectionController()

  public init() {}

  @discardableResult
  public mutating func update(
    frame: GhosttyTerminalFrame,
    forceFullRedraw: Bool = false,
    dirtyRowsEnabled: Bool = true,
    selectionRows: Set<Int> = []
  ) -> CellGridDirtyResult {
    let result: CellGridDirtyResult
    if forceFullRedraw || !dirtyRowsEnabled {
      result = CellGridDirtyTracker.fullDirtyResult(for: frame)
    } else {
      let previousSelectionRows = selectionController.selectedRows
      _ = selectionController.update(selectionRows: selectionRows)
      result = CellGridDirtyTracker.diff(
        previous: self.frame,
        next: frame,
        previousSelectionRows: previousSelectionRows,
        nextSelectionRows: selectionRows
      )
    }
    if result.mode == .clean {
      cacheHits += 1
    } else {
      cacheMisses += 1
    }
    previousFrame = self.frame
    self.frame = frame
    lastDirtyResult = result
    return result
  }

  public var cacheHitRate: Double {
    let total = cacheHits + cacheMisses
    guard total > 0 else { return 0 }
    return Double(cacheHits) / Double(total)
  }
}

public struct CellGridDirtyResult: Equatable, Sendable {
  public var mode: TerminalRedrawMode
  public var rows: Set<Int>
  public var cellRanges: [CellGridDirtyRange]

  public init(mode: TerminalRedrawMode, rows: Set<Int>, cellRanges: [CellGridDirtyRange] = []) {
    self.mode = mode
    self.rows = rows
    self.cellRanges = cellRanges
  }

  public var dirtyCellCount: Int {
    cellRanges.reduce(0) { $0 + $1.cols.count }
  }
}

public struct CellGridDirtyRange: Equatable, Sendable {
  public let row: Int
  public let cols: Range<Int>

  public init(row: Int, cols: Range<Int>) {
    self.row = row
    self.cols = cols
  }
}

public enum CellGridDirtyTracker {
  public static func diff(
    previous: GhosttyTerminalFrame?,
    next: GhosttyTerminalFrame,
    previousSelectionRows: Set<Int> = [],
    nextSelectionRows: Set<Int> = []
  ) -> CellGridDirtyResult {
    guard let previous else {
      return fullDirtyResult(for: next)
    }
    guard previous.rows == next.rows, previous.cols == next.cols else {
      return fullDirtyResult(for: next)
    }

    var rows = Set<Int>()
    var cellRanges: [CellGridDirtyRange] = []
    let visibleRowCount = min(previous.rows, next.rows)
    for row in 0..<visibleRowCount where rowHash(previous, row: row) != rowHash(next, row: row) {
      rows.insert(row)
      cellRanges.append(contentsOf: dirtyCellRanges(previous: previous, next: next, row: row))
    }

    if cursorChanged(previous, next) {
      rows.insert(clampedRow(previous.cursorY, rowCount: previous.rows))
      rows.insert(clampedRow(next.cursorY, rowCount: next.rows))
    }
    rows.formUnion(previousSelectionRows)
    rows.formUnion(nextSelectionRows)

    return CellGridDirtyResult(
      mode: rows.isEmpty ? .clean : .dirty,
      rows: rows,
      cellRanges: cellRanges
    )
  }

  public static func diffIgnoringCursorOnlyChanges(
    previous: GhosttyTerminalFrame?,
    next: GhosttyTerminalFrame,
    previousSelectionRows: Set<Int> = [],
    nextSelectionRows: Set<Int> = []
  ) -> CellGridDirtyResult {
    let result = diff(
      previous: previous,
      next: next,
      previousSelectionRows: previousSelectionRows,
      nextSelectionRows: nextSelectionRows
    )
    guard
      result.mode == .dirty,
      let previous,
      previousSelectionRows.isEmpty,
      nextSelectionRows.isEmpty,
      isCursorOnlyDirty(previous: previous, next: next, dirtyRows: result.rows)
    else {
      return result
    }
    return CellGridDirtyResult(mode: .clean, rows: [])
  }

  public static func fullDirtyResult(for frame: GhosttyTerminalFrame) -> CellGridDirtyResult {
    let rows = Set(0..<max(0, frame.rows))
    return CellGridDirtyResult(
      mode: .full,
      rows: rows,
      cellRanges: rows.sorted().map { CellGridDirtyRange(row: $0, cols: 0..<max(0, frame.cols)) }
    )
  }

  private static func rowHash(_ frame: GhosttyTerminalFrame, row: Int) -> Int {
    var hasher = Hasher()
    let start = row * frame.cols
    let end = min(start + frame.cols, frame.cells.count)
    guard start < end else { return 0 }
    for cell in frame.cells[start..<end] {
      hasher.combine(cell.scalar.value)
      hasher.combine(cell.foreground)
      hasher.combine(cell.background)
      hasher.combine(cell.bold)
      hasher.combine(cell.italic)
      hasher.combine(cell.faint)
      hasher.combine(cell.underline)
      hasher.combine(cell.inverse)
      hasher.combine(cell.usesDefaultForeground)
      hasher.combine(cell.usesDefaultBackground)
    }
    return hasher.finalize()
  }

  private static func cursorChanged(_ previous: GhosttyTerminalFrame, _ next: GhosttyTerminalFrame) -> Bool {
    previous.cursorX != next.cursorX
      || previous.cursorY != next.cursorY
      || previous.cursorVisible != next.cursorVisible
      || previous.cursorShape != next.cursorShape
  }

  private static func dirtyCellRanges(
    previous: GhosttyTerminalFrame,
    next: GhosttyTerminalFrame,
    row: Int
  ) -> [CellGridDirtyRange] {
    guard row >= 0, row < min(previous.rows, next.rows), previous.cols > 0, next.cols > 0 else {
      return []
    }
    let cols = min(previous.cols, next.cols)
    var ranges: [CellGridDirtyRange] = []
    var runStart: Int?
    for col in 0..<cols {
      let previousIndex = row * previous.cols + col
      let nextIndex = row * next.cols + col
      let changed = previousIndex >= previous.cells.count
        || nextIndex >= next.cells.count
        || previous.cells[previousIndex] != next.cells[nextIndex]
      if changed {
        if runStart == nil {
          runStart = col
        }
      } else if let start = runStart {
        ranges.append(CellGridDirtyRange(row: row, cols: start..<col))
        runStart = nil
      }
    }
    if let start = runStart {
      ranges.append(CellGridDirtyRange(row: row, cols: start..<cols))
    }
    return ranges
  }

  private static func isCursorOnlyDirty(
    previous: GhosttyTerminalFrame,
    next: GhosttyTerminalFrame,
    dirtyRows: Set<Int>
  ) -> Bool {
    guard cursorChanged(previous, next) else { return false }
    let expectedRows = Set([
      clampedRow(previous.cursorY, rowCount: previous.rows),
      clampedRow(next.cursorY, rowCount: next.rows),
    ])
    guard dirtyRows == expectedRows else { return false }
    return dirtyRows.allSatisfy { row in
      rowHash(previous, row: row) == rowHash(next, row: row)
    }
  }

  private static func clampedRow(_ row: Int, rowCount: Int) -> Int {
    guard rowCount > 0 else { return 0 }
    return min(max(0, row), rowCount - 1)
  }
}

public enum SmoothScrollDecision: Equatable, Sendable {
  case consumed(rowDelta: Int)
  case forwardToPTY
  case ignored
}

public enum PaneScrollDecision: Equatable, Sendable {
  case consumed(rowDelta: Int, pixelRemainderY: CGFloat)
  case forwardToPTY
  case ignored
}

public struct PaneScrollCoordinator: Sendable {
  public private(set) var pixelRemainderY: CGFloat
  public private(set) var lastCommittedRowDelta: Int
  public private(set) var coalescedWheelEvents: Int
  public private(set) var lastDisabledReason: String
  private var pendingWheelEvents: Int

  public init(
    pixelRemainderY: CGFloat = 0,
    lastCommittedRowDelta: Int = 0,
    coalescedWheelEvents: Int = 0,
    lastDisabledReason: String = TerminalRendererDiagnostics.smoothScrollEnabledReason
  ) {
    self.pixelRemainderY = pixelRemainderY
    self.lastCommittedRowDelta = lastCommittedRowDelta
    self.coalescedWheelEvents = coalescedWheelEvents
    self.lastDisabledReason = lastDisabledReason
    pendingWheelEvents = 0
  }

  public var isPixelScrollActive: Bool {
    lastDisabledReason == TerminalRendererDiagnostics.smoothScrollEnabledReason
  }

  @discardableResult
  public mutating func scroll(
    deltaY: CGFloat,
    cellHeight: CGFloat,
    alternateScreen: Bool,
    smoothPixelScrollingEnabled: Bool,
    hasOverscanRowsForProjectedRemainder: Bool
  ) -> PaneScrollDecision {
    lastCommittedRowDelta = 0
    guard deltaY != 0 else { return .ignored }
    guard !alternateScreen else {
      reset(reason: TerminalRendererDiagnostics.alternateScreenScrollReason)
      return .forwardToPTY
    }
    guard smoothPixelScrollingEnabled else {
      reset(reason: TerminalRendererDiagnostics.smoothScrollDisabledReason)
      return rowBasedDecision(for: deltaY)
    }
    guard cellHeight > 0 else {
      reset(reason: TerminalRendererDiagnostics.invalidCellHeightReason)
      return .ignored
    }
    let projectedRemainderY = pixelRemainderY + deltaY
    let needsOverscanRows = projectedRemainderY != 0
    guard !needsOverscanRows || hasOverscanRowsForProjectedRemainder else {
      reset(reason: TerminalRendererDiagnostics.missingOverscanRowsReason)
      return rowBasedDecision(for: deltaY)
    }

    pendingWheelEvents += 1
    lastDisabledReason = TerminalRendererDiagnostics.smoothScrollEnabledReason
    pixelRemainderY = projectedRemainderY
    let rowDelta = Int(pixelRemainderY / cellHeight)
    if rowDelta != 0 {
      pixelRemainderY.formTruncatingRemainder(dividingBy: cellHeight)
      lastCommittedRowDelta = rowDelta
      coalescedWheelEvents = pendingWheelEvents
      pendingWheelEvents = abs(pixelRemainderY) > .ulpOfOne ? 1 : 0
    } else {
      coalescedWheelEvents = pendingWheelEvents
    }
    return .consumed(rowDelta: rowDelta, pixelRemainderY: pixelRemainderY)
  }

  public mutating func reset(reason: String = TerminalRendererDiagnostics.smoothScrollEnabledReason) {
    pixelRemainderY = 0
    lastCommittedRowDelta = 0
    coalescedWheelEvents = 0
    pendingWheelEvents = 0
    lastDisabledReason = reason
  }

  private mutating func rowBasedDecision(for deltaY: CGFloat) -> PaneScrollDecision {
    let rowDelta = deltaY.sign == .minus ? -1 : 1
    lastCommittedRowDelta = rowDelta
    coalescedWheelEvents = 1
    return .consumed(rowDelta: rowDelta, pixelRemainderY: 0)
  }
}

public struct ScrollCommitBatch: Equatable, Sendable {
  public var rowDelta: Int
  public var wheelEvents: Int

  public init(rowDelta: Int, wheelEvents: Int) {
    self.rowDelta = rowDelta
    self.wheelEvents = wheelEvents
  }
}

public struct ScrollCommitCoordinator: Sendable {
  public private(set) var pendingRowDelta: Int
  public private(set) var pendingWheelEvents: Int
  private var commitScheduled: Bool

  public init(pendingRowDelta: Int = 0, pendingWheelEvents: Int = 0, commitScheduled: Bool = false) {
    self.pendingRowDelta = pendingRowDelta
    self.pendingWheelEvents = pendingWheelEvents
    self.commitScheduled = commitScheduled
  }

  public var hasPendingCommit: Bool {
    commitScheduled || pendingRowDelta != 0
  }

  @discardableResult
  public mutating func enqueue(rowDelta: Int) -> Bool {
    guard rowDelta != 0 else { return false }
    let shouldSchedule = !commitScheduled
    pendingRowDelta += rowDelta
    pendingWheelEvents += 1
    commitScheduled = true
    return shouldSchedule
  }

  public mutating func drain() -> ScrollCommitBatch? {
    commitScheduled = false
    let rowDelta = pendingRowDelta
    let wheelEvents = pendingWheelEvents
    pendingRowDelta = 0
    pendingWheelEvents = 0
    guard rowDelta != 0 else { return nil }
    return ScrollCommitBatch(rowDelta: rowDelta, wheelEvents: wheelEvents)
  }

  public mutating func reset() {
    pendingRowDelta = 0
    pendingWheelEvents = 0
    commitScheduled = false
  }
}

public struct SmoothScrollController: Sendable {
  public private(set) var viewport: TerminalViewport
  public var isEnabled: Bool

  public init(viewport: TerminalViewport = TerminalViewport(), isEnabled: Bool = true) {
    self.viewport = viewport
    self.isEnabled = isEnabled
  }

  @discardableResult
  public mutating func scroll(
    deltaY: CGFloat,
    cellHeight: CGFloat,
    maxStartRow: Int?,
    alternateScreen: Bool
  ) -> SmoothScrollDecision {
    guard deltaY != 0 else { return .ignored }
    guard !alternateScreen else { return .forwardToPTY }
    guard isEnabled else {
      let rowDelta = deltaY.sign == .minus ? -1 : 1
      viewport.visualOffsetY = 0
      if let maxStartRow {
        let nextStartRow = clamp(viewport.startRow + rowDelta, maxStartRow: maxStartRow)
        guard nextStartRow != viewport.startRow else { return .ignored }
        viewport.startRow = nextStartRow
      } else {
        viewport.startRow += rowDelta
      }
      return .consumed(rowDelta: rowDelta)
    }
    guard cellHeight > 0 else { return .ignored }

    let edgeDirection = deltaY.sign == .minus ? -1 : 1
    if let maxStartRow, isAtEdge(for: edgeDirection, maxStartRow: maxStartRow) {
      viewport.visualOffsetY = 0
      return .ignored
    }

    viewport.visualOffsetY += deltaY
    var rowDelta = 0
    while abs(viewport.visualOffsetY) >= cellHeight {
      if viewport.visualOffsetY > 0 {
        guard moveStartRow(by: 1, maxStartRow: maxStartRow) else {
          viewport.visualOffsetY = 0
          break
        }
        viewport.visualOffsetY -= cellHeight
        rowDelta += 1
      } else {
        guard moveStartRow(by: -1, maxStartRow: maxStartRow) else {
          viewport.visualOffsetY = 0
          break
        }
        viewport.visualOffsetY += cellHeight
        rowDelta -= 1
      }
    }
    return rowDelta == 0 && viewport.visualOffsetY == 0 ? .ignored : .consumed(rowDelta: rowDelta)
  }

  public mutating func reset() {
    viewport = TerminalViewport()
  }

  public mutating func resetStartRowKeepingVisualOffset() {
    viewport.startRow = 0
  }

  private func clamp(_ row: Int, maxStartRow: Int) -> Int {
    min(max(0, row), max(0, maxStartRow))
  }

  private func isAtEdge(for rowDelta: Int, maxStartRow: Int) -> Bool {
    (rowDelta < 0 && viewport.startRow == 0)
      || (rowDelta > 0 && viewport.startRow == max(0, maxStartRow))
  }

  @discardableResult
  private mutating func moveStartRow(by rowDelta: Int, maxStartRow: Int?) -> Bool {
    guard let maxStartRow else {
      viewport.startRow += rowDelta
      return true
    }
    let nextStartRow = clamp(viewport.startRow + rowDelta, maxStartRow: maxStartRow)
    guard nextStartRow != viewport.startRow else { return false }
    viewport.startRow = nextStartRow
    return true
  }
}

public struct CellDrawRun: Sendable {
  public var range: Range<Int>
  public var text: String
  public var style: GhosttyTerminalFrame.Cell

  public init(range: Range<Int>, text: String, style: GhosttyTerminalFrame.Cell) {
    self.range = range
    self.text = text
    self.style = style
  }
}

public enum CellRunBuilder {
  public static func runs(for cells: ArraySlice<GhosttyTerminalFrame.Cell>) -> [CellDrawRun] {
    runs(for: Array(cells))
  }

  public static func runs(for cells: [GhosttyTerminalFrame.Cell]) -> [CellDrawRun] {
    guard let first = cells.first else { return [] }
    var runs: [CellDrawRun] = []
    var start = 0
    var text = String(first.scalar)
    var style = first

    for index in cells.indices.dropFirst() {
      let cell = cells[index]
      if sameStyle(style, cell) {
        text.append(String(cell.scalar))
      } else {
        runs.append(CellDrawRun(range: start..<index, text: text, style: style))
        start = index
        text = String(cell.scalar)
        style = cell
      }
    }
    runs.append(CellDrawRun(range: start..<cells.count, text: text, style: style))
    return runs
  }

  private static func sameStyle(_ lhs: GhosttyTerminalFrame.Cell, _ rhs: GhosttyTerminalFrame.Cell) -> Bool {
    lhs.foreground == rhs.foreground
      && lhs.background == rhs.background
      && lhs.bold == rhs.bold
      && lhs.italic == rhs.italic
      && lhs.faint == rhs.faint
      && lhs.underline == rhs.underline
      && lhs.inverse == rhs.inverse
      && lhs.usesDefaultForeground == rhs.usesDefaultForeground
      && lhs.usesDefaultBackground == rhs.usesDefaultBackground
  }
}

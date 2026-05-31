import Foundation

public struct MetalCellInstanceRange: Equatable, Sendable {
  public let row: Int
  public let range: Range<Int>
}

public typealias MetalCellDirtyRange = CellGridDirtyRange

public enum MetalCellInstanceGridUpdate: Equatable, Sendable {
  case unchanged
  case fullRebuild
}

public struct MetalCellInstanceBuffer: Equatable, Sendable {
  public private(set) var rows: Int
  public private(set) var cols: Int

  public init(rows: Int, cols: Int) {
    self.rows = max(0, rows)
    self.cols = max(0, cols)
  }

  public func instanceRanges(forDirtyRows dirtyRows: Set<Int>) -> [MetalCellInstanceRange] {
    dirtyRows
      .filter { row in row >= 0 && row < rows && cols > 0 }
      .sorted()
      .map { row in
        let start = row * cols
        return MetalCellInstanceRange(row: row, range: start..<(start + cols))
      }
  }

  public func instanceRanges(forDirtyCellRanges dirtyCellRanges: [MetalCellDirtyRange]) -> [MetalCellInstanceRange] {
    dirtyCellRanges.compactMap { dirtyRange in
      guard dirtyRange.row >= 0, dirtyRange.row < rows, cols > 0 else {
        return nil
      }
      let lower = min(max(0, dirtyRange.cols.lowerBound), cols)
      let upper = min(max(lower, dirtyRange.cols.upperBound), cols)
      guard lower < upper else {
        return nil
      }
      let start = dirtyRange.row * cols + lower
      return MetalCellInstanceRange(row: dirtyRange.row, range: start..<(start + upper - lower))
    }
  }

  public func uploadedCellCount(for ranges: [MetalCellInstanceRange]) -> Int {
    ranges.reduce(0) { total, range in
      total + range.range.count
    }
  }

  public mutating func updateGridSize(rows: Int, cols: Int) -> MetalCellInstanceGridUpdate {
    let nextRows = max(0, rows)
    let nextCols = max(0, cols)
    guard self.rows != nextRows || self.cols != nextCols else {
      return .unchanged
    }
    self.rows = nextRows
    self.cols = nextCols
    return .fullRebuild
  }
}

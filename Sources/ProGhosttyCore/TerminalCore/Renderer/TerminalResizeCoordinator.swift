import Foundation

public enum TerminalResizeCommitDecision: Equatable, Sendable {
  case commit(TerminalGridSize)
  case deferUntilLiveResizeEnds
  case ignore
}

public struct TerminalResizeCommitCoordinator: Sendable {
  public private(set) var lastCommittedGridSize: TerminalGridSize?
  public private(set) var pendingGridSize: TerminalGridSize?

  public init() {}

  public mutating func update(
    gridSize: TerminalGridSize,
    isLiveResize: Bool,
    isResizeSensitiveScreen: Bool
  ) -> TerminalResizeCommitDecision {
    guard gridSize != lastCommittedGridSize else {
      if pendingGridSize == gridSize {
        pendingGridSize = nil
      }
      return .ignore
    }
    guard gridSize != pendingGridSize else {
      if isResizeSensitiveScreen && isLiveResize {
        return .deferUntilLiveResizeEnds
      }
      return gridSize == lastCommittedGridSize ? .ignore : .commit(gridSize)
    }

    if isResizeSensitiveScreen && isLiveResize {
      pendingGridSize = gridSize
      return .deferUntilLiveResizeEnds
    }

    pendingGridSize = gridSize
    return .commit(gridSize)
  }

  public mutating func finishLiveResize() -> TerminalResizeCommitDecision {
    guard let pendingGridSize, pendingGridSize != lastCommittedGridSize else {
      self.pendingGridSize = nil
      return .ignore
    }
    self.pendingGridSize = nil
    return .commit(pendingGridSize)
  }

  public mutating func markCommitted(_ gridSize: TerminalGridSize) {
    lastCommittedGridSize = gridSize
    if pendingGridSize == gridSize {
      pendingGridSize = nil
    }
  }
}

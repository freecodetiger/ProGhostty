import Testing

@testable import ProGhosttyCore

@Suite("Terminal resize coordinator")
struct TerminalResizeCoordinatorTests {
  @Test func normalScreenCommitsGridChangesDuringLiveResize() {
    var coordinator = TerminalResizeCommitCoordinator()
    let grid = TerminalGridSize(rows: 36, cols: 104)

    let decision = coordinator.update(
      gridSize: grid,
      isLiveResize: true,
      isResizeSensitiveScreen: false
    )

    #expect(decision == .commit(grid))
    #expect(coordinator.lastCommittedGridSize == nil)
    #expect(coordinator.pendingGridSize == grid)
  }

  @Test func alternateScreenDefersGridChangesDuringLiveResize() {
    var coordinator = TerminalResizeCommitCoordinator()
    let grid = TerminalGridSize(rows: 36, cols: 104)

    let decision = coordinator.update(
      gridSize: grid,
      isLiveResize: true,
      isResizeSensitiveScreen: true
    )

    #expect(decision == .deferUntilLiveResizeEnds)
    #expect(coordinator.lastCommittedGridSize == nil)
    #expect(coordinator.pendingGridSize == grid)
  }

  @Test func alternateScreenCommitsOnlyLatestPendingGridWhenLiveResizeEnds() {
    var coordinator = TerminalResizeCommitCoordinator()
    let first = TerminalGridSize(rows: 36, cols: 104)
    let second = TerminalGridSize(rows: 36, cols: 110)

    _ = coordinator.update(gridSize: first, isLiveResize: true, isResizeSensitiveScreen: true)
    _ = coordinator.update(gridSize: second, isLiveResize: true, isResizeSensitiveScreen: true)
    let decision = coordinator.finishLiveResize()

    #expect(decision == .commit(second))
    #expect(coordinator.lastCommittedGridSize == nil)
    #expect(coordinator.pendingGridSize == nil)
  }

  @Test func duplicateGridChangesAreIgnored() {
    var coordinator = TerminalResizeCommitCoordinator()
    let grid = TerminalGridSize(rows: 36, cols: 104)

    _ = coordinator.update(gridSize: grid, isLiveResize: false, isResizeSensitiveScreen: false)
    coordinator.markCommitted(grid)
    let decision = coordinator.update(gridSize: grid, isLiveResize: false, isResizeSensitiveScreen: false)

    #expect(decision == .ignore)
    #expect(coordinator.lastCommittedGridSize == grid)
  }

  @Test func markCommittedClearsMatchingPendingGrid() {
    var coordinator = TerminalResizeCommitCoordinator()
    let grid = TerminalGridSize(rows: 36, cols: 104)

    _ = coordinator.update(gridSize: grid, isLiveResize: false, isResizeSensitiveScreen: false)
    coordinator.markCommitted(grid)

    #expect(coordinator.lastCommittedGridSize == grid)
    #expect(coordinator.pendingGridSize == nil)
  }

  @Test func pendingAlternateScreenGridCommitsOnNextNonLiveResizeUpdate() {
    var coordinator = TerminalResizeCommitCoordinator()
    let grid = TerminalGridSize(rows: 36, cols: 104)

    _ = coordinator.update(gridSize: grid, isLiveResize: true, isResizeSensitiveScreen: true)
    let decision = coordinator.update(gridSize: grid, isLiveResize: false, isResizeSensitiveScreen: true)

    #expect(decision == .commit(grid))
  }
}

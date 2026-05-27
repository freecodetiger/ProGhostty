import Foundation
import Testing

@testable import ProGhosttyCore

@Suite("Terminal resize coordinator")
struct TerminalResizeCoordinatorTests {
  @MainActor @Test func resizeSchedulerKeepsLatestRequestDuringCoalescingWindow() async throws {
    let session = TerminalSessionID()
    var delivered: [ResizeRequest] = []
    let scheduler = TerminalResizeScheduler<ResizeRequest>(coalescingDelayNanoseconds: 8_000_000) { _, request in
      delivered.append(request)
    }

    scheduler.schedule(
      request: ResizeRequest(rows: 24, cols: 80),
      session: session
    )
    scheduler.schedule(
      request: ResizeRequest(rows: 30, cols: 100),
      session: session
    )

    let deadline = Date().addingTimeInterval(1)
    while Date() < deadline, delivered.isEmpty {
      try await Task.sleep(nanoseconds: 10_000_000)
    }

    #expect(delivered == [ResizeRequest(rows: 30, cols: 100)])
  }

  @Test func normalScreenDefersGridChangesDuringLiveResize() {
    var coordinator = TerminalResizeCommitCoordinator()
    let grid = TerminalGridSize(rows: 36, cols: 104)

    let decision = coordinator.update(
      gridSize: grid,
      isLiveResize: true,
      isResizeSensitiveScreen: false
    )

    #expect(decision == .deferUntilLiveResizeEnds)
    #expect(coordinator.lastCommittedGridSize == nil)
    #expect(coordinator.pendingGridSize == grid)
  }

  @Test func normalScreenCommitsOnlyLatestPendingGridWhenLiveResizeEnds() {
    var coordinator = TerminalResizeCommitCoordinator()
    let first = TerminalGridSize(rows: 36, cols: 104)
    let second = TerminalGridSize(rows: 38, cols: 110)

    _ = coordinator.update(gridSize: first, isLiveResize: true, isResizeSensitiveScreen: false)
    _ = coordinator.update(gridSize: second, isLiveResize: true, isResizeSensitiveScreen: false)
    let decision = coordinator.finishLiveResize()

    #expect(decision == .commit(second))
    #expect(coordinator.pendingGridSize == nil)
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

private struct ResizeRequest: Equatable, Sendable {
  var rows: Int
  var cols: Int
}

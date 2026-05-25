# Resize Coalescing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:test-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reduce terminal resize jank by avoiding repeated VT resize/snapshot work while a pane is being live-resized.

**Architecture:** Move resize policy into `TerminalResizeCommitCoordinator`, so live resize always stores only the latest grid size and commits once when live resize ends. Keep the existing short delayed commit for non-live layout churn, but make the delay a named policy value instead of an inline constant.

**Tech Stack:** Swift, Swift Testing, AppKit `NSViewController` layout callbacks, existing PTY/libghostty-vt rendering pipeline.

---

### Task 1: Resize Coordinator Policy

**Files:**
- Modify: `Sources/ProGhosttyCore/TerminalCore/Renderer/TerminalResizeCoordinator.swift`
- Modify tests: `Tests/ProGhosttyCoreTests/TerminalResizeCoordinatorTests.swift`

- [ ] **Step 1: Write failing tests**

Add tests showing that live resize always defers, regardless of screen sensitivity, and that only the latest live-resize grid is committed:

```swift
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
```

- [ ] **Step 2: Verify RED**

Run:

```bash
swift test --filter TerminalResizeCoordinatorTests
```

Expected: `normalScreenDefersGridChangesDuringLiveResize` fails because current behavior returns `.commit(grid)`.

- [ ] **Step 3: Implement minimal coordinator change**

In `TerminalResizeCommitCoordinator.update`, change the live-resize branch to defer for every live resize:

```swift
if isLiveResize {
  pendingGridSize = gridSize
  return .deferUntilLiveResizeEnds
}
```

Keep non-live behavior unchanged:

```swift
pendingGridSize = gridSize
return .commit(gridSize)
```

- [ ] **Step 4: Verify GREEN**

Run:

```bash
swift test --filter TerminalResizeCoordinatorTests
```

Expected: all coordinator tests pass after updating tests that previously expected normal screens to commit during live resize.

### Task 2: Pane Layout Debounce Constant

**Files:**
- Modify: `Sources/ProGhosttyApp/UI/TerminalCanvasView.swift`

- [ ] **Step 1: Write failing compile-oriented assertion by test impact**

No new public behavior test is needed here; Task 1 covers the behavior boundary. This task is a refactor of the existing inline `40ms` delayed non-live commit. Keep it minimal and verify with the app/core test suite.

- [ ] **Step 2: Implement named debounce value**

In `TerminalPaneViewController`, add:

```swift
private static let resizeCommitDebounce: DispatchTimeInterval = .milliseconds(80)
```

Replace:

```swift
DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(40), execute: workItem)
```

with:

```swift
DispatchQueue.main.asyncAfter(deadline: .now() + Self.resizeCommitDebounce, execute: workItem)
```

- [ ] **Step 3: Verify**

Run:

```bash
swift test --filter TerminalResizeCoordinatorTests
swift test --filter PTYLaunchTests
swift test --filter TerminalSurfaceTests
```

Expected: pass. `PTYLaunchTests` confirms resize rendering remains deferred and completes.

### Task 3: Final Verification

**Files:**
- No production edit expected.

- [ ] **Step 1: Run full suite**

Run:

```bash
swift test
```

Expected: pass.

- [ ] **Step 2: Manual sanity**

Run the app, open a Codex-like long-output terminal, resize a split pane, and confirm:

```text
Live drag does not visibly replay many intermediate terminal widths.
Final released size applies once.
The latest prompt remains visible when pinned to bottom.
```

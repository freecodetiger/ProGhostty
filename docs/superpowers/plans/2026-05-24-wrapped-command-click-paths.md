# Wrapped Command Click Paths Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let Cmd+click file path detection recover paths split across visual terminal rows.

**Architecture:** Extend `TerminalLinkDetector` only. Keep AppModel path resolution and Finder reveal unchanged. The detector will construct a likely soft-wrapped row group around the clicked/rendered row, run existing URL/path matching on the reconstructed logical text, and return per-row `TerminalLinkHit` segments that carry the full target.

**Tech Stack:** Swift 6.1, Swift Testing, existing `GhosttyTerminalFrame`.

---

### Task 1: Detect Wrapped File Paths

**Files:**
- Modify: `Sources/ProGhosttyCore/TerminalCore/Renderer/TerminalLinkDetector.swift`
- Modify: `Tests/ProGhosttyCoreTests/TerminalLinkDetectorTests.swift`

- [ ] **Step 1: Add failing detector tests**

Add tests for a file path split across two rendered rows, and for `:line:column` split onto the second row.

- [ ] **Step 2: Verify red**

Run:

```bash
swift test --filter TerminalLinkDetectorTests
```

Expected: the new wrapped-path tests fail because detection is still single-row.

- [ ] **Step 3: Implement wrapped row grouping**

In `TerminalLinkDetector`, add a row extraction helper, a soft-wrap grouping heuristic, and a mapper from logical regex range back to per-row ranges. A row joins downward only when the current row has no trailing space. Each emitted row segment keeps the full link target.

- [ ] **Step 4: Verify green**

Run:

```bash
swift test --filter TerminalLinkDetectorTests
swift test --filter "ptyGridCommandClickOpensFilePathTarget|ptyGridCommandClickOpensVisibleURL|ptyGridReportsLinkHoverHintWithoutOpeningURL"
swift test
swift build
```

Expected: all pass.

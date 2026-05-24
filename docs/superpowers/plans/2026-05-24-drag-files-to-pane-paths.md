# Drag Files To Pane Paths Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let users drag Finder files or folders onto a ProGhostty split pane and insert shell-safe absolute path arguments into that pane without pressing Enter.

**Architecture:** Put the shell argument formatter in `ProGhosttyCore` so it can be unit-tested. Keep drag/drop ownership in the pane host/controller layer because each pane view already knows its pane ID. Route successful drops through `AppModel` to `TerminalSessionManager.writePaste` so existing bracketed paste handling remains the single PTY write path.

**Tech Stack:** Swift 6.1, AppKit drag and drop (`NSDraggingDestination`, `NSPasteboard.PasteboardType.fileURL`), Swift Testing, existing ProGhostty pane/session abstractions.

---

## File Structure

- Create `Sources/ProGhosttyCore/TerminalCore/TerminalDraggedPathFormatter.swift`
  - Pure formatter for local file URLs and shell-safe single-quoted path arguments.
- Create `Tests/ProGhosttyCoreTests/TerminalDraggedPathFormatterTests.swift`
  - Unit tests for spaces, single quotes, multiple URLs, local-only filtering, and no trailing newline.
- Modify `Sources/ProGhosttyApp/UI/AppModel.swift`
  - Add `pasteDroppedPaths(_:intoPane:)` to resolve pane ID to session ID and call `writePaste`.
- Modify `Sources/ProGhosttyApp/UI/TerminalCanvasView.swift`
  - Thread a pane-targeted path paste callback through `TerminalTreeLayoutView`, `SplitContainerViewController`, and `TerminalPaneViewController`.
  - Register `TerminalPaneHostView` for file URL drops.
  - Add restrained drag hover highlighting on the pane under the mouse.

---

### Task 1: Add Test-Covered Path Formatting

**Files:**
- Create: `Sources/ProGhosttyCore/TerminalCore/TerminalDraggedPathFormatter.swift`
- Create: `Tests/ProGhosttyCoreTests/TerminalDraggedPathFormatterTests.swift`

- [ ] **Step 1: Write the failing formatter tests**

Create `Tests/ProGhosttyCoreTests/TerminalDraggedPathFormatterTests.swift`:

```swift
import Foundation
import Testing

@testable import ProGhosttyCore

@Suite("Terminal dragged path formatter")
struct TerminalDraggedPathFormatterTests {
  @Test func formatsSimpleAbsolutePathAsSingleQuotedArgument() {
    let urls = [URL(fileURLWithPath: "/Users/me/file.txt")]

    let text = TerminalDraggedPathFormatter.formattedText(for: urls)

    #expect(text == "'/Users/me/file.txt'")
  }

  @Test func preservesSpacesInsideSingleQuotedPath() {
    let urls = [URL(fileURLWithPath: "/Users/me/My Folder/a file.txt")]

    let text = TerminalDraggedPathFormatter.formattedText(for: urls)

    #expect(text == "'/Users/me/My Folder/a file.txt'")
  }

  @Test func escapesSingleQuotesUsingPosixShellSequence() {
    let urls = [URL(fileURLWithPath: "/Users/me/it's here/file.txt")]

    let text = TerminalDraggedPathFormatter.formattedText(for: urls)

    #expect(text == "'/Users/me/it'\\''s here/file.txt'")
  }

  @Test func joinsMultiplePathsWithSingleSpaceAndNoTrailingNewline() {
    let urls = [
      URL(fileURLWithPath: "/tmp/a file.txt"),
      URL(fileURLWithPath: "/tmp/folder b"),
    ]

    let text = TerminalDraggedPathFormatter.formattedText(for: urls)

    #expect(text == "'/tmp/a file.txt' '/tmp/folder b'")
    #expect(text?.hasSuffix("\n") == false)
    #expect(text?.hasSuffix("\r") == false)
  }

  @Test func returnsNilForEmptyURLList() {
    #expect(TerminalDraggedPathFormatter.formattedText(for: []) == nil)
  }

  @Test func ignoresNonFileURLs() {
    let urls = [
      URL(string: "https://example.com/file.txt")!,
      URL(fileURLWithPath: "/Users/me/local.txt"),
    ]

    let text = TerminalDraggedPathFormatter.formattedText(for: urls)

    #expect(text == "'/Users/me/local.txt'")
  }

  @Test func returnsNilWhenNoLocalFileURLsRemain() {
    let urls = [URL(string: "https://example.com/file.txt")!]

    let text = TerminalDraggedPathFormatter.formattedText(for: urls)

    #expect(text == nil)
  }
}
```

- [ ] **Step 2: Run the new tests and verify they fail**

Run:

```bash
swift test --filter TerminalDraggedPathFormatterTests
```

Expected: FAIL because `TerminalDraggedPathFormatter` is not defined.

- [ ] **Step 3: Add the formatter implementation**

Create `Sources/ProGhosttyCore/TerminalCore/TerminalDraggedPathFormatter.swift`:

```swift
import Foundation

public enum TerminalDraggedPathFormatter {
  public static func formattedText(for urls: [URL]) -> String? {
    let arguments = urls.compactMap { url -> String? in
      guard url.isFileURL else { return nil }
      return shellSingleQuotedArgument(url.path)
    }
    guard !arguments.isEmpty else { return nil }
    return arguments.joined(separator: " ")
  }

  public static func shellSingleQuotedArgument(_ path: String) -> String {
    "'\(path.replacingOccurrences(of: "'", with: "'\\''"))'"
  }
}
```

- [ ] **Step 4: Run formatter tests and verify they pass**

Run:

```bash
swift test --filter TerminalDraggedPathFormatterTests
```

Expected: PASS.

- [ ] **Step 5: Commit formatter work**

Run:

```bash
git add Sources/ProGhosttyCore/TerminalCore/TerminalDraggedPathFormatter.swift Tests/ProGhosttyCoreTests/TerminalDraggedPathFormatterTests.swift
git commit -m "Add dragged path formatter"
```

---

### Task 2: Add Pane-Targeted Paste Routing

**Files:**
- Modify: `Sources/ProGhosttyApp/UI/AppModel.swift`

- [ ] **Step 1: Add the pane-targeted paste method**

In `Sources/ProGhosttyApp/UI/AppModel.swift`, add this method near `sendCommand()` and `surfaceView(for:)`:

```swift
  func pasteDroppedPaths(_ text: String, intoPane paneID: UUID) {
    guard
      let activeWorkspaceID,
      let runtime = workspaceRuntimes.first(where: { $0.id == activeWorkspaceID }),
      let pane = PaneTreeReducer.findPane(in: runtime.layout.root, paneId: paneID)
    else {
      DebugLog.write("pasteDroppedPaths ignored: pane not found pane=\(paneID)")
      return
    }

    selectPane(paneID)
    sessionManager.writePaste(text, to: pane.sessionId)
  }
```

- [ ] **Step 2: Build to verify the method compiles**

Run:

```bash
swift build
```

Expected: PASS.

- [ ] **Step 3: Commit routing work**

Run:

```bash
git add Sources/ProGhosttyApp/UI/AppModel.swift
git commit -m "Route dropped paths to target pane"
```

---

### Task 3: Thread Drop Callback Through Pane Layout

**Files:**
- Modify: `Sources/ProGhosttyApp/UI/TerminalCanvasView.swift`

- [ ] **Step 1: Add the callback to `TerminalTreeLayoutView.updateNSViewController`**

In `TerminalTreeLayoutView.updateNSViewController`, add this argument to the `controller.update(...)` call after `onClose`:

```swift
      onPasteDroppedPaths: { paneID, text in model.pasteDroppedPaths(text, intoPane: paneID) },
```

- [ ] **Step 2: Add storage and update parameters to `SplitContainerViewController`**

In `SplitContainerViewController`, add this stored property near `onClose`:

```swift
  private var onPasteDroppedPaths: ((UUID, String) -> Void)?
```

Then add this parameter to `func update(...)` after `onClose`:

```swift
    onPasteDroppedPaths: @escaping (UUID, String) -> Void,
```

Inside that method, after `self.onClose = onClose`, assign:

```swift
    self.onPasteDroppedPaths = onPasteDroppedPaths
```

- [ ] **Step 3: Pass the callback when creating leaf controllers**

In `makeController(for:)`, update the leaf `controller.update(...)` call by adding this argument after `onClose`:

```swift
        onPasteDroppedPaths: { [weak self] paneID, text in self?.onPasteDroppedPaths?(paneID, text) },
```

- [ ] **Step 4: Copy the callback into nested split controllers**

In the `.split` case of `makeController(for:)`, after `controller.onClose = onClose`, add:

```swift
      controller.onPasteDroppedPaths = onPasteDroppedPaths
```

- [ ] **Step 5: Preserve the callback during structural sync**

In `updateLeaf(...)`, add this argument to `leaf.update(...)` after `onClose`:

```swift
      onPasteDroppedPaths: { [weak self] paneID, text in self?.onPasteDroppedPaths?(paneID, text) },
```

- [ ] **Step 6: Extend `TerminalPaneViewController.update` signature**

In `TerminalPaneViewController.update(...)`, add this parameter after `onClose`:

```swift
    onPasteDroppedPaths: @escaping (UUID, String) -> Void,
```

For now, inside the method body after `self.onResize = onResize`, add:

```swift
    _ = onPasteDroppedPaths
```

This keeps the compiler happy until Task 4 consumes the callback.

- [ ] **Step 7: Build and verify callback threading compiles**

Run:

```bash
swift build
```

Expected: PASS.

- [ ] **Step 8: Commit callback threading**

Run:

```bash
git add Sources/ProGhosttyApp/UI/TerminalCanvasView.swift
git commit -m "Thread dropped path callback through panes"
```

---

### Task 4: Implement Pane Drag Hover And Drop Handling

**Files:**
- Modify: `Sources/ProGhosttyApp/UI/TerminalCanvasView.swift`

- [ ] **Step 1: Add drag state and callback storage to `TerminalPaneViewController`**

In `TerminalPaneViewController`, add these properties near the existing callbacks:

```swift
  private var onPasteDroppedPaths: ((UUID, String) -> Void)?
  private var currentPalette = TerminalSurfacePalette.dark
  private var isDropTargeted = false
```

- [ ] **Step 2: Store callback and configure host drag closures**

Replace the temporary `_ = onPasteDroppedPaths` line added in Task 3 with:

```swift
    self.onPasteDroppedPaths = onPasteDroppedPaths
    currentPalette = palette
    configureDropHandling()
```

- [ ] **Step 3: Add drop configuration and handling methods**

Add these methods inside `TerminalPaneViewController`, near `setContentView(_:)`:

```swift
  private func configureDropHandling() {
    guard let hostView = view as? TerminalPaneHostView else { return }
    hostView.onDraggingFilesChanged = { [weak self] isTargeted in
      self?.setDropTargeted(isTargeted)
    }
    hostView.onFileURLsDropped = { [weak self] urls in
      self?.handleDroppedFileURLs(urls)
    }
  }

  private func handleDroppedFileURLs(_ urls: [URL]) -> Bool {
    guard let text = TerminalDraggedPathFormatter.formattedText(for: urls) else {
      DebugLog.write("dropped paths ignored pane=\(pane.paneId): no local file URLs")
      setDropTargeted(false)
      return false
    }

    onSelect?(pane.paneId)
    onPasteDroppedPaths?(pane.paneId, text)
    setDropTargeted(false)
    return true
  }

  private func setDropTargeted(_ isTargeted: Bool) {
    isDropTargeted = isTargeted
    updateDropTargetAppearance()
  }

  private func updateDropTargetAppearance() {
    guard isDropTargeted else {
      view.layer?.borderWidth = 0
      view.layer?.borderColor = nil
      return
    }

    view.layer?.borderWidth = 1
    view.layer?.borderColor = currentPalette.cursorBackground.withAlphaComponent(0.55).cgColor
  }
```

- [ ] **Step 4: Preserve hover border during normal appearance updates**

At the end of `applyAppearance(isSelected:palette:dimsWhenInactive:)`, after clearing `borderWidth` and `borderColor`, add:

```swift
    currentPalette = palette
    updateDropTargetAppearance()
```

- [ ] **Step 5: Clear hover state when the pane is detached**

Add this method to `TerminalPaneViewController`:

```swift
  override func viewWillDisappear() {
    super.viewWillDisappear()
    setDropTargeted(false)
  }
```

- [ ] **Step 6: Implement `TerminalPaneHostView` as an `NSDraggingDestination`**

Replace `TerminalPaneHostView` with this implementation:

```swift
private final class TerminalPaneHostView: NSView {
  var onLiveResizeEnded: (() -> Void)?
  var onDraggingFilesChanged: ((Bool) -> Void)?
  var onFileURLsDropped: (([URL]) -> Bool)?
  private(set) var isLiveResizeActive = false

  override var acceptsFirstResponder: Bool { true }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    registerForDraggedTypes([.fileURL])
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    registerForDraggedTypes([.fileURL])
  }

  override func mouseDown(with event: NSEvent) {
    nextResponder?.mouseDown(with: event)
  }

  override func viewWillStartLiveResize() {
    super.viewWillStartLiveResize()
    isLiveResizeActive = true
  }

  override func viewDidEndLiveResize() {
    super.viewDidEndLiveResize()
    isLiveResizeActive = false
    onLiveResizeEnded?()
  }

  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    guard hasFileURLs(sender.draggingPasteboard) else {
      onDraggingFilesChanged?(false)
      return []
    }
    onDraggingFilesChanged?(true)
    return .copy
  }

  override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
    guard hasFileURLs(sender.draggingPasteboard) else {
      onDraggingFilesChanged?(false)
      return []
    }
    onDraggingFilesChanged?(true)
    return .copy
  }

  override func draggingExited(_ sender: NSDraggingInfo?) {
    onDraggingFilesChanged?(false)
  }

  override func draggingEnded(_ sender: NSDraggingInfo) {
    onDraggingFilesChanged?(false)
  }

  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    let urls = fileURLs(from: sender.draggingPasteboard)
    let handled = onFileURLsDropped?(urls) ?? false
    onDraggingFilesChanged?(false)
    return handled
  }

  private func hasFileURLs(_ pasteboard: NSPasteboard) -> Bool {
    !fileURLs(from: pasteboard).isEmpty
  }

  private func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
    guard
      let items = pasteboard.readObjects(
        forClasses: [NSURL.self],
        options: [.urlReadingFileURLsOnly: true]
      ) as? [URL]
    else {
      return []
    }
    return items
  }
}
```

- [ ] **Step 7: Build and verify drag code compiles**

Run:

```bash
swift build
```

Expected: PASS.

- [ ] **Step 8: Commit drag handling**

Run:

```bash
git add Sources/ProGhosttyApp/UI/TerminalCanvasView.swift
git commit -m "Handle file drops on terminal panes"
```

---

### Task 5: Verify End-To-End Behavior

**Files:**
- Verify: `Sources/ProGhosttyCore/TerminalCore/TerminalDraggedPathFormatter.swift`
- Verify: `Sources/ProGhosttyApp/UI/AppModel.swift`
- Verify: `Sources/ProGhosttyApp/UI/TerminalCanvasView.swift`

- [ ] **Step 1: Run focused formatter tests**

Run:

```bash
swift test --filter TerminalDraggedPathFormatterTests
```

Expected: PASS.

- [ ] **Step 2: Run the full package tests**

Run:

```bash
swift test
```

Expected: PASS.

- [ ] **Step 3: Build the app executable**

Run:

```bash
swift build
```

Expected: PASS.

- [ ] **Step 4: Manually verify real Finder drag behavior**

Run the app:

```bash
swift run ProGhostty
```

Manual checks:

- Split the terminal into at least two panes.
- Drag one Finder file over the left pane and confirm only the left pane shows the subtle border.
- Drag the same file over the right pane and confirm only the right pane shows the subtle border.
- Drop on an unfocused pane and confirm that pane becomes focused.
- Confirm the inserted text is single-quoted, absolute, visible in the target pane, and has no automatic Enter.
- Drag multiple files or folders and confirm they insert as one space-separated line.
- Drag a path containing a single quote and confirm it inserts with the `'\''` shell escape sequence.

- [ ] **Step 5: Final commit if verification required small fixes**

If Tasks 1-4 commits were amended during verification, commit only the verified implementation files:

```bash
git add Sources/ProGhosttyCore/TerminalCore/TerminalDraggedPathFormatter.swift Tests/ProGhosttyCoreTests/TerminalDraggedPathFormatterTests.swift Sources/ProGhosttyApp/UI/AppModel.swift Sources/ProGhosttyApp/UI/TerminalCanvasView.swift
git commit -m "Add drag and drop path insertion"
```

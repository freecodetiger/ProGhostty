# IME State Machine Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rebuild terminal IME handling around one internal state machine so composition, cursor visibility, marked text placement, and presentation sync all come from the same snapshot.

**Architecture:** Add a small input-method probe, a pure state machine, and a resolved presentation snapshot type. `PTYGridView` becomes the single bridge between AppKit/NSTextInputClient events and the state machine, while renderers only consume the resolved snapshot and never recompute IME anchor rules themselves.

**Tech Stack:** Swift 6, AppKit, XCTest, existing Ghostty VT renderer stack.

---

### Task 1: Build the core IME state machine

**Files:**
- Create: `Sources/ProGhosttyCore/TerminalCore/TerminalInputMethodState.swift`
- Create: `Sources/ProGhosttyCore/TerminalCore/TerminalInputStateMachine.swift`
- Create: `Tests/ProGhosttyCoreTests/TerminalInputStateMachineTests.swift`

**What this task owns:**
- the Carbon-backed "is current input source an IME/composition method?" probe
- a pure state machine that tracks composition phase, anchor rects, cursor suppression, and resolved marked-text presentation
- unit tests that prove the state machine keeps a stable anchor across transient renders and clears suppression on exit

- [ ] **Step 1: Write the failing tests**

Add tests that describe the exact state transitions we need before implementation:

```swift
private func cursor(_ row: Int, _ col: Int) -> NSRect {
  PTYGridView.textGlyphRect(
    row: row,
    col: col,
    cellSize: CGSize(width: 8, height: 16),
    inset: CGSize(width: 14, height: 12)
  )
}

@Test func compositionStartsFromStableCursor() {
  let machine = TerminalInputStateMachine()
  machine.ingestRenderSnapshot(.init(generation: 1, cursorRect: cursor(2, 6), isFocused: true, hasMarkedText: false))

  let snapshot = machine.handle(.setMarkedText("nihao", selectedRange: .init(location: 5, length: 0)))

  #expect(snapshot.compositionAnchorRect == cursor(2, 6))
  #expect(snapshot.cursorSuppressed)
}

@Test func transientHomeCursorDoesNotMoveActiveAnchor() {
  let machine = TerminalInputStateMachine()
  machine.ingestRenderSnapshot(.init(generation: 1, cursorRect: cursor(2, 6), isFocused: true, hasMarkedText: false))
  machine.handle(.keyDown(isCompositionMethod: true))
  machine.ingestRenderSnapshot(.init(generation: 2, cursorRect: cursor(0, 0), isFocused: true, hasMarkedText: false))

  let snapshot = machine.handle(.setMarkedText("nihao", selectedRange: .init(location: 5, length: 0)))

  #expect(snapshot.compositionAnchorRect == cursor(2, 6))
}

@Test func unmarkClearsSuppression() {
  let machine = TerminalInputStateMachine()
  machine.handle(.setMarkedText("ni", selectedRange: .init(location: 2, length: 0)))

  let snapshot = machine.handle(.unmarkText)

  #expect(snapshot.cursorSuppressed == false)
  #expect(snapshot.markedText == nil)
}
```

Run:

```bash
swift test --filter TerminalInputStateMachineTests -q
```

Expected: fail until the state machine exists.

- [ ] **Step 2: Implement the smallest state machine that passes**

Implement the new types and keep the API narrow:

```swift
public struct TerminalInputRenderSnapshot: Equatable {
  public var generation: Int
  public var cursorRect: NSRect?
  public var isFocused: Bool
  public var hasMarkedText: Bool
}

public enum TerminalInputEvent {
  case keyDown(isCompositionMethod: Bool)
  case setMarkedText(String, selectedRange: NSRange)
  case insertText(String)
  case unmarkText
  case render(TerminalInputRenderSnapshot)
  case focusChanged(Bool)
}

public struct TerminalInputPresentationSnapshot: Equatable {
  public var cursorRect: NSRect?
  public var markedTextOverlay: GridMarkedTextOverlay?
  public var markedTextString: String?
  public var cursorSuppressed: Bool
}
```

Keep the state machine pure and deterministic. It should own:
- active composition phase
- anchor rect selection
- last stable cursor rect
- last committed cursor rect
- whether cursor suppression is active

Run:

```bash
swift test --filter TerminalInputStateMachineTests -q
```

Expected: pass.

- [ ] **Step 3: Commit**

Commit just this foundation before moving on:

```bash
git add Sources/ProGhosttyCore/TerminalCore/TerminalInputMethodState.swift \
        Sources/ProGhosttyCore/TerminalCore/TerminalInputStateMachine.swift \
        Tests/ProGhosttyCoreTests/TerminalInputStateMachineTests.swift
git commit -m "feat: add terminal ime state machine"
```

### Task 2: Route PTYGridView and NSTextInputClient through the state machine

**Files:**
- Modify: `Sources/ProGhosttyCore/TerminalCore/PTY/PTYTerminalEngine.swift`
- Modify: `Tests/ProGhosttyCoreTests/TerminalSurfaceTests.swift`

**What this task owns:**
- `keyDown`, `setMarkedText`, `insertText`, `unmarkText`, `firstRect`, and `characterIndex` all resolving from one snapshot
- cursor suppression recovery after IME exit
- keeping English typing unaffected after a composition session
- preserving the current public `NSTextInputClient` behavior

- [ ] **Step 1: Write the failing integration tests**

Add tests for the visible regressions we care about first:

```swift
private func keyEvent(_ characters: String, keyCode: UInt16 = 45) -> NSEvent {
  NSEvent.keyEvent(
    with: .keyDown,
    location: .zero,
    modifierFlags: [],
    timestamp: 0,
    windowNumber: 0,
    context: nil,
    characters: characters,
    charactersIgnoringModifiers: characters,
    isARepeat: false,
    keyCode: keyCode
  )!
}

@Test func pinyinCompositionKeepsAnchorStableAcrossTransientRender() {
  let gridView = PTYGridView()
  gridView.render(initialFrame, isFocused: true)
  gridView.presentationSynchronizationHandler = { gridView.render(transientFrame, isFocused: true) }

  gridView.setMarkedText("nihao", selectedRange: .init(location: 5, length: 0), replacementRange: .init(location: NSNotFound, length: 0))

  #expect(gridView.currentMarkedTextOverlay?.col == 6)
  #expect(gridView.cursorCellRect == nil)
}

@Test func englishTypingRecoversCursorAfterImeExit() {
  let gridView = PTYGridView()
  gridView.setMarkedText("ni", selectedRange: .init(location: 2, length: 0), replacementRange: .init(location: NSNotFound, length: 0))
  gridView.unmarkText()
  gridView.keyDown(with: englishKeyEvent)

  #expect(gridView.cursorCellRect != nil)
  #expect(gridView.isIMECompositionCursorSuppressed == false)
}
```

Run:

```bash
swift test --filter TerminalSurfaceTests -q
```

Expected: the new regression tests fail until the bridge is rewritten.

- [ ] **Step 2: Move the bridge logic into explicit state transitions**

Refactor the PTY view so it:
- ingests render snapshots before answering IME queries
- stores the resolved presentation snapshot in one place
- never recomputes anchor placement from ad hoc heuristics in multiple methods
- resolves `cursorCellRect`, `currentMarkedTextOverlay`, `currentMarkedTextString`, `firstRect`, and `characterIndex` from the same state

The implementation should replace the current scattered state with a small bridge around:

```swift
private var imeStateMachine = TerminalInputStateMachine()
private var currentInputPresentation: TerminalInputPresentationSnapshot?
```

Update the event flow in this order:
1. capture / update the render snapshot
2. synchronize presentation if needed
3. feed the event to the state machine
4. expose the returned snapshot to AppKit and the renderers

Run:

```bash
swift test --filter TerminalSurfaceTests/ptyGridMarkedText -q
swift test --filter TerminalSurfaceTests/ptyGridMarkedTextUsesVisibleCursorBeforePresentationFlushDuringCompositionStart -q
```

Expected: pass.

- [ ] **Step 3: Commit**

```bash
git add Sources/ProGhosttyCore/TerminalCore/PTY/PTYTerminalEngine.swift \
        Tests/ProGhosttyCoreTests/TerminalSurfaceTests.swift
git commit -m "feat: route pty ime handling through state machine"
```

### Task 3: Make renderers consume one resolved IME snapshot per frame

**Files:**
- Modify: `Sources/ProGhosttyCore/TerminalCore/Renderer/GhosttyVTCellGridRendererBackend.swift`
- Modify: `Sources/ProGhosttyCore/TerminalCore/Renderer/MetalDirectRenderEngine.swift`
- Modify: `Sources/ProGhosttyCore/TerminalCore/Renderer/MetalOverlayBuffer.swift`
- Modify: `Tests/ProGhosttyCoreTests/TerminalRendererBackendTests.swift`

**What this task owns:**
- cursor and marked-text rendering consuming the same snapshot
- no renderer-side re-derivation of IME anchor rules
- keeping Metal and AppKit backends visually aligned during composition

- [ ] **Step 1: Write the failing renderer tests**

Add or adjust tests so the renderer sees one coherent snapshot for cursor + overlay:

```swift
@Test func backendUsesSameImeSnapshotForCursorAndMarkedText() {
  let backend = GhosttyVTCellGridRendererBackend()
  backend.gridView.render(frame, isFocused: true)
  backend.gridView.setMarkedText("zhong", selectedRange: .init(location: 5, length: 0), replacementRange: .init(location: NSNotFound, length: 0))

  backend.flushPendingFrame()

  #expect(backend.gridView.currentMarkedTextOverlay?.rect?.origin == backend.gridView.cursorCellRect?.origin)
}
```

Run:

```bash
swift test --filter TerminalRendererBackendTests -q
```

- [ ] **Step 2: Pass the resolved snapshot through renderer entry points**

Have the backend capture the `TerminalInputPresentationSnapshot` once per frame and pass that through to the AppKit and Metal overlay builders instead of asking the view to recompute the same values repeatedly.

Run:

```bash
swift test --filter TerminalRendererBackendTests -q
swift test --filter TerminalSurfaceTests -q
```

Expected: pass.

- [ ] **Step 3: Commit**

```bash
git add Sources/ProGhosttyCore/TerminalCore/Renderer/GhosttyVTCellGridRendererBackend.swift \
        Sources/ProGhosttyCore/TerminalCore/Renderer/MetalDirectRenderEngine.swift \
        Sources/ProGhosttyCore/TerminalCore/Renderer/MetalOverlayBuffer.swift \
        Tests/ProGhosttyCoreTests/TerminalRendererBackendTests.swift
git commit -m "feat: render ime from resolved snapshot"
```

### Task 4: Clean up heuristics and verify the full IME matrix

**Files:**
- Modify: `Sources/ProGhosttyCore/TerminalCore/PTY/PTYTerminalEngine.swift`
- Modify: `Tests/ProGhosttyCoreTests/TerminalSurfaceTests.swift`

**What this task owns:**
- removing any dead cursor-inference helpers left over after the state machine lands
- confirming the cursor recovers after IME exit
- confirming English typing still behaves normally after composition
- confirming system Pinyin continuous input and backspace work in a plain terminal

- [ ] **Step 1: Remove dead heuristic code**

Delete any now-unused IME helper fields or methods that only existed to compensate for stale render timing. Keep the implementation small enough that the active state machine is obviously the only source of truth.

Run:

```bash
swift test --filter TerminalSurfaceTests -q
```

- [ ] **Step 2: Run the full focused regression matrix**

Run:

```bash
swift test --filter TerminalInputStateMachineTests -q
swift test --filter TerminalSurfaceTests -q
swift test --filter TerminalRendererBackendTests -q
```

Expected: all pass.

- [ ] **Step 3: Manual smoke test**

Launch the rebuilt app and verify manually in a plain terminal:

```bash
swift run ProGhostty
```

Manual checks:
- type system Pinyin continuously
- backspace inside marked text
- commit IME text
- type English immediately after exiting IME
- confirm the cursor comes back and does not drift

- [ ] **Step 4: Commit**

```bash
git add Sources/ProGhosttyCore/TerminalCore/PTY/PTYTerminalEngine.swift \
        Tests/ProGhosttyCoreTests/TerminalSurfaceTests.swift
git commit -m "refactor: finalize ime state machine cleanup"
```

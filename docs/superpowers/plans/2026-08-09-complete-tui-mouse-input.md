# Complete TUI Mouse Input - Implementation Plan

> Branch baseline: `fix/tui-scroll-input-plan`
>
> Prerequisite commit: `048d167 fix(terminal): forward TUI wheel input`
>
> Scope: complete terminal mouse ownership after the vertical wheel fix.

## 1. Objective

When a terminal application enables mouse reporting, ProGhostty must forward
the mouse interactions that the active VT protocol accepts instead of running
its local selection and click-to-position behavior.

The completed path must cover:

- left, middle, and right button press/release;
- button drag and any-motion reporting for modes 1002/1003;
- vertical and horizontal wheel buttons 4-7;
- X10, UTF-8, SGR, URxvt, and SGR-Pixels output formats;
- alternate-screen mode 1007 cursor-key fallback;
- explicit local overrides for selection and semantic links;
- correct Retina coordinates, padding, and edge clamping;
- deterministic ownership during VT mode transitions.

This plan does not change the normal-screen Pattern-2 scrollback renderer or
implement configurable mouse acceleration.

## 2. Behavioral Contract

### 2.1 Ownership priority

Apply the following priority for each input event:

1. `Command` plus primary click keeps ProGhostty semantic-link handling.
2. `Shift` plus primary-button interaction keeps local text selection.
3. Active terminal mouse reporting receives supported mouse events.
4. Alternate screen plus mode 1007 receives vertical wheel as cursor keys.
5. Remaining vertical wheel input controls local scrollback.
6. Other uncaptured mouse events use existing local behavior.

The first implementation deliberately treats Shift as the local selection
override. Ghostty's configurable `mouse-shift-capture` and XTSHIFTESCAPE
support should be a separate settings task because libghostty-vt does not
currently expose the resolved capture policy through the public terminal API.

### 2.2 Selection rules

- Clear local selection before forwarding a press, wheel event, or alternate
  scroll event to the child application.
- Do not begin or extend local selection while the child owns the event.
- A Shift-local gesture may create or extend selection normally.
- If reporting is enabled between press and release, do not synthesize a
  release for a press that was handled locally.
- If reporting is disabled between a forwarded press and release, forward the
  matching release using the capture decision recorded at press time.

### 2.3 Coordinate rules

- `PTYGridView` is flipped, so its view coordinates already use a top-left
  origin compatible with Ghostty renderer coordinates.
- Position, screen size, cell size, and padding must all use backing pixels.
- SGR-Pixels must preserve pixel position after backing-scale conversion.
- Cell protocols must clamp through the Ghostty mouse encoder.
- Events outside the view bounds must not produce invalid unsigned geometry.

## 3. Architecture

### 3.1 General mouse event model

Replace the wheel-specific bridge event with a general event:

```swift
public enum TerminalMouseAction: Sendable, Equatable {
  case press
  case release
  case motion
}

public enum TerminalMouseButton: Sendable, Equatable {
  case left
  case middle
  case right
  case wheelUp
  case wheelDown
  case wheelLeft
  case wheelRight
}

public struct TerminalMouseInputEvent: Sendable, Equatable {
  public var action: TerminalMouseAction
  public var button: TerminalMouseButton?
  public var shift: Bool
  public var control: Bool
  public var alt: Bool
  public var x: Float
  public var y: Float
  public var anyButtonPressed: Bool
}
```

The C shim gets matching enums and a single
`proghostty_vt_encode_mouse_input` entry point. Remove the wheel-only API once
all callers and tests are migrated.

### 3.2 View-owned gesture state

`PTYGridView` owns AppKit gesture state:

- buttons currently physically pressed;
- buttons whose press was forwarded to the terminal;
- whether the active primary-button gesture is a local Shift selection;
- pending coalesced motion event;
- the current TUI scroll quantizer remainders for X and Y.

This state must reset when the view detaches, the terminal session changes, or
the live renderer is replaced. VT protocol state remains owned by
`GhosttyVTBridge`.

### 3.3 Motion delivery

Do not write every raw `mouseMoved` callback directly to the PTY. Store the
latest captured motion event and flush at most once per main-run-loop turn.
This preserves SGR-Pixels positions while bounding writes from high-frequency
trackpads.

The Ghostty encoder remains responsible for filtering motion according to
1000/1002/1003 and for choosing the output protocol. No protocol-specific
filtering belongs in Swift.

### 3.4 Failure policy

Keep the last successfully resolved `TerminalScrollOwnership` per grid view.
On a bridge query failure:

- use the last successful value for the current attached session;
- otherwise use the frame-based safe fallback;
- log the error with rate limiting;
- never silently switch a captured button gesture from terminal to local.

## 4. Implementation Tasks

### Task 1: Generalize the C mouse encoder boundary

Files:

- `Sources/ProGhosttyGhosttyVT/include/ProGhosttyGhosttyVT.h`
- `Sources/ProGhosttyGhosttyVT/ProGhosttyGhosttyVT.c`
- `Sources/ProGhosttyCore/TerminalCore/LibGhostty/GhosttyVTBridge.swift`
- `Tests/ProGhosttyCoreTests/GhosttyVTBridgeTests.swift`

Steps:

1. Add C enums for action and button with explicit raw values.
2. Add nullable-button support for motion events.
3. Pass `any_button_pressed` to
   `GHOSTTY_MOUSE_ENCODER_OPT_ANY_BUTTON_PRESSED`.
4. Map all seven supported buttons to Ghostty button constants.
5. Continue refreshing terminal protocol options before encoding.
6. Preserve the existing two-pass allocation and byte ownership contract.
7. Remove `ProGhosttyVTMouseEvent.wheel_up` after Swift migration.

Tests:

- SGR press and release for left/middle/right.
- 1002 drag motion with a pressed button.
- 1003 motion without a pressed button.
- 1000 filters motion but accepts button events.
- X10 filters release, motion, and wheel.
- wheel buttons 4/5/6/7.
- modifier bit combinations.

Verification:

```bash
swift test --filter 'Ghostty VT bridge'
```

### Task 2: Add capture-policy and gesture-state tests

Files:

- `Sources/ProGhosttyCore/TerminalCore/PTY/PTYTerminalEngine.swift`
- `Tests/ProGhosttyCoreTests/TerminalSurfaceTests.swift`

Write failing tests before changing AppKit handlers:

1. Mouse reporting captures an unmodified left press/release.
2. Captured events do not create a local selection.
3. Shift-left drag stays local and writes no PTY bytes.
4. Command-click link handling stays local.
5. A forwarded press still receives its release after reporting is disabled.
6. A local press does not produce a terminal release if reporting is enabled
   midway through the gesture.
7. Right and middle buttons map to the correct terminal buttons.
8. Forwarding clears an existing local selection.

Expose narrow test hooks only where constructing `NSEvent` cannot observe the
gesture state through existing public behavior.

### Task 3: Route button press and release

Files:

- `Sources/ProGhosttyCore/TerminalCore/PTY/PTYTerminalEngine.swift`
- `Sources/ProGhosttyCore/TerminalCore/PTY/PTYTerminalSurfaceRegistry.swift`

Steps:

1. Add `terminalMouseInputEncodeHandler` to `PTYGridView`.
2. Add one helper that converts AppKit coordinates, modifiers, and geometry.
3. Decide capture before local link/selection handling.
4. Override `rightMouseDown`, `rightMouseUp`, `otherMouseDown`, and
   `otherMouseUp` in addition to primary-button handlers.
5. Record capture at press time and use that decision for release.
6. Clear selection and pending local-link/click-to-position state when a press
   is forwarded.
7. Send encoded bytes through the existing session `inputHandler`.

Do not duplicate PTY writing or terminal-mode parsing in the view.

Verification:

```bash
swift test --filter 'Terminal surface'
```

### Task 4: Route captured motion

Files:

- `Sources/ProGhosttyCore/TerminalCore/PTY/PTYTerminalEngine.swift`
- `Tests/ProGhosttyCoreTests/TerminalSurfaceTests.swift`

Steps:

1. Enable mouse-moved events for the terminal view's window while attached,
   preserving the window's previous setting when detached.
2. Route `mouseMoved`, `mouseDragged`, `rightMouseDragged`, and
   `otherMouseDragged` through the same capture policy.
3. Include the currently pressed logical button for drag motion.
4. Coalesce captured motion to one pending event per run-loop turn.
5. Cancel pending motion when ownership returns local or the view detaches.
6. Keep existing link-hover and selection-drag behavior for local gestures.

Tests:

- 1002 reports drag but not hover.
- 1003 reports hover and drag.
- 1000 reports neither motion type.
- local selection drag remains unchanged with no reporting.
- mode changes cancel pending uncaptured motion safely.

### Task 5: Add horizontal wheel and selection cleanup

Files:

- `Sources/ProGhosttyCore/TerminalCore/TerminalTUIScrollQuantizer.swift`
- `Sources/ProGhosttyCore/TerminalCore/PTY/PTYTerminalEngine.swift`
- `Tests/ProGhosttyCoreTests/TerminalTUIScrollQuantizerTests.swift`
- `Tests/ProGhosttyCoreTests/TerminalSurfaceTests.swift`

Steps:

1. Track independent X and Y precision remainders.
2. Quantize X using cell width and Y using cell height.
3. Encode horizontal positive/negative units as buttons 6/7.
4. Preserve vertical mode-1007 cursor-key behavior; mode 1007 does not invent
   horizontal cursor-key fallback.
5. Clear local selection when a nonzero TUI wheel unit is forwarded.
6. Reset both axes when ownership changes or the view detaches.

Tests must cover diagonal scrolling, opposite-direction cancellation, and
independent axis remainders.

### Task 6: Complete protocol and geometry matrix

Files:

- `Tests/ProGhosttyCoreTests/GhosttyVTBridgeTests.swift`
- `Tests/ProGhosttyCoreTests/TerminalSurfaceTests.swift`

Add table-driven coverage for:

| Tracking | Format | Expected coverage |
|---|---|---|
| X10 / mode 9 | X10 | press only; wheel and motion filtered |
| Normal / 1000 | X10 | press/release and wheel behavior |
| Button / 1002 | UTF-8 / 1005 | large cell coordinates |
| Any / 1003 | SGR / 1006 | hover motion and modifiers |
| Button / 1002 | URxvt / 1015 | protocol framing |
| Any / 1003 | SGR-Pixels / 1016 | backing-pixel coordinates |

Geometry cases:

- scale factors 1 and 2;
- top-left and bottom-right cells;
- pointer inside padding;
- pointer exactly on and outside each view edge;
- non-integral point cell dimensions after backing conversion.

### Task 7: Interoperability smoke matrix

Build the actual bundle, not only the SwiftPM executable:

```bash
./scripts/build-app-bundle.sh release
open -n .build/arm64-apple-macosx/release/ProGhostty.app
```

Manual matrix:

1. Vim and Neovim with `set mouse=a`: click, drag, vertical wheel, statusline.
2. `less`: vertical wheel with and without explicit mouse reporting.
3. tmux containing Vim: pane/statusline click and wheel.
4. htop or btop: button click and wheel.
5. fzf: wheel and click selection if supported by the installed version.
6. Primary shell: Shift selection, Command-click link, Pattern-2 scrollback.
7. Retina display: compare SGR-Pixels coordinates with requested position.

Record exact application versions and any configuration required to reproduce
failures.

## 5. Full Verification

Run after all tasks:

```bash
swift test
scripts/check-architecture.sh
./scripts/build-app-bundle.sh release
codesign --verify --deep --strict \
  .build/arm64-apple-macosx/release/ProGhostty.app
```

Acceptance criteria:

- all automated tests pass;
- no local selection begins for a terminal-captured gesture;
- Shift selection and Command-click remain available;
- no stuck pressed-button state after focus loss, detach, or mode change;
- mouse motion writes are bounded by the coalescing policy;
- primary-screen scrollback behavior is unchanged;
- Vim, tmux+Vim, less, and one dashboard TUI pass manual testing;
- the launched `.app` contains the newly built binary.

## 6. Suggested Commit Sequence

1. `refactor(vt): generalize terminal mouse encoding`
2. `feat(terminal): route captured mouse buttons`
3. `feat(terminal): report captured mouse motion`
4. `feat(terminal): support horizontal TUI wheel input`
5. `test(terminal): cover mouse protocols and TUI interoperability`

Each commit must keep `swift test` green. Do not include the pre-existing dirty
changes in `Vendor/ghostty`.

## 7. Deferred Work

Keep these outside this round unless a prerequisite API is added upstream:

- user-configurable mouse reporting enable/disable;
- configurable precision/discrete scroll multipliers;
- full Ghostty `mouse-shift-capture` and XTSHIFTESCAPE policy;
- extended buttons beyond left/middle/right and wheel 4-7;
- changing libghostty-vt public APIs in the vendored submodule.

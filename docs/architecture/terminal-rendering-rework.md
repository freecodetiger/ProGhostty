# Terminal Rendering Rework

## Goal

ProGhostty should treat `libghostty-vt` as the single source of terminal
semantics. The application should not identify individual TUI programs such as
vim, tmux, or Codex. It should render the terminal state that Ghostty produces.

The next rendering phase separates two presentation modes:

- Live screen: the current fixed-size terminal viewport, rendered from cell-grid
  state.
- Scrollback document: historical output, rendered as an AppKit text document
  for smooth pixel scrolling and selection.

This keeps the terminal model close to Ghostty while avoiding a large,
application-specific UI layer.

## Current Problem

The current live path can render `bridge.htmlText()` through
`GhosttyHTMLAttributedAdapter` and then display it in `NSTextView`. This works
well enough for shell prompts, styled scrollback, and zsh autosuggestions, but
it is not a complete terminal renderer.

Full-screen TUI programs expose the gap:

- Cursor shape is not bridged yet, so bar and underline cursors are flattened
  into the current UI representation.
- Background-colored blank cells can become broad attributed-text background
  runs.
- Alternate screen behavior is not represented as a first-class presentation
  boundary.
- Mouse reporting, application cursor keys, bracketed paste, and scrollback
  behavior need to be driven by terminal modes rather than UI guesses.

Continuing to expand the HTML adapter into a full TUI renderer would duplicate
terminal semantics that already belong to `libghostty-vt`.

## Architecture

```text
PTY bytes
  -> libghostty-vt
  -> TerminalSnapshot
      -> LiveScreenRenderer
      -> ScrollbackRenderer
  -> TerminalSurface
```

### PTY

PTY remains responsible only for connecting ProGhostty to the shell or child
process. It does not parse terminal semantics.

### libghostty-vt

`libghostty-vt` owns the terminal state:

- screen cells
- scrollback
- foreground/background/style
- cursor position, visibility, blink, and visual style
- alternate screen
- terminal input modes

### TerminalSnapshot

`TerminalSnapshot` is the stable Swift boundary between Ghostty state and UI.
It should be small, testable, and independent of AppKit.

Proposed shape:

```swift
struct TerminalSnapshot {
  var liveScreen: TerminalScreenFrame
  var scrollback: TerminalScrollbackDocument?
  var screenMode: TerminalScreenMode
  var cursor: TerminalCursorState
  var inputModes: TerminalInputModes
}

enum TerminalScreenMode {
  case main
  case alternate
}

enum TerminalCursorShape {
  case bar
  case block
  case underline
  case hollowBlock
}

struct TerminalCursorState {
  var visible: Bool
  var blinking: Bool
  var x: Int
  var y: Int
  var shape: TerminalCursorShape
}
```

The first implementation does not need every field. It should start with cursor
shape and live screen correctness, then expand as Ghostty state is bridged.

## Rendering Boundaries

### LiveScreenRenderer

The live renderer displays the active viewport as a fixed rows-by-cols grid.
This is the correct surface for:

- shell input at the bottom of the terminal
- vim
- tmux
- Codex
- top, htop, less, and similar TUI programs

It should render from cell state rather than HTML document flow. This preserves
cell backgrounds, cursor placement, cursor shape, and full-screen repaint
semantics.

### ScrollbackRenderer

The scrollback renderer displays historical output as a document. AppKit text
rendering remains useful here because it gives native pixel scrolling, inertial
trackpad behavior, text selection, and copy support.

The scrollback projection may continue to use Ghostty HTML as an intermediate
format, but it must remain a document projection. It should not become the live
TUI renderer.

## Viewport Policy

The UI should switch by viewport intent, not by process name.

- At the bottom: show live screen.
- User scrolls upward in main screen: show scrollback document.
- User returns to bottom: show live screen.
- Alternate screen: show live screen only for the first implementation.
- Mouse wheel in alternate screen should eventually follow terminal mouse mode:
  send input when the TUI owns mouse reporting, otherwise keep local behavior.

The UI must not mix live cell-grid rows and HTML document rows in the same
visual surface. This avoids alignment drift and mixed selection semantics.

## Compatibility Strategy

Do not add special cases for `vim`, `tmux`, or `codex`. Instead, implement the
protocol capabilities they share:

- cursor visual style
- cursor visibility and blink
- fixed cell-grid rendering
- alternate screen
- application cursor keys
- bracketed paste
- mouse reporting
- resize propagation to PTY and `libghostty-vt`
- wide and composed character handling
- selection policy based on terminal mode

This lets each TUI benefit from the same terminal-level improvements.

## Implementation Phases

### Phase 1: Live Screen Correctness

- Bridge `GHOSTTY_RENDER_STATE_DATA_CURSOR_VISUAL_STYLE`.
- Bridge cursor blink if available.
- Extend `GhosttyTerminalFrame` with cursor shape.
- Render live output from `frame()` first.
- Keep HTML attributed rendering for scrollback/document projection.
- Add tests for bar, block, underline, and hidden cursor states.

### Phase 2: Snapshot Boundary

- Introduce `TerminalSnapshot` and a snapshot provider around
  `GhosttyVTBridge`.
- Move render-path selection out of `PTYTerminalSurfaceRegistry`.
- Keep AppKit views as consumers of snapshot data.
- Add tests that prove UI logic does not branch on process name.

### Phase 3: Interaction Modes

- Bridge or infer terminal input modes from Ghostty state where available.
- Route mouse events to PTY when mouse reporting is active.
- Keep local text selection when terminal mouse reporting is inactive.
- Apply bracketed paste wrapping according to terminal mode.
- Keep resize propagation synchronized across view, PTY, and Ghostty.

### Phase 4: Performance

- Avoid rebuilding the entire live screen attributed string when only a few rows
  changed.
- Introduce shared font metrics and padding so live screen and scrollback
  projection align visually.
- Evaluate a custom `NSView` or CoreText renderer only if `NSTextView` cell-grid
  rendering becomes a measurable bottleneck.

## Non-Goals

- Do not detect specific applications such as vim, tmux, or Codex by name.
- Do not turn `GhosttyHTMLAttributedAdapter` into a full terminal renderer.
- Do not mix HTML rows and cell-grid rows in one scrollable surface.
- Do not reimplement VT parsing in Swift.

## Success Criteria

- Codex input cursor displays with the shape requested by terminal state.
- Full-screen TUI layouts do not produce unexpected full-width highlight bars
  from document-flow background rendering.
- Shell scrollback keeps smooth pixel scrolling.
- Alternate screen and scrollback behavior are visibly separated.
- Rendering choices are testable from terminal state, not process names.

# Terminal Core Positioning

This document locks the product direction for ProGhostty's terminal core.

## Product Intent

ProGhostty is a modern macOS terminal product built around Ghostty's terminal
core. "Like Ghostty" means behavior and terminal capability first: protocol
correctness, shell compatibility, fast rendering, low latency input, and clean
integration with the existing terminal ecosystem.

The UI can diverge from Ghostty. It should stay quiet, direct, and terminal
first, while product capabilities such as splits, workspaces, context, and
plugin management remain available without becoming visually dominant.

## Layer Responsibilities

```text
zsh / bash / fish / ssh / vim / shell plugins
        |
      PTY
        |
 raw terminal bytes
        |
libghostty-vt now, GhosttyKit/full Ghostty surface later
        |
terminal state, render state, cursor, style, damage
        |
ProGhostty surface adapter
        |
SwiftUI product shell: windows, splits, workspaces, settings, plugin UI
```

### PTY

The PTY layer owns process and shell connectivity.

- Start the user's real shell, so `.zshrc`, `.zprofile`, shell functions,
  completions, aliases, and prompt tooling continue to work.
- Preserve the user's environment unless ProGhostty intentionally injects a
  documented shell-integration hook.
- Forward input bytes to the shell and read output bytes back.
- Resize the pseudo-terminal and notify the child process with `SIGWINCH`.

The PTY layer does not parse terminal escape sequences and does not implement
plugins.

### libghostty / libghostty-vt / GhosttyKit

The Ghostty layer is the terminal engine. Its job is to handle the complex,
high-risk terminal behavior that ProGhostty should not reimplement:

- ANSI and VT escape sequence parsing.
- Cursor movement, clearing, wrapping, scroll regions, alternate screen, and
  terminal grid state.
- Text attributes such as color, bold, italic, underline, inverse, faint, and
  future style details.
- Render-state extraction, cursor visibility, and damage information when
  available.
- Future Ghostty behavior such as richer input protocols, selection,
  clipboard, IME, OSC handling, and graphics protocols.

Short term, the stable product path is `PTYTerminalEngine -> GhosttyVTBridge ->
libghostty-vt`. This gives ProGhostty a real interactive shell while keeping
the bridge narrow.

Long term, the full Ghostty macOS path should be studied and integrated through
an adapter around `GhosttyKit` and Ghostty's macOS `SurfaceView`. Product code
must not import Ghostty headers or Ghostty Swift types directly.

### Shell Integration Plugins

Plugins are shell-integration features, not UI-layer replacements for terminal
behavior.

The preferred plugin path is:

```text
ProGhostty injects shell integration
        |
shell plugin emits OSC / escape protocol / environment-aware output
        |
PTY carries the bytes
        |
Ghostty terminal engine interprets terminal bytes
        |
ProGhostty product layer consumes structured signals when needed
```

Autosuggestion, command context, working directory tracking, and similar
features should originate from shell integration wherever possible. The UI may
present plugin state, but it should not own the terminal semantics or duplicate
the shell ecosystem.

### Product UI

The UI owns product organization and presentation:

- Windows.
- Splits.
- Workspaces.
- Command palette and quiet management surfaces.
- Plugin discovery, enablement, and settings.
- History, command blocks, and workspace context.

The UI should stay terminal-first. Features should be discoverable through
keyboard-first flows, subtle titlebar affordances, palettes, and transient
sheets rather than permanent dashboards.

## Adapter Boundary

All Ghostty-specific calls belong behind a bridge owned by the terminal core.

Current boundary:

```text
TerminalEngine
  PTYTerminalEngine
    PTYLaunch
    GhosttyVTBridge
      ProGhosttyGhosttyVT C wrapper
        libghostty-vt
```

Future boundary:

```text
TerminalEngine
  GhosttySurfaceTerminalEngine
    GhosttyKitBridge
      GhosttyKit / Ghostty SurfaceView
```

Product views should depend on `TerminalEngine`, session IDs, workspace models,
and plugin models. They should not depend on `GhosttyVTBridge`, C headers,
Zig types, or GhosttyKit types.

Workspace split state is represented by a Codable split tree:

```text
TerminalTab -> PaneNode
PaneNode -> leaf(TerminalPane) | split(SplitPane)
SplitPane -> axis, ratio, first, second
```

Each `TerminalPane` stores only lightweight metadata and a `TerminalSessionID`;
the tree does not know whether that session is rendered by the current
`PTYTerminalEngine + libghostty-vt` path or a future `GhosttyKit` surface
backend.

## Performance Direction

The renderer must prioritize low-latency input and efficient redraws without
forcing the product layer to know about terminal internals.

Short-term rules:

- Use libghostty-vt render state instead of reparsing terminal bytes in Swift.
- Keep per-cell rendering behind a surface adapter.
- Avoid pushing plugin/UI state into the terminal render path.
- Keep `MockTerminalEngine` available for UI and data-layer development.

Long-term rules:

- Prefer Ghostty's native renderer and damage tracking when integrating
  GhosttyKit.
- Keep resource-heavy features opt-in or lazy, especially history indexing,
  workspace context capture, and plugin management.
- Let terminal sessions remain independently disposable so splits and
  workspaces do not create hidden global state.

## Near-Term Priorities

1. Make `PTY + libghostty-vt` stable and genuinely interactive.
2. Preserve cursor and text attributes from Ghostty render state.
3. Keep autosuggestion and other special behavior shell-integration based.
4. Add split and workspace management in the product layer without coupling it
   to the renderer.
5. Continue researching full `GhosttyKit` integration as a replaceable terminal
   backend, not as a rewrite of the whole app.

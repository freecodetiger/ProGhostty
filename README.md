# ProGhostty

ProGhostty is a macOS-native terminal experiment built around a narrow Ghostty terminal-core boundary. The project goal is not to replace the shell model with a custom UI model. The terminal remains a real PTY-backed shell, while product features such as splits, workspaces, shell integration, history, settings, and plugin management sit above the terminal core.

The current implementation is an MVP. It uses `PTYTerminalEngine` as the live engine, feeds PTY output into `libghostty-vt`, and renders through a temporary AppKit text surface. Full GhosttyKit / complete libghostty macOS surface integration is intentionally left behind an adapter boundary.

## Goals

- Keep the terminal session real: user shell, `.zshrc`, aliases, completions, prompt tooling, and shell plugins should continue to work.
- Use Ghostty's terminal core for the hard terminal-emulation work instead of reimplementing VT parsing in app UI code.
- Keep product features terminal-first and visually restrained.
- Make splits and workspaces own real terminal sessions, not fake panes over shared output.
- Treat shell integration and plugins as ecosystem hooks, not as hard-coded UI behavior.
- Keep Ghostty-specific calls isolated from the product layer.

## Non-Goals

- No AI mode.
- No agent-specific terminal protocol.
- No custom prompt parser based on `$`, `%`, `❯`, or similar prompt guesses.
- No UI-owned autosuggestion or command-line semantics.
- No direct product-layer dependency on Ghostty C, Zig, or GhosttyKit APIs.

## Architecture

```text
SwiftUI / AppKit product shell
  - windows
  - titlebar integration
  - split layout
  - workspace switcher
  - settings
  - plugin manager
        |
        v
Product state
  - WorkspaceRuntime
  - PaneNode / SplitPane / TerminalPane
  - CommandBlockIndexer
  - HistoryStore / WorkspaceStore
  - AppSettings
        |
        v
TerminalEngine protocol
        |
        v
PTYTerminalEngine
  - forkpty shell process
  - input routing
  - resize propagation
  - OSC side-channel parsing
  - GhosttyVTBridge
        |
        v
libghostty-vt
```

The core boundary is documented in:

- `docs/architecture/terminal-core-positioning.md`
- `docs/libghostty-vt.md`

## Runtime Terminal Path

The current runtime flow is:

```text
keyboard / mouse input
  -> PTY text surface
  -> TerminalSessionManager.writeInput
  -> PTY master fd
  -> user shell / program
  -> PTY output bytes
  -> GhosttyVTBridge / libghostty-vt
  -> render frame
  -> AppKit text surface
```

The OSC parser also observes PTY bytes without mutating them. Raw bytes still go to Ghostty's VT layer.

## Workspace And Pane Model

Workspace layout is represented as a serializable split tree:

```text
WorkspaceLayout
  -> PaneNode
     -> leaf(TerminalPane)
     -> split(SplitPane)
```

Important constraints:

- Each pane owns a distinct `TerminalSessionID`.
- Closing a pane closes only that pane's session.
- Deleting a running workspace closes every terminal session in that workspace.
- Workspaces are independent runtime containers.
- Non-active workspaces keep their sessions running while detached from the visible layout.
- Focus is tracked independently from layout.
- PTY resize is propagated through the pane/session boundary.

## Shell Integration And History

Command metadata is derived from shell integration signals, primarily OSC 133 and OSC 7.

The app keeps command history as side-channel metadata:

- terminal scrollback stays terminal-owned;
- command blocks are indexed separately;
- output previews are bounded;
- command start/finish/cwd state comes from structured events when available.

This avoids turning terminal output into a custom block renderer.

## Plugin Management

The plugin manager is designed for shell ecosystem integration:

- detect installed shell tools;
- generate install/uninstall plans;
- back up modified files before applying plans;
- write managed shell modules under `~/.your-terminal/shell/`;
- avoid dumping large generated blocks directly into `~/.zshrc`;
- use a guarded source block when `.zshrc` must be touched.

The terminal should continue to work if plugin detection or shell integration is unavailable.

## Settings

Settings are persisted through `AppSettings` and `SettingsStore`.

Current settings include:

- shell path;
- default working directory;
- light/dark theme and follow-system appearance;
- font family and size;
- history and command block options;
- shell enhancement controls;
- customizable global keyboard shortcuts.

Default terminal sessions resolve their working directory as:

```text
workspace root path
  -> configured default working directory
  -> current user's home directory
  -> process current directory fallback
```

## libghostty-vt

Ghostty is vendored as a submodule under `Vendor/ghostty`.

Initialize it with:

```bash
git submodule update --init --recursive
```

Build the VT library from inside `Vendor/ghostty`:

```bash
../../.tools/zig-aarch64-macos-0.15.2/zig build \
  --global-cache-dir ../../.zig-cache-global \
  -Demit-lib-vt=true \
  -Demit-xcframework=true
```

Ghostty currently requires Zig `0.15.2`.

With Command Line Tools only, the build should produce:

```text
Vendor/ghostty/zig-out/lib/libghostty-vt.a
Vendor/ghostty/zig-out/lib/libghostty-vt.0.1.0.dylib
Vendor/ghostty/zig-out/include/ghostty/vt.h
```

`ghostty-vt.xcframework` generation requires full Xcode because Ghostty invokes `xcodebuild -create-xcframework`.

SwiftPM currently links the static archive directly:

```text
Vendor/ghostty/zig-out/lib/libghostty-vt.a
```

If the archive is missing, rebuild `libghostty-vt` before running SwiftPM commands.

## Build

```bash
swift build
```

Run the app:

```bash
swift run ProGhostty
```

Run the command-line helper:

```bash
swift run pg -- help
```

## Test

```bash
swift test --no-parallel
```

The test suite covers:

- PTY launch behavior;
- Ghostty VT bridge formatting;
- terminal surface rendering behavior;
- OSC parsing;
- command block indexing;
- history and workspace stores;
- split tree behavior;
- pane workspace controller behavior;
- settings migration and shortcut handling;
- shell enhancement plan generation and rollback.

## Repository Shape

```text
Sources/
  ProGhosttyApp/
    SwiftUI and AppKit product shell
  ProGhosttyCore/
    terminal protocols, PTY engine, Ghostty VT bridge, history,
    workspaces, plugins, settings, shell integration
  ProGhosttyGhosttyVT/
    C wrapper boundary for Ghostty VT
  ProGhosttyPTY/
    C PTY spawn/resize/wait helpers
  ProGhosttyPG/
    shell-facing command helper

Tests/
  ProGhosttyCoreTests/

Vendor/
  ghostty/
```

## Current Limitations

- Rendering still uses a temporary AppKit text surface, not Ghostty's full native renderer.
- `LibGhosttyTerminalEngine` remains a narrow placeholder; the live path is `PTYTerminalEngine`.
- `libghostty-vt` is built locally from the vendored Ghostty source.
- Full GhosttyKit integration needs further research against Ghostty's macOS frontend.
- Plugin installation is intentionally conservative and should remain explicit.

## Engineering Direction

Near-term work should focus on:

1. Stabilizing the PTY plus `libghostty-vt` interaction path.
2. Replacing temporary text rendering with a more faithful Ghostty-backed surface.
3. Keeping workspace and split behavior session-safe.
4. Keeping shell ecosystem features shell-integration based.
5. Preserving a clean adapter boundary so the terminal backend can evolve without rewriting product UI.

# ProGhostty

ProGhostty is a native macOS terminal built for real shell workflows.

It is not an IDE, not a shell replacement, and not a closed command environment. ProGhostty keeps the terminal as the first-class surface: your shell, dotfiles, prompt, completions, plugins, and TUI tools should continue to behave like they do in a normal terminal.

The product direction is deliberately restrained: a Ghostty-inspired terminal surface, real PTY sessions, `libghostty-vt` for terminal semantics, smooth scrollback, split panes, workspaces, settings, and plugin management.

> ProGhostty is not an official Ghostty release and is not affiliated with the Ghostty project. It vendors Ghostty source code and uses `libghostty-vt` as the terminal semantics layer.

## Download

Download the latest DMG from GitHub Releases:

https://github.com/freecodetiger/ProGhostty/releases/latest

The current DMG is ad-hoc signed. macOS may warn that the developer cannot be verified. This is expected for now. If macOS blocks launch, open it from Finder with right click -> Open.

ProGhostty checks for updates on launch and from Settings. When a newer GitHub Release is available, it shows a titlebar update bubble; clicking it opens the release page so you can download the new DMG.

## Why ProGhostty

Most terminal experiments become heavy by adding UI around the shell until the terminal feels secondary. ProGhostty takes the opposite route.

The terminal remains the product. Workspaces, split panes, plugin management, and settings are supporting tools around it. They should not take over the shell, rewrite user configuration, or special-case individual programs.

The goal is to feel close to the existing terminal ecosystem:

- `.zshrc`, aliases, completions, prompts, shell plugins, and TUI programs remain owned by the user's shell environment.
- Terminal bytes flow through a real PTY.
- VT parsing, cursor state, style attributes, scrollback, and terminal grid state are delegated to `libghostty-vt`.
- Product features stay outside terminal semantics.
- Codex, Claude Code, vim, tmux, fzf, htop, and similar tools should work through the same terminal path rather than through app-name-specific rendering hacks.

## Core Experience

### Smooth Scrollback

ProGhostty treats scrollback feel as a first-order terminal experience.

Normal scrollback uses an overscan-backed pixel scrolling path:

```text
libghostty-vt viewport + overscan rows
  -> AppKit cell-grid renderer
  -> sub-row visual offset
  -> row commits back to the libghostty viewport
```

This avoids fake UI-only scroll state. The terminal viewport remains owned by `libghostty-vt`, while the visible movement can feel smoother than terminals that only jump one row at a time.

In alternate screen / TUI programs, wheel input is forwarded to the program instead of forcing ProGhostty scrollback behavior. Stability and terminal correctness come before visual tricks.

### Real Terminal Sessions

Each pane is backed by an independent PTY session. Splitting a pane creates a new shell process. Closing a pane releases only that pane's session.

The active runtime path is:

```text
forkpty shell
  -> PTY output bytes
  -> GhosttyVTBridge
  -> libghostty-vt
  -> cell-grid snapshot
  -> AppKit renderer
```

### Ghostty-Powered Terminal Semantics

ProGhostty does not try to reinterpret terminal output in the UI layer. The expensive and error-prone parts of terminal behavior live behind `GhosttyVTBridge`:

- ANSI / VT parsing
- cursor state
- style attributes
- scrollback state
- viewport state
- cell-grid snapshots

The current renderer is an AppKit cell-grid renderer driven by `libghostty-vt` snapshots. It is not the full Ghostty macOS renderer, and the bridge boundary is kept explicit so the integration can evolve.

## Workflow

### Split Panes

Right click in a terminal pane to split right, split down, close the current pane, copy, paste, open workspaces, or open settings.

Splits are modeled as a split tree. Pane, session, and view ownership are separated so closing one pane does not collapse unrelated sessions.

### Workspaces

Workspaces organize independent terminal layouts without adding visible tabs or a permanent sidebar.

- Multiple workspaces can exist at the same time.
- Each workspace owns its own split tree and terminal sessions.
- The window shows only the active workspace.
- Inactive workspace sessions keep running by default.
- The workspace switcher opens through keyboard shortcuts or the context menu.

### Plugin Management

The plugin manager is intentionally shell-oriented. It can detect and install a small curated set of shell tools, generate install plans, back up files before changes, and write managed shell configuration into `~/.your-terminal/shell/`.

When `.zshrc` needs to be touched, ProGhostty uses a guarded source block instead of dumping large plugin configuration into user dotfiles.

### Settings

Settings are persisted locally and include:

- theme: light, dark, or follow system
- font family and size
- default shell
- default working directory
- language
- custom keyboard shortcuts
- plugin management entry
- update checks

## Project Status

ProGhostty is an early native macOS terminal. It is usable, but the most important work remains terminal correctness and rendering stability.

The current priority order is:

1. Terminal semantics must be correct.
2. PTY and `libghostty-vt` state must stay consistent.
3. TUI programs must remain stable.
4. Scrolling, selection, resize, and rendering should feel native and calm.
5. Product features should remain outside the terminal core.

## Build From Source

Requirements:

- macOS 13 or newer
- Swift 6.1 toolchain
- Git submodule support
- Zig 0.15.2 for building vendored Ghostty `libghostty-vt`
- Full Xcode if you need to generate `ghostty-vt.xcframework`

Initialize submodules:

```bash
git submodule update --init --recursive
```

Build `libghostty-vt` from the vendored Ghostty source:

```bash
cd Vendor/ghostty
../../.tools/zig-aarch64-macos-0.15.2/zig build \
  --global-cache-dir ../../.zig-cache-global \
  -Demit-lib-vt=true
```

Build and run:

```bash
swift build
swift run ProGhostty
```

Build the macOS app bundle:

```bash
scripts/build-app-bundle.sh release
```

Run tests:

```bash
swift test --no-parallel
```

## Repository Layout

```text
Sources/
  ProGhosttyApp/        macOS app, SwiftUI/AppKit UI, windows, workspace UI
  ProGhosttyCore/       PTY engine, Ghostty bridge, renderer, settings, plugins
  ProGhosttyGhosttyVT/  C boundary for libghostty-vt
  ProGhosttyPTY/        forkpty / resize / wait C helpers
  ProGhosttyPG/         shell-facing helper command

Tests/
  ProGhosttyCoreTests/

Vendor/
  ghostty/              vendored Ghostty source

docs/
  architecture/         terminal architecture notes
  superpowers/          design specs and implementation plans
```

## Technical Notes

- Current terminal scrollback defaults to 10,000 rows per session.
- The primary renderer is `GhosttyVTCellGridRendererBackend`.
- Text / HTML fallback code exists, but the main terminal path is the AppKit cell-grid renderer.
- Normal scrollback can use overscan-backed pixel scrolling.
- Alternate screen programs receive wheel input instead of ProGhostty scrollback.
- The full Ghostty macOS renderer is not embedded.

## English Summary

ProGhostty is an early native macOS terminal focused on real shell workflows, Ghostty-powered terminal semantics, and smooth scrollback.

It uses real PTY sessions, routes terminal bytes through `libghostty-vt`, and renders a native AppKit cell grid. Product features such as split panes, workspaces, settings, update checks, and plugin management are built around the terminal rather than replacing the user's shell ecosystem.

ProGhostty is not an official Ghostty release. It vendors Ghostty source code and keeps Ghostty integration behind a bridge so the terminal core can evolve without coupling product UI to unstable internals.

Download the latest DMG:

https://github.com/freecodetiger/ProGhostty/releases/latest

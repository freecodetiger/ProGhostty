# ProGhostty

[![Release](https://img.shields.io/github/v/release/freecodetiger/ProGhostty?sort=semver)](https://github.com/freecodetiger/ProGhostty/releases/latest)
[![Platform](https://img.shields.io/badge/platform-macOS%2013%2B-black)](Package.swift)
[![Swift](https://img.shields.io/badge/Swift-6.1-orange)](Package.swift)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

ProGhostty is a native macOS terminal for real shell workflows, built around
Ghostty's terminal semantics and a restrained developer experience layer.

It keeps the terminal as the product: your shell, dotfiles, prompt, completion,
aliases, plugins, tmux, vim, fzf, htop, Codex, Claude Code, and other TUI tools
continue to run through the normal terminal path.

> ProGhostty is not an official Ghostty release and is not affiliated with the
> Ghostty project. This repository vendors Ghostty and uses `libghostty-vt` as
> the terminal semantics layer.

## Status

ProGhostty is an early-stage native macOS terminal. It is usable for real PTY
sessions, but the project still prioritizes terminal correctness, renderer
stability, resize behavior, scrollback quality, and TUI compatibility over broad
product surface area.

Current priorities:

1. Correct VT semantics through `libghostty-vt`.
2. Stable PTY, resize, scrollback, and renderer behavior.
3. Natural macOS interaction without replacing the user's shell ecosystem.
4. Product features that stay outside the terminal core.

## Features

- Native macOS app built with Swift, SwiftUI, and AppKit.
- Real PTY sessions, one shell process per pane.
- Ghostty-powered VT parsing, cell state, styles, cursor state, and viewport
  semantics behind a narrow bridge.
- AppKit cell-grid renderer driven by `libghostty-vt` snapshots.
- Overscan-backed pixel scrollback for smoother normal-screen scrolling.
- Split panes with independent terminal sessions.
- Workspaces with independent split trees and long-running sessions.
- Settings for appearance, font, shell, working directory, language, shortcuts,
  plugin management, and update checks.
- Shell plugin management that uses previews, backups, and guarded shell config
  blocks instead of taking over dotfiles.
- `pg` helper executable for shell-facing integrations.

## Download

Download the latest DMG from GitHub Releases:

<https://github.com/freecodetiger/ProGhostty/releases/latest>

Current DMG builds use ad-hoc signing. macOS may show a developer verification
warning. If macOS blocks the app, open it from Finder with right click -> Open.

ProGhostty can check for updates on launch or from Settings. When a newer GitHub
Release is available, the titlebar shows an update prompt that opens the release
page.

## Build From Source

Requirements:

- macOS 13 or newer
- Swift 6.1 toolchain
- Git submodule support
- Zig 0.15.2 for building the vendored Ghostty `libghostty-vt`
- Full Xcode when producing the `ghostty-vt.xcframework` or app bundle

Clone submodules:

```bash
git submodule update --init --recursive
```

Build the vendored Ghostty VT library:

```bash
cd Vendor/ghostty
../../.tools/zig-aarch64-macos-0.15.2/zig build \
  --global-cache-dir ../../.zig-cache-global \
  -Demit-lib-vt=true
```

Build and run the app:

```bash
swift build
swift run ProGhostty
```

Build a macOS app bundle:

```bash
scripts/build-app-bundle.sh release
```

Run tests:

```bash
swift test --no-parallel
```

## Architecture

ProGhostty keeps Ghostty integration behind a bridge so UI and product code do
not directly depend on Ghostty internals.

```text
forkpty shell
  -> PTY output bytes
  -> GhosttyVTBridge
  -> libghostty-vt
  -> cell-grid snapshot
  -> AppKit renderer
```

The terminal core owns PTY lifecycle, resize, input routing, and renderer
snapshots. Product features such as workspaces, settings, plugin management, and
update checks live around that core rather than inside the terminal parser or
renderer.

## Repository Layout

```text
Sources/
  ProGhosttyApp/        macOS app, SwiftUI/AppKit UI, windows, workspaces
  ProGhosttyCore/       PTY engine, Ghostty bridge, renderer, settings, plugins
  ProGhosttyGhosttyVT/  C boundary for libghostty-vt
  ProGhosttyPTY/        forkpty, resize, and wait C helpers
  ProGhosttyPG/         shell-facing helper command

Tests/
  ProGhosttyCoreTests/  terminal, renderer, workspace, settings, and update tests

Vendor/
  ghostty/              vendored Ghostty source

docs/
  architecture/         terminal architecture notes
```

## Design Principles

- Do not replace the user's shell.
- Do not parse terminal output in product UI when VT semantics belong in the
  terminal layer.
- Do not hard-code behavior for specific terminal apps or developer tools.
- Keep enhanced workflows optional and degradable.
- Prefer native macOS interaction, quiet UI, and predictable terminal behavior.

## Contributing

Issues and pull requests are welcome. For meaningful changes, please describe:

- the user-facing problem,
- the terminal behavior affected,
- how the change was tested,
- and whether it touches PTY, `libghostty-vt`, renderer, workspace, settings, or
  plugin-management code.

Before opening a pull request, run:

```bash
swift test --no-parallel
```

## License

ProGhostty is released under the [MIT License](LICENSE).

Vendored Ghostty source code remains under its own MIT license in
[`Vendor/ghostty/LICENSE`](Vendor/ghostty/LICENSE).

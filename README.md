# ProGhostty

ProGhostty is a macOS-native terminal MVP shaped by `guide.md`: a Ghostty-core adapter boundary with a developer-experience layer for command blocks, local history, workspaces, settings, and shell environment inspection.

## Current Build Shape

- `ProGhosttyCore` contains the terminal engine protocol, mock engine, OSC parser, command block indexer, SQLite history/workspace stores, settings, and plugin scanner.
- `ProGhosttyApp` is a SwiftUI macOS shell using `PTYTerminalEngine` by default. The live path is PTY bytes from the user's shell into `libghostty-vt`, then a temporary plain-text formatter surface for display.
- `MockTerminalEngine` remains available as a fallback/demo engine so the UI and data layer can run without a real terminal backend.
- `Vendor/ghostty` tracks the official Ghostty source as a git submodule. `LibGhosttyTerminalEngine` is intentionally a narrow stub; real integration should stay isolated there.
- `ProGhosttyGhosttyVT` is a narrow C wrapper around the unstable `libghostty-vt` C API. Swift code calls `GhosttyVTBridge`, not Ghostty headers directly.
- `PaneNode` / `SplitPane` / `TerminalPane` form the renderer-agnostic split tree for workspace panes. Each pane stores only lightweight metadata and a `TerminalSessionID`, not Ghostty-specific bridge types.
- `docs/architecture/terminal-core-positioning.md` defines the layer boundaries for PTY, Ghostty, shell integration plugins, and the product UI.
- Tests under `Tests/ProGhosttyCoreTests` cover OSC parsing, command block indexing, history store behavior, workspace store behavior, PTY launch, and the Ghostty VT bridge.

## Terminal Backend

The current runtime flow is:

```text
SwiftUI terminal view
  -> PTYTerminalEngine
  -> forkpty shell process
  -> PTY output bytes
  -> GhosttyVTBridge / libghostty-vt
  -> plain-text formatted terminal state
  -> NSTextView surface
```

This is intentionally not the final Ghostty renderer. `libghostty-vt` now interprets PTY bytes and maintains terminal state, while the app uses its plain formatter as a temporary rendering surface. A future full renderer should replace only the surface/bridge internals and keep the upper app layers unchanged.

## Ghostty VT Library

Short term, build Ghostty's VT library from the submodule:

```bash
git submodule update --init --recursive
../../.tools/zig-aarch64-macos-0.15.2/zig build --global-cache-dir ../../.zig-cache-global -Demit-lib-vt=true -Demit-xcframework=true
```

Run the Zig command from `Vendor/ghostty`. Ghostty currently requires Zig `0.15.2`.

With only Command Line Tools installed, the build produces:

- `Vendor/ghostty/zig-out/lib/libghostty-vt.a`
- `Vendor/ghostty/zig-out/lib/libghostty-vt.0.1.0.dylib`
- `Vendor/ghostty/zig-out/include/ghostty/vt.h`

`ghostty-vt.xcframework` requires full Xcode because Ghostty invokes `xcodebuild -create-xcframework`. Long term, investigate how the full macOS frontend links complete libghostty/GhosttyKit before replacing `MockTerminalEngine`.

The SwiftPM build currently links the locally built static archive:

```text
Vendor/ghostty/zig-out/lib/libghostty-vt.a
```

If that archive is missing, re-run the VT build command above before `swift build` or `swift test`.

## Run

```bash
swift run ProGhostty
```

## Test

```bash
swift test
```

This project currently builds and tests with Command Line Tools for Xcode 16.4 / Swift 6.1.2.

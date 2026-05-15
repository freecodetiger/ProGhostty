# ProGhostty

ProGhostty is a macOS-native terminal MVP shaped by `guide.md`: a Ghostty-core adapter boundary with a developer-experience layer for command blocks, local history, workspaces, settings, and shell environment inspection.

## Current Build Shape

- `ProGhosttyCore` contains the terminal engine protocol, mock engine, OSC parser, command block indexer, SQLite history/workspace stores, settings, and plugin scanner.
- `ProGhosttyApp` is a SwiftUI macOS shell using `MockTerminalEngine` so the UI and data layer can run before libghostty is linked.
- `Vendor/ghostty` tracks the official Ghostty source as a git submodule. `LibGhosttyTerminalEngine` is intentionally a narrow stub; real integration should stay isolated there.
- Tests under `Tests/ProGhosttyCoreTests` cover OSC parsing, command block indexing, history store behavior, and workspace store behavior.

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

## Run

```bash
swift run ProGhostty
```

## Test

```bash
swift test
```

This project currently builds and tests with Command Line Tools for Xcode 16.4 / Swift 6.1.2.

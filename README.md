# ProGhostty

ProGhostty is a macOS-native terminal MVP shaped by `guide.md`: a Ghostty-core adapter boundary with a developer-experience layer for command blocks, local history, workspaces, settings, and shell environment inspection.

## Current Build Shape

- `ProGhosttyCore` contains the terminal engine protocol, mock engine, OSC parser, command block indexer, SQLite history/workspace stores, settings, and plugin scanner.
- `ProGhosttyApp` is a SwiftUI macOS shell using `MockTerminalEngine` so the UI and data layer can run before libghostty is linked.
- `LibGhosttyTerminalEngine` is intentionally a narrow stub. Real libghostty integration should be isolated there after vendored headers or a stable frontend example are available.
- Tests under `Tests/ProGhosttyCoreTests` cover OSC parsing, command block indexing, history store behavior, and workspace store behavior.

## Run

```bash
swift run ProGhostty
```

## Test

```bash
swift test
```

This project currently builds and tests with Command Line Tools for Xcode 16.4 / Swift 6.1.2.

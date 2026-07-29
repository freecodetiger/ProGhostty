# Contributing to ProGhostty

Welcome! ProGhostty is a bilingual project — 中文界面, English code and docs. Whether you're fixing a typo or rewriting the scroll engine, we're glad you're here.

This guide covers everything you need to go from "I want to help" to a merged PR.

---

## Ways to Contribute

| You care about… | Jump in on… | Good first step |
|-----------------|-------------|-----------------|
| Daily-driver bugs | Repro + PR or detailed issue | Run the app, file what breaks |
| Scroll / split / resize | Pattern-2 smooth scroll, pane layout | Read `docs/architecture/ownership-map.md` |
| Themes & settings | Cohesive palettes, a11y contrast | Tweak Soft Dark / Soft Light, add previews |
| Docs & onboarding | Screenshots, build tips, translations | Improve this file or the README |
| Tests | Pure value types, scroll resolvers | Add edge-case tests to `Tests/` |
| CI & release | Workflow hardening, DMG scripting | Check `.github/workflows/` and `scripts/` |

Not sure where to start? Browse [open issues](https://github.com/freecodetiger/ProGhostty/issues) — anything labeled `good first issue` is a solid entry point.

---

## Development Setup

### 1. Fork & Clone

```bash
git clone --recursive https://github.com/<your-username>/ProGhostty.git
cd ProGhostty
```

The `--recursive` flag is **required** — it pulls in `Vendor/ghostty` (the Ghostty submodule that provides `libghostty-vt`). If you already cloned without it:

```bash
git submodule update --init --recursive
```

### 2. System Requirements

| Tool | Version | Notes |
|------|---------|-------|
| macOS | **14+** | App target minimum |
| Swift | **6.1** | Language mode `.v6` |
| Zig | **0.15.2** | Builds vendored `libghostty-vt` |
| Xcode | Latest stable | App bundle and signing tooling |

Verify your toolchain:

```bash
swift --version   # Swift 6.1
zig version        # 0.15.2
xcodebuild -version
```

### 3. Build `libghostty-vt` (ReleaseFast — Required)

A Debug VT library makes parsing **pathologically slow**. Always use ReleaseFast:

```bash
cd Vendor/ghostty
zig build \
  --global-cache-dir ../../.zig-cache-global \
  -Demit-lib-vt=true \
  -Demit-xcframework=false \
  -Doptimize=ReleaseFast
cd ../..
```

Full notes: [`docs/libghostty-vt.md`](docs/libghostty-vt.md).

### 4. Compile & Test

```bash
swift build
swift test
```

Both must pass green before you open a PR.

### 5. Architecture Guard

```bash
scripts/check-architecture.sh
```

This script enforces the layering rules (e.g. Core cannot import SwiftUI). If it fails, your change violates an architecture boundary — fix the import before proceeding.

### 6. Build the Real .app

`swift build` alone does **not** produce a launchable `.app` bundle. For manual testing:

```bash
./scripts/build-app-bundle.sh release
open .build/arm64-apple-macosx/release/ProGhostty.app
```

Always hand-test renderer and scroll changes in the real app before submitting.

---

## Architecture Overview

One pipeline. One owner per concern. Dependencies flow top-down only.

```text
PTY bytes
  → PTYTerminalEngine           session lifecycle & I/O
  → GhosttyVTBridge.write
  → libghostty-vt               ★ sole terminal state truth
  → frame / scrollFrame / rows(at:)
  → TerminalRenderFrame         immutable snapshot
  → Metal direct | cell-grid | text fallback
```

### Layer Rules

```
┌─────────────────────────────────────────────────────┐
│ App  (ProGhosttyApp) — SwiftUI + AppKit host         │
│   AppModel · RootView · window chrome                │
└──────────────────────▲──────────────────────────────┘
                       │ protocols + value types only
┌──────────────────────┴──────────────────────────────┐
│ Core (ProGhosttyCore) — NO import SwiftUI            │
│   Terminal · Workspace · Settings · Persistence      │
└──────────────────────┬──────────────────────────────┘
                       │ C shims
                       ▼
              libghostty-vt (Zig)
```

**Key constraint:** `ProGhosttyCore` **cannot** `import SwiftUI`. This is enforced by `scripts/check-architecture.sh` in CI. AppKit usage in Core is restricted to a whitelist of renderer/PTY files.

Deep dive: [`docs/architecture/ownership-map.md`](docs/architecture/ownership-map.md).

### Source Layout

```text
Sources/
  ProGhosttyApp/        macOS app, settings UI, windows
  ProGhosttyCore/       PTY, VT bridge, renderer, workspace
  ProGhosttyGhosttyVT/  C surface for libghostty-vt
  ProGhosttyPTY/        forkpty / resize helpers
  ProGhosttyPG/         `pg` helper CLI

Vendor/ghostty/         vendored Ghostty (MIT)
Tests/                  swift-testing
scripts/                bundle, DMG, architecture guard
```

---

## Coding Conventions

### Layering

- **Core cannot import SwiftUI.** This is a hard rule enforced by CI.
- **AppKit in Core** is limited to a whitelist (renderer, PTY, mock files). See `scripts/check-architecture.sh` for the exact allow-list.
- **App layer** communicates with Core through protocols and value types only. Touching `GhosttyVTBridge` or C headers from App is a boundary violation.

### Types & Style

- **Prefer pure value types** (`struct`, `enum`) over reference types. Most of the Core → App contract is built on `Sendable` / `Equatable` structs.
- **Each concern has one owner type.** Before adding a new type, check the [ownership map](docs/architecture/ownership-map.md) — if a type already owns that concern, extend it instead of creating a parallel one.
- **Dependency injection via composition root**, not internal instantiation. Types receive their collaborators; they don't `new` them internally.
- **Swift 6.1 strict concurrency.** The project uses `.v6` language mode — all types crossing concurrency boundaries must be `Sendable`.

### Testing

- Tests live in `Tests/ProGhosttyCoreTests/` and `Tests/ProGhosttyAppTests/`.
- Framework: **swift-testing** (not XCTest).
- Focus tests on pure value types and resolvers — they're the easiest to test and the most valuable to have covered.

---

## Commit Conventions

ProGhostty uses [Conventional Commits](https://www.conventionalcommits.org/). Full spec: [`docs/git-workflow.md`](docs/git-workflow.md).

### Format

```
<type>(<scope>): <summary>

[optional body]
```

### Type

| Type | When |
|------|------|
| `feat` | User-visible feature |
| `fix` | Bug fix / regression |
| `refactor` | Behavior-preserving restructure |
| `test` | Test-only changes |
| `docs` | Documentation / specs |
| `chore` | Build scripts, dependencies |
| `ci` | Workflows / release pipeline |
| `perf` | Performance optimization |

### Scope (common)

`scroll` · `render` · `pty` · `vt` · `workspace` · `settings` · `ci` · `release` · `arch`

### Rules

- **Imperative mood, present tense:** `fix false bottom when…` — not `fixed` / `fixes`.
- **≤ 72 characters** in the summary line.
- **One intent per commit.** Don't mix unrelated changes.
- **English summaries preferred**; Chinese is fine in the body.

### Good / Bad Examples

```
# Good
fix(scroll): stop cursor-rect rebuild thrashing during browse
feat(settings): add theme import from iTerm2 plist
refactor(workspace): extract PaneNode from PaneTreeReducer

# Bad
update stuff
fix bug
WIP
PTYTerminalEngine.swift changes
```

---

## PR Process

1. **Fork** the repo and create a branch from `main`.
2. **Make your changes** following the coding conventions above.
3. **Run the full check:**

   ```bash
   swift build && swift test && scripts/check-architecture.sh
   ```

   If your change touches UI or rendering, also:

   ```bash
   ./scripts/build-app-bundle.sh release   # hand-test the .app
   ```

4. **Open a PR** against `main` on the upstream repo.
5. **Fill the PR template** — describe:
   - **User-visible behavior** — what changed from the user's perspective?
   - **Layer touched** — PTY / VT / renderer / workspace / settings?
   - **How you tested** — unit tests, hand-testing, both?
6. **CI must pass.** The PR will not be merged with red CI.
7. **Respond to review feedback.** Maintainers may request changes — this is normal and collaborative.

### What Maintainers Look For

- **Correctness** — does it do what the description says?
- **Layering** — no import violations, no boundary crossings.
- **Tests** — new behavior has tests; bug fixes have regression tests.
- **Commit hygiene** — clean history, conventional messages, one intent per commit.
- **No drive-by refactors** — keep unrelated cleanup in a separate PR.
- **User impact** — the description clearly states what the user will see or experience.

---

## Getting Help

- **Questions & ideas:** [GitHub Discussions](https://github.com/freecodetiger/ProGhostty/discussions)
- **Bug reports & feature requests:** [GitHub Issues](https://github.com/freecodetiger/ProGhostty/issues)
- **Security issues:** See [SECURITY.md](SECURITY.md) — do not file public issues for vulnerabilities.

We aim to respond to issues and PRs within a few days. If you haven't heard back in a week, a polite ping is welcome and encouraged.

---

## License

By contributing to ProGhostty, you agree that your contributions will be licensed under the [MIT License](LICENSE), the same as the project itself.

---

Thank you for making ProGhostty better. Every contribution — no matter how small — helps build a better terminal for everyone.

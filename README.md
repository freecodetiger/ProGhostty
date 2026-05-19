# ProGhostty

## 中文

ProGhostty 是一个 macOS 原生终端实验项目。它以真实 PTY、用户现有 shell 环境和 Ghostty 的终端核心能力为基础，在上层补充工作区、分屏、设置和插件管理等产品能力。

项目的目标不是重新发明 shell，也不是把终端包装成一套封闭 IDE。ProGhostty 保留真实 shell 工作流：用户的 `.zshrc`、alias、补全、prompt、shell plugin 和 TUI 程序都应继续按终端生态的方式运行。

当前项目仍处于 MVP 阶段。真实运行路径以 `PTYTerminalEngine` 为主，PTY 输出进入 `GhosttyVTBridge` / `libghostty-vt`，界面层使用 SwiftUI + AppKit 渲染终端表面。完整 GhosttyKit 或 Ghostty macOS 前端集成仍保留在适配层后续研究。

### 核心原则

- 真实 shell 优先：终端会话必须来自真实 PTY，而不是自定义命令解释器。
- `libghostty-vt` 负责终端语义：VT 解析、光标、样式、滚动状态和终端网格不由 UI 层猜测。
- 产品能力在终端外层实现：工作区、分屏、设置和插件不污染终端核心。
- 不按程序名特殊处理 TUI：Codex、Claude Code、vim、tmux、fzf 等都应从同一套终端状态和输入规则中受益。
- Ghostty 相关 API 必须封装在 bridge / adapter 后面，避免产品层直接依赖不稳定接口。

### 当前架构

```text
SwiftUI / AppKit UI
  -> Workspace / Split / Settings / Plugins
  -> TerminalEngine
  -> PTYTerminalEngine
  -> forkpty shell
  -> GhosttyVTBridge
  -> libghostty-vt
```

相关文档：

- `docs/architecture/terminal-core-positioning.md`
- `docs/architecture/terminal-rendering-rework.md`
- `docs/renderer-scrolling.md`
- `docs/libghostty-vt.md`

### 已实现能力

- 基于 PTY 的真实 shell 交互。
- 每个 pane 对应独立 terminal session。
- split tree 管理分屏布局，关闭 pane 只释放对应 session。
- 多 workspace 并存，非当前 workspace 的 session 默认保持运行，只 detach UI。
- workspace switcher 支持切换、创建、重命名和删除工作区。
- OSC 7 作为 side-channel 跟踪 cwd 信息。
- 设置持久化，支持主题、字体、默认工作目录和自定义快捷键。
- shell 插件管理支持扫描、安装计划、备份、回滚和受控写入。
- 基于 `libghostty-vt` cell grid 的终端渲染路径，以及文本 fallback。
### 构建要求

- macOS 13 或更新版本。
- Swift 6.1 工具链。
- Git submodule 支持。
- Zig `0.15.2`，用于构建 vendored Ghostty 的 `libghostty-vt`。
- 如需生成 `ghostty-vt.xcframework`，需要完整 Xcode；仅 Command Line Tools 可能不足。

### 初始化和构建

初始化 submodule：

```bash
git submodule update --init --recursive
```

从 `Vendor/ghostty` 构建 `libghostty-vt`：

```bash
../../.tools/zig-aarch64-macos-0.15.2/zig build \
  --global-cache-dir ../../.zig-cache-global \
  -Demit-lib-vt=true \
  -Demit-xcframework=true
```

SwiftPM 当前直接链接：

```text
Vendor/ghostty/zig-out/lib/libghostty-vt.a
```

构建并运行应用：

```bash
swift build
swift run ProGhostty
```

运行命令行辅助工具：

```bash
swift run pg -- help
```

运行测试：

```bash
swift test --no-parallel
```

### 项目结构

```text
Sources/
  ProGhosttyApp/        macOS app, SwiftUI/AppKit UI, windows, workspace UI
  ProGhosttyCore/       PTY engine, Ghostty bridge, settings, plugins
  ProGhosttyGhosttyVT/  C boundary for libghostty-vt
  ProGhosttyPTY/        forkpty / resize / wait C helpers
  ProGhosttyPG/         shell-facing helper command

Tests/
  ProGhosttyCoreTests/

Vendor/
  ghostty/              vendored Ghostty source

docs/
  architecture/         terminal architecture notes
  superpowers/          feature specs and implementation plans
```

### 当前限制

- 渲染路径仍是渐进式集成，还不是完整 Ghostty 原生 macOS renderer。
- `LibGhosttyTerminalEngine` 仍是占位边界，当前真实运行路径是 `PTYTerminalEngine`。
- `libghostty-vt` 需要从 vendored Ghostty 源码本地构建。

### 下一步方向

1. 继续稳定 `PTY -> libghostty-vt -> cell grid -> AppKit` 渲染链路。
2. 在不绕过 `libghostty-vt` 的前提下提升渲染还原度、选择和滚动体验。
3. 保持 pane / session / view 解耦，为未来 GhosttyKit 或完整 Ghostty frontend 集成保留适配空间。
4. 让 shell integration 和插件承担特殊能力，避免把程序特例硬编码进终端渲染层。

---

## English

ProGhostty is an experimental native macOS terminal. It is built on real PTY sessions, the user's existing shell environment, and Ghostty's terminal core capabilities, while adding product-level features such as workspaces, splits, settings, and plugin management.

The goal is not to reinvent the shell or wrap the terminal in a closed IDE. ProGhostty preserves the real terminal workflow: `.zshrc`, aliases, completions, prompts, shell plugins, and TUI applications should continue to behave as part of the normal terminal ecosystem.

The project is currently an MVP. The active runtime path is `PTYTerminalEngine`; PTY output is passed into `GhosttyVTBridge` / `libghostty-vt`, and the UI layer renders the terminal surface with SwiftUI and AppKit. Full GhosttyKit or Ghostty macOS frontend integration remains future adapter-layer work.

### Principles

- Real shell first: terminal sessions must come from a real PTY, not a custom command interpreter.
- `libghostty-vt` owns terminal semantics: VT parsing, cursor state, styles, scrolling, and the terminal grid are not guessed by the UI layer.
- Product features live outside the terminal core: workspaces, splits, settings, and plugins must not pollute terminal semantics.
- No app-name-specific TUI handling: Codex, Claude Code, vim, tmux, fzf, and similar tools should benefit from the same terminal-state and input rules.
- Ghostty APIs must stay behind bridge / adapter boundaries so product code does not depend directly on unstable interfaces.

### Architecture

```text
SwiftUI / AppKit UI
  -> Workspace / Split / Settings / Plugins
  -> TerminalEngine
  -> PTYTerminalEngine
  -> forkpty shell
  -> GhosttyVTBridge
  -> libghostty-vt
```

Related documents:

- `docs/architecture/terminal-core-positioning.md`
- `docs/architecture/terminal-rendering-rework.md`
- `docs/renderer-scrolling.md`
- `docs/libghostty-vt.md`

### Implemented Capabilities

- Real shell interaction through PTY.
- One independent terminal session per pane.
- Split-tree-based pane layout; closing a pane releases only that pane's session.
- Multiple workspaces; inactive workspaces keep their sessions running by default.
- Workspace switcher for switching, creating, renaming, and deleting workspaces.
- OSC 7 side-channel tracking for cwd metadata.
- Persistent settings for theme, font, default working directory, and custom shortcuts.
- Shell plugin management with detection, install plans, backups, rollback, and controlled writes.
- `libghostty-vt` cell-grid rendering path with a text fallback.
### Requirements

- macOS 13 or newer.
- Swift 6.1 toolchain.
- Git submodule support.
- Zig `0.15.2` for building vendored Ghostty's `libghostty-vt`.
- Full Xcode is required if you need to generate `ghostty-vt.xcframework`; Command Line Tools alone may not be enough.

### Setup and Build

Initialize submodules:

```bash
git submodule update --init --recursive
```

Build `libghostty-vt` from `Vendor/ghostty`:

```bash
../../.tools/zig-aarch64-macos-0.15.2/zig build \
  --global-cache-dir ../../.zig-cache-global \
  -Demit-lib-vt=true \
  -Demit-xcframework=true
```

SwiftPM currently links directly against:

```text
Vendor/ghostty/zig-out/lib/libghostty-vt.a
```

Build and run the app:

```bash
swift build
swift run ProGhostty
```

Run the shell-facing helper:

```bash
swift run pg -- help
```

Run tests:

```bash
swift test --no-parallel
```

### Repository Layout

```text
Sources/
  ProGhosttyApp/        macOS app, SwiftUI/AppKit UI, windows, workspace UI
  ProGhosttyCore/       PTY engine, Ghostty bridge, settings, plugins
  ProGhosttyGhosttyVT/  C boundary for libghostty-vt
  ProGhosttyPTY/        forkpty / resize / wait C helpers
  ProGhosttyPG/         shell-facing helper command

Tests/
  ProGhosttyCoreTests/

Vendor/
  ghostty/              vendored Ghostty source

docs/
  architecture/         terminal architecture notes
  superpowers/          feature specs and implementation plans
```

### Current Limitations

- Rendering is still a staged integration path, not the full native Ghostty macOS renderer.
- `LibGhosttyTerminalEngine` is still a boundary placeholder; the active runtime path is `PTYTerminalEngine`.
- `libghostty-vt` must be built locally from the vendored Ghostty source.

### Roadmap

1. Continue stabilizing the `PTY -> libghostty-vt -> cell grid -> AppKit` rendering path.
2. Improve rendering fidelity, selection, and scrolling without bypassing `libghostty-vt`.
3. Keep pane / session / view boundaries clean for future GhosttyKit or full Ghostty frontend integration.
4. Let shell integration and plugins own special behavior instead of hard-coding application-specific rules into terminal rendering.

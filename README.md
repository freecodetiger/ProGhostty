# ProGhostty

## 中文

ProGhostty 是一个 macOS 原生终端实验项目。它以真实 PTY、用户现有 shell 环境和 Ghostty 的终端核心能力为基础，在上层补充工作区、分屏、历史、插件管理和 Codex 辅助输入等产品能力。

项目的目标不是重新发明 shell，也不是把终端包装成一套封闭 IDE。ProGhostty 保留真实 shell 工作流：用户的 `.zshrc`、alias、补全、prompt、shell plugin 和 TUI 程序都应继续按终端生态的方式运行。

当前项目仍处于 MVP 阶段。真实运行路径以 `PTYTerminalEngine` 为主，PTY 输出进入 `GhosttyVTBridge` / `libghostty-vt`，界面层使用 SwiftUI + AppKit 渲染终端表面。完整 GhosttyKit 或 Ghostty macOS 前端集成仍保留在适配层后续研究。

### 核心原则

- 真实 shell 优先：终端会话必须来自真实 PTY，而不是自定义命令解释器。
- `libghostty-vt` 负责终端语义：VT 解析、光标、样式、滚动状态和终端网格不由 UI 层猜测。
- 产品能力在终端外层实现：工作区、分屏、设置、历史、插件和 AI 辅助能力不污染终端核心。
- 不按程序名特殊处理 TUI：Codex、Claude Code、vim、tmux、fzf 等都应从同一套终端状态和输入规则中受益。
- Ghostty 相关 API 必须封装在 bridge / adapter 后面，避免产品层直接依赖不稳定接口。
- AI 能力默认是辅助输入和上下文整理，不接管终端、不自动执行命令。

### 当前架构

```text
SwiftUI / AppKit UI
  -> Workspace / Split / Settings / Plugins / History / AI Command Capsule
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
- `docs/superpowers/specs/2026-05-18-codex-command-capsule-design.md`

### 已实现能力

- 基于 PTY 的真实 shell 交互。
- 每个 pane 对应独立 terminal session。
- split tree 管理分屏布局，关闭 pane 只释放对应 session。
- 多 workspace 并存，非当前 workspace 的 session 默认保持运行，只 detach UI。
- workspace switcher 支持切换、创建、重命名和删除工作区。
- OSC 133 / OSC 7 作为 side-channel 记录命令和 cwd 信息。
- 设置持久化，支持主题、字体、默认工作目录和自定义快捷键。
- shell 插件管理支持扫描、安装计划、备份、回滚和受控写入。
- 基于 `libghostty-vt` cell grid 的终端渲染路径，以及文本 fallback。
- 面向 Codex CLI 的 AI Companion 和 Codex Command Capsule。

### Codex Command Capsule

Codex Command Capsule 是 ProGhostty 的第一版 Codex 外围体验优化。它是一个浮动输入面板，而不是聊天侧栏。

它可以：

- 通过快捷键 `Cmd+Shift+I` 或 AI 菜单打开。
- 接收文字输入。
- 调用阿里云 DashScope 实时语音识别，把语音转成请求文本。
- 调用 OpenAI-compatible `/chat/completions` API，把口语化请求整理成适合 Codex CLI 的 prompt。
- 显式附带少量上下文：workspace path、git branch、git status、changed file list、selected terminal text。
- 通过 bracketed paste 把 draft 发送到 Codex CLI，可选择只粘贴或粘贴并回车。

它不会：

- 维护每个目录的长期聊天记忆。
- 自动观察或解析 Codex 输出。
- 使用 Codex 私有协议。
- 自动向终端发送命令。
- 默认上传完整文件内容或完整终端历史。

相关配置在 Settings 的 `AI Companion` 区域：

- `DashScope API Key`：用于阿里云实时语音识别。
- `OpenAI Base URL`：OpenAI-compatible API base URL，默认 `https://api.openai.com/v1`。
- `OpenAI API Key`：用于 prompt refinement。
- `OpenAI Model`：用于 prompt refinement 的模型名。

也可以通过环境变量提供 OpenAI-compatible 配置：

```bash
export OPENAI_BASE_URL="https://api.openai.com/v1"
export OPENAI_API_KEY="..."
export OPENAI_MODEL="..."
```

DashScope key 可通过设置项、Keychain 或 `DASHSCOPE_API_KEY` 提供。

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
  ProGhosttyCore/       PTY engine, Ghostty bridge, settings, history, AI helpers
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
- Codex Command Capsule 是 prompt refinement 和发送工具，不是 Codex 内部上下文同步系统。
- AI 相关功能需要用户自行配置 API key；项目不会默认启用云端请求。

### 下一步方向

1. 继续稳定 `PTY -> libghostty-vt -> cell grid -> AppKit` 渲染链路。
2. 在不绕过 `libghostty-vt` 的前提下提升渲染还原度、选择和滚动体验。
3. 完善 Codex Command Capsule 的交互细节、错误处理和可配置上下文包。
4. 保持 pane / session / view 解耦，为未来 GhosttyKit 或完整 Ghostty frontend 集成保留适配空间。
5. 让 shell integration 和插件承担特殊能力，避免把程序特例硬编码进终端渲染层。

---

## English

ProGhostty is an experimental native macOS terminal. It is built on real PTY sessions, the user's existing shell environment, and Ghostty's terminal core capabilities, while adding product-level features such as workspaces, splits, history, plugin management, and Codex-oriented input assistance.

The goal is not to reinvent the shell or wrap the terminal in a closed IDE. ProGhostty preserves the real terminal workflow: `.zshrc`, aliases, completions, prompts, shell plugins, and TUI applications should continue to behave as part of the normal terminal ecosystem.

The project is currently an MVP. The active runtime path is `PTYTerminalEngine`; PTY output is passed into `GhosttyVTBridge` / `libghostty-vt`, and the UI layer renders the terminal surface with SwiftUI and AppKit. Full GhosttyKit or Ghostty macOS frontend integration remains future adapter-layer work.

### Principles

- Real shell first: terminal sessions must come from a real PTY, not a custom command interpreter.
- `libghostty-vt` owns terminal semantics: VT parsing, cursor state, styles, scrolling, and the terminal grid are not guessed by the UI layer.
- Product features live outside the terminal core: workspaces, splits, settings, history, plugins, and AI assistance must not pollute terminal semantics.
- No app-name-specific TUI handling: Codex, Claude Code, vim, tmux, fzf, and similar tools should benefit from the same terminal-state and input rules.
- Ghostty APIs must stay behind bridge / adapter boundaries so product code does not depend directly on unstable interfaces.
- AI features are input and context helpers by default; they do not take control of the terminal or execute commands automatically.

### Architecture

```text
SwiftUI / AppKit UI
  -> Workspace / Split / Settings / Plugins / History / AI Command Capsule
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
- `docs/superpowers/specs/2026-05-18-codex-command-capsule-design.md`

### Implemented Capabilities

- Real shell interaction through PTY.
- One independent terminal session per pane.
- Split-tree-based pane layout; closing a pane releases only that pane's session.
- Multiple workspaces; inactive workspaces keep their sessions running by default.
- Workspace switcher for switching, creating, renaming, and deleting workspaces.
- OSC 133 / OSC 7 side-channel indexing for command and cwd metadata.
- Persistent settings for theme, font, default working directory, and custom shortcuts.
- Shell plugin management with detection, install plans, backups, rollback, and controlled writes.
- `libghostty-vt` cell-grid rendering path with a text fallback.
- AI Companion and Codex Command Capsule for Codex CLI workflows.

### Codex Command Capsule

Codex Command Capsule is the first version of ProGhostty's Codex-focused outer workflow. It is a floating input panel, not a chat sidebar.

It can:

- Open from `Cmd+Shift+I` or the AI menu.
- Accept typed input.
- Use Aliyun DashScope realtime ASR to turn speech into request text.
- Use an OpenAI-compatible `/chat/completions` API to refine casual requests into Codex-ready prompts.
- Attach a small explicit context set: workspace path, git branch, git status, changed file list, and selected terminal text.
- Send the resulting draft to Codex CLI through bracketed paste, with or without Return.

It does not:

- Maintain long-term chat memory per directory.
- Automatically observe or parse Codex output.
- Use private Codex protocols.
- Automatically send commands to the terminal.
- Upload full file contents or full terminal history by default.

Configuration lives under `AI Companion` in Settings:

- `DashScope API Key`: used for Aliyun realtime ASR.
- `OpenAI Base URL`: OpenAI-compatible API base URL, defaulting to `https://api.openai.com/v1`.
- `OpenAI API Key`: used for prompt refinement.
- `OpenAI Model`: model name used for prompt refinement.

OpenAI-compatible configuration can also be provided with environment variables:

```bash
export OPENAI_BASE_URL="https://api.openai.com/v1"
export OPENAI_API_KEY="..."
export OPENAI_MODEL="..."
```

The DashScope key can be provided through Settings, Keychain, or `DASHSCOPE_API_KEY`.

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
  ProGhosttyCore/       PTY engine, Ghostty bridge, settings, history, AI helpers
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
- Codex Command Capsule is a prompt refinement and delivery tool, not a Codex internal context synchronization system.
- AI features require user-provided API keys; cloud requests are not enabled by default.

### Roadmap

1. Continue stabilizing the `PTY -> libghostty-vt -> cell grid -> AppKit` rendering path.
2. Improve rendering fidelity, selection, and scrolling without bypassing `libghostty-vt`.
3. Refine Codex Command Capsule interaction, error handling, and configurable context packs.
4. Keep pane / session / view boundaries clean for future GhosttyKit or full Ghostty frontend integration.
5. Let shell integration and plugins own special behavior instead of hard-coding application-specific rules into terminal rendering.

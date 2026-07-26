---
name: terminal-vt-core
description: 改动 PTY 会话、libghostty-vt 桥接、终端输入、OSC/HTML 适配时使用。覆盖终端状态唯一真相源、会话协议、输出合并与输入路径。
---

# 终端 / VT 核心（Terminal & VT Core）

改任何 `TerminalCore/PTY/`、`TerminalCore/LibGhostty/`、或输入/OSC 相关代码前读本文件。

## 铁律

- **`libghostty-vt` 是终端状态唯一真相源**：光标、屏幕缓冲、scrollback、终端状态、ANSI/VT 解析全归它。
- **绝不在 `libghostty-vt` 之外解析 ANSI/VT。** Swift 侧不重新解析终端字节。
- **绝不复制**光标 / scrollback / 屏幕缓冲。想加终端相关状态前，先确认 VT 层是否已有。
- PTY 层**不**解析转义序列，只转发字节 + resize + `SIGWINCH`。

## 分层

```
zsh/vim/ssh/... → PTY（进程 + 字节）→ libghostty-vt（VT 引擎，真相源）
              → GhosttyVTBridge（唯一适配边界）→ Swift 值快照 → Renderer
```

产品代码只能依赖 `TerminalSessionManager` / `TerminalSurfaceRegistry` / 会话 ID / 值类型，**不得**依赖 `GhosttyVTBridge`、C/Zig 头文件、GhosttyKit 类型。

## PTY 域

- `PTYTerminalEngine`（`PTY/PTYTerminalEngine.swift:199`）— 同时实现 `TerminalSessionManager` + `TerminalSurfaceRegistry`，是 PTY I/O 与会话生命周期的 owner。
- `PTYTerminalSessionManager`（同文件:302）— 会话管理具体实现。
- `TerminalSessionManager`（协议，`TerminalModels.swift:57`）：`createSession / closeSession / resizeSession / writeInput / writePaste / workingDirectory / controlToken / hasForegroundProcess / events`。
- `MockTerminalEngine`（`Mock/`）— UI/数据层可脱离真实 PTY 开发；保持它可用。
- `PTYTerminalSurfaceRegistry` — 把会话映射到 NSView / 渲染表面。

## VT 桥接域

- `GhosttyVTBridge`（`LibGhostty/GhosttyVTBridge.swift`）— **唯一** libghostty-vt 适配边界。`write` 喂字节；`frame()` / `scrollFrame(overscanTop:overscanBottom:)` / `scrollbar` 出快照；`scrollViewport` 移动权威视口。它拥有 VT 交互，别在别处调 C API。
- `GhosttyHTMLAttributedAdapter` — 把 VT HTML 输出转 `NSAttributedString`（文本回退用）。
- `HTMLPaletteNormalizer`（纯字符串/正则，无 AppKit）— 把 `var(--vt-palette-N)` + `<style>` 改写成具体 `rgb(...)`，幂等。放在 VT 层而非 AppKit 适配层。

## 输出合并（两级）

`PTY 字节 → TerminalOutputBatchCoordinator（合并原始字节）→ TerminalOutputCoordinator（合并 render 快照）→ 渲染`。两级共分一个 8ms 预算（各 4ms，`pipelineStageDelayNanoseconds`），交互回显走 `.immediate` 绕过两级。改输出延迟/合并时保持这个预算划分，别让字节→像素最坏延迟翻倍。

## 输入路径

- `TerminalInputStateMachine`（`TerminalCore/`）— 输入状态机（纯逻辑，**不该** import AppKit）。
- 输入/粘贴/激活/链接 handler 经 `TerminalSurfaceRegistry.set*Handler(...)` 注入。
- ⚠️ 已删除：`TerminalInputRouter`、`LibGhosttyTerminalEngine`。老文档提到它们即过期。

## 数据流（真实类型）

```
PTY 字节
  → PTYTerminalEngine 读出
  → GhosttyVTBridge.write → libghostty-vt（解析 + 维护全部终端状态）
  → PTYTerminalSurfaceRegistry.render → GhosttyVTBridge.frame/scrollFrame
  → GhosttyTerminalFrame / TerminalRenderFrame（不可变值）
  → 渲染后端
事件（output/osc/bell/cwd/title）→ TerminalEvent（AsyncStream）→ App 层
```

## 禁止

- ❌ 在 VT 层外解析 ANSI/VT，或用 prompt 字符（`$`/`%`/`❯`）猜命令边界（用 OSC 133/7 语义事件）。
- ❌ 复制光标/scrollback/屏幕缓冲状态。
- ❌ 绕过 `TerminalSessionManager` 直接碰 PTY。
- ❌ 产品/UI 代码直接 import Ghostty C/Zig 头文件或调 C API（只经 `GhosttyVTBridge`）。
- ❌ 在 `TerminalInputStateMachine` 引 AppKit。

## 深入参考

`CLAUDE.md`（产品方向与核心原则）、`docs/architecture/ownership-map.md`（职责归属）、`docs/libghostty-vt.md`（vendored 构建）、`docs/architecture/ghostty-html-compatibility.md`。测试：`GhosttyVTBridgeTests`、`OscParserTests`、`PTYLaunchTests`、`TerminalInputStateMachineTests`、`GhosttyHTMLAttributedAdapterTests`。

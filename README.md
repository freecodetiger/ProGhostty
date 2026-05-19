# ProGhostty

ProGhostty 是一个面向真实 shell 工作流的 macOS 原生终端。

它不是 IDE，不是 shell 替代品，也不是一套封闭的命令环境。ProGhostty 把终端本身作为第一公民：你的 shell、dotfiles、prompt、补全、插件和 TUI 工具，都应该继续以正常终端生态的方式运行。

它的产品方向是克制的：Ghostty 风格的纯终端界面、真实 PTY 会话、由 `libghostty-vt` 负责终端语义、丝滑 scrollback、分屏、工作区、设置和插件管理。

> ProGhostty 不是 Ghostty 官方版本，也不隶属于 Ghostty 项目。它 vendor 了 Ghostty 源码，并使用 `libghostty-vt` 作为终端语义层。

## 下载

从 GitHub Releases 下载最新 DMG：

https://github.com/freecodetiger/ProGhostty/releases/latest

当前 DMG 使用 ad-hoc 签名。macOS 可能会提示开发者无法验证，这是当前阶段的预期行为。如果系统阻止打开，可以在 Finder 中右键应用，然后选择“打开”。

ProGhostty 会在启动时检查更新，也可以在设置里手动检查更新。当 GitHub Release 有新版本时，窗口 titlebar 会出现一个更新提示气泡；点击后会打开 release 页面，由用户下载新的 DMG 覆盖安装。

## 为什么做 ProGhostty

很多终端实验项目会不断往 shell 外面堆 UI，最后终端本身反而变成了一个被包裹的执行窗口。ProGhostty 选择相反方向。

终端本身才是产品。工作区、分屏、插件管理和设置只是围绕终端的辅助能力。它们不应该接管 shell，不应该重写用户配置，也不应该为了某个具体程序在渲染层做硬编码特判。

ProGhostty 希望尽可能贴近现有终端生态：

- `.zshrc`、alias、补全、prompt、shell 插件和 TUI 程序继续由用户的 shell 环境拥有。
- 终端交互来自真实 PTY，而不是自定义命令解释器。
- VT 解析、光标、样式、scrollback 和终端网格状态交给 `libghostty-vt`。
- 产品能力放在终端核心之外。
- Codex、Claude Code、vim、tmux、fzf、htop 等工具应该从同一套终端路径中受益，而不是依赖 app-name-specific 的 UI hack。

## 核心体验

### 丝滑 Scrollback

ProGhostty 把 scrollback 的手感当成终端体验的一部分，而不是附属细节。

普通 scrollback 使用基于 overscan 的像素级滚动路径：

```text
libghostty-vt viewport + overscan rows
  -> AppKit cell-grid renderer
  -> sub-row visual offset
  -> row commits back to the libghostty viewport
```

这不是 UI 层伪造一个独立 scroll state。真实 viewport 仍然由 `libghostty-vt` 拥有，UI 只在有真实 overscan 行的前提下做一行以内的视觉余量，因此 scrollback 可以比传统“一行一跳”的桌面终端更顺滑。

在 alternate screen / TUI 程序中，滚轮输入优先交给程序本身。终端语义正确和 TUI 稳定性优先于视觉技巧。

### 真实终端会话

每个 pane 都对应一个独立 PTY session。分屏会创建新的 shell 进程；关闭 pane 只释放当前 pane 对应的 session，不影响其他分屏。

当前运行路径是：

```text
forkpty shell
  -> PTY output bytes
  -> GhosttyVTBridge
  -> libghostty-vt
  -> cell-grid snapshot
  -> AppKit renderer
```

### Ghostty 驱动的终端语义

ProGhostty 不在 UI 层重新解释终端输出。终端里最复杂、最容易出错的部分放在 `GhosttyVTBridge` 后面：

- ANSI / VT 解析
- 光标状态
- 样式属性
- scrollback 状态
- viewport 状态
- cell-grid snapshot

当前 renderer 是由 `libghostty-vt` snapshot 驱动的 AppKit cell-grid renderer。它不是完整 Ghostty macOS renderer；Ghostty 相关能力被明确封装在 bridge 边界后面，方便后续继续演进。

## 工作流能力

### 分屏

在终端 pane 中右键，可以进行向右分屏、向下分屏、关闭当前 pane、复制、粘贴、打开工作区和打开设置。

分屏由 split tree 管理。Pane、session、view 三层解耦，因此关闭一个 pane 不会误删其他 session。

### 工作区

工作区用于组织独立终端布局，但不会在主界面放置显眼 tab 或常驻侧边栏。

- App 可以同时存在多个 workspace。
- 每个 workspace 拥有独立 split tree 和 terminal sessions。
- 当前窗口一次只显示 active workspace。
- 非当前 workspace 的 sessions 默认保持运行。
- Workspace switcher 通过快捷键或右键菜单呼出。

### 插件管理

插件管理面向 shell 生态，而不是试图替代 shell 生态。

它可以扫描和安装一组克制的 shell 工具，生成安装计划，在修改文件前备份，并把 ProGhostty 管理的 shell 配置写入：

```text
~/.your-terminal/shell/
```

如果必须触碰 `.zshrc`，ProGhostty 只插入 guarded source block，不会把大量插件配置直接写进用户 dotfiles。

### 设置

设置会持久化到本地，目前包括：

- 浅色、深色、跟随系统
- 字体和字号
- 默认 shell
- 默认工作目录
- 软件语言
- 自定义快捷键
- 插件管理入口
- 检查更新

## 项目状态

ProGhostty 仍然是早期 macOS 原生终端。它已经可以真实交互，但当前最重要的工作仍然是终端正确性和渲染稳定性。

优先级是：

1. 终端语义正确。
2. PTY 和 `libghostty-vt` 状态一致。
3. TUI 程序稳定。
4. 滚动、选择、resize 和渲染体验尽量自然、安静、原生。
5. 产品能力不污染终端核心。

## 从源码构建

要求：

- macOS 13 或更新版本
- Swift 6.1 工具链
- Git submodule 支持
- Zig 0.15.2，用于构建 vendored Ghostty 的 `libghostty-vt`
- 如果需要生成 `ghostty-vt.xcframework`，需要完整 Xcode

初始化 submodule：

```bash
git submodule update --init --recursive
```

从 vendored Ghostty 源码构建 `libghostty-vt`：

```bash
cd Vendor/ghostty
../../.tools/zig-aarch64-macos-0.15.2/zig build \
  --global-cache-dir ../../.zig-cache-global \
  -Demit-lib-vt=true
```

构建并运行：

```bash
swift build
swift run ProGhostty
```

构建 macOS app bundle：

```bash
scripts/build-app-bundle.sh release
```

运行测试：

```bash
swift test --no-parallel
```

## 项目结构

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

## 技术备注

- 当前每个 session 的 scrollback 默认保留 10,000 行。
- 主 renderer 是 `GhosttyVTCellGridRendererBackend`。
- Text / HTML fallback 仍然存在，但主终端路径是 AppKit cell-grid renderer。
- 普通 scrollback 可以使用 overscan-backed pixel scrolling。
- alternate screen 程序接收滚轮输入，不强行套用 ProGhostty scrollback。
- 当前没有嵌入完整 Ghostty macOS renderer。

## English Summary

ProGhostty is an early native macOS terminal focused on real shell workflows, Ghostty-powered terminal semantics, and smooth scrollback.

It uses real PTY sessions, routes terminal bytes through `libghostty-vt`, and renders a native AppKit cell grid. Product features such as split panes, workspaces, settings, update checks, and plugin management are built around the terminal rather than replacing the user's shell ecosystem.

ProGhostty is not an official Ghostty release. It vendors Ghostty source code and keeps Ghostty integration behind a bridge so the terminal core can evolve without coupling product UI to unstable internals.

Download the latest DMG:

https://github.com/freecodetiger/ProGhostty/releases/latest

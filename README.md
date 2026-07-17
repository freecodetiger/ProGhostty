# ProGhostty

[![Release](https://img.shields.io/github/v/release/freecodetiger/ProGhostty?sort=semver)](https://github.com/freecodetiger/ProGhostty/releases/latest)
[![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-black)](Package.swift)
[![Swift](https://img.shields.io/badge/Swift-6.1-orange)](Package.swift)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

ProGhostty 是一个原生 macOS 终端，目标是把 Ghostty 的终端语义和更适合开发者日常工作的交互层结合起来。

它不是一个重新发明 Shell 的工具。你的 zsh、dotfiles、prompt、补全、tmux、vim、fzf、htop、Codex、Claude Code 和其它 TUI 工具，仍然沿着真实 PTY 和正常终端输入输出路径运行。

> ProGhostty 不是 Ghostty 官方版本，也不隶属于 Ghostty 项目。本仓库 vendored Ghostty，并使用 `libghostty-vt` 作为终端语义层。

## 亮点

- **Ghostty 终端语义**：底层接入 `libghostty-vt`，终端状态、样式、光标、滚动视口等语义尽量交给真正的 VT 层处理。
- **面向 Codex / AI TUI 的阅读体验**：滚动历史时不会轻易被新输出拉回底部，适合长上下文、长回答、长日志的阅读和继续输入。
- **旁路输入框**：每个 pane 都可以用快捷键呼出自己的轻量输入框，在浏览历史记录时输入命令或 prompt，不打断当前预览位置；回车后按粘贴语义落到真实终端。
- **真实终端 Shift+Enter 换行**：在 Codex 等 TUI 中可以直接输入多行内容，普通 Enter 仍保持回车行为。
- **分屏和工作区**：支持多 pane、多工作区、独立 split tree 和长时间运行的终端会话。
- **路径友好交互**：拖拽文件或文件夹到 pane 会解析为绝对路径；Cmd+点击文件路径会定位到访达。
- **titlebar 更有用**：右侧显示当前工作区，中间显示当前聚焦 pane 的目录；鼠标悬停时可展开为绝对路径，长路径会保留首尾并在中间省略。
- **克制的 macOS 原生体验**：SwiftUI + AppKit 实现，尽量保持安静、直接、可预测，不接管你的 Shell 生态。

## 下载

从 GitHub Releases 下载最新版 DMG：

<https://github.com/freecodetiger/ProGhostty/releases/latest>

当前 DMG 使用 ad-hoc 签名。macOS 可能提示无法验证开发者；如果被系统拦截，请在 Finder 中右键应用并选择“打开”。

ProGhostty 会在启动时或设置中检查更新。发现新版本时，titlebar 会显示更新提示，点击后打开对应 Release 页面。

## 当前状态

ProGhostty 仍处于早期阶段，但已经可以用于真实 PTY 会话和日常开发试用。当前优先级是：

1. 终端语义正确性。
2. PTY、resize、scrollback 和 renderer 稳定性。
3. Codex、Claude Code 等 TUI 的输入、滚动和粘贴体验。
4. 不侵入用户已有 Shell 配置的产品增强能力。

## 功能概览

- 原生 macOS app，使用 Swift、SwiftUI 和 AppKit。
- 真实 PTY session，每个 pane 对应独立 Shell 进程。
- 基于 `libghostty-vt` 的 VT 解析、cell state、样式、光标和 viewport 语义。
- AppKit cell-grid renderer，使用 Ghostty VT snapshot 渲染。
- 支持 overscan 的像素级 scrollback。
- 分屏、工作区、工作区恢复和独立焦点管理。
- 设置项覆盖外观、字体、Shell、工作目录、语言、快捷键、插件管理和更新检查。
- Shell 插件管理支持预览、备份和受控配置块，不直接接管 dotfiles。
- `pg` helper executable，用于 Shell 侧集成。

## 从源码构建

要求：

- macOS 14 或更新版本
- Swift 6.1 toolchain
- Git submodule 支持
- Zig 0.15.2，用于构建 vendored Ghostty `libghostty-vt`
- 生成 `ghostty-vt.xcframework` 或 app bundle 时需要完整 Xcode

拉取 submodules：

```bash
git submodule update --init --recursive
```

构建 vendored Ghostty VT library：

```bash
cd Vendor/ghostty
../../.tools/zig-aarch64-macos-0.15.2/zig build \
  --global-cache-dir ../../.zig-cache-global \
  -Demit-lib-vt=true \
  -Demit-xcframework=false \
  -Doptimize=ReleaseFast
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

## 架构

ProGhostty 把 Ghostty 集成封装在桥接层后面，让 UI 和产品代码不直接依赖 Ghostty 内部实现。

```text
forkpty shell
  -> PTY output bytes
  -> GhosttyVTBridge
  -> libghostty-vt
  -> cell-grid snapshot
  -> AppKit renderer
```

终端核心负责 PTY 生命周期、resize、输入路由和 renderer snapshot。工作区、设置、插件管理、更新检查、旁路输入框等产品功能围绕终端核心构建，而不是塞进 parser 或 renderer。

## 仓库结构

```text
Sources/
  ProGhosttyApp/        macOS app、SwiftUI/AppKit UI、窗口、工作区
  ProGhosttyCore/       PTY engine、Ghostty bridge、renderer、设置、插件
  ProGhosttyGhosttyVT/  libghostty-vt 的 C 边界
  ProGhosttyPTY/        forkpty、resize、wait C helpers
  ProGhosttyPG/         Shell 侧 helper command

Tests/
  ProGhosttyCoreTests/  终端、renderer、workspace、settings、update tests

Vendor/
  ghostty/              vendored Ghostty source

docs/
  architecture/         终端架构说明
```

## 设计原则

- 不替代用户的 Shell。
- 不在产品 UI 中用字符串硬猜终端输出，终端语义应留在 VT 层。
- 不为某个特定 TUI 写死 hack，但优先保证真实开发工具的体验。
- 增强工作流必须可选、可降级。
- 优先选择原生 macOS 交互、安静 UI 和可预测的终端行为。

## 参与贡献

欢迎提交 Issue 和 Pull Request。对于较大的改动，请说明：

- 用户可见的问题是什么；
- 涉及哪些终端行为；
- 如何测试；
- 是否触及 PTY、`libghostty-vt`、renderer、workspace、settings 或 plugin-management 代码。

提交 PR 前请运行：

```bash
swift test --no-parallel
```

## License

ProGhostty 使用 [MIT License](LICENSE)。

Vendored Ghostty source code 保持其自身 MIT license，见 [`Vendor/ghostty/LICENSE`](Vendor/ghostty/LICENSE)。

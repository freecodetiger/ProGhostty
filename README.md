# ProGhostty

ProGhostty 是一个 macOS 原生终端实验项目。它的定位不是把 shell 重新包装成一套自定义 UI，而是在真实 PTY 和现有 shell 生态之上，逐步接入 Ghostty 的终端核心能力。

当前实现仍是 MVP：运行路径以 `PTYTerminalEngine` 为主，PTY 输出会进入 `GhosttyVTBridge` / `libghostty-vt`，界面层暂时使用 AppKit 文本表面渲染。完整 GhosttyKit 或完整 libghostty macOS 前端集成会继续放在适配层之后研究。

## 核心原则

- 终端必须是真实 shell：继承 `.zshrc`、alias、补全、prompt、shell plugin 和用户已有工作流。
- PTY 负责连接 shell / 程序，`libghostty-vt` 负责解释 PTY 字节流并维护终端状态。
- UI 层只负责产品能力：分屏、工作区、设置、插件管理和必要的窗口交互。
- 不在 UI 层猜测 prompt，不解析 `$`、`%`、`❯` 等提示符，不自造命令行语义。
- shell integration 和插件能力应通过现有生态接入，而不是硬编码到终端渲染层。
- Ghostty 相关 API 必须封装在 bridge / adapter 后面，避免产品层直接依赖不稳定接口。

## 当前架构

```text
SwiftUI / AppKit UI
  -> Workspace / Split / Settings / Plugins / History
  -> TerminalEngine
  -> PTYTerminalEngine
  -> forkpty shell
  -> GhosttyVTBridge
  -> libghostty-vt
```

相关设计文档：

- `docs/architecture/terminal-core-positioning.md`
- `docs/libghostty-vt.md`

## 已实现能力

- 基于 PTY 的真实 shell 交互。
- 每个 pane 对应独立 terminal session。
- split tree 管理分屏布局，关闭 pane 只释放对应 session。
- 多 workspace 并存，非当前 workspace 的 session 默认保持运行，只 detach UI。
- workspace switcher 负责切换、创建、重命名和删除工作区。
- OSC 133 / OSC 7 作为 side-channel 记录命令和 cwd 信息。
- 设置持久化，支持主题、字体、默认工作目录和自定义快捷键。
- shell 插件管理支持扫描、安装计划、备份、回滚和受控写入。

## libghostty-vt

Ghostty 源码作为 submodule 放在 `Vendor/ghostty`：

```bash
git submodule update --init --recursive
```

从 `Vendor/ghostty` 目录构建 VT 库：

```bash
../../.tools/zig-aarch64-macos-0.15.2/zig build \
  --global-cache-dir ../../.zig-cache-global \
  -Demit-lib-vt=true \
  -Demit-xcframework=true
```

当前 Ghostty 构建依赖 Zig `0.15.2`。SwiftPM 直接链接：

```text
Vendor/ghostty/zig-out/lib/libghostty-vt.a
```

如果该文件不存在，需要先重新构建 `libghostty-vt`。`ghostty-vt.xcframework` 生成依赖完整 Xcode，因为 Ghostty 会调用 `xcodebuild -create-xcframework`。

## 构建和运行

```bash
git submodule update --init --recursive
swift build
swift run ProGhostty
```

命令行辅助工具：

```bash
swift run pg -- help
```

测试：

```bash
swift test --no-parallel
```

## 项目结构

```text
Sources/
  ProGhosttyApp/        macOS 应用、窗口、分屏、工作区、设置界面
  ProGhosttyCore/       PTY engine、Ghostty bridge、历史、插件、设置
  ProGhosttyGhosttyVT/  Ghostty VT C 边界
  ProGhosttyPTY/        forkpty / resize / wait C 辅助层
  ProGhosttyPG/         shell-facing helper

Tests/
  ProGhosttyCoreTests/

Vendor/
  ghostty/
```

## 当前限制

- 渲染仍是临时 AppKit 文本表面，还不是完整 Ghostty 原生渲染器。
- `LibGhosttyTerminalEngine` 仍是占位边界，当前真实运行路径是 `PTYTerminalEngine`。
- `libghostty-vt` 需要从 vendored Ghostty 源码本地构建。
- 完整 GhosttyKit / macOS frontend 链接方式仍需继续研究。

## 下一步方向

1. 稳定 PTY + `libghostty-vt` 的真实交互链路。
2. 在不污染产品层的前提下提升渲染还原度。
3. 继续保持 pane / session / view 解耦。
4. 让插件和 shell integration 承担特殊能力，而不是把功能硬塞进 UI。

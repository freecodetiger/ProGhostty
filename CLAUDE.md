# ProGhostty · AI 开发指南

> 本文件是 Agent 进入项目的**唯一入口**，只放最高优先级规则。
> 渲染管线、VT 边界、工作区、性能等细节在 `.claude/skills/` 和 `docs/`，用到时再查。
> 规则与代码冲突时，**以代码为准**，并在此更新本文件。

---

## 项目目标（Project Goal）

ProGhostty 是原生 macOS 终端：把 Ghostty 的终端语义（`libghostty-vt`）和更适合开发者、AI CLI（Codex / Claude Code）日常工作的交互层结合起来。

它**不重新发明 Shell**。用户的 zsh、dotfiles、prompt、tmux、vim、fzf 仍沿真实 PTY 和正常终端 I/O 路径运行。

优先级排序（发生冲突时按此裁决）：

```
终端语义正确性  >  架构边界清晰  >  性能/流畅  >  功能  >  代码风格
```

---

## 核心原则（Core Principles · 不可违反）

- **`libghostty-vt` 是终端状态的唯一真相源**：光标、屏幕缓冲、scrollback、终端状态、ANSI/VT 解析。**绝不**在别处复制或重新维护这些状态。
- **绝不在 `libghostty-vt` 之外解析 ANSI/VT。** Swift 侧不重新解析终端字节，只消费 VT 层产出的快照 / render state。
- **Renderer 只渲染。** 它读不可变快照（`GhosttyTerminalFrame` / `TerminalRenderFrame`）画像素，不拥有终端状态、不解析 ANSI、不管光标语义、不直接碰 PTY。
- **职责链自上而下，禁止回指：** `App → Core`，`Workspace → Session → PTY → libghostty-vt → Renderer`。
- **`ProGhosttyCore` 绝不 `import SwiftUI`**；Core 里 `AppKit` 只允许出现在渲染/视图层。（由 `scripts/check-architecture.sh` 守卫。）
- **不要重新发明架构，扩展现有架构。** 这是本项目对 AI 最重要的一条约束（见下）。

---

## 真实职责边界（Architecture Boundaries · 已读代码验证）

数据流水线（真实类型名）：

```
PTY 字节
  → PTYTerminalEngine（拥有 PTY 进程 / I/O，实现 TerminalSessionManager）
  → GhosttyVTBridge.write → libghostty-vt        （唯一真相源）
  → PTYTerminalSurfaceRegistry.render
  → GhosttyVTBridge.frame / scrollFrame → TerminalRenderFrame（不可变快照）
  → TerminalRendererPolicy 选后端
  → MetalDirectRendererBackend  或  GhosttyVTCellGridRendererBackend  或 文本回退
```

唯一 owner（改代码前先确认你没有在别处复制这些职责）：

| 关注点 | 唯一 owner | 位置 |
|---|---|---|
| PTY I/O · 会话生命周期 | `PTYTerminalEngine`（实现 `TerminalSessionManager`） | `TerminalCore/PTY/` |
| VT 语义 / 终端状态 | `GhosttyVTBridge` → `libghostty-vt` | `TerminalCore/LibGhostty/` |
| 渲染后端选择 | `TerminalRendererPolicy` | `TerminalCore/Renderer/` |
| 渲染（画像素） | `MetalDirectRendererBackend` / `GhosttyVTCellGridRendererBackend` | `TerminalCore/Renderer/` |
| 像素滚动余量 | `PaneScrollCoordinator` + `ScrollCommitCoordinator`（收敛中，见 skill） | `TerminalCore/Renderer/` |
| 工作区运行时状态 | `PaneWorkspaceController` | `Workspace/` |
| App 协调 / 视图模型 | `AppModel`（瘦身中） | `ProGhosttyApp/UI/` |

App 层只依赖 Core 的**协议 + 值类型**：`TerminalSessionManager`、`TerminalSurfaceRegistry`、`TerminalSessionID`、`TerminalEvent`、`WorkspaceLayout`。**不得**依赖 `GhosttyVTBridge`、C/Zig 头文件、或具体后端类型。

> 完整责任表 + 分层图：`docs/architecture/ownership-map.md`
> 各域深入细节：`.claude/skills/`（rendering-pipeline / terminal-vt-core / workspace-domain / performance-invariants）

---

## 改代码前的工作流（Development Workflow）

1. **理解架构与数据流** —— 先读上面的边界表；跨模块改动读对应 skill。
2. **找到唯一 owner** —— 这个职责归谁？我要改的状态谁拥有？
3. **绝不引入重复状态** —— 终端最容易出现两个光标 / 三份 scrollback。想加状态前，先确认 `libghostty-vt` 是否已有。
4. **守住模块边界** —— 不跨层回指、不在 Core 引 SwiftUI、不在 Renderer 解析 ANSI。
5. **扩展而非重写** —— 复用现有抽象，不建平行实现。
6. **构建 + 全量测试**（见下），保持绿。
7. **说明你为什么这么改** —— 尤其涉及边界/状态归属时。

---

## 禁止事项（Forbidden · Never）

- ❌ 在 `libghostty-vt` 之外解析 ANSI/VT。
- ❌ 复制光标状态 / scrollback / 屏幕缓冲（真相源只有 `libghostty-vt`）。
- ❌ Renderer 拥有或修改终端状态、直接访问 PTY。
- ❌ 每帧重建 `NSAttributedString` / 重绘整个视口（用脏行 + cell diff，见性能 skill）。
- ❌ 在 render loop 里做分配 / O(n²) 扫描。
- ❌ 绕过 `TerminalSessionManager` 直接操作 PTY，或绕过 `PaneWorkspaceController` 改工作区状态。
- ❌ `ProGhosttyCore` 里 `import SwiftUI`；在非渲染/视图文件里 `import AppKit`。
- ❌ **未被明确要求就重新设计架构 / 渲染管线 / 降级梯。**

---

## 偏好模式（Preferred）

- 组合优于继承 · 不可变快照优于共享可变状态 · 状态机优于散落 flag。
- 依赖注入（组合根装配）优于类内部 `new` 协作者。
- 小模块 · 纯值类型（可测）· 面向协议优于面向具体类。
- 增量更新 / 缓存优于全量重算。

---

## 构建与测试（Build & Test）

Swift 6.1 · macOS 13+ · 语言模式 `.v6` · 测试用 **swift-testing**（`import Testing`，非 XCTest）。

```bash
swift build            # 构建（依赖 libghostty-vt 已 vendored 构建，见 docs/libghostty-vt.md）
swift test             # 全量测试（31 个测试文件，纯值类型/reducer 有直接覆盖）
scripts/check-architecture.sh   # 分层守卫：Core 无 SwiftUI；AppKit 仅限渲染/视图层
```

改动后：`swift build` + `swift test` + `check-architecture.sh` 三者全绿再收工。首次构建 libghostty-vt 见 `docs/libghostty-vt.md`。

> ⚠️ **libghostty-vt 必须用 `-Doptimize=ReleaseFast` 构建**（`Vendor/ghostty/zig-out/lib/libghostty-vt.a`，Package.swift 直接链接）。缺了它 Zig 默认 Debug 模式，`ghostty_terminal_vt_write` 慢上千倍，`seq 1 30000` 会长时间卡住 UI。`swift build` **不会**重建这个 `.a`（vendored 手工产物）。排查"输出/scrollback 慢"时，先确认这个 `.a` 是 ReleaseFast。重建命令见 `docs/libghostty-vt.md`。

### 🔁 在应用里手测改动的标准流程（每次照做，别跳步）

`swift build` 只更新裸二进制 `.build/<triple>/<config>/ProGhostty`；**`.app` bundle 内的二进制是另一份，只有 `build-app-bundle.sh` 才刷新**。多次误判（设置界面"回退"、探针无效、性能测到旧代码）都因启动了 stale bundle。手测前**必做**：

```bash
# 1) 确认 libghostty-vt 是 ReleaseFast（若刚 clean 过 / 不确定就重建，见 docs/libghostty-vt.md）
strings Vendor/ghostty/zig-out/lib/libghostty-vt.a | grep -ciE "index out of bounds|reached unreachable"  # ReleaseFast≈0-2，Debug 很多

# 2) 打包 bundle（release 手测性能，debug 带探针）——不是 swift build！
./scripts/build-app-bundle.sh release

# 3) 验证 bundle 二进制比最后一次源码编辑新
stat -f "%Sm" .build/arm64-apple-macosx/release/ProGhostty.app/Contents/MacOS/ProGhostty

# 4) 杀旧进程再启动 bundle 内二进制
pkill -f "ProGhostty.app/Contents/MacOS/ProGhostty"
PROGHOSTTY_RENDER_DEBUG=1 .build/arm64-apple-macosx/release/ProGhostty.app/Contents/MacOS/ProGhostty &
```

加的日志/探针没出现 → 先怀疑 stale bundle，再怀疑代码路径。

---

## 现状备注（避免踩到过期文档）

- 项目正按 `.claude/ARCHITECTURE_PLAN.md` 增量重构（拆 `AppModel` / `PTYGridView`、收敛像素滚动）。骨架健康，**不重写**。
- 已删除的旧类型：`LibGhosttyTerminalEngine`、`TerminalInputRouter`、`WorkspaceManager`、`WorkspaceTemplate`。部分老文档（`guide.md`、`docs/architecture/terminal-core-positioning.md`）仍提到它们——**以当前代码和本文件为准**。

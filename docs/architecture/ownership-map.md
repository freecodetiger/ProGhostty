# 架构职责归属图（Ownership Map）

> 目的：为 Agent 和维护者提供**已读代码验证**的单一 owner 表与分层规则，防止终端项目最常见的"状态被复制、边界被绕过"漂移。
> 与 `.claude/ARCHITECTURE_PLAN.md` 的关系：那份是"怎么演进"的路线图；本文件是"当前边界是什么"的事实快照。冲突时以代码为准。

## 分层与依赖方向

依赖只允许自上而下，禁止回指：

```
┌─────────────────────────────────────────────────────────────┐
│ App 层 (ProGhosttyApp) —— SwiftUI + AppKit 宿主               │
│   AppModel（协调 + 视图模型）· RootView/* · 窗口 chrome/外观    │
│   只依赖 Core 的协议 + 值类型                                   │
└───────────────▲─────────────────────────────────────────────┘
                │  TerminalSessionManager / TerminalSurfaceRegistry
                │  TerminalSessionID / TerminalEvent / WorkspaceLayout
┌───────────────┴─────────────────────────────────────────────┐
│ Core 层 (ProGhosttyCore) —— 不 import SwiftUI                 │
│  Terminal 域: PTY 会话 · GhosttyVTBridge · 渲染后端三层梯       │
│  Workspace 域: PaneWorkspaceController（唯一 owner）           │
│  Settings · Plugins · Control(OSC) · Persistence · Updates    │
└───────────────┬─────────────────────────────────────────────┘
                │  ProGhosttyGhosttyVT (C shim) / ProGhosttyPTY (C shim)
                ▼
        libghostty-vt (Zig) —— 终端状态唯一真相源
```

模块（`Package.swift`）：

- `ProGhosttyCore`（library）— 依赖 `ProGhosttyGhosttyVT`、`ProGhosttyPTY`；链接 `sqlite3`。
- `ProGhosttyApp`（executable）— 依赖 `ProGhosttyCore`。
- `ProGhosttyPG`（executable，`pg` helper）— 依赖 `ProGhosttyCore`。
- `ProGhosttyGhosttyVT` / `ProGhosttyPTY` — C shim，暴露 `include/`。
- 测试：`ProGhosttyCoreTests`、`ProGhosttyAppTests`（swift-testing）。

## 四条分层准则（所有改动的验收标准）

1. **Core 不 `import SwiftUI`**（`scripts/check-architecture.sh` 守卫）。
2. **Core 中 `AppKit` 只出现在渲染/视图层**（守卫白名单：`TerminalCore/Renderer|PTY|LibGhostty|Mock`、`TerminalModels.swift`、`TerminalSurfaceStyle.swift`；`Settings/AppSettings.swift` 是已记录的待偿技术债）。
3. **每个"关注点"有唯一 owner 类型**（见下表）。
4. **依赖通过组合根注入**，而非类内部 `new` 出协作者。

## 唯一 owner 表（已验证）

| 关注点 | 唯一 owner | 位置 | 状态 |
|---|---|---|---|
| PTY I/O · 进程生命周期 | `PTYTerminalEngine`（实现 `TerminalSessionManager` + `TerminalSurfaceRegistry`） | `TerminalCore/PTY/PTYTerminalEngine.swift` | ✅ |
| 终端会话管理协议 | `TerminalSessionManager`（协议）；Mock 为 `MockTerminalEngine` | `TerminalCore/TerminalModels.swift:57` | ✅ |
| VT 语义 / 终端状态 / ANSI 解析 | `GhosttyVTBridge` → `libghostty-vt` | `TerminalCore/LibGhostty/GhosttyVTBridge.swift` | ✅ |
| 渲染后端选择 | `TerminalRendererPolicy` | `TerminalCore/Renderer/TerminalRendererPolicy.swift` | ✅ |
| 渲染（画像素，Metal 直渲） | `MetalDirectRendererBackend` + `MetalDirectRenderEngine` | `TerminalCore/Renderer/` | ✅ |
| 渲染（AppKit cell-grid 回退） | `GhosttyVTCellGridRendererBackend` | `TerminalCore/Renderer/` | ✅ |
| 渲染诊断（Metal 专属字段） | `MetalDirectDiagnostics` 子结构 | `TerminalCore/Renderer/MetalDirectDiagnostics.swift` | ✅ 已拆分 |
| 像素滚动物理余量 | `PaneScrollCoordinator` | `TerminalCore/Renderer/` | ⚠️ 计划收敛到 `PaneScrollController` |
| 滚动行提交批处理 | `ScrollCommitCoordinator`（~120Hz 合并） | `TerminalCore/Renderer/` | ⚠️ 同上 |
| 输出合并（字节 + 快照两级） | `TerminalOutputBatchCoordinator` + `TerminalOutputCoordinator` | `TerminalCore/PTY/` | ✅ |
| 工作区运行时状态 | `PaneWorkspaceController` | `Workspace/PaneWorkspaceController.swift` | ✅ |
| 分屏树 reduce（纯值） | `PaneTreeReducer` | `Workspace/` | ✅ |
| 分屏比例布局（纯值） | `SplitRatioLayout` | `Workspace/` | ✅ |
| 工作区持久化（纯值） | `WorkspaceStore` | `Workspace/` | ✅ |
| App 协调 / 视图模型 | `AppModel` | `ProGhosttyApp/UI/AppModel.swift` | ⚠️ ~1632 行，拆分中 |

⚠️ 标记的项正在 `.claude/ARCHITECTURE_PLAN.md` 的计划内收敛/拆分——改到它们前先读那份计划，别把重构方向做反。

## 关键值类型（App 层与 Core 层的契约）

- `TerminalSessionID` — 会话标识（`TerminalModels.swift`）。
- `TerminalEvent` — 会话事件流（output / osc / bell / cwdChanged / titleChanged …）。
- `TerminalSessionConfig` — 启动配置（shell / cwd / env / rows / cols）。
- `GhosttyTerminalFrame` — 不可变屏幕快照：cells + 光标 + alt-screen 标志（`Sendable`/`Equatable`）。
- `TerminalRenderFrame` — 渲染帧（frame + 可选 scrollFrame）。
- `WorkspaceLayout` / `TerminalPane` / `PaneNode` — 分屏树（Codable）。

App 层只应触达以上协议与值类型。触达 `GhosttyVTBridge`、C 头文件或具体后端类型即越界。

## 已删除类型（防止踩过期文档）

以下类型在近期重构中删除，老文档仍可能提及；**它们已不存在**：

- `LibGhosttyTerminalEngine` — 被 `PTYTerminalEngine` + `GhosttyVTBridge` 取代。
- `TerminalInputRouter` — 输入路径现由 `TerminalInputStateMachine` + `TerminalSurfaceRegistry` 的 handler 承接。
- `WorkspaceManager` / `WorkspaceTemplate` — 工作区职责收敛进 `PaneWorkspaceController`。

引用了这些名字的旧文档（`guide.md`、`docs/architecture/terminal-core-positioning.md`）在这些点上已过期，以当前代码为准。

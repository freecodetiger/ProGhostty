---
name: workspace-domain
description: 改动工作区、分屏树、pane 生命周期、App 层协调 (AppModel)、或 App↔Core 分层时使用。覆盖唯一 owner、值类型分屏树与分层边界。
---

# 工作区域与 App 分层（Workspace & App Layering）

改任何 `Sources/ProGhosttyCore/Workspace/`、`Sources/ProGhosttyApp/`、或跨 App↔Core 边界的代码前读本文件。

## 铁律

- **`PaneWorkspaceController` 是工作区运行时状态的唯一 owner。** 别在别处存一份工作区/pane 状态。
- **依赖自上而下：`App → Core`，`Workspace → Session → PTY → libghostty-vt`。禁止回指。**
- **`ProGhosttyCore` 绝不 import SwiftUI**（`scripts/check-architecture.sh` 守卫）。
- **工作区不读 VT 缓冲。** 它只持 `TerminalSessionID` 和轻量元数据，不知道会话如何渲染。

## 模块结构（`Package.swift`）

- `ProGhosttyApp`（executable，SwiftUI+AppKit）→ 依赖 `ProGhosttyCore`。
- `ProGhosttyCore`（library）→ 依赖 C shim `ProGhosttyGhosttyVT` / `ProGhosttyPTY`。
- `ProGhosttyPG`（`pg` helper）→ 依赖 Core。
- Swift 6.1 · macOS 13+ · 语言模式 `.v6`。

## 工作区域

- `PaneWorkspaceController`（`Workspace/PaneWorkspaceController.swift`，`@MainActor final class`）— 唯一 owner。持 `workspaceLayouts: [WorkspaceLayout]` + `activeWorkspaceID`。依赖注入 `TerminalSessionManager` + `TerminalFocusStore`（组合根装配，不在类内 `new`）。open/split/close/rename/updatePaneCwd 都经它。
- `PaneTreeReducer`（纯值）— 分屏树 reduce / `listLeaves`。
- `SplitRatioLayout`（纯值）— 比例布局几何。
- `WorkspaceStore`（纯值）— 工作区持久化。
- 分屏树形状：`WorkspaceLayout → root: PaneNode`，`PaneNode = leaf(TerminalPane) | split(SplitPane)`，`SplitPane = axis, ratio, first, second`。`TerminalPane` 只存元数据 + `TerminalSessionID`。

这些纯值类型可测、干净——新增工作区逻辑优先做成纯函数放进 reducer/layout，而非塞进 controller 或 view。

## App 层 / AppModel

- `AppModel`（`ProGhosttyApp/UI/AppModel.swift`，~1632 行，14 个 `@Published`）— 当前兼任组合根 + 视图模型 + 事件路由。**正在按 `.claude/ARCHITECTURE_PLAN.md` 阶段 3 拆分**成一组 Feature Controller（`ConfirmationPrompts` / `TitleFormatting` / `TerminalWindowSizingController` / `PaneSplitAvailabilityController` / `NotificationPresenter` / `UtilityWindowController` / `AppComposition` / `AppearanceViewModel`）。
- 改 AppModel 前先读那份计划的抽取表，别把已规划要抽出去的职责往里加。
- 保留在 AppModel 的内核：工作区运行时状态 + 持久化、事件分发 hub `handle()`、switcher 同步、输入路由、布局快照、更新检查适配。

## App↔Core 契约

App 层**只**依赖：
- 协议：`TerminalSessionManager`、`TerminalSurfaceRegistry`。
- 值类型：`TerminalSessionID`、`TerminalEvent`、`TerminalSessionConfig`、`WorkspaceLayout`、`TerminalPane`。

App 层**不得**依赖 `GhosttyVTBridge`、C/Zig 头文件、具体渲染后端类型。

## 分层已知债务

- `TerminalWindowAppearance`（窗口 chrome/外观）目前误放在 Core，计划移到 App/UI（阶段 0）。别再往 Core 加窗口 chrome/外观类型。
- `Settings/AppSettings.swift` 因字体查询用 `NSFont`/`NSFontManager` 仍 import AppKit——是 arch guard 白名单里已记录的待偿债（阶段 5 抽 `FontCatalog`）。别以它为先例在 Core 其它地方引 AppKit。

## 禁止

- ❌ 在别处复制工作区/pane 运行时状态（绕过 `PaneWorkspaceController`）。
- ❌ 工作区/App 层直接读 VT 缓冲或调 `GhosttyVTBridge`。
- ❌ Core 里 import SwiftUI；非渲染/视图文件里 import AppKit。
- ❌ 类内部 `new` 协作者（用组合根注入）。
- ❌ 把已规划要从 AppModel 抽出的职责继续往 AppModel 堆。

## 深入参考

`docs/architecture/ownership-map.md`、`.claude/ARCHITECTURE_PLAN.md`。测试：`PaneWorkspaceControllerTests`、`PaneTreeReducerTests`、`SplitRatioLayoutTests`、`WorkspaceStoreTests`、`WorkspaceSwitcherStateTests`。

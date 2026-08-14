# ProGhostty 多窗口重构 Spec（执行底稿）

> 状态：**草稿 · 未开始执行** · 基于 2026-08-15 对 `main` 的读码验证
> 分支：`feat/multi-window`
>
> 目标：让 ProGhostty 支持 **Ghostty 式「新建窗口」** —— ⌘N 打开一个独立窗口，每个窗口有自己的一套工作区、workspace switcher、分屏、titlebar 内容；窗口间互不影响；关最后一个窗口退出。
>
> 与既有计划的关系：
> - 本 spec 是 `ARCHITECTURE_PLAN.md` **阶段 3（拆分 AppModel）的一个目标驱动切片**——它把「拆分 AppModel」的切分轴明确为 **「App 全局 vs 每窗口」**。
> - 与 `ARCHITECTURE_DEBT_SPEC.md` 的 **D2（AppModel god-object）** 共享同一块地。执行时以本 spec 的切分为准，**不要**与 debt 线重复拆分同一批字段/方法，避免两线冲突。

---

## 进度块（执行时逐条勾选）

| 步 | 内容 | 状态 |
|---|---|---|
| S0 | 抽 `AppComposition`（App 全局服务） | ⬜ 未开始 |
| S1 | 建 `TerminalWindowModel`（每窗口状态） | ⬜ 未开始 |
| S2 | 换 scene：`Window("main")` → `WindowGroup` | ⬜ 未开始 |
| S3 | 修 6 处「单窗口硬编码」为「本窗口」 | ⬜ 未开始 |
| S4 | 接 ⌘N 命令 + 翻转 `supportsMultipleTerminalWindows` | ⬜ 未开始 |

---

## 0. 目标与范围

### 0.1 用户可见行为（验收锚点）

1. ⌘N 打开**新窗口**，窗口内是一个新的默认工作区（新 PTY session，cwd = 默认工作目录）。
2. 每个窗口有自己的 titlebar 内容（标题 / 副标题 / pane 标签 / toast）、自己的 workspace switcher、自己的分屏树、自己的焦点。
3. 关闭一个窗口不影响其他窗口；`applicationShouldTerminateAfterLastWindowClosed` 已保证关最后一个窗口退出 app（无需改动）。
4. ⌘Q / 关闭最后一个窗口前的「前台进程确认」**跨所有窗口聚合**（现在只查单窗口，见 §1.6）。

### 0.2 明确不做（YAGNI · 边界）

- ❌ 不做跨窗口迁移工作区 / session reparent（session 永远归属一个窗口，见 §2.1）。
- ❌ 不做「⌘⇧N 复制当前工作区到新窗口」（后续可加，非本 spec）。
- ❌ 不做窗口位置/帧持久化恢复（`WindowGroup` 自带 macOS 窗口恢复）。
- ❌ 不改渲染层 / VT 层 / 工作区纯值层（`PaneTreeReducer` / `SplitRatioLayout` / `WorkspaceStore` 保持现状）。

---

## 1. 现状确诊：为什么现在做不了

核心一句话：**`AppModel` 把「App」和「窗口」两个概念焊死，`activeWorkspaceID` 是全局的，视图层只渲染「那一个」窗口。**

### 1.1 AppModel 是单例 + 组合根 + 视图模型（`Sources/ProGhosttyApp/UI/AppModel.swift`，1778 行）

| 锚点 | 内容 | 归类 |
|---|---|---|
| [AppModel.swift:11](../Sources/ProGhosttyApp/UI/AppModel.swift) | `static weak var shared: AppModel?` | App 全局单例（AppDelegate 用） |
| [:51](../Sources/ProGhosttyApp/UI/AppModel.swift) | `@Published var workspaceRuntimes: [WorkspaceRuntime]` | **每窗口**状态 |
| [:52](../Sources/ProGhosttyApp/UI/AppModel.swift) | `@Published var activeWorkspaceID: UUID?` | **每窗口**状态（全局唯一） |
| [:104–116](../Sources/ProGhosttyApp/UI/AppModel.swift) | `sessionManager` / `surfaceRegistry` / `paneWorkspaceController` / `focusStore` / `workspaceStore` / `settingsStore` / `utilityWindows` | 混排：前半**App 全局**，`focusStore` **每窗口** |
| [:175–179](../Sources/ProGhosttyApp/UI/AppModel.swift) | init 里 `new` 出 `PTYTerminalSurfaceRegistry` + `PTYTerminalSessionManager` + `PaneWorkspaceController` | 组合根职责，应下沉 |

### 1.2 单窗口 scene + 空壳命令（`Sources/ProGhosttyApp/ProGhosttyApp.swift`）

| 锚点 | 内容 |
|---|---|
| [:11](../Sources/ProGhosttyApp/ProGhosttyApp.swift) | `Window("ProGhostty", id: "main")` —— 单窗口 scene |
| [:24–28](../Sources/ProGhosttyApp/ProGhosttyApp.swift) | `.newItem` 里 `Button("New Window") {}` 是**空 action**，被 `ProGhosttyWindowPolicy.supportsMultipleTerminalWindows` 关掉 |
| [:113–122](../Sources/ProGhosttyApp/ProGhosttyApp.swift) | `windowCloseGuard` 闭包读 `AppModel.shared` → `hasAnyForegroundSession()`（单窗口假设） |

`ProGhosttyWindowPolicy.swift:2`：`supportsMultipleTerminalWindows = false`。

### 1.3 全局 activeWorkspaceID（`Sources/ProGhosttyCore/Workspace/PaneWorkspaceController.swift`）

| 锚点 | 内容 |
|---|---|
| [:22](../Sources/ProGhosttyCore/Workspace/PaneWorkspaceController.swift) | `workspaceLayouts: [WorkspaceLayout]` —— 可留全局（layout store） |
| [:23](../Sources/ProGhosttyCore/Workspace/PaneWorkspaceController.swift) | `activeWorkspaceID: UUID?` —— **全局「当前工作区」，多窗口下语义错误** |
| [:111](../Sources/ProGhosttyCore/Workspace/PaneWorkspaceController.swift) · [:167](../Sources/ProGhosttyCore/Workspace/PaneWorkspaceController.swift) · [:215](../Sources/ProGhosttyCore/Workspace/PaneWorkspaceController.swift) · [:246](../Sources/ProGhosttyCore/Workspace/PaneWorkspaceController.swift) | `openTerminal` / `restoreWorkspace` / `selectSession` / `splitPane` 都写这个全局字段 |

结论：`activeWorkspaceID` 的「active」语义要上移到每窗口，`PaneWorkspaceController` 回归纯 layout store（新增 `workspaceLayout(id:)` 查询接口，去掉 active 写点）。

### 1.4 视图层只渲染一个窗口

| 锚点 | 内容 |
|---|---|
| [TerminalCanvasView.swift:19](../Sources/ProGhosttyApp/UI/TerminalCanvasView.swift) | `if let workspace = model.activeWorkspace` —— 读全局唯一 active workspace |
| [RootView.swift:89–91](../Sources/ProGhosttyApp/UI/RootView.swift) | `.onAppear { model.activateMainWindowAndFocusTerminal() }` |

### 1.5 窗口尺寸发现是「猜 key/main 窗口」（`Sources/ProGhosttyApp/UI/TerminalWindowSizingController.swift`）

| 锚点 | 内容 |
|---|---|
| [:86–100](../Sources/ProGhosttyApp/UI/TerminalWindowSizingController.swift) | `terminalWindow()` = `NSApp.keyWindow ?? mainWindow ?? windows.first` —— **不知道 workspace 属于哪个窗口**，多窗口下会找错窗口 |

这是「单窗口假设」最隐蔽的一处：尺寸记忆按 `workspaceID` 存，但落点窗口靠 key/main 猜测。多窗口下必须改为「按 workspace 的 owning window」定位。

### 1.6 关闭/聚焦/⌘Q 的 6 处「单窗口硬编码」汇总

| # | 位置 | 现状 | 多窗口改法 |
|---|---|---|---|
| 1 | `PaneWorkspaceController.activeWorkspaceID`（:23） | 全局唯一 active | 上移到 `TerminalWindowModel` |
| 2 | `TerminalWindowSizingController.terminalWindow()`（:86） | key/main 猜测 | 注入「本窗口」，按 owning window 定位 |
| 3 | `AppModel.activateMainWindowAndFocusTerminal()`（:1246） | `NSApp.windows.first` | 每窗口各自的 onAppear 聚焦本窗口 |
| 4 | `AppModel.closeTerminalWindowIfNoWorkspace()`（:1684） | `NSApp.windows.first` | 本窗口最后一个工作区关闭 → 关**本窗口** |
| 5 | `AppModel.shared` 弱单例（:11）+ `windowCloseGuard`（ProGhosttyApp.swift:113） | 只查单窗口 session | 注册表 `windowModels`，⌘Q 守卫**跨窗口聚合** `hasAnyForegroundSession()` |
| 6 | `AppModel.applyTerminalAppearance()`（:1202） | 迭代 `NSApp.windows` | 保留（appearance 是全局的），但确保不误伤 settings 窗口（已有 `utilityWindows.settingsWindow` 排除） |

---

## 2. 关键设计决策

### 2.1 窗口↔工作区映射：**模型 A（每窗口一套工作区）**（已定）

- ⌘N = 新窗口 + 空的新默认工作区。每个窗口的 workspace switcher 只显示本窗口的工作区。
- **理由**：最贴 Ghostty（tab ≈ 窗口内工作区）；session 永远归属一个窗口，避免跨窗口 reparent NSView 的复杂度；工作区持久化（SQLite）不变。
- 模型 B（全局工作区 + 多窗口视口）**不采用**：更像文档型 app，且要处理 session 跨窗口迁移，违反「session 归属唯一窗口」的简单性。

### 2.2 窗口管理：**`WindowGroup`**（已定）

- 用 SwiftUI `WindowGroup { RootView() }` 替换 `Window("main")`。每个窗口自动获得独立的 `@StateObject`（`TerminalWindowModel`），⌘N / Window 菜单 / 窗口恢复免费拿到。
- **不用**手动 `NSWindowController`（尽管 settings 窗口用了它、Ghostty 也用手动 AppKit）：`WindowGroup` 对「多窗口 + 每窗口独立视图模型」是天然匹配；现有 titlebar/sizing chrome 的 AppKit 细节仍通过 `WorkspaceTitlebarView` 的 `NSViewRepresentable`（拿 `view.window`）照常工作，不冲突。

### 2.3 「App 全局 vs 每窗口」切分表（S0/S1 的验收清单）

> **2026-08-15 修正**：改为「**整条 session 栈 per-window**」，比原 spec 的「global sessionManager + session→window 路由」更简单、更安全。理由：`PaneWorkspaceController` 依赖注入 `TerminalFocusStore`（二者天然 per-window），per-window 栈**消除**了事件路由表和 focus 跨窗口作用域两个最大风险。代价只是 settings 变更要广播到所有窗口（单点，见 S0b）。

| 关注点 | 归属 | 理由 |
|---|---|---|
| `SettingsStore` / `settings` / appearance 派生 | **AppComposition（全局）** | 设置全局唯一；appearance 是 settings 的纯函数 |
| `WorkspaceStore` / `AppDatabase` / `workspaces`（持久化库） | 全局 | 工作区库全局共享 |
| `TerminalNotificationCenter` / `AgentNotificationHookManager` / `AppUpdateChecker` | 全局 | 系统服务 |
| `UtilityWindowController`（settings 窗口） | 全局 | 单例设置窗口 |
| **`PTYTerminalSessionManager` + `PTYTerminalSurfaceRegistry`** | **每窗口** | 每窗口 = 独立终端宿主 |
| **`PaneWorkspaceController` + `TerminalFocusStore`** | **每窗口** | 二者注入耦合，同 per-window |
| `workspaceRuntimes` / `activeWorkspaceID` | **TerminalWindowModel（每窗口）** | 本窗口工作区 |
| `sideInputStore` | 每窗口 | 本窗口输入框 |
| `isWorkspaceSwitcherPresented` / `workspaceSwitcherState` | 每窗口 | 本窗口 switcher |
| titlebar toast / in-app 通知 | 每窗口 | 本窗口 titlebar |
| `TerminalWindowSizingController` | 每窗口 | 绑定本窗口尺寸 |

---

## 3. 目标架构

```
AppComposition（App 全局，单例 · 组合根）
 ├─ SettingsStore / settings / appearance 派生
 ├─ WorkspaceStore / AppDatabase / workspaces（持久化库）
 ├─ TerminalNotificationCenter / AgentNotificationHookManager / AppUpdateChecker
 ├─ UtilityWindowController（设置窗口）
 └─ windowModels: [AppModel]                 ← 注册表（供 ⌘Q 聚合 + settings 广播）

AppModel（每窗口，ObservableObject · 独立终端宿主）
 ├─ PTYTerminalSessionManager + PTYTerminalSurfaceRegistry
 ├─ PaneWorkspaceController + TerminalFocusStore
 ├─ workspaceRuntimes / activeWorkspaceID
 ├─ sideInputStore / workspaceSwitcherState / isWorkspaceSwitcherPresented
 ├─ titlebar toast / in-app 通知
 └─ TerminalWindowSizingController（绑本窗口）

ProGhosttyApp（WindowGroup）
 └─ RootView() ← @EnvironmentObject AppModel
```

依赖方向不变：`App → Core`，Core 不 import SwiftUI；App 层只依赖 Core 的协议 + 值类型（`TerminalSessionManager` / `TerminalSurfaceRegistry` / `TerminalSessionID` / `TerminalEvent` / `WorkspaceLayout`）。

---

## 4. 分阶段实施计划（每步 build + test + check-architecture 绿再进下一步）

### S0 · 抽 `AppComposition`（App 全局服务）— 纯搬，零行为变化

把 §2.3 里标记「全局」的字段/构造从 `AppModel` 挪到新的 `AppComposition`（`@MainActor final class`，组合根）。`AppModel` 通过注入拿这些依赖，不再 `new`。

- 产出：`Sources/ProGhosttyApp/UI/AppComposition.swift`（或按 debt 计划放 `AppComposition` 目录）。
- `PaneWorkspaceController` 先**保持全局 active**不动（S3 再收），本步只做服务搬移。
- 验收：行为零变化；`AppModel` 减少 ~150 行；`AppModel.shared` 暂时保留（S3 替换为注册表）。

### S1 · 建 `TerminalWindowModel`（每窗口状态）— 搬，不改逻辑

把 §2.3 标记「每窗口」的状态 + 对应方法（`createAndActivateWorkspace` / `splitPane` / `closePane` / `handle(event)` / 输入路由 / switcher 同步）从 `AppModel` 搬到 `TerminalWindowModel`。**这是量最大、最机械的一步，主体是「移动 + 改 self 引用」，不是重写。**

- `TerminalWindowModel` 持有注入的 `AppComposition` 引用（拿 sessionManager / surfaceRegistry / settings / persistence）。
- `focusStore` 下沉到 `TerminalWindowModel`；`PaneWorkspaceController` 若仍需要 focus 做 `focusedSessionId(in:)` 查询，改为「由 WindowModel 传入 focusStore」或「focus 查询接口参数化」。
- `handle(_ event:)`（现在 `AppModel.handle`，:1587）是事件 hub：event 带 `TerminalSessionID`，需按 session → owning window 路由到正确的 `TerminalWindowModel`。**路由表 = session→window 的归属映射**，放在 AppComposition。
- 验收：单窗口下行为不变；`AppModel` 瘦身到「App 协调 + 事件路由 + 注册表」。

### S2 · 换 scene — `Window("main")` → `WindowGroup`

- `ProGhosttyApp.swift`：`WindowGroup { RootView().environmentObject(windowModel) }`，每个窗口 `@StateObject var windowModel = TerminalWindowModel(...)`。
- `RootView` / `TerminalCanvasView` / `WorkspaceSwitcherView` 的 `@EnvironmentObject AppModel` → `TerminalWindowModel`（settings 窗口仍用全局 AppModel/AppComposition）。
- 此时 `supportsMultipleTerminalWindows` 仍可先关，但结构已能支撑多窗口。
- 验收：单窗口行为不变；`swift build` 全绿。

### S3 · 修 6 处「单窗口硬编码」（§1.6 汇总表）

按表逐条改：
1. `PaneWorkspaceController.activeWorkspaceID` 全局写点 → 删除，active 由 `TerminalWindowModel` 持有；`selectSession`/`splitPane` 等改为返回结果、不再写全局 active。
2. `TerminalWindowSizingController` → 注入 owning window（由 WindowModel 在 `onAppear` 绑定本窗口），`terminalWindow()` 不再 key/main 猜测。
3. `activateMainWindowAndFocusTerminal` → 拆成每窗口的 `focusTerminal()`，由各自 `RootView.onAppear` 调。
4. `closeTerminalWindowIfNoWorkspace` → 「本窗口最后一个工作区关闭」→ 由 WindowModel 关**本窗口**（`NSWindow.performClose`），不碰 `NSApp.windows.first`。
5. `AppModel.shared` → `AppComposition.windowModels` 注册表；`windowCloseGuard` 与 `applicationShouldTerminate` 的 `hasAnyForegroundSession` 跨窗口聚合。
6. `applyTerminalAppearance` 保留全局，核对 settings 排除逻辑。

- 验收：两窗口并行时，焦点、尺寸、关闭、⌘Q 确认各归各窗口，无串扰。

### S4 · 接 ⌘N + 翻转开关

- `.newItem` 空按钮 → `AppComposition.openNewWindow()`（新 `TerminalWindowModel` + 默认工作区 + 新 session）。
- `ProGhosttyWindowPolicy.supportsMultipleTerminalWindows = true`。
- 验收：见 §6。

---

## 5. 风险与守卫

| 风险 | 说明 | 缓解 |
|---|---|---|
| **settings 广播**（新，最高） | settings 移到 AppComposition 后，变更要同步到所有窗口的 `applyTerminalAppearance`；且 `$model.settings` 绑定依赖 `@Published` | settings 留在 AppComposition 作 `@Published`；SettingsView 改绑 `@EnvironmentObject AppComposition`；AppModel 订阅 composition.objectWillChange 转发并重跑 appearance |
| **settings 窗口归属** | SettingsView 现 `@EnvironmentObject AppModel`，绑定打开它的那个窗口 | S0b 把 SettingsView 改绑 AppComposition（全局），appearance 颜色也移到 composition |
| **尺寸找错窗口** | §1.5 | S3 注入 owning window，删掉 key/main 猜测 |
| **窗口关闭生命周期** | 关窗口 ≠ 关 session；session 可能被其他窗口引用 | 每窗口 close 时同步 close 其 workspace 的 session（走 `PaneWorkspaceController.closeWorkspace` + `sessionManager.closeSession`） |
| **与 debt 线冲突** | `ARCHITECTURE_DEBT_SPEC` D2 也在拆 AppModel | 以本 spec 的「App全局/每窗口」切分为准；debt 线后续在此基础上继续，不重复拆同一批字段 |

> per-window session 栈消除了原 spec 的「事件路由」和「focus 跨窗口作用域」两个风险：每窗口消费自己的 `sessionManager.events`，每窗口有自己的 focusStore。

---

## 6. 验收标准（S4 完成后）

- [ ] ⌘N 打开新窗口，新窗口是独立默认工作区（新 PTY session）。
- [ ] 每个窗口有独立的 titlebar 内容、workspace switcher、分屏、焦点。
- [ ] 两窗口同时运行：各自敲键盘、滚动、分屏、切工作区互不干扰。
- [ ] 关闭任一窗口不影响其余窗口；关最后一个窗口退出。
- [ ] 任窗口有前台进程时，⌘Q / 关窗口前的确认跨窗口生效。
- [ ] 全屏进出（含 §5 全屏后 titlebar 重建）在多窗口下正常。
- [ ] `swift build` + `swift test` + `scripts/check-architecture.sh` 全绿。
- [ ] 手测用 `./scripts/build-app-bundle.sh release`（非裸 `swift build`）。

---

## 附：执行提示

- 每步独立 commit（`feat(workspace): …` / `refactor(app): …`，见 `docs/git-workflow.md`）。
- 只 push 当用户明确要求。
- 复用 debt spec 已验证的样板：`RenderedGridGeometry` 是「抽几何」样板；本 spec 的 `AppComposition` 复用 `ARCHITECTURE_PLAN.md` 阶段 3 已命名的类型，别另起名字。

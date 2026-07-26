# ProGhostty 架构债 Spec（执行底稿）

> 状态：已核实 · 基于 2026-07-26 对 `main`（HEAD `701b869`）的逐文件精读
> 验证快照：`swift build` ✅ · `swift test` **611 tests 全绿** ✅ · `scripts/check-architecture.sh` OK ✅ · libghostty-vt 确认 ReleaseFast ✅
>
> 与 `ARCHITECTURE_PLAN.md` 的关系：PLAN 是重构蓝图（阶段 0–5）；本文是**债务的精确测绘**——每个债点的职责分解、行号锚点、耦合链、拆分约束与验收标准。PLAN 确诊于更早的代码状态，本文修正了其中已过期/漏算的条目（见各节"对 PLAN 的修正"）。执行阶段 3/4/5 时以本文锚点为准。

---

## 0. 总览：债在哪里、不在哪里

### 0.1 四个债点

| # | 债点 | 类型 | 规模 | PLAN 状态 |
|---|---|---|---|---|
| D1 | `PTYGridView`（藏在 PTYTerminalEngine.swift 内） | 单类 god-object | ~2807 行 · 12 职责簇 · ~70 存储属性 | 阶段 4，未动 |
| D2 | `AppModel` | 单类 god-object | 1901 行 · 18 `@Published` · 13 职责簇 | 阶段 3，未动，**仍在膨胀**（确诊 1632 → 现 1901） |
| D3 | `TerminalCanvasView.swift` | 分层聚集文件（**非** god-object） | 1925 行 · 15 个类型 | **PLAN 未登记** |
| D4 | `AppSettings` + `FontManager` | Core 内 AppKit 切口 | AppKit 符号仅 4 行 | 阶段 5，未动 |

### 0.2 已核实健康、不要动的部分（防止误伤）

- **渲染层已拆干净**：`Renderer/` 25 文件，除 `MetalDirectRenderEngine.swift`(1501行，内聚的 Metal 引擎) 外多数 <500 行。
- **阶段 0/1/2 是真落地，非薄壳**：
  - `PaneScrollController`（[PaneScrollController.swift:13](../Sources/ProGhosttyCore/TerminalCore/Renderer/PaneScrollController.swift)，85 行）**真组合**了 `physics: PaneScrollCoordinator` + `commit: ScrollCommitCoordinator` 两个协作者；旧类型仍被引用 5/4 处主要是测试直接驱动底层值类型，不构成并存债。
  - `MetalDirectDiagnostics` 已按 backend 拆出（113 行独立文件）。
- **`RenderedGridGeometry`**（[PTYTerminalEngine.swift:3890](../Sources/ProGhosttyCore/TerminalCore/PTY/PTYTerminalEngine.swift)–3954，纯值类型、Sendable）是"从 NSView 抽几何"的**现成样板**——阶段 4 全部几何抽取照此模式。
- 纯值层（`PaneTreeReducer` / `SplitRatioLayout` / `CellGridModel` / `GhosttyVTBridge` / `WorkspaceStore`）干净可测，维持现状。

### 0.3 债的本质：三种耦合机制（跨债点反复出现）

1. **单一可变快照当隐式总线** —— D1 的 `frameSnapshot`、D2 的 `workspaceRuntimes` / `shellIntegrationState`：多簇同读同写，无显式契约。拆出的通用解法：改为**显式传入不可变快照**（`RenderedGridGeometry` 已示范）。
2. **`didSet` / 尾调用副作用扇出** —— D1 的 `viewport.didSet`、D2 的 `settings.didSet` 与 `syncWorkspaceSwitcherState()` 万能尾调用：把本应独立的簇钉成隐式时序契约。拆前必须先把副作用显式化。
3. **继承消费公共表面** —— `MetalDirectRendererView : PTYGridView`（[MetalDirectRendererBackend.swift:13](../Sources/ProGhosttyCore/TerminalCore/Renderer/MetalDirectRendererBackend.swift)）锁死基类 public API。所有 D1 抽取都是"移动实现、保留投影"，**不是**"移动代码"。

---

## 1. D1 · PTYGridView（约 2807 行，最硬的一块）

文件 `Sources/ProGhosttyCore/TerminalCore/PTY/PTYTerminalEngine.swift` 共 4299 行，但 `PTYTerminalEngine` 类本体（199–889）是**薄门面**（转发给 `PTYTerminalSessionManager` / `PTYTerminalSurfaceRegistry`），债务全部集中在 `PTYGridView`（[915](../Sources/ProGhosttyCore/TerminalCore/PTY/PTYTerminalEngine.swift)–3721）+ 其 `NSTextInputClient` 扩展（3722–3850）。

### 1.1 文件内类型清单

| 类型 | 行区间 | 角色 | 处置 |
|---|---|---|---|
| `TerminalScrollAnchor` / `TerminalAttributedDiff` / `PTYRenderDebugLog` / `ResizeRenderSnapshot` / `GhosttyVTQueueWork` | 5–198 | 纯值/工具 | 健康，可考虑分文件 |
| `PTYTerminalEngine` | 199–889 | PTY 会话薄门面 | 健康 |
| `GridCoordinate` / `GridSelectionPoint` | 891–913 | 纯值坐标 | 健康 |
| **`PTYGridView: NSView`** | **915–3721** | **god-object** | **本节主题** |
| `extension PTYGridView: NSTextInputClient` | 3722–3850 | IME 协议 | 留在外壳 |
| `GridSelectionCoordinate` / `GridSelectionCellRange` / `GridMarkedTextOverlay` | 3851–3881 | 纯值 | 健康 |
| `RenderedGridGeometry` | 3890–3954 | **抽取样板** | 扩展它 |
| `PTYTextView: NSTextView` | 3956–4251 | 平行的文本回退视图 | 独立，后续同类处理 |
| `NSMenu`/`NSMenuItem`/`NSPoint` 便利扩展 | 4252–4299 | 工具 | 可分文件 |

### 1.2 十二个职责簇（行号 · 纯度 · 处置）

| 簇 | 职责 | 关键锚点 | 纯度 / 处置 |
|---|---|---|---|
| C1 | 配置/字体/调色板注入 | `applyPalette` :1175 · `applyFont` :1181 · 静态 `cellSize(for:)` :3658 | 字体度量近纯 → 可下沉 `FontMetrics` 值类型；`apply*` 留外壳 |
| C2 | 渲染入口 + 脏矩形 | `render` ×3 :1255/:1271/:1296 · 静态 `dirtyRects` :2318/:2328 | 脏矩形静态法纯 → 可抽；`render` 是 NSView 入口且被子类 `super` 调用，**不可动签名** |
| C3 | 绘制管线 | `draw(_:)` :1338 · `drawRow/Run/Cell/Cursor/Text` :2462–2799 | NSGraphicsContext 强耦合，**留外壳** |
| C4 | **静态/实例几何计算** | `visualScrollTranslationY` :1372 · `contentDirtyRect` :1385 · `urlCursorRects` :1450 · `rectForCell` :2806 · `visibleRowRange` :2815 · `extendedFrame` :2849 · `absoluteBaseRow` :2859 | **近纯，抽取目标 ①**：扩展 `RenderedGridGeometry` |
| C5 | 滚动/平滑浏览物理（~350行，状态最密） | `scrollWheel` :1499 · `feedSmoothScroll` :1534 · `applyBrowseTick` :1661 · `processScroll` :1727 · `commitViewportScroll` :1847 | 计算内核已外置（`SmoothScrollEngine`/`SmoothScrollBrowseResolver`/`PaneScrollController`）；剩余 `browseTopRow`/`browseAnchorRow`/`isSmoothScrollBrowsing` 等状态与 CADisplayLink 绑定，**继续收敛而非重抽** |
| C6 | 键盘/命令/剪贴板 | `keyDown` :1854 · `performKeyEquivalent` :1885 · `copy`/`paste` :1911/:1917 | AppKit 强耦合，留外壳 |
| C7 | 鼠标/链接 hover/dwell/ring cursor（~450行） | `mouseDown` :2010 · `updateLinkHover` :2975 · `applyDwellState` :3034 · `updateRingCursor` :3058 | 子模块已存在（`SemanticDwell`/`SemanticLinkPopover`）；NSTrackingArea/CALayer/CADisplayLink 深绑定，抽取收益低、风险中 |
| C8 | **选区模型 + 拖拽自动滚动** | 归一化 `normalizedSelectionPointRange` :3624 · `normalizedSelectionRange(in:)` :3632 · `isSelected` :3649 · auto-scroll :3250–3357 | **归一化部分纯，抽取目标 ③**（合入 `GridSelectionModel` 值类型）；Timer/auto-scroll 留外壳 |
| C9 | **prompt 光标推断** | `renderedGeometry` :3401 · `inferredPromptCursorRect` :3433 · `shouldInferPromptCursor` :3497 · `inferredPromptCursorCoordinate` :3572 · `promptMarkerColumn` :3603 | **近纯（`frameSnapshot → NSRect` 启发式），抽取目标 ①，风险最低价值最高** → `PromptCursorInferrer` |
| C10 | IME / marked text | 状态 :1079–1087 · `drawMarkedText` :2549 · 协议方法 :3723–3844 | 宽度/caret 计算纯可参数化；`NSTextInputClient` 协议**必须留外壳** |
| C11 | 焦点/响应链/跟踪区 | `setFocused` :1249 · `viewDidMoveToWindow` :2225 · `updateTrackingAreas` :2318 | 留外壳，不可抽 |
| C12 | 公共访问器/Metal 转发面 | 见 §1.3 | **冻结的契约**，任何抽取保留等价投影 |

另有**测试白盒钩子**（`test*` :1927–2010、`testSetSelection` :3884）直接读写私有滚动/选区状态——拆分需同步迁移这些测试。

### 1.3 冻结契约：Metal 子类/后端消费的公共表面（拆分时一个都不能删）

继承关系：`MetalDirectRendererView : PTYGridView`（[MetalDirectRendererBackend.swift:13](../Sources/ProGhosttyCore/TerminalCore/Renderer/MetalDirectRendererBackend.swift)）。子类 `present(...)`（同文件 74–92）调 `super.render(...)` 并读继承状态。

**转发访问器/方法全集**（来源：MetalDirectRendererBackend.swift:329–581 的 `directView.*` + 子类 super 调用）：

```
applyPalette · applyFont · applyRendererOptions · applyScrollDiagnostics
setFocused · present · render(×3 重载) · resetPixelScroll
resetViewportStartRowKeepingVisualOffset · selectedText · terminalCellSize
markedTextStateRevision · viewport(.visualOffsetY) · cursorCellRect
currentCursorOverlay · currentMarkedTextOverlay
闭包属性: inputHandler · activationHandler · viewportDidChangeHandler
         transientOverlayDidChangeHandler · scrollActivityHandler
         boundsSizeDidChangeHandler(定义在子类 :31)
```

跨层其他消费者还读：`isFocusedTerminal`(×7) · `selectedText`(×4) · `isComposingMarkedText`(×3) · `isViewingHistory`(×2) · `flushPendingScrollCommit`(×2) · `renderedText` · `isSmoothScrollBrowsingActive` · `isDraggingSelection` · `browseTopAbsoluteRow`。

### 1.4 耦合结构（为什么难拆）

1. **继承而非组合**（§0.3-3）：public 表面冻结。
2. **`frameSnapshot`/`scrollFrameSnapshot`（:968/:969）是全簇隐式真相源**：C2 写；C3/C4/C8/C9/C10 及 `selectedText`/`renderedText` 读。抽取时以参数显式传入。
3. **`viewport.didSet` 副作用扇出**（[:1011](../Sources/ProGhosttyCore/TerminalCore/PTY/PTYTerminalEngine.swift)–1022）：一次赋值 = 清 `currentInputPresentation` + 清 `latestPromptInputCursorRect` + 调 `viewportDidChangeHandler` + `needsDisplay` + `invalidateCursorAndIMEIfSettled()`。C5 主写，C9/C10/C3 被动依赖此链。
4. **共享滚动/浏览状态**（:990–1009）：`browseTopRow` 等被 C5、C8 的 `stepBrowseForSelectionAutoScroll`(:3357)、C2 的 render 早退分支(:1275/:1301)共同读写。
5. **光标/IME 状态三方交织**（:1079–1087）：`currentInputPresentation` / `latestPromptInputCursorRect` / `markedText*` 被 C9/C10/C12 共享，汇聚点 `resolvedInputPresentation()`。
6. **display-link 生命周期**：C5 `scrollDisplayLink` 与 C7 `linkHoverDisplayLink`/`ringCursorLayer` 同挂 C11 的 window attach 生命周期。

### 1.5 D1 拆分序（对应 PLAN 阶段 4，修正后）

| 步 | 抽出 | 对应 PLAN | 前置 | 验收 |
|---|---|---|---|---|
| 4-1 | `PromptCursorInferrer`（C9，~200行） | 4a | 无 | 纯值类型 + 直接单测；外壳保留 `inferredPromptCursorRect` 等投影 |
| 4-2 | 扩展 `RenderedGridGeometry`（C4，~140行） | 4b | 无 | 静态几何全部迁入；实例侧改为构造 geometry 后转调 |
| 4-3 | `GridSelectionModel`（C8 归一化，~130行） | 4c | 无 | 归一化/取文本纯函数化；白盒测试迁移到值类型 |
| 4-4 | `CellTextStyler`（C3 attribute 构建，~120行） | 4d | 4-2 | 属性构建参数化；draw 调用点不变 |
| 4-5 | `MarkedTextPresenter`（C10 计算部分，~130行） | 4e | 4-1 | 协议方法留外壳，宽度/caret/clamp 迁入 |
| — | C5 滚动状态继续收敛进 `PaneScrollController` 家族 | 阶段2余项 | 4-2 | `browse*` 状态归属单一 owner |

每步硬性检查：`MetalDirectRendererBackend.swift` 无改动即可编译（契约未破）；`swift test` 611+ 全绿；白盒测试同步迁移。

---

## 2. D2 · AppModel（1901 行，债在按计划要拆的方向继续增厚）

文件 [AppModel.swift](../Sources/ProGhosttyApp/UI/AppModel.swift)，单一 `@MainActor final class AppModel: ObservableObject`。确诊时 1632 行 / 14 `@Published`，现 **1901 行 / 18 `@Published`**。

### 2.1 `@Published` 状态映射（18 个）

| 职责簇 | 属性 | 行 |
|---|---|---|
| A 工作区运行时 | `workspaceRuntimes` · `activeWorkspaceID` · `workspaces` | 41, 42, 49 |
| G switcher | `isWorkspaceSwitcherPresented` · `workspaceSwitcherState` | 43, 44 |
| H 通知呈现 | `titlebarToast` · `inAppNotification` | 45, 46 |
| C 输入路由 | `commandLine` · `sideInputStore` | 47, 48 |
| E 外观/设置 | `settings`（`didSet` → `applyTerminalAppearance()` + `persistSettings()`） | 50–55 |
| K 更新检查 | `isCheckingForUpdates` | 56 |
| （总线滥用） | `shellIntegrationState` | 58 |
| **新增：Agent notify hook 门** | `systemNotificationsAuthorized` · `agentNotifyHooksStatus` · `agentNotifyHookError` · `isInstallingAgentNotifyHooks` · `showAgentNotifyInstallSheet` · `showAgentNotifyUninstallSheet` | 57, 59–68 |

私有可变状态 6 个：`savedLayoutSnapshots`(:83) · `rememberedWorkspaceContentSizes`(:84) · `titlebarToastTask`/`inAppNotificationTask`(:85–86) · `paneSplitAvailability`(:87) · `bareTokenExistenceCache`(:90–92，新增)。

### 2.2 十三个职责簇

| 簇 | 职责 | 关键锚点 | 可抽性 |
|---|---|---|---|
| A | 工作区运行时 + 持久化（~400行，最大簇） | `createAndActivateWorkspace` :286 · `closeSelectedTerminal` :382 · `updateWorkspaceForSession` :1849 | **内核，不抽** |
| B | 分屏可用性几何（~120行） | `updatePaneSplitAvailability` :681 · `childPaneSizesAfterSplit` :775 · `splitCanFitAvailableScreen` :824 | **高（纯几何）**→ 3d；私有字典随控制器搬走；注意 seed 与 splitPane 同事务(:733) |
| C | 输入路由（~100行） | `sendCommand` :390 · side-input :397–471 · `routeTerminalInput` :897 | 低，保留 |
| D | 窗口尺寸几何（~90行） | `expandTerminalWindowIfNeeded` :1108 · `minimumContentSize` :1131 · `terminalWindow` :1148 | **高** → 3c；与 F 交叉：`terminalWindow()` 需排除 settings 窗(:1151) |
| E | 外观派生（~90行只读） | `terminalPalette` :549 · `configuration*Color` :561–599 · 副作用 `applyTerminalAppearance` :1314 | 派生高 → 3h；`settings.didSet` 副作用留 AppModel |
| F | 辅助窗口（~110行） | `openSettingsWindow` :1270（内 `.environmentObject(self)` :1282 反向依赖） | 中 → 3f；与 D 需先约定"终端窗口判定"归属 |
| G | switcher 同步（~150行） | **`syncWorkspaceSwitcherState` :1737（万能尾调用枢纽）** · 导航 :1679–1703 | 低，保留；**是拆 A/G 的最大障碍** |
| H | 事件 hub + 通知呈现（~130行） | hub：`handle` :1783（`cwdChanged` 直改 `workspaceRuntimes` :1787）；呈现：`showTitlebarToast` :1367 · `showInAppNotification` :1829 | 呈现高 → 3e（4 个分散调用点：K :1206、B :754、URL :982、init :169）；hub 保留 |
| I | 确认弹窗（~100行，纯 NSAlert） | `confirmWorkspaceDeletion` :1502 · `confirmQuitWithForegroundProcess` :1531（新增） · `confirmPaneCloseWithForegroundProcess` :1548 | **最高** → 3a，零 `@Published` 耦合 |
| J | 布局快照（~50行） | `saveActiveLayoutSnapshot` :1453 · `restoreActiveLayoutSnapshot` :1459 | 低，保留 |
| K | 更新检查（~30行） | `checkForUpdates` :1191 | 低，保留 |
| L | 标题/路径格式化（~60行，纯字符串） | `compactTitlebarTitle` :1392 · `displayPath` :1407 · `normalizedWorkspaceName` :1417 | **最高** → 3b，零状态依赖 |
| **M（新增，PLAN 未登记）** | **URL/文件交互（~90行）** | `openTerminalLinkTarget` :911 · `bareTokenResolvesToExistingPath` :930（含 TTL 磁盘 stat 缓存 :90–92） · `terminalFileInfo` :955 · `openProjectInfoPanel` :1622 · `isInsideGitWorkTree` :1661 | 中；经 init 的 7 个 `surfaceRegistry.set*Handler` 闭包(:158–179)挂入 |

### 2.3 init 组合根（:135–189，对应 3g）

装配密度：**13 个协作者**（init 体内硬 new 5 个：`SettingsStore`/`WorkspaceStore`+SQLite 建库/`PTYTerminalSurfaceRegistry`/`PTYTerminalSessionManager`/`PaneWorkspaceController`；默认参数 3；属性初始化器 4）+ **7 个 handler 闭包**(:158–179) + `AppModel.shared = self`(:180) + **4 个启动副作用**(:183–188)。抽 `AppComposition` 时按此三段切。

### 2.4 确诊后的膨胀（+269 行，全是"该拆走的方向"）

| 新增职责 | 来源 commit | 落点 |
|---|---|---|
| Agent notify hook 安装门（6 `@Published` + ~90行状态机 :207–281） | `f258d98` | 全新簇，PLAN 未覆盖 |
| URL 交互 + file info（~60行 + stat 缓存） | `6717788` / `32302e8` | 新簇 M |
| 项目面板（~55行） | `531f7fc` | 新簇 M |
| ⌘Q 前台进程确认 | `c07bc8f` | 加胖 I 簇 |
| per-pane label（`startRenamePane` :404 等） | `701b869` | 加胖 A/L 边界 |

**含义**：在阶段 3 落地前，每个新 feature 默认落进 AppModel。**止血措施**：新 feature 若属 3a–3h / M 的方向，直接建 Feature Controller，不再进 AppModel。

### 2.5 耦合链（拆分前必须先解开的契约）

1. **`syncWorkspaceSwitcherState()`(:1737) 万能尾调用**：A/G/H 几乎每个 mutation 尾部调用，写 `workspaceSwitcherState` 并顺带 `applyFocusedTerminalSurface()`(:1763)。拆 A/G 前先把"改完就 sync"显式化（事件/observation）。
2. **`shellIntegrationState`(:58) 全局状态总线**：split 失败 :741 · save 失败 :365 · layout :1456/:1489 · cwd :1788 · error :1810 共写。拆任何簇前先决定归属（建议并入 3e 通知呈现域）。
3. **`workspaceRuntimes`(:41) 公共写入面**：A/H(`handle` :1787)/J/B 共写；B 的 seed 与 splitPane 同事务(:733) 是时序耦合。
4. **`titlebarToast` 四簇共用**（见 H 行）→ 3e 时统一走 presenter 注入。
5. **`settings.didSet`(:50–55)**：Agent hook 分支(:216/226/243) 也触发外观重放——E 派生可抽，didSet 副作用链留。
6. **D/F 交叉**：`terminalWindow()`(:1148) 与 `applyTerminalAppearance`(:1324) 都要排除 settings 窗。

### 2.6 D2 拆分序（修正 PLAN 阶段 3）

```
3-1  TitleFormatting (L, 纯函数, 零耦合)                 ← 最先
3-2  ConfirmationPrompts (I, 纯 NSAlert, 含新增 ⌘Q 确认)
3-3  PaneSplitAvailabilityController (B, 纯几何+私有字典)
3-4  TerminalWindowSizingController (D)   ┐ 先约定"终端窗口判定"归属
3-5  UtilityWindowController (F)          ┘ 再各自抽
3-6  AppearanceViewModel (E 只读派生)
3-7  NotificationPresenter (H 呈现; 顺带收编 shellIntegrationState 归属)
3-8  TerminalLinkInteractionController (M, 新增, PLAN 补登)
3-9  AgentNotifyGateController (新增 6 @Published 状态机, PLAN 补登)
3-10 AppComposition (3g, init 三段切)                     ← 最后
内核保留: A · C · G · H-hub · J · K
```

---

## 3. D3 · TerminalCanvasView.swift（1925 行，计划外的分层聚集）

### 3.1 定性

**不是第三个 god-object**：15 个类型分摊，最大两个（`SplitContainerViewController` ~489 行 :86–575、`TerminalPaneViewController` ~505 行 :808–1313）中等且内聚。对 AppModel 是**干净薄转发、无回指**——所有语义动作委派回 `model.*`（:51–81，`TerminalTreeLayoutView.updateNSViewController` 一次转接 ~25 个闭包）。

### 3.2 类型清单（拆文件依据）

| 类型 | 行 | 角色 |
|---|---|---|
| `TerminalCanvasView` / `TerminalView` | 6–30 | SwiftUI 壳 |
| `TerminalTreeLayoutView` | 32–84 | SwiftUI↔AppKit 桥（25 闭包布线） |
| `SplitContainerViewController` | 86–575 | 分屏树布局协调 + NSSplitViewDelegate（递归 rebuild :231–341 · 比例 :342–427 · 增量 sync :445–534） |
| `TerminalSplitView` | 576–807 | divider 预览/拖拽物理 |
| `TerminalPaneViewController` | 808–1313 | 单 pane 宿主（resize 提交 :851–1003 · grid 尺寸 :1004–1028 · drop :1136–1183 · 菜单 :1185–1276 · side-input :1057–1135 · `reportSplitAvailability` :1294–1313） |
| `TerminalPaneHostView` … `SplitGlyphButton`（5 个自绘 chrome） | 1314–1859 | **首选分文件对象** |
| `KeyboardShortcutBinding` 扩展 / `InspectorView` | 1860–1925 | 工具/SwiftUI |

### 3.3 两处已核实的软分层气味

1. **App 层钻 Core 的 `PTYGridView` 公共 API**：`.terminalCellSize`/`.terminalContentInset`（[TerminalCanvasView.swift:1007](../Sources/ProGhosttyApp/UI/TerminalCanvasView.swift)–1008）· `.setInteractionEnabled`(:1118) · `.copy(nil)`/`.paste(nil)`(:1256/:1264) · `.selectedText`(:1272)。全是 public，非守卫违规，但泄漏渲染域细节。**处置**：在 `TerminalSurfaceRegistry` 协议面上补齐等价操作，App 层停止触碰 `liveGridView`。
2. **App 层第二个 cell 几何 owner**：拿不到 `terminalCellSize` 时用 `NSFont.monospacedSystemFont` + `"W".size(withAttributes:)` 自算（:1017–1018）。违反"cell 几何 Core 单一 owner"。**处置**：Core 提供 fallback 度量 API，删掉 App 层复算。

### 3.4 处置汇总

- **补登进 PLAN**：作为"App/UI 分屏视图层"，与 3d（分屏可用性几何）同批评审——`reportSplitAvailability`(:1299) 正是喂给 AppModel `updatePaneSplitAvailability` 的上游。
- **按类型拆文件**（零行为变化）：至少把 5 个自绘 chrome 类型（:1314–1859）移出。
- 修复 §3.3 两处气味。

---

## 4. D4 · 设置域（AppSettings 641 行 + SettingsView 1024 行）

### 4.1 AppSettings 混了 **7 个域**（对 PLAN 的修正：PLAN 说 6 类，漏算渲染域）

单 struct 平铺 18 字段（[AppSettings.swift:4](../Sources/ProGhosttyCore/Settings/AppSettings.swift)–45）：

| 域 | 字段（行 5–24） | 目标子结构 |
|---|---|---|
| **渲染（PLAN 漏算）** | `rendererMode` · `smoothPixelScrollingEnabled` · `dirtyRowRenderingEnabled` · `forceFullRedrawEnabled` | `RenderingSettings`（新增） |
| 通知 | `notificationsEnabled` · `notifyWhenFocused` | `NotificationSettings` |
| Shell | `defaultShell` · `defaultWorkingDirectory` | `ShellSettings` |
| 字体 | `fontFamily` · `cjkFallbackFontFamily` · `fontSize` | `AppearanceSettings` |
| 主题/外观 | `themeName` · `followSystemAppearance` · `softDarkPreferred` · `softLightPreferred` | `AppearanceSettings` |
| 语言 | `appLanguage` | 独立或 App 域 |
| 控制协议 | `pgControlCommandsEnabled` | Control 域 |
| 快捷键 | `keyboardShortcuts: KeyboardShortcutSettings`(:24) | **已是子结构，拆分样板** |

### 4.2 AppKit 切口（对 PLAN 的修正：精确到符号）

AppKit 符号**不在 struct 本体，全在同文件 `FontManager` enum**（:343–549），共 4 处：

- `NSFont(name:)` [AppSettings.swift:345](../Sources/ProGhosttyCore/Settings/AppSettings.swift)（defaultMonospacedFontName）
- `NSFontManager.shared.availableFontFamilies` :355
- `NSFont(name:)` :438（isInstalled 探测）
- `NSFont(name:)` :541（isMonospacedByMetrics）

**抽出 `FontCatalog` 后，文件第 1 行 `import AppKit` 可降为纯 Foundation**——Core 去一处 AppKit 依赖的最干净切口。唯一反向调用点：`AppSettings.defaults` 里 `fontFamily: FontManager.defaultMonospacedFontName()`(:35)，改注入或延迟解析。同文件 `ThemeManager`(:551) / `AppLanguageManager`(:598) 无 AppKit，可留。

### 4.3 拆分的外溢成本（PLAN 未记）

`SettingsView` 全部绑定走 `$model.settings.*`（经 AppModel 而非直连 store）。子结构化会连锁改写大批绑定路径（`$model.settings.fontFamily` → `$model.settings.appearance.fontFamily`）；`FontManager → FontCatalog` 改名同步波及 SettingsView :498–509 等调用点；另有 agent-notify sheet 一整块（:292–476）与 AppModel 双向绑定（依赖 3-9 先行）。**结论：阶段 5 必须与 SettingsView 绑定迁移、持久化 schema 迁移同批评估**，不是纯 Core 改动。

`SettingsView` 本体过大但规整（11 个 pane 工厂 + 6 个已抽复用组件），非紧急。

### 4.4 D4 拆分序

```
5-1  FontManager → FontCatalog（独立服务，AppSettings.swift 去 import AppKit）  ← 切口最干净，可提前到任意时点
5-2  AppSettings 子结构化（含 RenderingSettings）+ 持久化迁移 + SettingsView 绑定迁移，同一 PR 批次
     前置：3-9（agent-notify 状态机先出 AppModel，减少 SettingsView 双向绑定面）
```

---

## 5. 全局执行顺序（风险从低到高）

> **执行进度（2026-07-26，分支 `refactor/architecture-debt`）**：
> 第一波：✅ 3-1 TitleFormatting · ✅ 3-2 ConfirmationPrompts · ✅ 5-1 FontCatalog（守卫
> 例外从 AppSettings.swift 收窄为 FontCatalog.swift）· ✅ 3-3 PaneSplitAvailability ·
> ✅ 4-1 PromptCursorInferrer。
> 第二波：✅ 4-3 GridSelectionModel（选区 anchor/head 归单一值类型 owner）· ✅ 3-5
> UtilityWindowController · ✅ 3-4 TerminalWindowSizingController（D/F 交叉以注入的
> isExcludedWindow 谓词解开）· ✅ D3 拆文件（TerminalPaneChrome.swift，1925→1335 行；
> 顺带删除无引用的 KeyboardShortcutBinding menu 扩展）。
> 第三波：✅ 4-2 RenderedGridGeometry 独立成文件并收编全部纯几何（PTYGridView 静态面
> 保留为转发）· ✅ D3 两处气味修复（PTYTerminalSurfaceView 门面，App 层 liveGridView
> 引用清零；fallback cell 几何入 Core `TerminalGridSizer.gridSize(for:font:...)`）。
> **次手全部完成。** 每项独立 commit，三绿（639 tests）。
> 第四波（深水区，分支 `refactor/architecture-deep`，waves 1-3 已并入 main）：
> ✅ 3-6 AppearanceViewModel（14 个派生属性归纯值类型，注入 systemIsLight，首次可测）·
> ✅ 3-7 NotificationPresenter（toast/in-app `@Published` + 消失任务迁出；**收编
> `shellIntegrationState` 为 statusLine**，AppModel 以链式 objectWillChange + 同名转发
> 保持视图零改动）· ✅ 3-9 AgentNotifyGateController（6 个 `@Published` 状态机迁出，
> 写 settings 与授权以闭包注入）。三绿（644 tests）。
> 剩余：3-8 链接交互控制器 · 3-10 AppComposition · 5-2 AppSettings 子结构化 · A/G/H 内核。
> 执行中发现：架构守卫对 Core 内 AppKit 有 per-file 白名单强制（非仅 review 清单），
> §4.2 的"深迁移 App 层"如推进需同步改守卫白名单。

```
█ 先手（零耦合，每项独立 PR，纯结构无行为变化）
  ✅ 3-1 TitleFormatting       ✅ 3-2 ConfirmationPrompts    ✅ 5-1 FontCatalog

█ 次手（纯几何/纯推断，有样板，带私有状态搬迁）
  ✅ 4-1 PromptCursorInferrer  ✅ 4-2 RenderedGridGeometry     ✅ 4-3 GridSelectionModel
  ✅ 3-3 PaneSplitAvailability ✅ 3-4/3-5 窗口尺寸+辅助窗口     ✅ D3 拆文件+两处气味修复

█ 深水（先解契约，再动内核）
  3-7 NotificationPresenter（顺带收编 shellIntegrationState）
  3-8/3-9 URL交互 + AgentNotify 控制器（PLAN 补登）
  3-10 AppComposition          4-4/4-5 CellTextStyler + MarkedTextPresenter
  5-2 AppSettings 子结构化（与 SettingsView/持久化同批）
  最后: A/G/H-hub 内核（syncWorkspaceSwitcherState 显式化之后）
```

**每个 PR 的验收标准**（沿用 PLAN + 本文补充）：
1. 单一簇、纯结构、无行为变化；
2. `swift build` + `swift test`（≥611）+ `scripts/check-architecture.sh` 三绿；
3. D1 相关：`MetalDirectRendererBackend.swift` **零改动**通过编译（§1.3 契约未破）；白盒测试同步迁移；
4. D2 相关：被抽簇的 `@Published` 回写路径经注入而非全局引用；
5. 提交遵循 `docs/git-workflow.md`（一个意图一个 commit，仅署用户本人）。

**止血规则（立即生效，不等重构）**：新 feature 不再默认落入 `AppModel` / `PTYGridView`；属 3a–3h/M 方向的直接建 Feature Controller，属 C4/C8/C9 方向的直接进值类型。

---

## 6. 对 ARCHITECTURE_PLAN.md 的修正清单

| PLAN 条目 | 修正 |
|---|---|
| AppModel "~1632 行 / 14 `@Published`" | 现 1901 行 / 18 `@Published`；新增簇 M（URL/文件交互）与 AgentNotify 门，需补 3-8/3-9 |
| PTYGridView "~1840 行" | 实测 ~2807 行（915–3721 + IME 扩展） |
| AppSettings "混 6 类" | 实为 7 域（漏渲染域 4 字段），需 `RenderingSettings` |
| "AppSettings AppKit 375–571" | 精确为 `FontManager` enum 4 处符号（345/355/438/541），struct 本体零 AppKit |
| 阶段 5 "可选、纯 Core" | 实为跨层批次：SettingsView 绑定 + 持久化迁移同批；前置 3-9 |
| （未登记） | D3 `TerminalCanvasView.swift` 补登为"App/UI 分屏视图层"，含两处软分层气味修复 |
| 阶段 2 "像素滚动收敛" | 已落地且为真组合（非薄壳）；余项：C5 的 `browse*` 状态继续收敛 |

# ProGhostty 架构优化方案

目标：在不改变产品行为的前提下，把"能用但在漂移"的架构收敛成**分层清晰、职责单一、易维护**的结构。所有改动分阶段、可增量落地，每步 build + 全量测试绿。

---

## 一、目标架构（分层与依赖方向）

依赖只允许自上而下，禁止回指：

```
┌───────────────────────────────────────────────────────────┐
│ App 层 (ProGhosttyApp)  —— SwiftUI + AppKit 宿主            │
│  · 组合根 (AppComposition)  · 视图 (RootView/*)             │
│  · 视图模型 (AppModel 瘦身后) + 一组 Feature Controller     │
│  · 窗口 chrome / 外观 (TerminalWindowAppearance 从 Core 移入)│
└───────────────▲───────────────────────────────────────────┘
                │ 只依赖 Core 的公共 API（协议 + 值类型）
┌───────────────┴───────────────────────────────────────────┐
│ Core 层 (ProGhosttyCore)                                    │
│  ┌─ Terminal 域 ──────────────────────────────────────┐    │
│  │ PTY 会话 · VT 桥 (libghostty) · 渲染 backend 三层梯 │    │
│  │ 像素滚动 · 输入状态机 · 值类型帧/布局              │    │
│  └────────────────────────────────────────────────────┘    │
│  ┌─ Workspace 域 ─┐ ┌─ Settings ─┐ ┌─ Plugins ─┐ ┌─Control┐│
│  │ PaneWorkspace  │ │ 拆分后的    │ │ 自洽已隔离 │ │ OSC 协 ││
│  │ Controller(唯一│ │ 设置模型    │ │           │ │ 议     ││
│  │ owner)         │ └────────────┘ └───────────┘ └────────┘│
│  └────────────────┘                                         │
│  ┌─ Persistence · Updates · Diagnostics · ShellIntegration ┐│
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

**四条架构准则（后续所有 PR 的验收标准）：**
1. **Core 不 import SwiftUI**（现已满足，加 CI 守卫防回退）。
2. **Core 中 AppKit 只出现在渲染/视图层**；窗口 chrome、外观主题不属于 Core。
3. **每个"关注点"有唯一 owner 类型**（见第四节责任表）。
4. **依赖注入通过组合根**，而非在类内部 `new` 出协作者。

---

## 二、现状确诊（已逐条读代码 / grep 验证）

| 症状 | 证据 | 归类 |
|---|---|---|
| `AppModel` 兼任组合根 + 视图模型 + 事件路由 + 12 类职责 | AppModel.swift:111-154 构造整个 Core 图；14 个 `@Published`；~1632 行 | 职责过载 |
| `PTYGridView` 一个 NSView 扛 9 类职责 | PTYTerminalEngine.swift:892-2733，~1840 行 | 职责过载 |
| `AppSettings` 单 struct 混 6 类设置 | AppSettings.swift:15-33（通知/shell/字体/主题/语言/快捷键） | 关注点混合 |
| `TerminalWindowAppearance` 窗口 chrome 放在 Core | Core 内定义，仅被 App 层 + 自身测试引用 | 分层错位 |
| `TerminalInputStateMachine` import AppKit 但零 AppKit 符号 | 文件内无 NSEvent/NSColor | 伪依赖 |
| 渲染诊断单 struct 塞 31 个 `metalDirect*` 字段三 backend 共背 | TerminalRendererBackend.swift:283-313 | 职责混合 |
| 像素滚动 owner 分散四处 | PaneScrollCoordinator / ScrollCommitCoordinator / scrollViewport / visualOffsetY | 无单一 owner |
| `.ghosttyVTTextFallback` 作 activeBackend 映射到 CellGrid | PTYTerminalSurfaceRegistry.swift:136 | 误导枚举臂 |

**结论：骨架健康，不重写。** 纯值层（`PaneTreeReducer`/`SplitRatioLayout`/`CellGridModel`/`GhosttyVTBridge`/`WorkspaceStore`）干净可测；降级梯（Metal→CellGrid→Text）是有意设计非冗余；Plugins 已隔离在自己的 feature 模块。问题集中在两个 god-object 和几处分层错位。

---

## 三、分阶段实施计划

### 阶段 0 — 分层守卫与低风险归位（S，先做）
建立"不再漂移"的防线，全是零行为变化的移动/删除：
1. **`TerminalWindowAppearance.swift` 从 Core 移到 App/UI**（audit B2）。仅被 App + 自身测试引用，移动 + 迁测试。
2. **删 `TerminalInputStateMachine` 的伪 `import AppKit`**（无符号使用）。
3. **重命名误导性 API**：`PaneWorkspaceController.closeSelectedTerminal` → `closeActiveWorkspace`（名不符实，实关整个工作区）；修 `TerminalRendererPolicy` 里 `.ghosttyVTTextFallback` activeBackend 死臂（改文档或收敛枚举）。
4. **加 CI 守卫**：脚本断言 `Sources/ProGhosttyCore` 无 `import SwiftUI`，并把"Core 里 AppKit 仅限渲染/视图目录"列为 review 清单项。

### 阶段 1 — 渲染诊断按 backend 拆分（S）
把 `TerminalRendererDiagnostics` 的 31 个 `metalDirect*` 字段抽到 `MetalDirectDiagnostics` 子结构，`TerminalRendererDiagnostics` 持一个可选子结构。CellGrid/Text backend 不再背 Metal 字段。`debugSummary` 拆成分段拼接。**收益**：加 Metal 指标只动一处；三 backend 的诊断契约清晰。

### 阶段 2 — 像素滚动收敛到单一 owner（M，旗舰功能）
把分散的滚动逻辑归到一个 `PaneScrollController`（Core，值/引用类型），拥有：物理（现 `PaneScrollCoordinator`）+ 提交批处理（现 `ScrollCommitCoordinator`）+ `viewport` 偏移状态 + 边缘判定。`PTYGridView.scrollWheel` 只负责把 `NSEvent` 解包后调进去；VT 视口行移动仍由 libghostty (`bridge.scrollViewport`) 负责（保持职责边界）。
- 该 cluster 已被测试直接驱动（processScroll 参数化，测试在 TerminalRendererBackendTests），迁移风险可控。
- **约束**：`MetalDirectRendererView` 通过 `directView.viewport.visualOffsetY` 等公共访问器读滚动状态（MetalDirectRendererBackend.swift:526-531），迁移后这些访问器需保留为转发属性。

### 阶段 3 — 拆分 `AppModel`（L，分多个小 PR）
按 cluster 图把可独立的职责抽成 Feature Controller，`AppModel` 回归"协调 + 发布"本职。抽取顺序（按"干净度"从高到低，每个独立 PR + 测试）：

| # | 抽出类型 | 承接 cluster | 规模 | 风险 |
|---|---|---|---|---|
| 3a | `ConfirmationPrompts`（NSAlert 封装） | I | ~40 | 极低 |
| 3b | `TitleFormatting`（路径/标题格式化纯函数） | L | ~60 | 极低 |
| 3c | `TerminalWindowSizingController`（窗口尺寸几何） | D | ~90 | 低 |
| 3d | `PaneSplitAvailabilityController`（分屏可用性几何） | B 几何部分 | ~120 | 低 |
| 3e | `NotificationPresenter`（toast/in-app 呈现 + 自动消失） | H 呈现部分 | ~90 | 低 |
| 3f | `UtilityWindowController`（设置/插件窗口） | F | ~110 | 低 |
| 3g | `AppComposition`（组合根，从 AppModel.init 抽出依赖装配） | — | ~60 | 中 |
| 3h | `AppearanceViewModel`（主题色派生只读属性） | E 派生部分 | ~90 | 低 |

**保留在 AppModel（不可约的视图模型内核）**：工作区运行时状态数组 + 持久化（A）、事件分发 hub `handle()`（H 路由部分）、switcher 同步（G）、输入路由（C）、布局快照（J）、更新检查适配（K）。
预期 `AppModel` 从 ~1632 行降到 ~1000 行的纯协调。

### 阶段 4 — 拆分 `PTYGridView`（L，分多个小 PR）
把近乎纯计算的 cluster 抽成值类型协作者，NSView 只保留"视图内核"。**关键约束**：`MetalDirectRendererView` 继承并通过公共访问器消费几乎所有行为，所有抽取必须保留这些访问器为转发属性（不能删）。抽取顺序：

| # | 抽出类型 | 承接 cluster | 规模 | 风险 |
|---|---|---|---|---|
| 4a | `PromptCursorInferrer`（prompt 光标推断，近乎纯） | 6 | ~200 | 低 |
| 4b | `GridGeometryFactory` / 扩展 `RenderedGridGeometry`（视口/overscan 几何） | 7 | ~140 | 低 |
| 4c | `GridSelectionModel`（选区锚点/规范化/取文本，纯） | 4 模型部分 | ~130 | 低 |
| 4d | `CellTextStyler`（cell 文本属性/字体/字形矩形） | 1 样式部分 | ~120 | 低 |
| 4e | `MarkedTextPresenter`（IME 呈现解析 + overlay 几何） | 3 呈现部分 | ~130 | 中 |

**保留在 NSView**：`draw()` 入口、`NSTextInputClient` 协议方法、mouse/scroll 事件解包、焦点/响应链/handler 装配（cluster 8）、以及 Metal backend 依赖的全部转发访问器。
预期 `PTYGridView` 从 ~1840 行降到 ~900 行。
（并行目标：`PTYTextView` 同类问题，可选后续处理。）

### 阶段 5 — `AppSettings` 拆分（M，可选）
把单 struct 按域拆成 `NotificationSettings` / `ShellSettings` / `AppearanceSettings` / `KeyboardShortcutSettings`(已存在) 子结构，`AppSettings` 组合它们。字体可用性查询（`NSFont`/`NSFontManager`，AppSettings.swift:375-571）抽到独立 `FontCatalog` 服务，去掉 AppSettings 对 AppKit 的耦合。**收益**：设置项分域清晰，Core 再去一处 AppKit 依赖。

---

## 四、目标责任归属表（唯一 owner）

| 关注点 | 唯一 owner（目标） | 现状 |
|---|---|---|
| PTY I/O | `PTYTerminalSessionManager` | ✅ 已是 |
| VT 语义 | `GhosttyVTBridge` | ✅ 已是 |
| 渲染 backend 选择 | `TerminalRendererPolicy` | ✅ 已是（修死臂） |
| 像素滚动（物理+提交+偏移） | `PaneScrollController`（阶段2 新建） | ❌ 现分散四处 |
| 渲染诊断 | 分 backend 子结构（阶段1） | ❌ 现单 struct 共背 |
| 工作区运行时状态 | `PaneWorkspaceController` | ✅ 已收敛（上一轮） |
| 窗口尺寸几何 | `TerminalWindowSizingController`（3c） | ❌ 现在 AppModel |
| 分屏可用性几何 | `PaneSplitAvailabilityController`（3d） | ❌ 现在 AppModel |
| 通知呈现 | `NotificationPresenter`（3e） | ❌ 现在 AppModel |
| 辅助窗口 | `UtilityWindowController`（3f） | ❌ 现在 AppModel |
| 依赖装配 | `AppComposition`（3g） | ❌ 现在 AppModel.init |
| 窗口 chrome/外观 | App/UI 层（阶段0 移入） | ❌ 现在 Core |
| prompt 光标推断 | `PromptCursorInferrer`（4a） | ❌ 现在 PTYGridView |
| 选区模型 | `GridSelectionModel`（4c） | ❌ 现在 PTYGridView |
| 设置 schema | 分域子结构（阶段5） | ❌ 现单 struct |

---

## 五、执行原则与顺序

- **顺序**：阶段 0 → 1 → 2 → 3(a→h) → 4(a→e) → 5。阶段 0/1/2 吃掉分层错位和旗舰功能收敛；3/4 是背景推进的增量重构，每个子项独立 PR。
- **每个 PR**：单一 cluster、`swift build` + `swift test` 全绿、无行为变化（纯结构）；涉及公共访问器的保留为转发属性。
- **风险控制**：阶段 4 每步先确认 `MetalDirectRendererView` 依赖的访问器仍存在；像素滚动/选区/IME 相关抽取后跑对应现有测试（这些 cluster 已有覆盖）。
- **不做的事**：不重写渲染管线、不动降级梯、不合并语义不同的去抖器、不删有测试覆盖的"仅当前接线下不走"的路径（上一轮教训）。

---

## 六、未决问题（需你拍板）

1. **范围**：这份方案是完整蓝图。你想让我**现在就执行到哪个阶段**？（建议先落地阶段 0+1+2，收益明确、风险低。）
2. **阶段 5（AppSettings 拆分）** 会改设置的持久化结构（子结构嵌套），需迁移已存的用户设置。要不要纳入本轮？
3. 是否需要我把**每个阶段拆成独立的 TaskCreate 任务**以便逐项跟踪？

# ProGhostty 缓冲区搜索（Find）Spec

> 状态：待开发 · 基于 2026-08-16 对 `main`（HEAD `2a91c6d`）的现状测绘
> 关联：`APP_STORE_READINESS_AUDIT.md` §2①（搜索是专业开发者五项缺口之首）
> 本文是"缓冲区搜索"的**开发依据**：目标、非目标、架构归属、数据模型、集成点、不变量、模块拆分、验收标准、分阶段计划。规则与代码冲突时以代码为准。

---

## 1. 目标与非目标

### 目标（MVP）
在终端缓冲区（屏幕 + scrollback，含 alt-screen）里：
1. **Cmd+F** 打开搜索输入；边输边找（incremental）。
2. **高亮所有命中**（屏幕可见的命中；scrollback 里命中在跳转后高亮）。
3. **Cmd+G / Shift+Cmd+G** 上一个 / 下一个命中；命中在视口外时**跳转到该历史行**（不动 VT 视口）。
4. 大小写不敏感（默认），可切大小写敏感。

### 非目标（YAGNI，明确砍掉，后续按需再加）
- ❌ 正则搜索（MVP 只用纯子串匹配）。
- ❌ 跨行匹配（换行符不参与匹配；逐行匹配，与 iTerm2/Ghostty 默认一致）。
- ❌ 替换（replace）。
- ❌ 整词 / 前缀 / 模糊匹配。
- ❌ 跨 pane 全局搜索。
- ❌ 滚动过程中实时重算高亮（高亮只在查询/结果变化时算一次）。
- ❌ 持久化搜索历史 / 搜索状态。

> 这些是**明确的功能边界**，不是"没时间做"。加正则/替换/跨行会让 matcher、高亮映射、结果模型复杂度翻倍，MVP 收益不匹配。

---

## 2. 架构归属（先划清边界，再动手）

搜索状态**不是终端状态**。`libghostty-vt` 仍是 buffer 唯一真相源；搜索是**只读消费者**，通过 `bridge.rows(at:count:)` 读快照，产出派生结果。**绝不在搜索层复制 scrollback / 光标 / 屏幕缓冲。**

| 关注点 | 归属 | 位置 |
|---|---|---|
| buffer 真相源（只读） | `GhosttyVTBridge` → libghostty-vt | `TerminalCore/LibGhostty/` |
| 搜索状态 + 匹配逻辑（纯值类型） | **新建** `SearchState` / `SearchMatcher` | `TerminalCore/Search/` |
| 搜索执行（批量读 `rows(at:)`，后台队列） | **新建** `SearchSessionDriver` | `TerminalCore/Search/` |
| 高亮渲染（渲染后端消费命中） | 既有渲染后端（Metal / cell-grid / 文本） | `TerminalCore/Renderer/` |
| 跳转到历史行（复用 pattern-2 browse） | 既有 `presentBrowseWindow` | `PTYTerminalSurfaceRegistry.swift:688` |
| 搜索输入 UI（find bar） | **新建** SwiftUI 视图 | `ProGhosttyApp/UI/` |
| App 协调（Cmd+F/Cmd+G 接线、把结果喂给 surface） | `AppModel` + `PaneWorkspaceController` | `ProGhosttyApp/UI/` |

**禁止**：
- ❌ 在 Swift 侧自己解析 ANSI/VT 或复制 buffer。
- ❌ 在 render loop 里跑搜索（搜索必须后台队列 + 可取消）。
- ❌ 在 `ProGhosttyCore` 引 SwiftUI（find bar 放 App 层；Search 核心是纯值类型 + 驱动，不碰视图）。

---

## 3. 数据模型（纯值类型，可测）

```swift
// TerminalCore/Search/SearchState.swift  —— 纯值类型，reducer 风格

/// 一个命中。绝对行号 + 列区间（单位：cell，非字符索引）。
public struct SearchMatch: Sendable, Equatable, Identifiable {
  public let id: Int            // 稳定序号（结果集内）
  public let absoluteRow: UInt64  // 与 rows(at:)/presentBrowseWindow 同一绝对行空间
  public let startCol: Int
  public let endCol: Int          // 左闭右开 [startCol, endCol)
}

public struct SearchState: Sendable, Equatable {
  public var query: String
  public var caseSensitive: Bool
  public var matches: [SearchMatch]
  public var currentIndex: Int?   // nil = 无命中
  public var truncated: Bool      // 命中数被截断（见 §6 不变量）
  public var isSearching: Bool

  // reducer：mutating func set(query:) / toggleCase() / next() / previous()
}
```

**为什么列区间用 cell 而非字符索引**：高亮要落在渲染 cell 上，跳转要落到行上；cell 是渲染层的最小寻址单元。字符索引需要和宽字符/组合字符来回换算，纯属自找麻烦（见 §6 宽字符不变量）。

---

## 4. 数据流

```
Cmd+F 打开 find bar
  → AppModel 持有 SearchState（per pane / 聚焦 pane）
  → 每次 query 变化（含 debounce ~150ms）
      → SearchSessionDriver 在后台队列批量读 bridge.rows(at:)
      → SearchMatcher 逐行子串匹配，跳过 spacer cell（§6）
      → 回主线程更新 SearchState.matches / currentIndex
  → 高亮：把当前可见的命中 cell 集合塞进 TerminalRenderFrame（§5 集成点 B）
  → 跳转：命中在视口外 → presentBrowseWindow(topAbsoluteRow: 命中行 − 居中偏移)
  → Cmd+G / Shift+Cmd+G → next()/previous() → 同上
```

**取消**：新 query 进来（或关 find bar）→ 递增 generation token → 后台搜索发现 token 过期即丢弃结果。避免旧结果覆盖新结果。

---

## 5. 集成点（真实类型 + file:line）

### A. 读 buffer（复用，不改）
- `GhosttyVTBridge.rows(at:count:)` → `GhosttyTerminalRowWindow`（`startRow`/`total`/`cols`/`rows`），`GhosttyVTBridge.swift:545`。
- `GhosttyTerminalRowWindow` 定义 `GhosttyVTBridge.swift:124`（已含 `total`，可直接算 scrollback 范围）。
- 批量窗口大小：256 行 / 次，遍历 `[0, total)`。

### B. 高亮渲染（新建通道，最深的改动）
现状：`TerminalRenderFrame`（`TerminalRendererBackend.swift:37`）只有 `frame` + `scrollFrame` + `isFocused` + `presentation` + `generation`，**无命中字段**。

改法（最小侵入）：
1. 给 `TerminalRenderFrame` 加一个字段 `highlightedCells: HighlightSet`（`Sendable & Equatable` 的稀疏集合，如 `[Int: Set<Int>]` 即 `[viewportRow: Set<col>]`，或 `Set<GridCoordinate>`）。
2. 三个后端各消费它：
   - **Metal 直渲**：命中 cell 用反显/背景色叠加（沿用 `MetalOverlayBuffer` 或 cell 背景色分支）。
   - **cell-grid 回退**：`draw(_:)` 命中 cell 刷背景色。
   - **文本回退**：`TerminalAttributedRenderer` 给命中 range 加 `.backgroundColor`（与 cursor 高亮同款机制，`TerminalAttributedRenderer.swift:53`）。

> 绝对行 → 视口行映射见 §6 不变量 #2。高亮输入放 `TerminalRenderFrame` 而非 `GhosttyTerminalFrame`：后者是 VT 快照（真相源），前者是"渲染输入"（含 UI 态），职责不混。

### C. 跳转（复用，不改）
- `PTYTerminalSurfaceRegistry.presentBrowseWindow(session:topAbsoluteRow:visibleRows:)`，`PTYTerminalSurfaceRegistry.swift:688`。pattern-2 已能 park 视口到任意绝对行、不动 VT。
- 居中：`topAbsoluteRow = max(0, match.absoluteRow − visibleRows/2)`。

### D. 菜单 / 快捷键（新建接线）
- 菜单：macOS 标准 `.find` CommandGroup（`ProGhosttyApp.swift` 现有 `CommandGroup(replacing: .newItem/.appSettings)` 旁加 `CommandGroup(replacing: .textEditing)` 或自定义 Find 项）。
- 快捷键：Cmd+F / Cmd+G / Shift+Cmd+G 走系统 find 语义；**不加进** `KeyboardShortcutAction` 枚举（那是 App 级自定义动作，find 是标准命令，且避免与 `AppSettings.swift:274` 的 defaults 崩溃隐患耦合）。

### E. find bar UI（新建）
- 放 `ProGhosttyApp/UI/`（SwiftUI 或 NSTextField overlay 到 pane chrome），**不**进 Core。
- 结构参考现有 `TerminalPaneChrome` / `SideInput` 的 overlay 做法。

---

## 6. 关键不变量（必须守住，否则出 bug）

1. **宽字符 spacer 必须跳过**：搜索在逐 cell 匹配时，`cell.width == .spacerTail || .spacerHead` 的 cell（codepoint 是 `' '`）**不能参与匹配**——否则"中文"会匹配到 `中 ` 的假命中，和刚修的复制空格 bug 同源（`PTYTerminalEngine.swift:1228` 已是同款守卫）。matcher 按"逻辑字符序列"匹配，每个非 spacer cell 一个字符。

2. **绝对行空间唯一**：匹配结果、`rows(at:)`、`presentBrowseWindow` 必须用**同一个绝对行号**（`rows(at:)` 的 `startRow` 空间，`total` = history + screen）。
   - 浏览态：视口 row 0 的绝对行 = `scrollFrame.viewportStartRow`（`GhosttyTerminalScrollFrame`，`GhosttyVTBridge.swift:141`）→ 高亮 cell 的视口行 = `absoluteRow − viewportStartRow`。
   - 实时态（屏幕可见）：屏幕顶行绝对行 = `total − screenRows` → 视口行 = `absoluteRow − (total − screenRows)`。
   - **两种态映射不同，别混。** 高亮集合在喂给 `TerminalRenderFrame` 前先换算成视口行。

3. **不阻塞 render loop / 主线程**：搜索在专用后台队列，按 256 行批量读 `rows(at:)`（每次锁一次桥，读完释放，不跨批次持锁）；结果回主线程。禁止一次性 `plainText()` 拉全量 scrollback 做匹配（无坐标 + 大内存）。

4. **命中数有界**：scrollback 上限 10000 行（`GhosttyVTBridge.swift:286`）。匹配结果截断到 `maxMatches = 1000`，置 `truncated = true`；避免"输入 `e` 匹配 5 万次"的内存/高亮爆炸。

5. **不复制终端状态**：`SearchState.matches` 是**派生只读结果**（绝对行 + 列区间），不是 buffer 副本。buffer 更新（新输出）时，匹配结果允许短暂过期，下一次查询/跳转前重算；**不做**"输出变化即重算"的实时同步（YAGNI，见 §1）。

6. **alt-screen**：vim/less 里搜索也生效（读的是当前活动屏）；跳转逻辑在 alt-screen 下不调 `presentBrowseWindow`（alt-screen 无 scrollback 浏览），只高亮 + 视口内导航。

---

## 7. 模块拆分（新建文件清单）

```
TerminalCore/Search/
  SearchState.swift        // SearchMatch + SearchState（纯值类型，reducer）
  SearchMatcher.swift      // 逐行子串匹配（跳过 spacer，输出 [SearchMatch]），纯函数
  SearchSessionDriver.swift// 后台批量读 rows(at:)，generation 取消，回主线程回调
TerminalCore/Renderer/
  TerminalRendererBackend.swift  // TerminalRenderFrame 加 highlightedCells 字段（改）
  MetalDirectRendererBackend.swift / GhosttyVTCellGridRendererBackend.swift
                              // 消费高亮（改）
  GhosttyVTTextRendererBackend.swift / TerminalAttributedRenderer.swift
                              // 消费高亮（改）
ProGhosttyApp/UI/
  TerminalFindBar.swift     // Cmd+F 搜索输入条（新建，SwiftUI）
  AppModel.swift            // SearchState 持有 + Cmd+F/G 接线（改）
ProGhosttyApp/
  ProGhosttyApp.swift      // 菜单 CommandGroup(.find)（改）
```

> 复用而非新建：匹配结果跳转用 `presentBrowseWindow`；输入框焦点/快捷键用系统 find 语义；高亮复用 cursor/背景色渲染分支。

---

## 8. 验收标准

1. `echo 一堆英文和中文` 后 Cmd+F 输入关键字，**屏幕命中高亮**，`中文字符` 搜索不出现假命中（无 spacer 空格命中）。
2. Cmd+G / Shift+Cmd+G 在命中间循环，命中在 scrollback 深处时**视口跳转到该历史行**，且**不移动 VT 视口**（退出搜索后回到原浏览位置或底部）。
3. 连续快速改 query，最终显示结果与最后一次 query 一致（无旧结果覆盖，generation 取消生效）。
4. 大 scrollback（`seq 1 30000`）下搜索不卡 UI（后台执行 + 批量读 + 截断）。
5. 大小写开关生效；空 query 清空高亮。
6. alt-screen（vim）内搜索可用（高亮 + 视口内导航，不触发 scrollback 跳转）。
7. `swift build` + `swift test` + `check-architecture.sh` 全绿；Search 核心是纯值类型有直接单测。

---

## 9. 分阶段计划

| 阶段 | 内容 | 产出 / 验收 |
|---|---|---|
| **P1 纯逻辑** | `SearchState` + `SearchMatcher`（逐行、跳 spacer、大小写、截断） | 单测覆盖 §8 #1 的 matcher 语义 |
| **P2 驱动** | `SearchSessionDriver`（后台批量 `rows(at:)` + generation 取消） | 单测：假 query 竞争不覆盖；大 buffer 不阻塞 |
| **P3 高亮** | `TerminalRenderFrame.highlightedCells` + 三后端消费 | 手测 §8 #1；cell-grid 回退也高亮 |
| **P4 导航** | 命中→视口映射 + `presentBrowseWindow` 跳转 + 实时态映射 | 手测 §8 #2、#6 |
| **P5 UI/接线** | `TerminalFindBar` + 菜单 CommandGroup(.find) + AppModel 持有状态 | 手测 §8 #3、#5 |

> 每阶段独立可测、可合入；P1 纯逻辑先行，与渲染/UI 解耦，风险最低。

---

## 10. 测试

- **纯逻辑**（swift-testing，`Tests/ProGhosttyCoreTests/SearchMatcherTests.swift`）：
  - 命中/未命中/边界（行首尾命中）。
  - 大小写敏感开关。
  - **宽字符 spacer 跳过**（构造 `中(wide)+空格(tail)+文(wide)` frame，搜索"中文"命中、搜索"中 "不误命中）。
  - 截断（命中超 1000 置 `truncated`）。
- **驱动**（`SearchSessionDriverTests.swift`）：generation 取消；结果集与 query 一致。
- **集成**（复用 `GhosttyVTBridgeTests` 的真 VT 桥）：写文本 → `rows(at:)` 读到 → matcher 命中。
- **导航**（`TerminalSurfaceTests.swift`）：跳转后 `browseTopRow` 指向命中行；实时态高亮映射正确。

---

## 11. 风险与注意

- **高亮通道是最大改动面**：`TerminalRenderFrame` 加字段会波及三个后端 + 所有 `render(_:)` 调用点，需保证 `Sendable/Equatable` 与既有 init 兼容（新增字段给默认值，避免全量改 init 调用）。
- **绝对行映射易错**：实时态 vs 浏览态两种映射（§6 #2）是 bug 高发区，单独抽一个纯函数 `viewportRow(for absoluteRow:)` 并单测。
- **桥锁竞争**：搜索批量读与渲染 `frame()/scrollFrame()` 抢同一 `NSLock`（`GhosttyVTBridge.swift:684`）。批量 + 后台 + 每批释放锁，避免长时间持锁卡渲染。
- **`KeyboardShortcutAction` 不动**：find 走系统命令，不新增该枚举 case（避开 `AppSettings.swift:274` 的 defaults 崩溃隐患，见 `APP_STORE_READINESS_AUDIT.md` §4）。

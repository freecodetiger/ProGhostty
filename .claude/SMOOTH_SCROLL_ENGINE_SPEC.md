# 方案：现代化平滑滚动引擎（display-link 驱动）

状态：设计稿 · 不计成本追求网页级滚动手感
分支建议：`feat/smooth-scroll-engine`（基于 main）

## 0. 一句话

把滚动从**事件驱动**（每个 NSEvent 直接渲一帧）升级为**节拍驱动**（CADisplayLink 按屏幕刷新取样一个连续滚动位置），并突破渲染侧"一帧最多动 ±1 行"的结构性天花板，从根上做到网页/原生组件那种匀速丝滑 + 惯性缓动。

---

## 1. 为什么现在做不到丝滑（已调研坐实）

三个层面的结构性原因，全部有代码证据：

1. **无渲染节拍**：全仓无 `CADisplayLink`/`CVDisplayLink`/`displaySyncEnabled`/`presentsWithTransaction`（grep 为空）。每个 `scrollWheel` NSEvent 直接 `viewport.didSet → needsDisplay → present`（PTYTerminalEngine.swift:911-912、MetalDirectRendererBackend.swift:312-317）。输入事件节奏不均匀、且 ≠ 屏幕刷新节奏 → 帧间隔忽长忽短、每帧位移忽大忽小 = 稍快就卡。

2. **一帧最多动 ±1 行（结构天花板）**：
   - 像素偏移在绘制时被 clamp 到 `±cellHeight`（`visualScrollTranslationY`, PTYTerminalEngine.swift:1208-1209；Metal 同义 `pixelRemainderY*scale`）。
   - overscan 只取 2 行（`scrollFrame(overscanTop:2, overscanBottom:2)`，四处硬编码），C shim 更是硬顶 4 行（ProGhosttyGhosttyVT.c:596-597）。
   - Metal 离屏纹理只按 viewport 行数分配（不含 overscan）。
   - **合起来**：视觉上移动超过 ~1 行就必须"提交一整行到 VT"。快滚时退化成逐行提交，每行都是一次 vtQueue 异步往返 + 整帧 scrollFrame 快照 → 追不上、卡顿。这是之前"数字逐行翻动"的根。

3. **无自有惯性**：不拦截系统 momentum、也没有自己的速度衰减模型（`suppressMomentumScroll` 只在 `prepareForUserInput` 后短暂生效）。松手即停，缺少现代交互的滑行减速感。

**已纠正的认知**：生产走的是**异步 vtQueue 提交路径**（`setViewportScrollHandler` 在 PTYTerminalEngine.swift:211 无条件设置），registry 里的同步 `renderScrollCommit` fallback 是死代码。

---

## 2. 可复用的资产（不推倒重来）

调研确认这些是**纯值类型、零 UI 耦合、可单测**，是新引擎的地基：
- `PaneScrollCoordinator`（CellGridModel.swift:330）——"累积像素、跨格吐整行"的积分器，本质已是连续位置的离散采样。
- `ScrollCommitCoordinator` / `PaneScrollController`、`TerminalViewport`、`ViewportController`、`MetalTerminalRenderPlan`/encoder。

新引擎不是从零，而是**把这些纯逻辑从"事件驱动"重挂到"节拍驱动"之下**，并补上渲染侧的多行能力。

---

## 3. 目标架构

严守边界，避免造出第二个 god-object。引擎**只拥有"滚动位置如何随时间演化"**，不碰 VT/渲染/事件。

```
┌ 输入侧 (view, 薄) ───────────────────────────┐
│ scrollWheel(NSEvent):                          │
│   - 区分 precise/line, 取 scrollingDeltaY       │
│   - 拦截系统 momentum(自己做惯性)               │
│   - engine.addWheelInput(delta, phase, time)   │
└───────────────┬───────────────────────────────┘
                ▼
┌ SmoothScrollEngine (Core, 纯逻辑, 可单测) ───────┐
│ 状态: targetPosition(连续,浮点行)               │
│       currentPosition(连续) + velocity          │
│ addWheelInput: 累积 target / 注入速度            │
│ tick(now): 朝 target 缓动前进 or 惯性衰减        │
│            → 返回 currentPosition                │
│ 输出映射: position → (topRow: Int, offsetY: px)  │
│ 不知道"提交行"、不碰 AppKit/Metal/bridge         │
└───────────────┬───────────────────────────────┘
                ▼
┌ 节拍层 (view/backend, 薄) ──────────────────────┐
│ CADisplayLink(主线程) 每次刷新:                  │
│   pos = engine.tick(displayTime)                │
│   → 请求渲染 [topRow, topRow+visibleRows] 窗口   │
│      在亚行偏移 offsetY 处, 一次呈现             │
│   活跃滚动时才跑, 静止/到位后停(省电)            │
└───────────────┬───────────────────────────────┘
                ▼
┌ 渲染侧 (需扩展) ────────────────────────────────┐
│ 能在"任意 topRow + 任意亚行偏移"渲染一个行窗口   │
│ (突破 ±1行 clamp + 加大/按需 overscan 缓冲)      │
│ VT 行提交与视觉滑行解耦: 提交在后台懒惰跟进      │
└─────────────────────────────────────────────────┘
```

关键设计原则：
- **引擎里没有"格/行提交"的概念**——只有连续位置。这一下消灭我们受的"跨格接缝"折磨。
- **输入只喂数据,渲染只由 display-link 触发**——帧间隔恒定 = 丝滑地基。
- **VT 行提交与视觉解耦**——滑行由渲染侧的大 overscan 窗口承载,VT 视口的整行推进在后台懒惰跟上,不再每帧同步往返。

---

## 4. 最硬的一环：渲染侧能否"任意行窗口 + 任意偏移"

这是整个方案的成败点。引擎再完美，如果渲染一帧只能画 ±1 行，快滚照样跳。三条候选路线：

**路线 R1（推荐）：加大 overscan 缓冲 + 解除偏移 clamp。**
- C shim `proghostty_vt_scroll_snapshot` 的 4 行硬顶（ProGhosttyGhosttyVT.c:596-597）改为可配置的较大值（如按 visibleRows 或固定 32 行）。`copy_screen_rows`（:364）本就支持任意 `start_row/row_count`，能力已在，只是被 cap 限制。**无需改 vendored Zig。**
- 解除 `visualScrollTranslationY` 的 `±cellHeight` clamp（PTYTerminalEngine.swift:1208），允许偏移在大 overscan 范围内自由平移。
- Metal 离屏纹理按 viewport+overscan 行数分配（当前只按 viewport）；`MetalCellInstanceBuffer`/dirty-tracking 适配可变行数。
- 效果：一帧可平滑跨多行（在 overscan 缓冲内），VT 整行提交在后台按累计位置懒惰跟进（把可视 topRow 拉回缓冲中部）。

**路线 R2（更彻底）：直接从 scrollback 渲任意行窗口，不用 VT 视口。**
- 用 C shim 的 `copy_screen_rows` 直接读"当前滚动位置对应的任意 N 行"，渲染完全脱离 VT viewport 的整行提交。VT viewport 只在需要交互（如 TUI）时才动。
- 最接近"网页浮动位置"的模型，接缝最少；但改动最大，且要处理 scrollback 行号与实时输出的同步。

**路线 R3（保守）：只加节拍,不改渲染多行能力。**
- 只上 display-link 平滑取样,但仍受 ±1 行限制。能改善"事件节奏抖",但快滚仍会因单帧多行而跳。**不足以达到网页级**,不推荐作为终态。

**建议**：R1 作为主线（能力已在 C shim,风险可控,不碰 vendored Zig,足以支撑多行/帧平滑）。R2 作为未来演进备选。

---

## 5. 惯性 / 缓动

- **拦截系统 momentum**：`scrollWheel` 里丢弃 `momentumPhase` 非空事件（扩展现有 `suppressMomentumScroll` 机制），改由引擎自己合成惯性——因为系统 momentum 的投递节奏不受我们的渲染时钟控制,混用会打架。
- **速度模型**：手势阶段累积速度；`.ended` 后引擎进入惯性衰减（指数衰减 or 摩擦模型），display-link 每帧推进直到速度阈值以下停止。
- **缓动**：离散 wheel（鼠标滚轮，非连续）可选做"朝目标位置的临界阻尼缓动"，让每格滚动也顺滑。
- 参数（衰减系数、缓动时长）先取业界经验值,再手调。

---

## 6. 分阶段实施（每步 build + test + 手测绿；每步独立价值）

1. **`SmoothScrollEngine` 纯逻辑 + 单测**（Core，零 UI）：连续位置 + 速度 + tick 缓动/惯性 + position→(topRow,offset) 映射。**先把物理做对、做可测**，脱离渲染独立验证（这是当前完全缺失的——现在滚动只能靠反复手动复现）。
2. **CADisplayLink 节拍层**：在 live-render view/backend 挂 display-link（主线程），活跃滚动时驱动 `tick`→设偏移→present；静止停。先在**现有 ±1 行能力内**跑通节拍（此时快滚仍受限，但能验证节拍链路 + 惯性手感）。
3. **渲染侧 R1**：加大 overscan（C shim 解 cap + 四处 fetch 调大）、解除偏移 clamp、Metal 纹理/instance buffer 适配可变行数。突破多行/帧天花板。
4. **VT 提交解耦**：整行提交改为后台懒惰跟进（把可视窗口拉回 overscan 缓冲中部），不再每格同步往返。
5. **惯性/缓动打磨** + 参数手调到网页级手感。
6. **收尾**：移除旧的事件驱动 present 触发（`viewport.didSet` 的 needsDisplay、`presentViewportChange` 事件路径），统一到 display-link；移除死代码（同步 renderScrollCommit fallback，若确认无用）。

每阶段都可交给你手测,不满意就地调,不盲目往前。

---

## 7. 风险与取舍（诚实）

- **最大风险在渲染侧 R1**，不在引擎本身。加大 overscan 意味着每帧渲染更多行（cell 拷贝 + GPU 上传更多）——要测性能，overscan 深度需平衡（够快滚一帧的位移，又不过大拖慢）。Metal 纹理/dirty-tracking 改可变行数有一定改动面。
- **display-link 生命周期**：必须只在活跃滚动时跑、静止即停,否则白耗电/GPU。要处理多 pane、失焦、窗口隐藏。
- **与实时输出的交互**：滚动浏览历史时若有新输出（如 `tail -f`），位置锚定策略要明确（跟随底部 vs 保持浏览位置）——现有逻辑有 pinned-to-bottom 处理,要接进新模型。
- **触控板 vs 鼠标滚轮**：两种输入特性差异大（连续 vs 离散、有无系统 momentum），引擎要分别处理好。
- **回归面**：滚动是高频核心路径，改动大。严格分阶段 + 每阶段手测 + 保留单测,避免像这次抖动排查那样反复。
- **纯逻辑引擎的价值**：即使渲染侧慢慢演进,第 1 步的可测引擎本身就消除了"滚动逻辑无法单测、只能手动复现"的长期痛点。

---

## 8. 落地形态小结

- **新增**：`SmoothScrollEngine`（Core，纯值类型/逻辑）+ 其单测；display-link 适配层（view/backend）；C shim overscan 参数化。
- **改造**：`scrollWheel` 输入喂给引擎；渲染侧解 clamp + 大 overscan + 可变行数；VT 提交懒惰化。
- **退役**：事件驱动的 present 触发路径；同步 renderScrollCommit 死代码。
- **不动**：libghostty-vt 的 Zig 源（只调 C shim 的参数上限）；VT 语义/解析。

---

## 9. 待你确认

1. 渲染侧走 **R1（加大 overscan + 解 clamp，推荐）** 还是要我进一步评估 **R2（任意 scrollback 窗口，最彻底但改动最大）**？
2. 分阶段落地（1→6）认可吗？还是要调整顺序/粒度？
3. 惯性缓动：要**完全自研惯性**（拦截系统 momentum），还是先用系统 momentum 事件喂进引擎（较省事但节奏对齐差些）？我倾向自研。

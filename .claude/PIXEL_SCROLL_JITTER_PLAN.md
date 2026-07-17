# 修复方案：像素滚动抖动

分支建议：`fix/pixel-scroll-jitter`（基于 main；诊断探针在临时 `debug/scroll-jitter` 分支，不进正式修复）

## 1. 问题

像素级平滑滚动时内容高频微抖（每次行提交处约 ≤1 行的位置不连续，120Hz 下呈现为振动）。像素滚动是 ProGhostty 独有功能，无上游参照。

## 2. 根因（已逐行代码坐实）

抖动是**"偏移 rebase 与内容行提交非原子"**导致的一帧位置不一致，叠加**接线缺失**放大：

### 2a. 接线缺失（次要，但真实）
生产用 `PTYTerminalSessionManager`（AppModel.swift:124-125）。它的 `init`（PTYTerminalEngine.swift:344）**从不调用 `setViewportScrollHandler`**，所以其 registry 的 `viewportScrollHandler == nil`（探针 `hasHandler=false` 证实）→ 滚动走 registry 的**同步 fallback**（PTYTerminalSurfaceRegistry.swift:497-505）：主线程同步 `bridge.scrollViewport` + `renderScrollCommit`（整帧重渲）+ rebase。设计好的异步路径（`PTYTerminalSessionManager.scrollViewport` :467 → vtQueue → `finishQueuedViewportScroll`）只被**未实例化的死类 `PTYTerminalEngine`**（:211）接线，生产从未走到。

### 2b. 偏移/内容非原子（核心）
两条路径**都**有的顺序问题，`processScroll` 行提交分支（PTYTerminalEngine.swift:1384-1405）：
1. **先** `viewport = TerminalViewport(visualOffsetY: pixelRemainderY)`（:1385）——此时 `pixelRemainderY` 已是**跨过一个 cell 高度后 rebase 的新小余数**（如 -20 → -0），但 **VT 内容还没滚动**。→ 视图立刻用"旧内容 + 新余数"画一帧，位置向回跳近一个字高。
2. **再** `commitViewportScroll`（:1396）→ 同步路径里 `bridge.scrollViewport`（内容才移 1 行）+ `renderScrollCommit`（渲新内容）+ `resetViewportStartRowKeepingVisualOffset`（又设 offset = pixelRemainderY）。

于是每次行提交存在一个瞬态：**offset 已 rebase、内容还没移**（步骤1），下一刻内容追上（步骤2）。两帧净位置差 ≤1 行 → 抖动。

**这是设计层面的时序缺陷，不是纯接线 bug。** 之前我一度说"接上异步路径即可"，经逐行核对后更正：异步路径同样以 :1385 提前 rebase offset 开头，同样有这个瞬态；它只是把内容移动挪到 vtQueue，反而可能让"offset 新 / 内容旧"的窗口更长。

## 3. 修复策略

核心原则：**任何一帧绘制时，`visualOffsetY` 必须与当前实际的 VT 内容行位置一致——offset 的 rebase 只能在内容行真正移动后、且与新内容同一帧生效。**

分两步，先低风险验证，再按需深入：

### 步骤 A（先做，验证接线假设）：接上异步提交路径
在 `PTYTerminalSessionManager.init`（PTYTerminalEngine.swift:344）补上 `PTYTerminalEngine.init:211` 那段 `setViewportScrollHandler` 接线，让生产走异步路径（移出主线程、先 flush 输出、用新鲜 scrollbar 判边缘、rebase 与 snapshot 一起回主线程）。
- 这是最小改动，且是设计者本意的路径。
- 落地后**实测**：抖动是否减轻/消除。异步路径至少消除了"主线程同步整帧重渲与逐帧像素绘制打架"这一层。
- 风险：`PTYTerminalEngine` 与 `PTYTerminalSessionManager` 是同文件两个类，接线要确认 registry 引用一致、无重复接线。

### 步骤 B（若 A 后仍有残余抖动）：修 offset/内容原子性
不在 `processScroll` 提前用新余数设 viewport；改为：
- 行提交前，视图保持**用提交前的完整偏移**绘制（内容未变，位置连续）；
- 待提交完成（新内容帧到达）后，**同一帧**内把 startRow 推进 + offset rebase 成新余数。
即让 `resetViewportStartRowKeepingVisualOffset` 与新 `scrollFrame` 的应用严格绑定，`processScroll` 不再抢先 rebase。
- 这一步动 `processScroll` 的提交分支 + `finishQueuedViewportScroll`/`renderScrollCommit` 的 offset 设置时机，是核心路径，需小步 + 每步实测。

## 4. 实施顺序与验证

1. 开 `fix/pixel-scroll-jitter`（基于 main，**不带**任何诊断探针）。
2. **步骤 A**：补接线 → build + test + guard → 构建 bundle → 你手测滚动顺滑度。
3. 若 A 已足够顺滑 → 提交、结束。
4. 若仍抖 → **步骤 B**：调 offset rebase 时序 → 再手测。
5. 每步 `swift build` + `swift test`（518）+ `./scripts/check-architecture.sh` 绿。
6. 全程用带 `PROGHOSTTY_RENDER_DEBUG` 的调试构建，可临时加最小探针验证 offset/内容是否同帧一致，验证后移除。

## 5. 诚实的不确定性

- 步骤 A **可能不足以完全消除抖动**（因为 2b 的时序缺陷两路径都有）。我按"先接线、实测、再决定是否做 B"的顺序,避免一次性大改核心路径。
- 步骤 B 的具体实现要在 A 的实测结果出来后才能精确设计（取决于异步路径下 offset/内容的实际时序）。
- 不排除还有第三层因素（如 Metal `presentationTranslationY` 与 CG 路径的偏移应用差异）——若 A+B 后仍有微抖，再针对渲染后端的偏移应用排查。

## 6. 已确认的决策

1. **渐进路线**：先做步骤 A（补异步提交接线）→ 手测 → 仍抖再做步骤 B（offset/内容原子性）。每步实测,核心路径最小改动。
2. **先修现有机制**：按现有设计（整行提交 + overscan + 亚行偏移）修 bug,本轮不做架构级重构(更大 overscan 缓冲 / CADisplayLink 等构想暂不纳入)。

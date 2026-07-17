# Pattern 2 SPEC：直接从 scrollback 按偏移渲染的平滑滚动

> **这份文档自包含。** 新对话窗口只读这份 + 文末"必读上下文"即可接手开发。
> 状态：待实现 · 分支：将新建 `feat/smooth-scroll-pattern2`（基于 main）
> 决策来源：三份 subagent review（可行性 / 最佳实践 / pattern 2 勘察）一致推荐。

---

## 0. 背景：为什么是 pattern 2（务必先理解，否则会重蹈覆辙）

ProGhostty 要做"网页级"平滑滚动。此前尝试过两次都失败，**根因 100% 相同**：

**Pattern 1（已放弃）**：把 viewport + 上下各 24 行 overscan 一次性画进一张大 Metal 纹理，滚动时平移这张纹理选出可视 band；滚超缓冲就"提交整行到 VT"（异步 vtQueue）再重新抓快照居中。
- 致命缺陷：**偏移(主线程、连续) 与 VT 内容提交(异步、整行) 是两个时钟，永远对不齐** → position 横跳、非原子闪帧（`.claude/PIXEL_SCROLL_JITTER_PLAN.md` 的 "2b"）。加守卫防不住，因为异步 `finishQueuedViewportScroll` 在 registry 里 render-then-reset。
- 且实测：大多数 fling 都超 24 行缓冲，所以缺陷是常态不是边缘。

**Pattern 2（本方案）**：**不缓存、不平移 band、滚动中不提交 VT。** 每一帧直接从 scrollback 按 `(topAbsoluteRow, P)`（绝对行号 + 亚行像素偏移）取"这一屏需要的行(含顶/底半行)"，按 P 偏移直接画。
- 滚动位置是纯值 `(topAbsoluteRow, P)`，渲染器直接消费，**VT 浏览时根本不参与**。每帧天然自洽 → **整类抖动 bug 从架构上消失**（不是防，是不存在）。
- 无缓冲深度上限（任意远滚）。命中测试更简单。tail -f 锚定更干净。
- 代价：每帧重取+重画可视行（~30-52 行 ≈ 0.2-0.25ms，120Hz 预算 8.3ms 的 ~3%，可接受；GPU 终端本就廉价做脏渲染）。

**一句话**：pattern 1 是"预渲染一大块然后平移，块不够就同步异步真相源"——同步就是 bug 源；pattern 2 是"每帧直接按当前偏移从真相源取数画"，没有同步、没有上限。

<!-- CHUNK-2 -->

## 1. 核心模型

滚动位置 = 连续量,由 `SmoothScrollEngine.position`(points)映射:
- `topAbsoluteRow: UInt64` — 可视区顶部对应的**绝对 scrollback 行号**(与 VT viewport 解耦)。
- `P: CGFloat` — 亚行像素偏移,范围 `[0, cellHeight)`,即 position 对 cellHeight 取余。
- `rowDelta = Int(position / cellHeight)`;`topAbsoluteRow = baseRow - rowDelta`;`P = position - rowDelta*cellHeight`。
- 符号沿用 `visualOffsetY`:正 = 向上看历史(topAbsoluteRow 减小),负 = 向下(增大)。

每帧渲染 = 纯函数:`(topAbsoluteRow, P) → 取 [topAbsoluteRow-1, topAbsoluteRow+visibleRows+1) 行 → 按 -P 平移画`(多取上下各 1 行覆盖半行,scissor/clip 到 viewport)。

**关键不变式**:滚动浏览期间 VT viewport 不动,`topAbsoluteRow` 是唯一真相。没有"提交"、没有 rebase、没有 `resetViewportStartRowKeepingVisualOffset`。

## 2. 数据侧:新增按绝对行取窗口的 shim + bridge

现有 `copy_screen_rows`(`Sources/ProGhosttyGhosttyVT/ProGhosttyGhosttyVT.c:371`)**已支持**任意 `start_row + row_count`(用 `GHOSTTY_POINT_TAG_SCREEN` 按绝对 y 取,已核实)。但没有 Swift/bridge 入口——`scrollFrame` 只暴露 viewport±overscan。

**新增**(~70 LOC,照抄现有代码风格):
- C: `proghostty_vt_rows_at(vt, start_row, row_count, out)` — 调 colors + `copy_screen_rows`,返回无 overscan 的裸行数组结构。头文件同步声明。
- Swift bridge: `GhosttyVTBridge.rows(at startRow: UInt64, count: Int) throws -> [GhosttyTerminalCellRow]`,复用现有 `Self.rows(from:rowCount:cols:)` 映射。
- 绝对行语义:`scrollbar.offset` = viewport 顶的绝对行号(`absoluteBaseRow(for:)` PTYTerminalEngine.swift:2189 已这么用);`total` = 全部行数;`length` = viewport 高。`topAbsoluteRow` 直接是 `scrollbar.offset` 坐标系里的值。

## 3. 渲染侧:一趟直画,复用顶点构建器,删掉 band/composite

现有顶点构建器 `buildBackgroundVertices`(MetalDirectRenderEngine.swift:1075)/`buildGlyphVertices`(:1111)本就是"给一组 cell + translationY 就画",不知 overscan/viewport。pattern 2 = 用取到的行拼一个 `GhosttyTerminalFrame`,`translationY = -P*scale`,调同样构建器,**直接画到 drawable**(不经离屏纹理)。

**改**(`MetalDirectRenderEngine.render` 主体重写,净 −150~−250 LOC):
- 删:离屏纹理(`renderTargetSize` overscan 尺寸、`offscreenTexture`)、composite quad + `compositePipeline`、`sceneTranslationY=0`/`presentationTranslationY` 两趟结构、`translationYOverride` overlay 管线。
- 留(复用):顶点构建器、glyph atlas + 纹理缓存、background/glyph pipeline、**`prefersAsyncPresent` + in-flight 信号量(pattern 2 更需要)**、async completion。
- overlay(光标/选区/marked)的 `overscanTopRows` 偏移项去掉,translationY 统一为 `-P*scale`。
- **设备像素对齐**:`P*scale` 平移必须 snap 到整数设备像素(Retina 2x),否则字形 shimmer(最佳实践 review 明确)。

## 4. display-link 节拍层(全新,R1.2 从未落地)

- 平台提 **macOS 14**(`NSView.displayLink(target:selector:)` 需要):`Package.swift .v14` + `README`(正文+badge)+ `scripts/build-app-bundle.sh`(LSMinimumSystemVersion 14.0)。
- `scrollWheel`:丢 `momentumPhase` 非空事件(自研惯性,Ghostty 同做);began/changed → `engine.addWheelInput`;ended → `.ended`;discrete(鼠标滚轮)→ `addDiscreteScroll`;首次输入 `startScrollDisplayLink()`。
- **物理步进用 `link.targetTimestamp` 而非 `timestamp`**,按实测 delta 积分(ProMotion 24-120Hz 变刷新率,最佳实践 review 引 WWDC21)。设 `preferredFrameRateRange` 允许高刷(否则被压 60)。
- tick:`engine.tick(targetTimestamp)` → 算 `(topAbsoluteRow, P)` → 取行 → 画;`!engine.isActive` → 停 link。
- `startScrollDisplayLink` 内**先**置 `scrollActivityHandler?(true)`(→ backend `prefersAsyncPresent=true`)**再**加 link,保证首帧已 async。停时置 false。
- 边缘(`topAbsoluteRow` 到 0 或 `total-length`):clamp + 引擎 velocity 归零(soft stop),停 link。不 thrash。
- present 用帧配速变体(`presentDrawable:afterMinimumDuration:`)而非裸 present(最佳实践 review 建议,可选优化)。

## 5. 命中测试(更简单,已就位)

`RenderedGridGeometry`(PTYTerminalEngine.swift:2893)已带 `absoluteBaseRow` + `translationY`,`selectionPoint(at:)` 已算 `absoluteRow = absoluteBaseRow + coordinate.row`。pattern 2 直接:`absoluteBaseRow = topAbsoluteRow`,`translationY = -P`。比 pattern 1"减 overscan band 再折回"更直接。选区/链接/URL/IME 逻辑不变,setup 更简单。**红线**:渲染实际用的 `(topAbsoluteRow, P)` 与 geometry 的 `(absoluteBaseRow, translationY)` 必须是同一对值。

## 6. 实时输出 / tail -f 锚定

浏览位置 `topAbsoluteRow` 与 VT viewport 解耦。新输出追加只增大 `total`,`topAbsoluteRow` 不动 → 浏览内容自动稳定,**无需 pattern 1 的 pinned 机制**。唯一要处理:scrollback 满(`maxScrollback` 默认 10000,GhosttyVTBridge.swift init)淘汰最老行时**绝对行号整体移位** → 检测 `total`/offset 变化,相应调 `topAbsoluteRow` 保持同一内容可见(单标量,远比 pattern 1 简单)。"跟随底部"(pinned to bottom)= `topAbsoluteRow` 自动追 `total-length`。

<!-- CHUNK-3 -->

## 7. 分步实施（每步 build+test+guard 绿 + release bundle 手测；每步独立 commit 可 revert）

> **手测前必做**（见 CLAUDE.md「运行前必做清单」）：确认 libghostty-vt 是 ReleaseFast → `./scripts/build-app-bundle.sh release` → 验 bundle 二进制 mtime 比源码新 → 杀旧进程再启 bundle 内二进制。`swift build` 不刷新 bundle！

1. **shim + bridge 按绝对行取窗口**（第 2 节）。单测：取任意 start/count 返回正确行、边界钳制。无渲染改动,静止不变。
2. **平台提 v14 + 接 `scrollActivityHandler`**（backend `directView.scrollActivityHandler = { self.engine?.prefersAsyncPresent = $0 }`）。build 绿。
3. **渲染引擎改直画**（第 3 节）：给定 `(rows, P)` 直接画到 drawable,删离屏/composite。**先用现有事件驱动路径喂固定 (viewport, P=0) 验证静止/打字逐像素不变**（这一步不动滚动,只换渲染结构,是最危险的一步,务必逐像素比对）。
4. **display-link 节拍 + 引擎驱动**（第 4 节）：tick 算 `(topAbsoluteRow, P)` → 取行 → 画。手测:缓冲无关的任意距离滚动是否 60/120fps 丝滑、`prefersAsync` 是否 true（日志 `gapMs≈targetTimestamp delta`、`workMs<1ms`）。
5. **边缘 + soft stop + tail -f 锚定**（第 4、6 节）：到顶/底钳制不 thrash;滚动中有输出不错乱;scrollback 淘汰锚点调整。
6. **命中测试红线复验**（第 5 节）：滚动中/后 选区/⌘链接/URL 点击/中文输入位置正确。
7. **惯性/缓动参数打磨**：`SmoothScrollEngine.Config` 调到网页级手感;惯性种子取最后几个 gesture delta(非单个末尾 delta,否则惯性瞬灭,最佳实践 review)。
8. **收尾**：退役 pattern 1 死代码（`GhosttyTerminalScrollFrame` overscan 类型、`expandedFrame` 拼接、C 的 `proghostty_vt_scroll_snapshot` overscan 几何、`enqueueCommit`/`drainCommit`/`schedulePendingScrollCommit`/`viewportIsPinnedToBottom`/`suppressViewportChangePresent`/`rebaseCommittedRows`——确认无引用后删）。

## 8. 复用 vs 废弃（相对当前 main）

**复用**：顶点构建器、glyph atlas/纹理缓存、pipeline、`prefersAsyncPresent`+信号量回压、`SmoothScrollEngine` 物理、绝对行命中测试模型（`RenderedGridGeometry`/`absoluteBaseRow`/`selectionPoint`）、`copy_screen_rows`。
**废弃/替换**：离屏大纹理 + composite quad、overscan band 概念(`GhosttyTerminalScrollFrame`/`expandedFrame`/C overscan 快照)、pattern 1 的 commit-during-scroll 全套。

> ⚠️ main 目前含 R1.0/R1.1（overscan 缓冲 + 大纹理 band composite），那是 pattern 1 的地基。pattern 2 会**替换**其渲染结构。R1.0 的 C shim overscan cap 提升(24)可保留(rows_at 也受 32 硬顶保护,无害)。R1.1 的大纹理/composite 将被直画取代——不要试图两者并存。

## 9. 风险（诚实）

1. **display-link 是全新工作**（R1.2 从未落地）——不是移植,是新建。节拍/生命周期按第 4 节 + 最佳实践（targetTimestamp、preferredFrameRateRange、.common mode、invalidate-not-pause、window==nil teardown）。
2. **每帧分配 churn**（120Hz × ~400KB calloc）——用复用 cell buffer(池化),别每帧新分配。设计时纳入。
3. **scrollback 淘汰移位锚点**——第 6 节,必须处理否则浏览内容跳。
4. **顶/底半行**——每边多取 1 行 + scissor/clip,当前 viewport-exact 路径没练过这个。
5. **第 3 步换渲染结构**是最危险的一步（影响所有帧,不只滚动）——务必 offset=0 逐像素比对静止/打字。
6. 每步独立 commit;失败回退到该步前。main 已是干净可用基线（事件驱动滚动,不丝滑但不卡不空白）。

## 10. 验收标准（全绿才算完成）
- 任意距离滚动稳定 60/120fps（`gapMs` ≈ 屏幕刷新间隔,`workMs<1ms`）。
- position/内容每帧自洽,无横跳、无非原子闪帧、无空白、无撕裂、无字形 shimmer。
- 边缘干净 soft stop,不卡死不 thrash。
- 命中测试红线全部正确（滚动中+后）。
- tail -f 浏览时内容稳定;淘汰不跳。
- `seq 1 30000` 秒出、打字跟手、静止逐像素正常——均不受影响。

## 11. 必读上下文（新窗口按需查）
- `CLAUDE.md` — 项目规则 + **运行前必做清单**（ReleaseFast + build-app-bundle）。
- `.claude/R1_SCROLL_BUGS.md` — pattern 1 两次失败的确切 bug（读它避免重犯）。
- `.claude/PIXEL_SCROLL_JITTER_PLAN.md` — 最早的 "2b 非原子" 根因分析。
- `.claude/r1.2-attempt.patch` — 被回退的 pattern 1 display-link 尝试的完整 diff（display-link 生命周期/scrollWheel 喂引擎的代码可参考,但**提交/rebase 逻辑是错的别抄**）。
- `.claude/SMOOTH_SCROLL_ENGINE_SPEC.md` — SmoothScrollEngine 原始设计。
- 记忆文件:`libghostty-releasefast`、`bundle-binary-vs-swift-build`（两个反复踩的坑）。
- 关键代码:`MetalDirectRenderEngine.swift`(render/顶点构建器)、`PTYTerminalEngine.swift`(PTYGridView: scrollWheel/viewport/renderedGeometry/absoluteBaseRow)、`GhosttyVTBridge.swift`(scrollFrame/scrollbar/rows)、`ProGhosttyGhosttyVT.c`(copy_screen_rows:371)、`SmoothScrollEngine.swift`。

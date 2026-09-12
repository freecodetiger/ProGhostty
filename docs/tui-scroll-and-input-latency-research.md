# TUI Scroll & Input Latency Research

调研问题：**同一个 ProGhostty pane 里跑 pi agent 时，输入和滚动都有明显延迟；同样输入在 codex cli / Claude Code 里正常，而同一个 pi 在 Ghostty 里也完全正常。** 根因在哪一侧？

方法：debug 构建 + `PROGHOSTTY_RENDER_DEBUG=1`，在四个位置打单调时钟（按键 / 写 PTY / marked text / 呈现），配合 `sample` 时间剖面与逐帧诊断日志。全部为只读测量 + 可摘的临时探针。

---

## Decision

Status: `resolved — fixed in perf(render): memoize per-cell color resolution`

**根因：`TerminalColorResolver.resolvedColors` 的 WCAG 最小对比度补偿被逐 cell、逐帧重算。**
该补偿最多跑 14 轮二分，每轮 `blended` + `contrastRatio`，即约 6 次
`NSColor.usingColorSpace(.deviceRGB)`（ColorSync 转换）。pattern-2 每帧全量重绘
~1k 个 cell，于是这一项吃掉了整个帧预算，把呈现节拍从显示器刷新率压到 ~19Hz。

修法见本文末尾「Resolution」。

> ⚠️ **本文下方「架构对照」一节给出的"缺呈现时钟"结论已被测量证伪**，保留它是
> 作为排查记录 —— 不要据此去写帧时钟。详见「Resolution」。

---

## 测量结果（可复现）

同一 pane、同样的 `localScrollback` ownership、几乎相同的 app 输出量（3.0 vs 2.8 块/秒）。

### 滚动

| | pi | codex |
|---|---|---|
| browse 驱动呈现 | 67 | 282 |
| output 驱动呈现 | 84 | 309 |
| **browse 呈现间隔 p50** | **53.4ms**（≈19Hz） | **16.7ms**（=60Hz 显示刷新） |
| **output 呈现间隔 p50** | **53.6ms** | **16.9ms** |
| **wheel → 下一次 browse 呈现 p50** | **83.3ms** | **0.0ms** |
| wheel 事件 | 194 | 376 |

**最关键的一条：codex 的滚动呈现发生在滚轮事件自己的调用栈里（0.0ms），pi 要等下一次 tick（中位 83ms）。**

### 键盘

| 段 | pi | codex |
|---|---|---|
| `kbd → marked`（AppKit + **macOS 输入法服务器往返**，ProGhostty 之外） | p50 15.0ms / **p90 177.5ms** | p50 13.7ms / **p90 188.7ms** |
| `marked → present`（本地渲染） | p50 10.7ms / p90 38.1ms | p50 14.4ms / p90 22.8ms |
| `kbd → present` 总计 | p50 24.9ms / p90 50.8ms | p50 28.1ms / p90 43.1ms |
| 英文直接写入 `kbd → present` | p50 15.3ms | p50 11.4ms |

**延迟的最大单项是输入法往返（p90 ~180ms），而它两个 app 几乎相同、且完全在 ProGhostty 之外。** 本地渲染段 pi 只在 p90 上差 15ms。

---

## 已排除的假设（逐条附证据）

| # | 假设 | 排除依据 |
|---|---|---|
| 1 | ProGhostty 算力不足 | 打字期间主线程 93.9% 阻塞在 `mach_msg`；vtQueue 仅 **6 个样本 / ~42000**；pi 与 codex 进程分别只用了 **0.08s CPU / 50s**。三者全空闲 |
| 2 | 输出 debounce 拖延迟 | `writeInput` 每次按键先 `outputBatchCoordinator.flush(session:)`（`PTYTerminalEngine.swift:494`） |
| 3 | 回显门（≤96B / ≤150ms / 每键仅一次）太窄 | pi 拿到 **44%** 即时回显，codex 只有 6% —— 卡的那个反而被优待 |
| 4 | 渲染量太大 | codex 每秒渲染更多（9.9 vs 6.4 fps）；coalesced/dropped 峰值也更高（12 vs 6） |
| 5 | 滚动/浏览态触发 per-keystroke 快照路径 | 两者都在底部、`visualOffsetY=0.00`、不在浏览历史 |
| 6 | 输入路径有节流/合并 | 不存在（唯一 `Task.sleep` 是 resize settle） |
| 7 | Kitty 键盘协议导致编码变慢 | ProGhostty 全仓无 kitty keyboard 处理（grep 零命中） |
| 8 | 呈现被 app 输出抢占 | 两边 browse:output 呈现比例几乎一致（67:84 vs 282:309 ≈ 45:55） |
| 9 | pi 滚到顶了所以不动（测量假象） | `offset==0` 采样极少（pi 5/34、codex 3/32），滚动确实在移动 |

**还有一条外部事实无法用本仓解释**：同一个 pi 在 **Ghostty 里完全无不适**。上表第 1 条已排除算力，所以这是"Ghostty 与 ProGhostty 的行为差异"，不是 pi 的性能问题。

---

## 已排除的假设（第二批）

| # | 假设 | 排除依据 |
|---|---|---|
| 10 | **帧形状翻转**（全屏 TUI 的 scrollback 被打到 0 → overscan 塌缩 → 扩展帧 51 行 ↔ 裸 viewport 27 行来回切） | 加了 `present-shape` 探针后直接否证：pi **形状稳定时**的呈现间隔 p50 = **54.5ms**，形状刚变后也只 65.6ms —— 它本来就慢，翻转只多加 11ms。且两 app 这次都长期稳定在**同一个形状**（29 行）上，pi 仍 54.5ms、codex 16.7ms。**差异与形状无关** |
| 11 | 滚动到顶导致显示链接被停（`handleScrollDisplayLink` 的 `atTopEdge → stopSmoothScrollBrowsing()`） | browse 位置 dwell 比例：**codex 57% > pi 31%** —— 停着不动的反而是 codex |
| 12 | 像素平滑滚动开关可关掉做 A/B | **该开关是死代码**：`smoothPixelScrollingEnabled`（`TerminalRendererOptions`）全仓无消费者；`PROGHOSTTY_EXPERIMENTAL_PIXEL_SCROLL=0` 与 `RendererDebug.enableExperimentalPixelScroll` 因此不改变任何行为 |

### 顺带发现的两处插桩缺陷

- **`pixelSmoothScroll` 诊断字段恒定说谎**：`PTYTerminalEngine.swift:1369-1374` 在 browse 分支与 else 分支**都**写 `.experimental`，除非在备用屏。它无法用来判断平滑滚动是否启用。
- **`avgDrawMs` / `maxDrawMs` 在生产后端结构性为 0**：只在 `GhosttyVTCellGridRendererBackend.swift:280-281` 赋值，MetalDirect 路径从不设置。

## Resolution：逐层劈开呈现路径，落到 `resolvedColors`

工具：`PROGHOSTTY_RENDER_DEBUG=1` 下逐段单调时钟（探针已全部摘除）。每一步都只
回答"是不是这一层"，前两次判断都错了，所以这里保留完整链条。

| 层 | 读数 | 判定 |
|---|---|---|
| `flushPendingFrame` 里的 `directView.present` | p50 **0.36ms** | 不是它 |
| `updateDiagnostics`（`diag`） | p50 **6.41ms** / p90 **50.28ms** | ← 在这里 |
| ├ frame encode（plan） | p50 1.98ms | 次要 |
| ├ glyph atlas 扫描 | p50 0.28ms | 不是 |
| ├ styleStats / resizeSensitivity | p50 0.14ms | 不是 |
| └ `engine.render`（CPU 侧顶点构建） | p50 **3.48ms** / p90 **48.22ms** | ← 在这里 |
| &nbsp;&nbsp;├ bg / ovl / above / slices / bufs | 各 ≤0.4ms，快慢帧**完全一致** | 不是 |
| &nbsp;&nbsp;└ **`buildGlyphVertices` 的逐 cell 段** | 慢帧 **47.23ms** vs 快帧 1.85ms | ← 在这里 |
| &nbsp;&nbsp;&nbsp;&nbsp;├ `glyphAtlas.entry` | 0.31ms | 不是 |
| &nbsp;&nbsp;&nbsp;&nbsp;├ `texture` | 0.07ms | 不是 |
| &nbsp;&nbsp;&nbsp;&nbsp;├ **`TerminalColorResolver.resolvedColors`** | 慢帧 **44.51ms** / 快帧 0.88ms | **就是它** |
| &nbsp;&nbsp;&nbsp;&nbsp;└ `append` | 0.96ms | 不是 |

**关键判别**：把帧按 `visited`（非空 cell 数）分组，`colors` 不是线性增长而是断崖 ——

```
visited~500  → 1.07ms
visited~750  → 42.93ms   ← 断崖
```

**说明耗时与 cell 数量无关、与 cell 颜色有关**：只有前景/背景对比度不足 3.0 的 cell
才进那 14 轮二分。这一条同时解释了全部三个现象：

- **pi 慢**：全屏 TUI 大量用暗色/灰色（dim 边框、灰色提示、spinner）→ 大批 cell 触发
- **codex 正常**：几乎全是默认前景色 → `guard contrastRatio < 3.0 else { return self }` 早退
- **Ghostty 正常**：Ghostty 不做这个逐 cell 对比度补偿

### 修复与验证

`ResolvedColorMemo`（`MetalDirectRenderEngine.swift`）按 cell 外观 memo 解析结果；
键只含解析器实际读取的纯值（构造键不需要任何 NSColor 转换），调色板变更即清空。

同一 pane 实测：

| | 修复前 | 修复后 |
|---|---|---|
| `colors` p50 | 44.51ms | **0.33ms** |
| 顶点构建循环 p50 / p90 / max | 1.82 / 9.18 / **74.07**ms | 2.69 / **3.52** / **5.27**ms |
| 慢调用（>50µs） | 每帧数百次 | 390 帧共 **3** 次（仅冷启动首次） |
| **present 间隔 p50** | **53.4ms（≈19Hz）** | **16.7ms（=60Hz）** |

**打字延迟随之消失** —— 它与滚动共用同一条呈现路径，这正是本文早先那条逻辑约束
（"打字不经过滚轮路径，若两者同根因，必须在共同路径上"）所指的位置。

回归测试 `ResolvedColorMemoTests` 钉住**键的完整性**（这是该缓存唯一会出错的方式：
漏一个字段，那个 cell 的变体就会静默套用另一套颜色）。已验证：从键里拿掉 `faint`
后两个测试立刻变红。

### 被证伪的方向（不要重走）

- **缺呈现时钟**：`prefersAsyncPresent` 在滚动期间**确实是 true**，整个 Metal 呈现
  路径（sem / drawable / encode / wait）p50 仅 **0.14ms**，无一次 drawable 池丢弃。
  帧时钟与呈现节拍无关。
- **同步 `waitUntilCompleted` 阻塞主线程**：滚动期 `wait` p50 = 0.02ms（走的是异步路径）。
  空闲/打字期才同步，也只有 0.96ms。

### 顺带修掉的一个构建阻塞

`MetalDirectRenderEngine.setUniforms` 用 `withUnsafeBytes` 闭包捕获了 encoder，
Swift 6.3.3 下 **release 构建直接编译失败**（`sending 'encoder' risks causing data
races`）。后果是 `.build/release/` 长期停留在旧产物 —— 期间任何"release 手测"测的
都不是当前代码。已改为直接传 `&uniforms`。

## 原先"仍未解释的唯一事实"（已解释）

**在完全相同的稳态下（同 pane、同 `localScrollback` ownership、同帧形状、几乎相同的 app 输出量），pi 的呈现比 codex 慢约 3 倍**（54.5ms vs 16.7ms）。

**已解释**：不是呈现管线的结构性差异，而是**逐 cell 的颜色对比度补偿成本随 cell 颜色变化**——
pi 的 TUI 充满低对比度的暗色 cell，codex 几乎全走早退。见本文「Resolution」。

当时提出的两条后续路线（插桩 `SmoothScrollEngine` / 读 Ghostty 呈现循环）**都不必再走**：
前者方向错了（物理与 tick 成本实测为 0.00ms），后者得出的"缺呈现时钟"结论已被证伪。

### 一个必须记住的逻辑约束

**打字不经过滚轮路径**（`scrollWheel` → `feedSmoothScroll` 只在滚轮事件时走）。所以"像素滚动是元凶"**解释不了打字延迟**。打字与滚动唯一的共同环节是**呈现管线本身** —— 若两者是同一个根因，它必须在这条共同路径上。

---

## 架构对照：Ghostty vs ProGhostty（呈现时钟）

对着 `Vendor/ghostty` 源码读出来的结构性差异。当时以为这是**唯一能解释"同稳态下 pi 19Hz / codex 60Hz"的机制** —— ❌ **已被证伪**，真正的机制是颜色成本，与本节的呈现时钟无关。

### Ghostty：呈现由 vsync 驱动，与输出事件解耦

```zig
// src/renderer/Thread.zig:500
fn drawFrame(self: *Thread, now: bool) void {
    if (!self.flags.visible) return;
    if (!now and self.renderer.hasVsync()) return;   // 事件驱动的 draw 直接丢弃
    ...
}
```

- 输出到达只走 `updateFrame`（重建 GPU cell 数据）+ 一次 `renderer_wakeup.notify()`；该 async 在 Darwin 上是 mach port、**队列深度 1**，N 次 notify 天然合并成 ≤1 次回调（libxev `async.zig:277/342-344/787-826`）。
- **真正上屏只由 CVDisplayLink 驱动**：`generic.zig:986-994` 每 tick 只 `draw_now.notify()`，`Thread.zig:554-570` → `drawFrame(true)` → present。默认 `window-vsync = true`（`config/Config.zig:2013`）。
- 结果：**上屏节拍 = 显示器刷新率**，与 app 输出密度无关；tick 之间的中间状态被丢弃，只画"那一刻的最新状态"。
- 上游**曾计划**做渲染 debounce，但已废弃（`Thread.zig:534-549` 的注释留了代码但注释掉了）。

### ProGhostty：没有呈现时钟，呈现由事件驱动

- **`MetalDirectRenderEngine` 里没有 display link**，直接 `commandBuffer.present(drawable)`，`maxInFlightDrawables = 2`。
- 于是上屏节拍 = 事件管线能跑多快，**没有独立帧时钟**。

### 另外三处叠加放大

| | Ghostty | ProGhostty |
|---|---|---|
| VT 解析位置 | 专用 `io-reader` 线程（`termio/Exec.zig:1260`），持 `renderer_state.mutex` | **主线程**：`DispatchSourceRead` → `Task { @MainActor } handleOutput`（`PTYTerminalEngine.swift:586-606`） |
| 合并 | 无时间去抖，mach port 天然合并 | **两级显式 4ms 去抖**（字节级 + 快照级 = 8ms，`TerminalOutputCoordinator.swift:10-17`） |
| GPU 帧深度 | `swap_chain_count = 3`（`renderer/Metal.zig:37`） | `maxInFlightDrawables = 2` |

### 结论（❌ 已证伪 —— 保留作为排查记录）

> 下面这段推理**是错的**，实测直接否掉了它：滚动期间 `prefersAsyncPresent` 为 true，
> 呈现路径 p50 仅 0.14ms。**不要据此去写 `MetalFrameScheduler` / 帧时钟。**

**为什么偏偏是 pi** ~~：pi 是全屏 TUI、输出突发且量大。没有 frame clock 时它的上屏节拍退化成"串行管线能撑住多快"（实测 19Hz）；codex 的输出模式恰好撑得住 ~60Hz。在 Ghostty 里两者被同一个 60/120Hz 时钟节流，所以 pi 完全正常。~~

**实际原因**：pi 是**颜色重**的全屏 TUI（大量 dim/灰暗 cell 命中对比度补偿的慢路径），
codex 是**颜色轻**的（几乎全走早退）。跟"输出突发量"和"呈现时钟"都无关 ——
两者在本次测量里的 PTY 读取密度几乎一致（4.2 vs 3.8 块/秒）。

**打字延迟的同一根源** ✅：**这一点是对的** —— 打字与滚动共用同一条呈现路径，
`resolvedColors` 的成本就落在那里。修掉它之后打字也随之变顺。

### 与项目既有规划的关系（⚠️ 此处的"证实"已作废）

> 本次测量**没有**证实那份文档对**本次延迟**的判断 —— 延迟的根因是 `resolvedColors`，
> 与呈现时钟无关。`gpu-first-renderer-rework.md` 描述的 presentation coordinator 是否
> 仍值得做，是一个**独立的问题**（它解决的是代际一致性 / 撕裂，而不是本次的慢），
> 不要把它当成这次修复的后续。

`docs/design/gpu-first-renderer-rework.md` **已经写下过这个诊断**：

> *display timing follows render submissions rather than a stable presentation clock;*
> *AppKit-visible grid state and Metal-presented state can diverge;*
> 修法：*coalesce multiple terminal updates into one display-frame presentation; submit only the newest complete generation; never present generation N after generation N+1; never mix text from one generation with cursor from another.*


## 测量陷阱（下次别再踩）

1. **日志时间戳只有 1 秒粒度**，测不了亚秒延迟 —— 必须在消息体里带单调时钟。
2. **`lastInputUptimeBySession` 在 `writeInput` 内部打点，且一次即时回显会消耗掉它**（`PTYTerminalEngine.swift:680`）。用它算的 `sinceInput` (a) 看不到 `keyDown → writeInput` 那段，(b) 只能测到突发里**第一个**块。字符所在的后继块全是 `nil`。
3. **`kbd → write` 会被输入法污染**：中文组字期间按键不写 PTY，64 次按键只产生 8 次写入，于是"按键→下一次写入"算出 800ms+ 的假延迟。必须按"该按键后是否有写入"分组。
4. **滚轮事件速率会因手势强度差 2.6 倍**（10/s vs 26.2/s），速率类指标（fps）会被污染 —— 用**触发原因归属**（`present-reason`）而不是速率来做结构对比。
5. **`avgDrawMs` / `maxDrawMs` 在生产后端下结构性恒为 0**：只在 `GhosttyVTCellGridRendererBackend.swift:280-281` 赋值，MetalDirect 路径从不设置。想从日志看绘制耗时会扑空。
6. **`sample` 采的是 app 进程**：`pgrep -f "…ProGhostty.app/…"` 会先命中 zsh wrapper，要用 `ps -Ao pid,comm` 按可执行名取。

## Sources

- `Sources/ProGhosttyCore/TerminalCore/PTY/PTYTerminalEngine.swift`（`writeInput` :492、`handleOutput` :662、`isInteractiveEchoOutput` :732、`scrollWheel` :1585、`setMarkedText` :4099）
- `Sources/ProGhosttyCore/TerminalCore/PTY/TerminalOutputCoordinator.swift`（两级 4ms debounce）、`TerminalOutputBatchCoordinator.swift`
- `Sources/ProGhosttyCore/TerminalCore/PTY/PTYTerminalSurfaceRegistry.swift`（`presentBrowseWindow` :829、render 入口 :711）
- `Sources/ProGhosttyCore/TerminalCore/Renderer/MetalDirectRendererBackend.swift`（`presentViewportChange` :558、`transientOverlayDidChangeHandler` :347）
- `Sources/ProGhosttyCore/TerminalCore/Renderer/MetalDirectRenderEngine.swift`（`prefersAsyncPresent` :178/457）

相关：`docs/ime-anchor-vt-semantics-research.md`（IME 锚定）、`docs/renderer-overscan-research.md`

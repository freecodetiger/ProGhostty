# TUI Scroll & Input Latency Research

调研问题：**同一个 ProGhostty pane 里跑 pi agent 时，输入和滚动都有明显延迟；同样输入在 codex cli / Claude Code 里正常，而同一个 pi 在 Ghostty 里也完全正常。** 根因在哪一侧？

方法：debug 构建 + `PROGHOSTTY_RENDER_DEBUG=1`，在四个位置打单调时钟（按键 / 写 PTY / marked text / 呈现），配合 `sample` 时间剖面与逐帧诊断日志。全部为只读测量 + 可摘的临时探针。

---

## Decision

Status: `open — localization done, mechanism unidentified`

**已定位：pi 的呈现管线被限速在 ~19Hz，codex 是 60Hz；滚动响应是 83ms vs 0ms。**
**未定位：是什么在限速。** 嫌疑已收窄到 `SmoothScrollEngine` 与显示链接那一层。

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

## 仍未解释的唯一事实

**在完全相同的稳态下（同 pane、同 `localScrollback` ownership、同帧形状、几乎相同的 app 输出量），pi 的呈现比 codex 慢约 3 倍**（54.5ms vs 16.7ms）。

触发源已按 `browse` / `output` 两类全部归因（151 = 67+84），不存在第三类漏标。**下一层需要插桩 `SmoothScrollEngine` / `CADisplayLink` tick 与 `applyBrowseTick` 的每次决策**（呈现 / 跳过 / clamp），成本较高且不确定性大。

**另一条成本更低的路线**：直接读 **Ghostty 的呈现循环源码**做架构对比 —— 同一个 pi 在 Ghostty 里正常，这是最强的对照，且不需要在 ProGhostty 里继续加探针。

### 一个必须记住的逻辑约束

**打字不经过滚轮路径**（`scrollWheel` → `feedSmoothScroll` 只在滚轮事件时走）。所以"像素滚动是元凶"**解释不了打字延迟**。打字与滚动唯一的共同环节是**呈现管线本身** —— 若两者是同一个根因，它必须在这条共同路径上。

---

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

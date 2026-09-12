# IME Anchor vs libghostty-vt Semantics Research

调研问题：**ProGhostty 为 IME 锚点做的工作（尤其是 pane 内的字符匹配）是否多余？libghostty-vt 是否已经知道这些信息？**

结论摘要：**分三块，答案不同。**

> **已测量（见文末「测量结果」）**：pi 这类 TUI **完全不发 OSC 133**（`frameInput=0 framePrompt=0`，`cursorSemantic` 恒为 `.output`），所以语义路线对 TUI 无效；而在全部观测里 `active`（上游 `CURSOR_X/Y`，Ghostty 的读法）与 `viewport`（ProGhostty 现用）**逐帧完全一致**。

---

## Decision

Status: `partially available`

**1. pane 内的字符匹配（`promptMarkerColumn` 的 `› ❯ > $ #`）在 OSC 133 可用的场景下是多余的。**

libghostty-vt 上游就把逐 cell 的语义内容标好了（`GHOSTTY_CELL_DATA_SEMANTIC_CONTENT`，值 `output / input / prompt`），而且 ProGhostty **已经把它接进了 Swift**（`Cell.semanticContent`，`Sources/ProGhosttyCore/TerminalCore/LibGhostty/GhosttyVTBridge.swift:790`）。同一个文件里它已经被用了 6 处 —— 全在 click-to-position，**IME 锚点一处都没用**。

也就是说：`› ❯ > $ #` 的字符匹配在**重建 VT 已经精确表达过的东西**，而且有 false positive 类别（普通输出里的 `>` `$` `#` 会被当成 prompt marker），语义标记没有这个问题。

**2. 但没有任何 libghostty-vt C API 直接给出"输入区的行范围"。**

上游 Zig 里有现成的推导实现，**全部没有 C 导出**：

- `Terminal.cursorIsAtPrompt()`（`Vendor/ghostty/src/terminal/Terminal.zig:1346`）—— 「光标是否在活的 prompt 上」
- `Pin.promptIterator(direction, limit)`（`Vendor/ghostty/src/terminal/PageList.zig:5209`）—— 找上/下一个 prompt 首行
- `PageList.highlightSemanticContent(pin, .input)`（`Vendor/ghostty/src/terminal/PageList.zig:4304-4392`）—— **最接近"输入区起止"的现成实现**：从前置的 prompt 首行 right_down 扫 cell，跳过 `.prompt`，首个 `.input` 即起点，遇 `.output` 结束

所以在 vt 消费方这一侧，要么**自己按 cell 语义扫**（可行，依赖已在手），要么**继续往 patch 里加导出**。

**3. 与"像素位置"有关的全部工作完全不多余。**

vt 层只给**格**坐标，没有任何像素坐标或 IME 位置 API。`ghostty_surface_ime_point` 在 **app 层**（`Vendor/ghostty/include/ghostty.h:1143`），不在 `vt/*.h`，作为 vt 消费方根本拿不到。所以这些都不多余：

- viewport 格 → 像素（`renderedCursorRect()` / `rectForCell`）
- overscan 扩展帧的行空间平移
- `preservedPromptCursorRectForBlankTransient()` 的 rect 记忆
- `firstRect` 的 5 级兜底链
- `isCaretCell`（孤立反显格 = app 自绘 caret）—— **没有 VT 对应物**，VT 的 `cursor_visual_style` 是终端自己的光标样式，不是 app 在屏幕内容里画的 caret

---

## 决定性前提：只有 OSC 133 存在时，语义才有效

语义标记不是凭空来的 —— 它由 OSC 133 驱动（`Screen.cursorSetSemanticContent`，`Vendor/ghostty/src/terminal/Screen.zig:2367-2401`；「推」到 cell 上是在打印时从 cursor 拷贝，`Terminal.zig:816-823`）。

- **shell 场景：语义有。** ProGhostty 的 `.app` bundle 里打了 ghostty 的 shell integration（`scripts/build-app-bundle.sh` 复制 `src/shell-integration`），zsh / bash / fish / elvish 实测发 `133;A`、`133;B`、`133;C`、`133;D`、`133;P`。
- **TUI（pi、Claude Code 之类）场景：取决于 app 自己发不发。** **这一点目前未测量**，而它决定第 1 条成立与否。

> 顺带：如果某个 TUI 不发 OSC 133，那它**也同时**让 click-to-position 失效（`PTYTerminalEngine.swift:2430` 的门要求 `cursorSemanticContent == .input` 或光标格是 `.input`）。所以「在 pi 里点命令行中间能不能跳过去」本身就是一次 OSC 133 探针。

---

## API Findings

### 上游已有、可直接用

| 项 | 语义 | 位置 |
|---|---|---|
| `GHOSTTY_CELL_DATA_SEMANTIC_CONTENT` = 9 | 取某格的语义内容 | `include/ghostty/vt/screen.h:190` |
| `GhosttyCellSemanticContent` | `OUTPUT=0` / `INPUT=1` / `PROMPT=2` | `include/ghostty/vt/screen.h:105-114` |
| `GHOSTTY_ROW_DATA_SEMANTIC_PROMPT` = 6 | 取某行的 prompt 标记 | `include/ghostty/vt/screen.h:282` |
| `GhosttyRowSemanticPrompt` | `NONE` / `PROMPT` / `PROMPT_CONTINUATION` | `include/ghostty/vt/screen.h:216-227` |
| `ghostty_terminal_grid_ref` | point → grid ref（支持 ACTIVE / VIEWPORT / SCREEN / HISTORY） | `include/ghostty/vt/terminal.h:1130` |
| `ghostty_terminal_point_from_grid_ref` | grid ref → point（不可表示时返回 `GHOSTTY_NO_VALUE`） | `include/ghostty/vt/terminal.h:1161` |
| `ghostty_grid_ref_row` / `ghostty_grid_ref_cell` | 由 ref 取行 / 格 | `include/ghostty/vt/grid_ref.h:82` / `:69` |
| `ghostty_grid_ref_graphemes` | 取格的 grapheme（文本读取） | `include/ghostty/vt/grid_ref.h:107` |
| `GhosttyPointTag` | `ACTIVE` / `VIEWPORT` / `SCREEN` / `HISTORY` | `include/ghostty/vt/point.h:45-58` |

**关键限制：行级语义只有 prompt，没有 input / output。**（`screen.h:216-227`）所以"输入区从哪行到哪行"只能**逐 cell** 看，没有行级捷径。

另注：行级 `semantic_prompt` 官方注释明确说**允许 false positive、不会有 false negative**（`Vendor/ghostty/src/terminal/page.zig:1942-1951`），定位后仍需逐 cell 复核。cell 级 `semantic_content` 是精确的。

### 上游有实现、但**没有 C 导出**

- `Terminal.cursorIsAtPrompt()` — `src/terminal/Terminal.zig:1346-1359`（生产者用：`src/Surface.zig:961,4158`、`src/termio/Termio.zig:562`）
- `Pin.promptIterator()` — `src/terminal/PageList.zig:5209-5219`
- `PageList.highlightSemanticContent()` — `src/terminal/PageList.zig:4304-4392`
- `PageList.scrollPrompt()`（jump-to-prompt 的实现）— `src/terminal/PageList.zig:2689-2743`
- `Screen.SemanticPrompt{ seen, click }` — `src/terminal/Screen.zig:94-117`
- `cursor.semantic_content_clear_eol` — `src/terminal/Screen.zig:170`
- **render state 完全不暴露语义状态**：`src/terminal/render.zig` 与 `src/terminal/c/render.zig` 里 `grep semantic` 零命中

### ProGhostty patch 加上去的（唯一一项）

`GHOSTTY_TERMINAL_DATA_CURSOR_SEMANTIC_CONTENT = 31` —— 取 `screens.active.cursor.semantic_content`：

- 头文件 `include/ghostty/vt/terminal.h:868-881`
- Zig `src/terminal/c/terminal.zig:578`（枚举）、`:607`（OutType）、`:717`（取值）
- patch 全文 `Vendor/ghostty.patch`（3 处 hunk，全部围绕这一个枚举值）

它补的是一个 **cell 级标记无法表达的区分**：OSC 133;C 之后 cursor 语义翻成 `.output`，而之前写下的 input cell 仍是 `.input` —— 所以「光标是否停在活的输入提示上」只能看 cursor，不能看 cell。

---

## Ghostty 自己的 IME 锚定怎么做（基准）

调用链：

```
SurfaceView_AppKit.firstRect(forCharacterRange:)
  (Vendor/ghostty/macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift:1935-1991)
  → ghostty_surface_ime_point()      include/ghostty.h:1143 → src/apprt/embedded.zig:1907
  → Surface.imePoint()               src/Surface.zig:2091
```

`Surface.imePoint()` 的内容（`src/Surface.zig:2093-2135`）：

- 只读 `cursor.x` 和 `cursor.y`（`x*cell.width + padding.left`，`y*cell.height + padding.top`）
- **不读任何 semantic 字段**（`semantic_content` / `semantic_prompt` 都不碰）
- **不读 `cursor_visible`**
- core 侧**零 fallback**，只有一条 TODO：滚到 history 时光标不在可见区未处理（`src/Surface.zig:2097-2098`）

**这条最重要**：ghostty 对全屏 TUI 的答案就是**裸光标坐标**，它没有比 ProGhostty 更聪明的办法。ProGhostty 的启发式是**偏离**了 ghostty 的行为，而不是在补 ghostty 缺失的能力。

`PromptCursorInferrer` 存在的理由是「光标被 park 在无意义位置」（shell 重绘 / presentation 帧），那只在**光标本身不可信**时成立 —— 而这个判断现在由 `cursorAppVisible` / `cursorPositionKnown` 精确给出了。

---

## 冗余判定（逐项）

| ProGhostty 的实现 | 是否多余 | 说明 / 替代物 |
|---|---|---|
| `promptMarkerColumn`（字符集 `› ❯ > $ #`） | **是**（OSC 133 可用时） | cell `.prompt` / row `semantic_prompt` |
| `lastPromptMarkerRow` | **是**（同上） | 反向扫 row `semantic_prompt != .none` |
| `rowIsInPromptInputRegion`（向上扫 marker） | **是**（同上） | row/cell 语义 |
| `inputRegionStart` 的 marker 分支 | **是**（同上） | 首个 `.input` cell 所在行 |
| `inputRegionEnd`（扫到第一个空行） | **部分** | 语义上输入区终于 `.output` 过渡；空行只是近似 |
| `lastNonBlankRow` / `rowIsBlank` | **部分** | 同上；语义过渡更精确 |
| `rowLooksLikeInput`（marker 或孤立反显格） | **部分** | marker 半可替代；孤立反显格不可 |
| `isCaretCell`（孤立反显格） | **否** | 无 VT 对应物（VT 的 cursor 样式不是 app 自绘 caret） |
| `shouldInferPromptCursor` 的 `cursorX == 0` 停驻假设 | **否**（但脆弱） | 现在有 `cursorAppVisible` / `cursorPositionKnown` 可精确判断 |
| `isLiveHiddenCursor` | **否** | 纯 VT 事实 |
| viewport 格 → 像素、overscan 平移、`preservedPromptCursorRectForBlankTransient`、`firstRect` 兜底链 | **否** | vt 层无像素坐标、无 IME 位置 API |
| `TerminalInputStateMachine.advance` 的 ASCII=1/非 ASCII=2 列宽估算 | **否**（但粗糙） | 无 VT 对应物；宽字符 / emoji / 组合字符会偏 |

---

## 测量结果

探针接在 `PTYTerminalEngine` 的 `inputRender` 日志行上（`semanticProbe`，gated by `PTYRenderDebugLog.isEnabled`），字段：`cursorSemantic` / `frameInput` / `framePrompt` / `rowInput` / `rowPrompt` / `active=(x,y)` / `viewport=(x,y)`。

### 1. TUI（pi）不发 OSC 133 —— 语义路线对 TUI 无效

在 pi 里打字（含中文）后，pi 的每一帧都是：

```
cursorSemantic=output  frameInput=0  framePrompt=0  rowInput=0  rowPrompt=0
```

**整帧零个 `.input` / `.prompt` cell。** pi 从不发 OSC 133。

后果：
- 语义**无法**用于 TUI 的锚点定位 —— 无论是逐 cell 扫还是 cursor 级判断，pi 全是 `.output`。
- 字符匹配对 TUI 是**唯一**手段（这也是 `promptMarkerColumn` 里 `>` `$` `#` 那套的来源）。
- **pi 的 click-to-position 本来就是失效的**（`PTYTerminalEngine.swift:2430` 的门要求 `cursorSemanticContent == .input` 或光标格是 `.input`）。可在 pi 里点命令行中间验证。

### 2. shell 发 OSC 133，但 cell 级语义定位不了空输入行

shell 帧：

```
cursorSemantic=input  frameInput=0  framePrompt=19  rowInput=0  rowPrompt=19
```

`cursor.semantic_content` 正确地翻成了 `.input`，但 **`frameInput=0`** —— 输入行是空的，还没有任何 cell 被写。OSC 133;B 之后 cursor 语义表示的是"**接下来写进去的 cell 会标成 input**"。

这条直接印证了 ProGhostty patch 的必要性，也是"用 `highlightSemanticContent(pin, .input)` 替代字符匹配"这条路的**致命伤**：空输入行上什么都扫不到。要判断"光标停在活的输入提示上"，只能看 **cursor 级**语义 —— 而上游 C API 恰好只暴露了 cell 级和 row 级，cursor 级是 ProGhostty patch 出来的。

### 3. 上游 `CURSOR_X/Y` 与 `CURSOR_VIEWPORT_X/Y` 逐帧一致 —— 「读错 API」假设被证伪

全部观测（60+ 帧）里 `active == viewport`，**无一例外**：`(0,23)`、`(19,0)`、`(4,23)`、`(49,23)`、`(21,0)` …

即：换成 Ghostty 的读法（上游 `GHOSTTY_TERMINAL_DATA_CURSOR_X/Y`）**运行时不改变任何值**。两者只在 `CURSOR_VIEWPORT_HAS_VALUE == false`（光标行不在 viewport 内，即滚回历史）时才分叉，而那个场景 Ghostty 自己也没处理（`src/Surface.zig:2097` 的 TODO）。

早前 `cursorGate` 探针里看到的 `raw=(0,3) viewport=(0,0)` 差异是**探针自身的假象** —— 当时 viewport 被 `cursor_visible` 门控清零了，不是两个坐标空间真的不同。

### 4. 对「收敛到 Ghostty 的方式」的含义 —— 尝试过，被测试否掉了

Ghostty 的方式 = 读裸光标 `cursor.x/y`，零语义、零 fallback。据此试过一版「把光标升为无条件主路径」（`isTrustworthyCursor`：位置已知且非 home 就信，去掉可见性条件），**`swift test` 当场 5 个失败**，全部落在 Codex CLI 场景：

```
liveGridInfersPromptCursorWhenCodexTransientCursorMovesToPromptLineStart
liveGridPreservesPromptCursorWhenCodexTransientCursorMovesToBlankRowStart
liveGridPreservesPromptCursorWhenCodexTransientCursorMovesToStyledBlankRowStart
liveGridPreservesPromptCursorWhenCodexTransientFrameErasesPromptRow
liveGridPreservesContinuationCursorWhenCodexTransientMovesToBlankRowStart
```

断言的都是同一件事：**TUI 把光标临时挪到行首时，锚点不能跟着走**（`TerminalSurfaceTests.swift:1122,1175,1232,1286,1340`）。

结论：**Ghostty 的无条件读法在 ProGhostty 不可直接采纳**，因为这里的宿主 TUI（Codex、pi 同级）会**可见地**把光标临时停在行首重绘。`cursorAppVisible` 不是冗余条件，它正是判别器：

| 状态 | 判别 | 处理 |
|---|---|---|
| **隐藏**光标停在 (0,y)（pi） | `!cursorAppVisible` | 可信 —— app 提前藏了光标并留在真实 caret 上 |
| **可见**光标停在 (0,y)（Codex 重绘中） | `cursorAppVisible` | 不可信 —— 走启发式 / 保留上次锚点 |
| 位置未知（光标行在 viewport 外） | `!cursorPositionKnown` | 不可信 —— 坐标被清零 |
| home (0,0) 停靠 | — | 不可信 —— presentation 帧 |

所以可采纳的部分是：**「隐藏光标 → 信光标位置」**（已验证对 pi 正确），这一条已经是当前实现。**「无条件信光标」不可采纳**，字符匹配与锚点保留对 Codex 这类 TUI 是承重结构，删不得。

这也回答了一个更根本的问题：`PromptCursorInferrer` 的存在理由**不是**"Ghostty 有能力而 ProGhostty 没接过来"，而是**Ghostty 的 IME 锚定在这里不够用**。

---

## Sources

- `Vendor/ghostty/include/ghostty/vt/terminal.h` / `render.h` / `screen.h` / `point.h` / `grid_ref.h` / `osc.h` / `formatter.h`
- `Vendor/ghostty/include/ghostty.h`（app 层，含 `ghostty_surface_ime_point`）
- `Vendor/ghostty/src/terminal/` — `Terminal.zig` / `Screen.zig` / `PageList.zig` / `page.zig` / `render.zig` / `c/*.zig` / `osc.zig` / `osc/parsers/semantic_prompt.zig`
- `Vendor/ghostty/src/Surface.zig`、`src/apprt/embedded.zig`、`src/termio/Termio.zig`
- `Vendor/ghostty/macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift`
- `Vendor/ghostty/src/shell-integration/`（zsh / bash / fish / elvish）
- `Vendor/ghostty.patch`（ProGhostty 唯一的 vendored 改动）
- ProGhostty：`Sources/ProGhosttyCore/TerminalCore/PTY/PromptCursorInferrer.swift`、`PTY/PTYTerminalEngine.swift`、`LibGhostty/GhosttyVTBridge.swift`、`TerminalCore/TerminalInputStateMachine.swift`、`Sources/ProGhosttyGhosttyVT/ProGhosttyGhosttyVT.c`

相关：`docs/superpowers/specs/2026-05-29-ime-state-machine-redesign.md`（那份 spec 全文没有提到 semantic / OSC 133）、`docs/specs/click-to-position-cursor.md`、`docs/libghostty-vt.md`、`docs/renderer-overscan-research.md`

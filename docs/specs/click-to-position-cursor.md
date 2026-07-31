# Spec: Click-to-Position Cursor in Terminal Input

> **分支:** `feat/click-to-position-cursor`
> **状态:** Draft
> **日期:** 2026-07-31

---

## 1. 动机（Motivation）

传统终端中，用户在 shell prompt 编辑命令时无法通过鼠标点击来移动输入光标——只能用左/右箭头键逐字移动。这在编辑长命令时体验很差。

现代终端（iTerm2、WezTerm、Kitty）已通过 shell integration 实现了这一功能。ProGhostty 作为面向开发者/AI CLI 用户的终端，应提供同等体验。

---

## 2. 目标（Goals）

1. 用户在 shell prompt 输入区域内点击时，光标移动到点击位置
2. 当应用程序开启鼠标报告模式（vim/tmux/fzf 等）时，正常转发鼠标事件而非拦截
3. 不违反项目核心原则：不在 libghostty-vt 之外解析 ANSI，不复制终端状态

---

## 3. 非目标（Non-Goals）

- 不实现完整的鼠标报告模式转发（那是独立 feature，本 spec 只做守卫判断）
- 不处理多行命令的跨行点击定位（v1 仅支持同一行内）
- 不支持远程 SSH 会话中无 shell integration 的场景下的精确定位

---

## 4. 现有代码基础（Existing Infrastructure）

经代码调研，以下能力已就绪：

| 能力 | 现有实现 | 位置 |
|------|----------|------|
| 像素→单元格映射 | `RenderedGridGeometry.coordinate(at:)` | `TerminalCore/PTY/RenderedGridGeometry.swift` |
| 当前光标位置 | `GhosttyTerminalFrame.cursorX/cursorY` | `TerminalCore/LibGhostty/GhosttyVTBridge.swift` |
| Prompt 区域推断 | `PromptCursorInferrer` | `TerminalCore/PTY/PromptCursorInferrer.swift` |
| 方向键序列生成 | `terminalControlInputData(for:)` → `\x1B[C` / `\x1B[D` | `TerminalCore/PTY/TerminalInputKeyMapper.swift` |
| 写入 PTY | `inputHandler?(data)` → `writeInput(_:to:)` | `PTYTerminalEngine.swift` |
| 鼠标点击入口 | `PTYGridView.mouseDown(with:)` | `PTYTerminalEngine.swift:2050` |
| VT 模式查询 API | `ghostty_terminal_mode_get()` | `Vendor/ghostty/include/ghostty/vt/modes.h` |

### 缺失/需新增：

| 缺失能力 | 所需工作 |
|----------|----------|
| 查询鼠标报告模式是否激活 | 扩展 C shim + `GhosttyVTBridge` 暴露 `isMouseReportingActive` |
| OSC 133 语义标记暴露到 Swift 层 | 扩展 C shim 读取 `GHOSTTY_ROW_DATA_SEMANTIC_PROMPT`（可选，v1 可用 heuristic） |
| 点击→光标移动的胶水逻辑 | 新增 `ClickToPositionHandler` |

---

## 5. 设计方案（Design）

### 5.1 整体流程

```
mouseDown on PTYGridView
  │
  ├─ ⌘-click? → 现有链接逻辑（不变）
  │
  ├─ 鼠标报告模式激活? → 转发鼠标事件给 PTY（future，本次仅 guard）
  │
  ├─ 点击在 prompt 输入区域内?
  │    ├─ YES → 计算 delta，发送方向键序列
  │    └─ NO  → 走现有文本选择逻辑
  │
  └─ fallback → 现有文本选择逻辑
```

### 5.2 组件拆分

#### 5.2.1 `MouseModeQuery`（扩展 GhosttyVTBridge）

```swift
// GhosttyVTBridge 新增
var isMouseReportingActive: Bool { get }
```

实现：调用 `ghostty_terminal_mode_get` 检查 mode 1000/1002/1003 任一激活。

需扩展 C shim 新增函数：

```c
bool proghostty_vt_mouse_reporting_active(ProGhosttyVTTerminal terminal);
```

#### 5.2.2 `PromptRegionDetector`（组合现有能力）

职责：判断给定 (row, col) 是否落在当前 prompt 的可编辑输入区域内。

v1 策略（heuristic）：
- 光标所在行（`frame.cursorY`）被视为输入行
- 使用 `PromptCursorInferrer` 的推断结果确定 prompt 前缀结束位置
- 点击列 ≥ prompt 前缀结束位置 且 ≤ 行末有效字符位置 → 在输入区域内

v2 策略（OSC 133，可选增强）：
- 从 libghostty-vt 读取 `GHOSTTY_ROW_DATA_SEMANTIC_PROMPT` 标记
- 精确知道哪些行是 `input` 类型

#### 5.2.3 `ClickToPositionHandler`

核心逻辑，纯值类型，可单测：

```swift
struct ClickToPositionHandler {
    struct Result {
        let arrowSequences: Data  // N 个 \x1B[C 或 \x1B[D
    }

    static func handle(
        clickCol: Int,
        cursorCol: Int,
        promptStartCol: Int,
        lineEndCol: Int
    ) -> Result?
}
```

逻辑：
1. 将 `clickCol` clamp 到 `[promptStartCol, lineEndCol]`
2. 计算 `delta = clickCol - cursorCol`
3. `delta > 0` → 生成 `delta` 个 `\x1B[C`（右箭头）
4. `delta < 0` → 生成 `|delta|` 个 `\x1B[D`（左箭头）
5. `delta == 0` → return nil（无需移动）

#### 5.2.4 `PTYGridView.mouseDown` 修改

在现有 `mouseDown(with:)` 中插入新分支（在链接检测之后、选择逻辑之前）：

```swift
// 新增：click-to-position
if !event.modifierFlags.contains(.command),
   !bridge.isMouseReportingActive,
   let geo = renderedGeometry(),
   let clickCoord = geo.coordinate(at: localPoint),
   isInPromptInputRegion(clickCoord) {
    if let sequences = ClickToPositionHandler.handle(...) {
        inputHandler?(sequences.arrowSequences)
        return  // 消费事件，不进入文本选择
    }
}
```

### 5.3 单击 vs 拖拽的区分

- `mouseDown` 记录点击位置但不立即触发定位
- `mouseUp` 时如果没有发生拖拽（移动距离 < 3px），才触发 click-to-position
- 这样保留了拖拽选择文本的能力

---

## 6. 边界约束（Architecture Compliance）

| 原则 | 合规方式 |
|------|----------|
| libghostty-vt 是唯一真相源 | 光标位置从 `frame.cursorX/Y` 读取，不自行追踪 |
| 不在 VT 外解析 ANSI | 不解析任何字节流，只消费已有快照 |
| Renderer 只渲染 | 不涉及 Renderer 修改 |
| 不复制终端状态 | `ClickToPositionHandler` 是无状态纯函数 |
| 扩展而非重写 | 复用 `RenderedGridGeometry`、`PromptCursorInferrer`、`inputHandler` |

---

## 7. 已知限制（Known Limitations）

1. **多行命令**：v1 仅处理光标所在行。跨行定位需要知道 shell 的 line-wrap 语义，复杂度高，留作 v2。
2. **宽字符（CJK）**：宽字符占 2 列，点击宽字符右半部分时需要正确计算实际列偏移。需在 `ClickToPositionHandler` 中处理。
3. **无 shell integration 的环境**：退化为 heuristic 推断，可能误判 prompt 区域。可接受——误判时最坏结果是不触发定位（用户体验与之前相同）。
4. **Tab 字符**：prompt 中如果有 tab，显示宽度与列数不一致。需按实际 cell 计数而非字符计数。
5. **右侧超出已输入内容**：点击在行尾已输入字符之后的空白区域，应 clamp 到最后一个有效字符位置。

---

## 8. 测试策略（Testing）

| 层级 | 测试内容 |
|------|----------|
| 单元测试 | `ClickToPositionHandler` 纯逻辑：正/负 delta、clamp、零 delta、边界情况 |
| 单元测试 | `PromptRegionDetector`：各种 prompt 样式的判定 |
| 单元测试 | `MouseModeQuery`：mock VT bridge 验证守卫逻辑 |
| 集成测试 | 在真实 PTY 场景中验证方向键序列到达 shell 并移动光标 |
| 手动测试 | zsh/bash/fish 下点击定位；vim 中点击不干扰；长命令编辑 |

---

## 9. 实现步骤（Implementation Plan）

### Phase 1: 基础设施（Guard + Query）

1. 扩展 C shim：新增 `proghostty_vt_mouse_reporting_active()`
2. 扩展 `GhosttyVTBridge`：暴露 `isMouseReportingActive`
3. 编写测试验证模式查询

### Phase 2: 核心逻辑

4. 实现 `ClickToPositionHandler`（纯值类型 + 单测）
5. 实现 `PromptRegionDetector`（组合 `PromptCursorInferrer` + frame cursor）
6. 编写测试覆盖各种 delta/clamp 场景

### Phase 3: 集成

7. 修改 `PTYGridView.mouseDown/mouseUp`：插入 click-to-position 分支
8. 处理单击 vs 拖拽区分逻辑
9. 集成测试 + 手动验证

### Phase 4: 增强（可选）

10. 暴露 OSC 133 语义标记到 Swift 层，替换 heuristic
11. 宽字符支持
12. 多行命令支持

---

## 10. 开放问题（Open Questions）

1. **双击/三击**：是否保留现有双击选词、三击选行行为？建议：保留，click-to-position 仅响应单击。
2. **alt-screen 下的行为**：vim/less 等 alt-screen 应用通常自己启用鼠标模式，但如果没启用呢？建议：alt-screen 下不触发 click-to-position。
3. **动画/视觉反馈**：光标跳转时是否需要闪烁或高亮？建议：v1 不加，依赖 shell 自身的光标渲染。

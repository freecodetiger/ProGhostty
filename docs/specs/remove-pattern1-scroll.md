# Spec: 移除 Pattern-1 滚动系统，统一到 Pattern-2

## 背景

ProGhostty 的滚动系统历史上有两套并行实现：

- **Pattern-1**：`PaneScrollController` + `PaneScrollCoordinator` + `ScrollCommitCoordinator` → 移动 VT viewport（`bridge.scrollViewport`）→ 行提交 + 像素余数
- **Pattern-2**：`SmoothScrollEngine` + display-link + `browseTopRow` + `presentBrowseWindow` → 不移动 VT viewport，直接从 scrollback fetch rows

经调研确认：
- `smoothPixelScrollingEnabled` 在生产中**永远为 true**（`SettingsStore.load()` 末尾强制覆写，无 UI 关闭入口）
- Pattern-2 在正常屏幕下**总是**处理滚轮事件
- Pattern-1 只在以下场景被触发：alt screen 转发（不涉及 scrollback 浏览）、极短暂的初始化窗口期
- 没有键盘滚动历史功能走 pattern-1

**目标**：删除 pattern-1 的 scrollback 浏览基础设施，保留 alt screen 转发，简化代码约 400 行。

---

## 删除清单

### 可完整删除的文件

| 文件 | 内容 |
|---|---|
| `TerminalCore/Renderer/PaneScrollController.swift` | `PaneScrollController` 整体（85 行） |

### `CellGridModel.swift` 中删除的类型（约 140 行）

| 类型 | 行范围 |
|---|---|
| `PaneScrollDecision` | 324-328 |
| `PaneScrollCoordinator` | 330-422 |
| `ScrollCommitCoordinator` | 424-466 |
| `ScrollCommitBatch` | （被 `drain()` 返回，连带删除） |

### `PTYTerminalEngine.swift`（PTYGridView）中删除/简化

| 内容 | 动作 |
|---|---|
| `private var scrollController = PaneScrollController()` | 删除 |
| `processScroll(deltaY:forwardToPTY:)` 整个方法（~90 行） | 删除 |
| `schedulePendingScrollCommit()` | 删除 |
| `flushPendingScrollCommit()` | 删除（公开方法，需检查外部调用） |
| `commitViewportScroll(rowDelta:)` | 删除 |
| `hasOverscanRows(forVisualOffsetY:)` | 保留（pattern-2 的 `canRenderPixelScroll` 也用到） |
| `viewportScrollHandler` 属性 | 删除 |
| `viewportCanScrollHandler` 属性 | 检查是否仍有 pattern-2 使用方（selection auto-scroll fallback），若无则删 |
| `testScrollWheelDeltaY` / `testMomentumScrollWheelDeltaY` 测试钩子 | 删除 |
| `resetViewportStartRowKeepingVisualOffset()` | 检查是否只被 pattern-1 调用，若是则删 |
| `applyScrollDiagnostics` 中的 pattern-1 字段 | 简化（`pixelRemainderY`、`committedRowDelta`、`coalescedWheelEvents`、`pendingScroll*`） |

### `PTYTerminalEngine.swift`（PTYTerminalSessionManager）中删除/简化

| 内容 | 动作 |
|---|---|
| `scrollViewport(_:rowDelta:)` 方法 | 删除（仅被 pattern-1 的 `viewportScrollHandler` 调用） |

### `PTYTerminalSurfaceRegistry.swift` 中删除/简化

| 内容 | 动作 |
|---|---|
| `scrollViewport(session:rowDelta:backend:)` | 删除 |
| `finishQueuedViewportScroll(...)` | 删除 |
| `cancelQueuedViewportScroll(session:)` | 删除 |
| `renderScrollCommit(...)` | 删除 |
| `isAtViewportEdge(...)` | 检查是否还有其他调用方，若无则删 |
| `configureLiveGridView` 中的 `viewportScrollHandler` 接线 | 删除 |
| `renderOutputImmediately` 中 `isViewingHistory` freeze 分支 | 删除（被 `browseTopAbsoluteRow` 分支覆盖） |
| `viewportScrollHandler` 属性（registry 层） | 删除 |

### `PTYGridView.isViewingHistory` 简化

```swift
// Before:
public var isViewingHistory: Bool {
    viewport != TerminalViewport() || scrollController.hasPendingCommit || browseTopRow != nil
}

// After:
public var isViewingHistory: Bool {
    browseTopRow != nil
}
```

### Selection auto-scroll fallback 迁移

`selectionAutoScrollTick()` 第 3529-3531 行有 pattern-1 fallback：

```swift
} else {
    didScroll = viewportCanScrollHandler?(selectionAutoScrollDirection) != false
        && viewportScrollHandler?(selectionAutoScrollDirection) == true
}
```

**迁移方案**：删除 `else` 分支。`canUsePattern2BrowseForSelection` 在生产中永远为 true（same guards as `shouldUseSmoothScrollBrowsing` minus alt-screen check，selection 不会在 alt screen 触发）。若 guard 不过（理论上不会），返回 `false` 即可停止自动滚动。

### `scrollWheel(with:)` 简化

```swift
// Before:
if shouldUseSmoothScrollBrowsing(for: event) {
    feedSmoothScroll(event)
    return
}
processScroll(deltaY: event.scrollingDeltaY) {
    super.scrollWheel(with: event)
}

// After:
if frame.isAlternateScreen {
    super.scrollWheel(with: event)
    return
}
feedSmoothScroll(event)
```

注意：`shouldUseSmoothScrollBrowsing` 的其他 guard（`smoothPixelScrollingEnabled`、handler 存在性、`cellSize > 0`）在生产中总是 true。为了防御性保留一个 early-return（不滚动），但不走 processScroll。

---

## 删除的测试（约 14 个）

### `TerminalRendererBackendTests.swift`

- `paneScrollCoordinatorConvertsWheelDeltaIntoCommittedRowsAndSubRowRemainder`
- `paneScrollCoordinatorKeepsOnlyOneLineOfPixelRemainderAcrossEvents`
- `paneScrollCoordinatorForwardsAlternateScreenWheelInputToPTY`
- `paneScrollCoordinatorFallsBackToRowScrollWithoutOverscanRows`
- `scrollCommitCoordinatorCoalescesRowDeltasUntilDrained`
- `liveGridDefersHighFrequencyWheelCommitsUntilFlush`
- `liveGridCommitsAccumulatedSlowTrackpadRowBeforeRemainderWraps`
- `paneScrollCoordinatorStateIsIndependentPerGridView`
- `liveGridForwardsAlternateScreenWheelInputToPTYWithoutPixelScroll`

### `TerminalSurfaceTests.swift`

- `liveCellGridScrollsLibGhosttyViewportForScrollbackHistory`
- `liveCellGridWheelScrollReachesLibGhosttyScrollbackWhenFrameHasNoExtraRows`
- `liveCellGridWheelScrollUsesOverscanPixelRemainderBeforeRowCommit`
- `liveCellGridWheelScrollFallsBackToRowScrollWhenPixelScrollIsDisabled`
- `liveCellGridWheelScrollReturnsToBottomAndIgnoresPastTopEdge`（需检查是否也测 pattern-2 行为）

---

## 必须保留的（不动）

| 内容 | 原因 |
|---|---|
| Alt screen `super.scrollWheel(with: event)` | TUI 鼠标滚轮报告 |
| `GhosttyVTQueueWork.scrollToBottom` / `bridge.scrollViewport` | 输入时回底部、输出跟随 |
| `SmoothScrollEngine` + display-link 全套 | 这就是新的唯一路径 |
| `browseTopRow` / `browseTopAbsoluteRow` | pattern-2 状态源 |
| `presentBrowseWindow` | pattern-2 渲染 |
| `renderOutputImmediately` 中 `browseTopAbsoluteRow` 分支 | pattern-2 输出时保持历史位置 |
| `TerminalRendererOptions.smoothPixelScrollingEnabled` 字段 | 保留但可考虑后续删除（目前还有 guard 引用） |

---

## 执行分 Phase

### Phase 1: 简化 `scrollWheel` 入口 + 删 `processScroll`

1. 重写 `scrollWheel(with:)` — alt screen 直接 forward，其余走 `feedSmoothScroll`
2. 删除 `processScroll(deltaY:forwardToPTY:)` 整个方法
3. 删除 `shouldUseSmoothScrollBrowsing(for:)`（逻辑内联到 `scrollWheel`）
4. 删除 `commitViewportScroll`、`schedulePendingScrollCommit`、`flushPendingScrollCommit`
5. 删除 `scrollController` 属性及所有引用
6. 删除 `viewportScrollHandler`、`viewportCanScrollHandler` 属性
7. 删除测试钩子 `testScrollWheelDeltaY` / `testMomentumScrollWheelDeltaY`

### Phase 2: 删 registry 层 pattern-1 基础设施

1. 删除 `scrollViewport(session:rowDelta:backend:)`
2. 删除 `finishQueuedViewportScroll` / `cancelQueuedViewportScroll`
3. 删除 `renderScrollCommit`
4. 删除 `configureLiveGridView` 中的 `viewportScrollHandler` 接线
5. 删除 registry 层 `viewportScrollHandler` 属性
6. 简化 `renderOutputImmediately` 中的 freeze 逻辑

### Phase 3: 删类型 + 简化属性

1. 删除 `PaneScrollController.swift` 文件
2. 删除 `CellGridModel.swift` 中 `PaneScrollDecision` / `PaneScrollCoordinator` / `ScrollCommitCoordinator`
3. 简化 `isViewingHistory` 为 `browseTopRow != nil`
4. 简化 `applyScrollDiagnostics`（去掉 pattern-1 字段）
5. 删除 `resetViewportStartRowKeepingVisualOffset`（若仅被 pattern-1 调用）

### Phase 4: 迁移 selection auto-scroll fallback

1. 删除 `selectionAutoScrollTick` 中的 `viewportScrollHandler` fallback 分支
2. 删除 `canUsePattern2BrowseForSelection`（永远为 true，内联）
3. 简化 `selectionAutoScrollCanScroll`

### Phase 5: 清理测试

1. 删除上述 14 个 pattern-1 专属测试
2. 新增 1-2 个测试验证 alt screen 仍正确转发
3. 确认 pattern-2 现有测试覆盖滚动全路径

---

## 验证

每个 Phase 结束后：
- `swift build` 通过
- `swift test` 全绿
- `scripts/check-architecture.sh` 通过
- 手测：普通滚动、惯性、alt screen（vim 中滚动）、selection drag auto-scroll

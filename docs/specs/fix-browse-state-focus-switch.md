# Spec: 修复分屏焦点切换导致历史浏览位置丢失

## 问题描述

当用户在多个分屏间切换焦点时，处于历史浏览状态（pattern-2 browse mode）的分屏会闪一下最底部（最新输出），然后在下一次滚动操作时才跳回正确的历史位置。

## 复现步骤

1. 有两个或以上分屏
2. 在 Pane A 中向上滚动查看历史（进入 browse mode，`browseTopRow` 非 nil）
3. 鼠标点击 Pane B 切换焦点
4. 鼠标点击 Pane A 切回
5. **观察**：Pane A 短暂显示最底部内容，而非之前浏览的历史位置
6. 再滚动一次，才跳回正确位置

## 根因分析

### 触发链路

```
鼠标点击 Pane B
  → PTYGridView activation handler
  → AppModel.selectSession(_:)
  → AppModel.applyFocusedTerminalSurface()
  → PTYTerminalSurfaceRegistry.setFocusedSession(newSessionID)
```

### 缺陷位置

`PTYTerminalSurfaceRegistry.setFocusedSession(_:)` 第 342-358 行：

```swift
public func setFocusedSession(_ id: TerminalSessionID?) {
    guard focusedSessionID != id else { return }
    focusedSessionID = id
    for (sessionID, surface) in surfaces {
        if let html = surface.lastHTMLSnapshot, ... {
            // text backend 路径
            surface.textBackend.render(attributed: attributed, scrollToEnd: false)
        } else if let frame = surface.lastFrame {
            // ← BUG: lastFrame 总是 live bottom frame
            render(frame, in: surface.liveRenderer, isFocused: isFocused(sessionID))
        }
    }
}
```

`surface.lastFrame` 的语义是"VT 层最后产出的 live frame"（即最底部），它在 `presentBrowseWindow` 中**不会被更新**（只更新 `lastRenderFrame`）。所以当 surface 处于 browse 模式时，用 `lastFrame` 渲染会把屏幕刷成最底部内容。

### 恢复机制

闪烁后恢复有两条路径：
- 新 PTY 输出到达 → `renderOutputImmediately` 检测 `browseTopAbsoluteRow != nil`，调 `presentBrowseWindow` 恢复
- 用户滚动 → `startSmoothScrollBrowsing` 从 `browseTopRow` 种子恢复

### 同源缺陷

以下方法存在完全相同的 pattern，有相同的潜在问题：
- `applyPalette(_:)` 第 277-296 行
- `applyFont(family:size:cjkFallbackFamily:)` 第 298-321 行

## 修复方案

### 策略：提取统一的 `refreshPresentation` 方法

将"以当前可见状态刷新 presentation 属性（cursor focused 等）"的逻辑封装为一个方法，所有需要"重绘但不改变滚动位置"的场景统一调用。

### 新增方法

```swift
/// 以当前可见状态重新渲染 surface 的 presentation 属性（如 focused cursor）。
/// 如果 surface 处于 browse 模式，重绘历史窗口；否则渲染 live bottom frame。
/// 用于 focus 切换、palette/font 变更等不改变滚动语义的场景。
private func refreshPresentation(for sessionID: TerminalSessionID) {
    guard let surface = surfaces[sessionID] else { return }

    // 路径 1: text backend (HTML snapshot)
    if let html = surface.lastHTMLSnapshot,
       let attributed = try? attributedTerminalSnapshot(
           fromHTML: html,
           cursorFrame: surface.lastCursorFrame,
           isFocused: isFocused(sessionID)
       ) {
        surface.textBackend.render(attributed: attributed, scrollToEnd: false)
        return
    }

    // 路径 2: pattern-2 browse mode — 重绘历史窗口
    if surface.containerView.isShowingLiveGrid,
       let browseTop = surface.gridView.browseTopAbsoluteRow {
        let visibleRows = surface.lastFrame?.rows ?? 0
        if visibleRows > 0 {
            presentBrowseWindow(session: sessionID, topAbsoluteRow: browseTop, visibleRows: visibleRows)
            return
        }
    }

    // 路径 3: live bottom — 正常渲染
    if let frame = surface.lastFrame {
        render(frame, in: surface.liveRenderer, isFocused: isFocused(sessionID))
    }
}
```

### 修改点

#### 1. `setFocusedSession(_:)`

```swift
public func setFocusedSession(_ id: TerminalSessionID?) {
    guard focusedSessionID != id else { return }
    focusedSessionID = id
    for sessionID in surfaces.keys {
        refreshPresentation(for: sessionID)
    }
}
```

#### 2. `applyPalette(_:)`

```swift
public func applyPalette(_ palette: TerminalSurfacePalette) {
    self.palette = palette
    for (sessionID, surface) in surfaces {
        surface.containerView.applyPalette(palette)
        surface.gridView.applyPalette(palette)
        surface.liveRenderer.applyPalette(palette)
        surface.textBackend.applyPalette(palette)
        refreshPresentation(for: sessionID)
    }
}
```

#### 3. `applyFont(family:size:cjkFallbackFamily:)`

```swift
public func applyFont(family: String, size: CGFloat, cjkFallbackFamily: String? = nil) {
    fontFamily = family
    self.cjkFallbackFamily = normalizedFontFamily(cjkFallbackFamily)
    fontSize = size
    for (sessionID, surface) in surfaces {
        surface.textView.font = terminalFont(weight: .regular)
        surface.gridView.applyFont(family: family, size: size, cjkFallbackFamily: self.cjkFallbackFamily)
        surface.liveRenderer.applyFont(family: family, size: size, cjkFallbackFamily: self.cjkFallbackFamily)
        surface.textBackend.applyFont(family: family, size: size, cjkFallbackFamily: self.cjkFallbackFamily)
        refreshPresentation(for: sessionID)
        surface.textView.window?.invalidateCursorRects(for: surface.textView)
        surface.gridView.window?.invalidateCursorRects(for: surface.gridView)
    }
}
```

## 设计要点

1. **`presentBrowseWindow` 已自包含 `isFocused` 逻辑**（内部调用 `isFocused(id)`），focus 变更后直接调用即可正确反映新状态，无需改签名。

2. **`surface.bridge` 在 focus 切换时一定非 nil**（session 活着），`presentBrowseWindow` 的 guard 不会 early-return。

3. **`isShowingLiveGrid` 检查**：只有在 live grid 模式下 browse 状态才有意义；text backend 回退模式走路径 1 已正确处理。

4. **不涉及 `PTYGridView` / `SmoothScrollEngine` 的改动**——纯粹是 registry 层的 presentation 刷新逻辑修正。

## 影响范围

- 只修改 `PTYTerminalSurfaceRegistry.swift` 一个文件
- 不改变任何公开 API
- 不影响 `renderOutputImmediately` / `presentBrowseWindow` / scroll 流水线的现有行为
- `replaceLiveRenderer` 中的 `lastRenderFrame` 路径（第 232 行）不受影响，它已经正确保持了可见帧

## 验证方式

1. `swift build` 编译通过
2. `swift test` 全量测试绿
3. `scripts/check-architecture.sh` 通过
4. 手动验证：
   - 两分屏，一个浏览历史，来回切换焦点 → 历史位置不闪烁
   - 浏览历史时切换 palette/font → 历史位置不跳
   - 非 browse 状态下切换焦点 → 行为不变（光标样式正确切换）

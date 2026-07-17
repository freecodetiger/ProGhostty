---
name: rendering-pipeline
description: 改动 ProGhostty 渲染层（Metal 直渲 / cell-grid 回退 / 滚动 / 脏行）时使用。覆盖三层降级梯、不可变快照契约、像素滚动路径与渲染边界。
---

# 渲染管线（Rendering Pipeline）

改任何 `Sources/ProGhosttyCore/TerminalCore/Renderer/` 下的代码，或滚动/脏行/Metal 相关逻辑前读本文件。

## 铁律

- **Renderer 只渲染。** 读不可变快照画像素。不拥有终端状态、不解析 ANSI、不管光标语义、不直接碰 PTY。
- **`libghostty-vt` 是终端状态唯一真相源。** UI 可保留亚行像素余量（sub-row remainder）用于呈现，但**绝不**保留独立的 scrollback 镜像。
- **Metal 只画像素**；终端语义留在 `libghostty-vt` 和 CPU 侧交互代码。
- Alternate-screen / TUI 正确性 **优先于** 滚动动画。

## 三层降级梯

`TerminalRendererPolicy.resolve(mode:hasFrame:isMetalDirectAvailable:)` 选后端：

```
.auto（默认）→ 有帧且 Metal 可用 → MetalDirectRendererBackend
              → 否则                → GhosttyVTCellGridRendererBackend
              → 无帧                → 文本回退 (.ghosttyVTTextFallback)
```

后端枚举臂：`.metalDirect` / `.ghosttyVTCellGrid` / `.ghosttyVTTextFallback`（`TerminalRendererMode`）。
**这是有意的降级设计，不是冗余——不要删任何一层。**

关键文件：
- `TerminalRendererPolicy.swift` — 纯函数选后端。
- `MetalDirectRendererBackend.swift` / `MetalDirectRenderEngine.swift` — GPU 路径。
- `GhosttyVTCellGridRendererBackend.swift` — AppKit 回退。
- `GhosttyVTTextRendererBackend.swift` — 文本回退（非实时投影）。
- `MetalTerminalFrameEncoder.swift` / `MetalGlyphAtlas.swift` / `MetalCellInstanceBuffer.swift` / `MetalOverlayBuffer.swift` — Metal 编码/字形/实例/overlay。
- `CellGridModel.swift` — `TerminalViewport` / `ViewportController` / `SelectionController` 等值类型。

## 不可变快照契约

- `GhosttyTerminalFrame`（`GhosttyVTBridge.swift`）：`Sendable`/`Equatable` 值，含 `cells: [Cell]` + 光标 (`cursorX/Y/Visible/Shape`) + `isAlternateScreen`。Renderer 读它，不改它。
- `GhosttyTerminalScrollFrame`：viewport + `overscanTop/Bottom` 行 + `viewportStartRow`。
- `TerminalRenderFrame`（`TerminalRendererBackend.swift`）：包 frame + 可选 scrollFrame + `isFocused`。

快照跨 bridge 锁把 cells 拷成 Swift 值——每次跨界都有成本，别在热路径重复取。

## 输出渲染路径

```
PTY 字节 → GhosttyVTBridge.write → libghostty-vt
        → PTYTerminalSurfaceRegistry.render
        → GhosttyVTBridge.frame + scrollFrame(overscanTop:2, overscanBottom:2)
        → TerminalRenderFrame → TerminalLiveRendererBackend.render → 调度/强制 flush
```

Metal 直渲时：`MetalDirectRendererBackend.render → flushPendingFrame → MetalDirectRendererView.present`。
注意 `MetalDirectRendererView` **继承** `PTYGridView`，`draw(_:)` 为空，但 `present(_:)` 仍调 `super.render(...)` 同步 grid 状态、输入呈现、光标 rect、选区、链接 hover、IME。拆分 `PTYGridView` 时**必须保留 Metal backend 依赖的转发访问器**（如 `directView.viewport.visualOffsetY`）。

## 像素滚动路径

```
trackpad/wheel → PTYGridView.scrollWheel
  → PaneScrollCoordinator.scroll（更新 viewport.visualOffsetY 亚行余量）
  → 累积跨过一行 → ScrollCommitCoordinator.enqueue（~120Hz 合并）
  → PTYGridView.commitViewportScroll → PTYTerminalSurfaceRegistry.scrollViewport
  → GhosttyVTBridge.scrollViewport + scrollbar   （VT 行移动仍归 libghostty）
  → renderScrollCommit → backend.render → resetViewportStartRowKeepingVisualOffset
```

- **纯亚行像素移动**便宜；**行提交帧**贵（要动权威 VT 视口 + 抓快照 + 渲染 + 调度）。
- 滚动 owner 目前分散在 `PaneScrollCoordinator` / `ScrollCommitCoordinator` / `viewport.visualOffsetY`，计划收敛到 `PaneScrollController`（见 `.claude/ARCHITECTURE_PLAN.md` 阶段 2）。收敛时 VT 行移动仍留在 `bridge.scrollViewport`——别把语义搬进 Swift。

## 诊断

- Metal 专属指标在 `MetalDirectDiagnostics` 子结构（已从 `TerminalRendererDiagnostics` 拆出）。加 Metal 指标只动这里；cell-grid / text 后端不背 Metal 字段。

## 禁止

- ❌ 每帧重建 `NSAttributedString`；❌ 重绘整个视口（用脏行 + cell diff）。
- ❌ 在 renderer 解析 ANSI / 维护 scrollback 镜像 / 改 VT 状态。
- ❌ render loop 里做分配或 O(n²) 扫描。
- ❌ 删降级梯任何一层；❌ 删 Metal backend 依赖的转发访问器。
- ❌ 未被要求就重写渲染管线。

## 深入参考

`docs/architecture/rendering-path-and-optimization-plan.md`（权威且最新，含全部缓存/合并层与已知重点）、`docs/design/gpu-first-renderer-rework.md`、`docs/design/metal-direct-renderer.md`、`docs/renderer-scrolling.md`、`docs/renderer-overscan-research.md`。测试见 `Tests/ProGhosttyCoreTests/TerminalRendererBackendTests.swift`。

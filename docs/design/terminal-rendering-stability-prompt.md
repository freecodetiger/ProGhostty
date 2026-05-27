# ProGhostty 终端渲染稳定性执行 Prompt

> 这是一份给执行型 agent 用的工作单。  
> 目标不变：默认走最高性能路径，但不能牺牲输入稳定、光标锚定、像素级滚动和可回退性。

## 任务目标

在 `/Users/zpc/projects/proghostty` 的当前工作树里，继续把终端渲染重构推进到“可用、可测、可回退”的状态。

不要重写整个 renderer，不要引入第二套 scrollback model，不要把 renderer 选择暴露成用户 UI。

你的工作重点是：

1. 长历史输出和缩放时，减少自上而下的重绘抖动
2. 输入时保持光标和内容锚定
3. 保住现有像素级滚动体验
4. 让高性能路径失败时能自动回退，并且诊断清楚

## 当前基线

以下能力已经成立，除非边界不对，不要重复做：

- `auto` 后端默认顺序是 `MetalDirect` -> `MetalLive` -> `GhosttyVTCellGrid`
- `MetalDirectRendererBackend`、`MetalDirectRenderEngine`、`MetalTerminalFrameEncoder` 已经存在
- partial redraw、offscreen texture、fallback、diagnostics、glyph atlas、overlay buffer 都已经有基础
- completion handler 不能直接碰 `MainActor`

## 必须遵守的边界

- `libghostty-vt` 仍然是唯一的终端语义来源
- GPU 只负责绘制和 present，不负责 VT state、scrollback、PTY、selection、link detection
- 像素级滚动必须继续是“CPU scroll state + GPU draw offset”
- 高性能路径不稳定时，优先保住像素滚动和视觉稳定，再考虑性能
- 不能为了快而让输入抖动、光标漂移、selection 失真或 IME 异常

## 先看这些文件

- `Sources/ProGhosttyCore/TerminalCore/Renderer/TerminalRendererBackend.swift`
- `Sources/ProGhosttyCore/TerminalCore/Renderer/MetalDirectRendererBackend.swift`
- `Sources/ProGhosttyCore/TerminalCore/Renderer/MetalDirectRenderEngine.swift`
- `Sources/ProGhosttyCore/TerminalCore/Renderer/MetalTerminalFrameEncoder.swift`
- `Sources/ProGhosttyCore/TerminalCore/Renderer/MetalOverlayBuffer.swift`
- `Sources/ProGhosttyCore/TerminalCore/Renderer/MetalCellInstanceBuffer.swift`
- `Sources/ProGhosttyCore/TerminalCore/Renderer/MetalGlyphAtlas.swift`
- `Sources/ProGhosttyCore/TerminalCore/Renderer/GhosttyVTCellGridRendererBackend.swift`
- `Sources/ProGhosttyCore/TerminalCore/PTY/PTYTerminalEngine.swift`
- `Tests/ProGhosttyCoreTests/TerminalRendererBackendTests.swift`
- `Tests/ProGhosttyCoreTests/TerminalSurfaceTests.swift`

## 先做什么

按下面顺序推进，必须 TDD：

1. 写失败测试
2. 运行测试确认是红的
3. 写最小实现
4. 再跑测试确认变绿
5. 再进入下一项

推荐先跑：

```bash
swift test --filter TerminalRendererBackendTests
swift test --filter TerminalSurfaceTests
```

## 优先级任务

### 1. 先砍掉整帧 styleStats 扫描

问题：长历史下 resize 或输入时，整帧扫描会把 CPU 成本拉高。

目标：

- `MetalDirectRendererBackend.updateDiagnostics(from:)` 不再把整帧扫描当常规路径
- 改成按 dirty rows 或等价缓存更新
- 首帧、full redraw、resize、grid size 变化时允许重建
- 其余情况只重算 dirty rows

要补的诊断字段：

- `metalDirectStyleScanRowCount`
- `metalDirectStyleScanCellCount`

推荐测试：

- `metalDirectRendererBackendScansStyleStatsOnlyForDirtyRowsAfterInitialFrame`

### 2. dirty partial redraw 不能清掉旧像素

问题：partial redraw 如果继续整屏 `.clear`，未重绘区域会闪掉。

目标：

- first frame 清屏
- texture 尺寸变化清屏
- full redraw 清屏
- dirty partial redraw 必须 `.load`
- 只有真正重建整张图时才清屏

推荐测试：

- `metalDirectRenderPassClearsFirstFrame`
- `metalDirectRenderPassClearsAfterResize`
- `metalDirectRenderPassLoadsForPartialDirtyRows`

### 3. 只重绘真正需要的 rows

问题：不能让 GPU 仍然偷偷构造全量顶点。

目标：

- dirty rows 要准确映射到 `drawFrame`
- scroll frame 下 viewport row 和 overscan row 偏移要算对
- background、glyph、atlas slice、overlay 都只能处理被选中的 rows

推荐测试：

- `metalDirectRenderRowsUsesFullRangeForFullRedraw`
- `metalDirectRenderRowsMapsViewportDirtyRowsThroughOverscan`
- `metalDirectRenderRowsClampsDirtyRowsToDrawFrame`

### 4. 降低同步等待和旧帧覆盖新帧的风险

问题：这是输入“不抖”、光标“不漂”的关键。

目标：

- 常规 dirty frame 不要阻塞主线程等 GPU
- first frame 和 resize 可以更保守
- 只保留 latest-frame-wins
- completion handler 不能直接改 `MainActor` 状态
- 旧 command buffer 完成后不能覆盖新 frame

推荐测试：

- 快速连续 render 两帧，只显示最新帧
- runtime failure 自动回退到 `GhosttyVTCellGrid`
- resize 后旧尺寸 frame 不能覆盖新 drawable

### 5. 诊断必须可读、可排障

目标：

- fallback reason 必须明确
- `usesBitmapCapture == false` 要稳定可见
- dirty frame 的 uploaded rows、drawn rows、glyph scan rows 应该小于全量 rows
- 日志里要区分：
  - requested backend
  - active backend
  - fallback reason
  - metal direct 是否真的在工作
  - 是否发生 stale completion / dropped frame / coalescing

## 不要做的事

- 不要重写整个 renderer
- 不要引入新的终端状态模型
- 不要把 scrollback 复制到 GPU 侧长期维护
- 不要把 VT parsing、selection、link detection 移到 GPU
- 不要只改 diagnostics，不减少真实 draw work
- 不要为了性能把稳定性问题藏起来

## 完成标准

只有下面这些都成立，才算这份 prompt 对应的工作做完：

- `swift test --filter TerminalRendererBackendTests` 通过
- `swift test --filter TerminalSurfaceTests` 通过
- `swift test` 通过
- 长历史下缩放 panel 不再出现持续数秒的自上而下刷新
- 输入时光标不漂，视觉锚定稳定
- 像素级滚动仍然保留
- `auto` 默认路径仍然选择最高性能且稳定的后端
- 高性能路径失败时自动回退，诊断可见

## 相关文档

- `docs/design/metal-direct-renderer.md`
- `docs/superpowers/specs/2026-05-26-metal-direct-renderer-design.md`
- `docs/superpowers/plans/2026-05-26-metal-direct-renderer-plan.md`

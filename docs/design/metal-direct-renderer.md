# Metal Direct Renderer Design

## Goal

把当前“先转 AppKit 位图、再走 Metal 显示”的路径，升级成真正的直接 Metal 渲染器。

目标是让长历史输出、窗口缩放、以及像素级滚动时的体验明显更稳，减少从上到下高速刷新带来的卡顿。

## Core Direction

保留现有的职责边界：

- `libghostty-vt` 继续负责终端状态
- `PaneScrollCoordinator` 继续负责像素滚动与行提交
- 命中测试、链接检测、选择、IME、PTY 行为继续留在 CPU 侧
- AppKit cell-grid 继续作为可用 fallback

GPU 只负责绘制，不负责终端语义。

## Rendering Model

新的路径大致是：

```text
PTY bytes
  -> libghostty-vt
  -> TerminalRenderFrame
  -> Metal render plan
  -> glyph atlas + cell instances + overlay primitives
  -> Metal draw pass
  -> CAMetalLayer present
```

这里的关键变化是：

- 不再在热路径里把 `PTYGridView` 渲染成 `NSBitmapImageRep`
- 不再依赖 PNG / CGImage / `MTKTextureLoader` 作为每帧中转
- 改为直接把字符、背景、光标、选择、链接提示编码成 Metal 绘制输入

## Main Components

### Metal render plan

把一次可展示的终端帧整理成不可变计划，包含：

- viewport / overscan 行数
- cell metrics
- pixel scroll remainder
- dirty rows
- focus / cursor / palette / font 相关信息

### Glyph atlas

用 CPU 预渲染字形，再上传到 Metal texture。

它负责缓存与复用，不负责文本 shaping，也不负责终端状态。

### Cell instance buffer

把 dirty rows 映射为 GPU 可绘制的 cell instances，只更新变化区域，避免整屏重建。

### Overlay buffer

把 cursor、selection、link hover、marked text 等覆盖层转成 GPU primitive。

## Fallback Rules

直接 Metal 不是无条件启用的。遇到这些情况要回退：

- Metal 不可用
- shader / pipeline 创建失败
- glyph atlas 上传失败
- frame 尺寸超过安全上限
- 像素滚动需要的 overscan 不足
- 当前文本能力尚未支持

回退必须可观测，诊断里要说明：

- 当前使用的 backend
- 请求的 backend
- fallback reason

## Phased Delivery

### Phase 1

先把 direct backend 骨架和 selection 接起来，做到“可请求、可回退、可观测”。

### Phase 2

补齐 render plan、glyph atlas、cell instance buffer 和 overlay buffer。

### Phase 3

把 pixel scroll、resize burst、selection/link/IME 行为全部对齐到现有语义。

### Phase 4

用完整测试和人工验证确认它适合长期使用，再考虑是否扩大默认启用范围。

## Success Criteria

这条路线成立的标志是：

- 长历史输出缩放时，不再出现明显的从上到下高速重绘感
- 像素级滚动仍然保持丝滑
- selection / link / cursor / IME 行为和现有路径一致
- fallback 明确、可诊断、可恢复
- 全量测试通过

## References

- [Detailed spec](../superpowers/specs/2026-05-26-metal-direct-renderer-design.md)
- [Implementation plan](../superpowers/plans/2026-05-26-metal-direct-renderer-plan.md)

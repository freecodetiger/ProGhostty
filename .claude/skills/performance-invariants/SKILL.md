---
name: performance-invariants
description: 做渲染/滚动/输出性能优化，或需要判断"正确性 vs 流畅 vs 可读性"取舍时使用。覆盖脏行渲染、缓存层、合并、render loop 禁忌。
---

# 性能不变量（Performance Invariants）

优化性能、动热路径（渲染 / 滚动 / 输出）前读本文件。

## 优先级（冲突时按此裁决）

```
正确性  >  流畅  >  可读性
```

含义：宁可代码复杂一点，也**绝不**每帧 rebuild 或重绘整屏。但正确性（尤其 alternate-screen / TUI）永远压过滚动动画的顺滑。

## 硬性规则

- ✅ **脏行 / 脏 cell 渲染**（dirty-region），不重绘整个视口。
- ✅ **不可变快照**（`GhosttyTerminalFrame`），不共享可变状态。
- ✅ **cell diff / 增量更新**，不每帧重建。
- ✅ **缓存优于重算**；命中后复用。
- ❌ 每帧重建 `NSAttributedString`。
- ❌ render loop 里做内存分配。
- ❌ O(n²) 扫描；优先缓存 + 增量。
- ❌ 把 plugin/UI 状态推进终端渲染路径。

## 现有缓存与合并层（别重复造）

已在位（`docs/architecture/rendering-path-and-optimization-plan.md`）：

- **Pattern-2 主路径**：`SmoothScrollEngine` + `SmoothScrollBrowseResolver` + `presentBrowseWindow`（`rows(at:)`，VT 不动）；亚行余量 `viewport.visualOffsetY`。
- **Fallback**：`PaneScrollController`（`PaneScrollCoordinator` 像素余量 + `ScrollCommitCoordinator` ~120Hz 行提交）。
- `CellGridDirtyTracker` — 算脏行 + 脏 cell 范围。
- `MetalGlyphAtlas` — 缓存渲染后的字形图。
- `MetalDirectRenderEngine` — 按字形 atlas entry id + generation 缓存 Metal 纹理。
- `StyleStatsCache` — 跳过未变行的样式统计重扫。
- `ResizeSensitivityCache` — 除非缓存键变，不重扫光标下方所有行。
- `TerminalOutputCoordinator` + `TerminalOutputBatchCoordinator` — 输出快照/字节两级合并，共 8ms 预算。

加优化前先确认想要的缓存是否已存在——主路径问题多在 `rows(at:)`/display-link 呈现；fallback 问题多在行提交帧。

## 已知重点（改这些要小心）

- **Fallback 行提交帧重**：同步动权威 VT 视口 + 抓 scrollbar/scrollFrame 快照 + backend staging + 视口余量 reset，全在主 actor（仅 smooth off / alt / 无 browse plumbing）。
- **扩展帧分配**：`overscanTop.cells + viewport.cells + overscanBottom.cells` 在多处重复构建，滚动时加 CPU 压力。
- **快照跨界成本**：每次 `frame()`/`scrollFrame()` 跨 bridge 锁把 cells 拷成 Swift 值。
- **GPU 等待**：`MetalDirectRenderEngine.shouldWaitForCommandCompletion` 在首帧/纹理 resize/全量重绘/光标行脏/overlay 存在等条件下等命令完成，可能造成滚动尖刺。
- **全量重建启发**：`MetalDirectRendererBackend.scrollFrameFullSceneRebuildReason` 在形状/维度/overscan 变化时强制全脏——保守但别无谓触发。

## 优化前的纪律

1. **先加诊断**再改行为——定位是哪一层慢（该文档 Diagnostics 节）。
2. **先测量**，别猜。行提交帧和纯像素移动成本差一个量级。
3. **改完更新** `docs/architecture/rendering-path-and-optimization-plan.md`（renderer 性能工作要求先更文档再对齐实现）。
4. **正确性回归**：alternate-screen / TUI（vim/htop/fzf/Codex）行为不能因优化退化。
5. **别合并语义不同的去抖器**；别删"仅当前接线下不走"但有测试覆盖的路径（上一轮教训）。

## 禁止

- ❌ 为流畅牺牲正确性。
- ❌ 每帧 rebuild / 重绘整屏 / render loop 分配。
- ❌ 重复造已存在的缓存层。
- ❌ 不测量就"优化"。

## 深入参考

`docs/architecture/rendering-path-and-optimization-plan.md`（权威，含全部层 + 已知重点 + 工作假设）、`docs/renderer-scrolling.md`、`docs/renderer-overscan-research.md`。计时测试：`TerminalRendererBackendTests`、`TerminalResizeCoordinatorTests`（burst/coalescing 相关）。

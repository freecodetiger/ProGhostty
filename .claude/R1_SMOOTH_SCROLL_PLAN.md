# R1 实施方案：大 overscan 缓冲 + display-link 像素滚动

状态：待审阅 · 基于两份子代理勘察(坐标铁证 + 全波及面)
分支：`feat/smooth-scroll-engine`(已含 R1.0 提交 `5df465b`)

---

## 0. 目标与已确立的事实

**目标**：让滚动既丝滑(display-link 节拍、一帧平移多行)又无闪烁(offset 与内容原子一致),消除当前事件驱动滚动的 14-26fps 上限。

**已用数据坐实的前提**：
- `seq` 慢是旧 bundle 假象,当前输出管线健康(23 批秒出)。
- 滚动帧率不足是事件驱动固有上限,非回归。
- 丝滑曾在 6/18 存在,被 `386615f`(消闪烁的原子提交抑制)换成微抖动——R1 要同时消除两者。
- VT 侧 overscan 硬顶 **32 行**(`ProGhosttyGhosttyVT.c` 已放开到 32,测试锁定);当前请求 24 行,已验证 0.45ms 廉价。

**坐标铁证**(shader 内嵌 `MetalDirectRenderEngine.swift:1286-1289`)：
- Y 向下(top-left 原点):`clip.y = 1.0 - 2·y/height`。
- 当前纹理仅 viewport 高;viewport band 锚在纹理顶部(texel y=inset),overscan-top 落在负 y 被裁。
- composite quad:`presentationTranslationY` 越负 → 内容越往上。
- 保持 `sceneTranslationY` 不变时纹理只能向底部长高 → 无法在 band 上方放 overscan-top。要 band 两侧都有缓冲,**必须** `sceneTranslationY=0` + composite 改为只采样 viewport 子 band。

---

## 1. 最关键的正确性红线(不可违反)

> **CoreGraphics 路径与 Metal 路径共享同一个 `RenderedGridGeometry.translationY`(`PTYTerminalEngine.swift:2402`),所有命中测试(选区/链接/IME/光标 rect/URL 点击/点→格)都依赖它与实际像素完全一致。**

任何改渲染平移的改动,**必须同步**改 `RenderedGridGeometry.translationY`,否则滚动时选区、链接高亮、IME 光标、URL 点击全部错位。这是全应用红线,是 R1 correctness 的核心约束。

## 2. 完整改动面(A–H,来自波及面勘察)

### A. 纹理尺寸 / band 选择(改动核心)
- `MetalDirectRenderEngine.renderTargetSize` :648-665 — 高度从 `viewportRows*cellHeight` → 含 overscan 的 `(overscanTop+viewport+overscanBottom)*cellHeight`。
- `render` 里 `renderSize`/`ensureOffscreenTexture` :243,:263 — 随之分配更大纹理。
- `TerminalRenderFrame.expandedFrame`(`TerminalRendererBackend.swift:72-83`)— 已拼好 overscan+viewport+overscan,`cursorY += overscanTop`。不改,是数据源。

### B. Metal 平移(sceneTranslationY + composite)
- `drawTranslationY` :1219-1221 → 场景平移改为 `0`(整 expanded grid 画进大纹理)。
- `sceneTranslationY` :237-241 → 0(sub-row 仍不在场景,留给 composite)。
- `presentationTranslationY` :242 + composite quad :395-404 → 从固定 `(0,0,1,1)` texCoord 改为**只采样 viewport 子 band**(v 从 `overscanTop*cellHeight/textureHeight` 起),并按 `-overscanTop*cellHeight + pixelRemainderY` 偏移选 band。
- 背景/字形顶点 translationY :294,:347 → 0。
- `cursorGlyphLayout` :746、`markedTextGlyphLayout` :774-778 → 平移改 0(行偏移 `+overscanTop` 不变)。
- `MetalOverlayBuffer.makeOverlays` translationY :62-63 → 从 `-overscanTop*cellHeight+remainder` 改为与新模型一致(0 + 行偏移已含 overscanTop)。
- `scrollFrameFullSceneRebuildReason` :694-717 — overscan 变化触发全重建;大 overscan 会更频繁,需评估脏跟踪成本。
- 脏行映射 `renderRowRuns`/`renderCellRanges` rowOffset :857,:886 — `+overscanTopRows`,随 overscan 数变化,复核。

### C. CoreGraphics / NSView draw 路径(PTYGridView)
- `draw(_:)` :1165-1197、`drawTranslationY` :2147-2149、`extendedFrame` :2172-2180、`renderedClipRect` :2163-2170、`contentDirtyRect` :2159-2161 — 与 Metal 同构,平移模型改动需镜像。
- **`visualScrollTranslationY` 的 ±cellHeight clamp :1199-1210 → 解除**(见 F,总闸)。

### D. 命中测试 / 点↔格几何(红线,必须与像素同步)
- `RenderedGridGeometry` :2886-2939 + `renderedGeometry()` :2397-2418 — `translationY`(:2402)是所有命中测试的单一权威,**必须与渲染器实际平移逐值一致**。
- 依赖它的:`linkHit` :2204、命令点击 URL :1563、选区 :1574-1590、`resetCursorRects`/URL rects :1637-1663/:1277-1321、`currentSelectionRowSet` :1706-1724、光标/IME overlay :1739-1751/:2088-2107、IME `firstRect`/`characterIndex` :2814-2837、`renderedCursorRect` :2420-2508。
- **不变式**:选区行来自 `renderedGeometry`(extended-frame 空间),故 Metal 传 `selectionRowsOffset:0`。改动须保持此不变式。

### E. overscan 行数偏移(row math)
- cursorY/cursorRow `+overscanTop`:`expandedFrame`:2175、Metal :348,:719-720、Overlay :65。
- `markedTextRowsOffset`/`selectionRowsOffset` 参数链。这些偏移语义不变(仍 +overscanTop),但要确认平移改 0 后组合结果仍正确。

### F. Clamp 与假设(解 clamp 是多行平移的前提)
- **`visualScrollTranslationY` clamp 到 ±cellHeight :1209** — "一次只滚一行"总闸。解除后允许在 overscan 缓冲内(±24 行 × cellHeight)自由平移。这是 R1.2 才需要的,R1.1 不动。
- `pixelScrollOverscanRows=24`(`GhosttyVTBridge.swift:107`)+ VT 32 行硬顶 — 已就位。
- `PaneScrollCoordinator.scroll`(`CellGridModel.swift:376-395`)— 假设 remainder 每次提交后回到 sub-row;大 overscan 下 remainder 可跨多行,需配合 display-link 消费模型重审(R1.2)。
- `render(...)` 非零 offset 强制全重绘 :1109,:1135 — ±1 行下廉价,大 band 下需复核。

### G. CellGrid 后端
- `GhosttyVTCellGridRendererBackend` 不拥有平移,委托 `PTYGridView`(:263-271),自动继承 C+D。仅诊断代码涉 overscan。

### H. 需更新的测试
- `TerminalRendererBackendTests`:clamp 断言 :2037-2054(offset24→16)、脏矩形 :2056-2079、提交/rebase :2020-2035、encoder pixelRemainderY :1380-1469。
- `TerminalSurfaceTests`:visualOffsetY `<cellHeight` 断言 :244/251/468、scrollFrame 构造 :1131-1312。
- `GhosttyVTBridgeTests`:overscan 计数/32 帽 :173-222(R1.0 已更新)。
- `SmoothScrollEngineTests`:resolve/rebase。

## 3. 分步实施(每步 build+test+guard 绿 + 明确手测验收)

### R1.1 — Metal 大纹理 + 平移模型(offset=0 逐像素不变)
改 A + B + D(Metal 侧)+ 对应 H 测试。**不解 clamp**(F 留给 R1.2),故仍是 ±1 行滚动,但纹理已含 overscan、composite 已能选 band、geometry 已与新平移同步。
- **验收(手测)**:静止显示、打字、±1 行慢滚 → 逐像素与现在一致;**滚动中选区拖拽、链接 hover、⌘点击 URL、IME 候选框位置全部正确**(命中测试红线)。
- 无可见丝滑提升(预期),纯为 R1.2 铺路 + 证明 geometry 同步无破坏。

### R1.2 — 解 clamp + display-link 多行平移(丝滑出现)
改 F(解 clamp)+ C(CG 镜像)+ 接回 display-link(需平台提 macOS 14)+ 引擎连续位置直接映射为 band 平移,overscan 缓冲深度内不做 VT 提交。
- **验收**:缓冲深度内滚动 60fps 丝滑、无抖动、无闪烁、无空白;命中测试在多行平移下仍正确。

### R1.3 — VT 提交懒惰化 / 缓冲重居中
可见 band 接近缓冲边缘时,后台提交行 + 重快照居中,用 `rebaseCommittedRows` 折抵。滚动无限(顺滑滚过整个 scrollback)。

### R1.4 — CG 后端对齐 + 惯性参数打磨到网页级。

## 4. 风险与回退
- 每步独立 commit,可 `git revert` 单步。
- R1.1 若命中测试错位 → 说明 geometry 与渲染平移未逐值对齐,回退该步重核 :2402。
- 平台提 macOS 14 在 R1.2(CADisplayLink 需要),与其理由同步。
- 全程 release bundle(`build-app-bundle.sh`)手测,避免 debug/旧 bundle 假象(见记忆)。

## 5. 已确认的决策
- **合并成一步**:R1.1+R1.2 合并——大纹理 + 平移模型 + 解 clamp + display-link + geometry 同步,一次做出可见丝滑。不拆纯地基。
- overscan 深度维持 **24 行**(VT 硬顶 32)。
- 全程 release bundle 手测;每完成一个可编译里程碑就 build+test+guard。
- 平台提 macOS 14(CADisplayLink),与本步同做。

## 6. R1.2 实现细节(display-link 多行平移,进行中)

**与失败 stage-2 的本质区别**:stage-2 每 tick 喂 `processScroll` → 每跨行同步提交 VT + clamp → 追不上抖动。R1.2 每 tick **直接设多行偏移**,缓冲深度内**不提交 VT**,仅接近边缘时提交整行 + `rebaseCommittedRows` 重居中。

**已完成前置**:clamp 解除;`canRenderPixelScroll` 改为按 overscan 深度边界判断(超出即拒,不画空白);纹理含 24 行 overscan + composite band(offset=0 逐像素一致,已验证)。

**tick 映射**:
1. `scrollWheel` 只喂 `SmoothScrollEngine`,启动 display-link。
2. 每 tick:`engine.tick()` → `position`(连续点数,可多行)。
3. `canRenderPixelScroll(position)` 真 → 直接 `viewport=TerminalViewport(visualOffsetY: position)`,不提交 VT。
4. 超出缓冲深度 → 提交整行拉回缓冲中部 + `rebaseCommittedRows` 折抵;geometry 用同一 `drawTranslationY` 自动同步。
5. 边缘 → reset 引擎 + 停 link;`!isActive` → 停 link。

**风险**:重居中那帧 offset rebase 与新内容须同帧(`suppressViewportChangePresent`)。

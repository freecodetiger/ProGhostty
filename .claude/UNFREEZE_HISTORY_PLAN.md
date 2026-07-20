# Plan: 去掉浏览历史时的输出冻结(pattern-2 tail-follow)

## 背景 / 根因

现在浏览历史时,新 PTY 输出到达 `PTYTerminalSurfaceRegistry.renderOutputImmediately`
(第 433-438 行)会因 `isViewingHistory == true` 直接 `return`——不渲染,画面定格。

这是 **pattern-1** 的设计:当时浏览靠移动 VT viewport + overscan 缓冲,新输出重渲染
会和进行中的像素滚动打架(两个时钟对不齐 = 抖动 bug)。冻结是用"不画"换稳定。

**pattern-2 不再需要它**:浏览位置是绝对行 `(topAbsoluteRow, P)`,和 VT viewport 解耦。
新输出只让 scrollback 在底部追加、`total` 变大,你锚定的 `topAbsoluteRow` 那几行内容不变。
每帧"按 topAbsoluteRow 从 scrollback 直接取那一屏"取的永远是锚定内容 → 天然稳定。

## 已核实的关键事实(读 Vendor/ghostty/src/terminal/PageList.zig)

- `scrollbar.total` = 当前缓冲总行数(`total_rows`),`offset` = viewport 在其中的偏移。
  **是相对当前缓冲的坐标系,不是历史累计。**
- 缓冲未满(`total < maxScrollback`,默认 10000):新输出只在底部追加,
  `browseTopRow` 指向的内容**不移位** → 去冻结后零锚点工作即正确。
- 缓冲已满触发 prune(第 3136 行):`total_rows` 先减去被删页的行数再增长,
  pin 型 viewport 的 offset 会相应减。即**淘汰会让相对行号整体前移**,
  且 `total` 在上限附近小幅震荡,无法靠 `total` 差值可靠反推淘汰行数。
- libghostty 自己用 **tracked pin** 解决(淘汰时自动更新),但我们的 C shim 未暴露。
- `scrollbar()` 文档注明"昂贵,勿频繁调用";当前每 tick(120Hz)调一次,是隐患(本计划顺带优化)。

## 方案(分两层,按用户选择"跟随更新")

### 第 1 层:去冻结 + 输出驱动重present 浏览窗口(核心,必做)

1. **`PTYGridView` 暴露浏览状态给 registry**:
   - 新增 `public var browseTopAbsoluteRow: UInt64?`(把现有 private `browseTopRow` 暴露只读),
     供 registry 判断"是否停在历史 + 停在哪一行"。

2. **`renderOutputImmediately` 改为不冻结**(第 433-438 行):
   - 当 `isViewingHistory` 且**正在拖动选区**(`isDraggingSelection`)时仍跳过——选区期间
     换内容会破坏选区语义(保留这条,和 pattern-1 一致)。
   - 否则不再 `return`:
     - 若 `browseTopAbsoluteRow != nil`(停在历史)→ 调 `presentBrowseWindow(topAbsoluteRow:)`
       重画浏览窗口(用新的 `total` 重取,内容锚定不变,底部新输出不影响可见行)。
     - 若在活跃手势/惯性中(display link 还在跑)→ 什么都不做,下一 tick 自然会用最新
       `total` 重present(tick 已每帧读 metrics)。
     - 若已跟随底部(`browseTopRow == nil`)→ 走原有 `render(snapshot)` 正常跟随。

3. **`presentBrowseWindow` 已具备重入能力**(它每次都用当前 `bridge.rows(at:)` 取),
   只需能被输出路径调用。加一个 registry 内部方法
   `repredentBrowseWindowIfViewingHistory(session:)` 供输出路径复用。

### 第 2 层:淘汰移位锚点修正(缓冲满 + 持续输出的边缘情况)

诚实评估:没有 tracked pin,做到像素级完美很难。两个可选精度:

- **(A) 先只做第 1 层**:缓冲未满(日常绝大多数)完全正确;缓冲满且持续输出时翻历史,
  内容可能偶发跳几行。失败模式温和(不崩不冻)。**建议先上,真机验证手感。**
- **(B) 加近似锚点**:在 shim 暴露一个单调递增的"累计产出行数"或用 libghostty tracked pin
  (需扩 C API + bridge)。工作量大,收益仅覆盖边缘场景。**留待第 1 层验证后再决定是否值得。**

本计划先实现 **(A)**。

## 顺带修的隐患(小、安全)

- `browseScrollMetricsHandler` 每 tick 调 `scrollbar()`(昂贵)。改为:tick 内复用上一次
  present 已知的 total,或降低调用频率。**本计划暂不动**(避免混入滚动手感回归),
  仅在注释里标记 TODO,单独处理。

## 测试

- 单测:`renderOutputImmediately` 在 `browseTopRow != nil` 且非拖选时,调用 present 浏览窗口
  而非冻结;在拖选时仍跳过;在跟随底部时正常 render。
- 单测:浏览停在历史,注入新输出(增大 total),可见的 top 行不变。
- 手测(真机):`seq 1 5000` 生成历史 → 翻到中间停住 → 底部持续 `ping`/`tail -f`,
  确认历史内容稳定 + 底部输出照常滚动 + 不冻结不跳(缓冲未满)。

## 验收

- 浏览历史时底部新输出照常渲染,不再定格。
- 停在历史的可见内容不随底部输出跳动(缓冲未满)。
- 选区拖动期间行为不变。
- 滚动丝滑度、跟手性、seq 秒出均不回归。
- 548 测试 + guard 全绿。

# Plan: 修复浏览锚点在输出洪流下卡死历史(cursor 消失 / 回不到底部)

## 症状
`seq 1 5000` 输出洪流时滚动,fling 惯性把浏览停在历史(如 top=1994),此后:
- 光标消失(历史窗口 `cursorVisible=false`,正确,但用户在底部看不到光标)。
- 滚动"恢复不了":新 gesture 也回不到真实底部。
- 切分屏才恢复(走了别的 render 路径重置状态)。

## 根因(读日志 + 代码核实)
`browseAnchorRow` 是 gesture 开始时抓的**绝对行号**,physics `position` 每次 gesture 从 0 积分,
`topAbsoluteRow = anchorRow - floor(position/cellH)`。

`seq` 输出让 `total` 从 ~2000 涨到 ~5000。但 anchor 停在历史(1949),要滚到真实底部
需要 `rowDelta ≈ -(5000-1949) = -3000` 行的向下位移——单次 gesture 的 `pos` 只有几百,
**物理上跨不过 anchor→底部的 3000 行鸿沟**。`maxTop = total - visible` 还每帧后退,
`topAbsoluteRow >= maxTop` 的"到底"判定永远不满足 → `browseTopRow` 永不清除 → 卡死历史。

本质:**绝对行锚点 + 从 0 积分的 position,在底部持续增长时无法表达"回到当前底部"。**
每个终端/浏览器的正确模型是:**滚动位置以"距活动底部的距离"度量**,回底部 = 距离归零,
无论涌入多少输出都可达。

## 方案:锚点改为"距底部距离",回底部鲁棒

保持 `SmoothScrollEngine`(纯物理,position/velocity 不变)和 resolver 的纯函数形态,
只改 **anchor 语义** 与 **回 follow 判定**:

### A. anchor 语义:距底部行数
- 新增 `browseDistanceFromBottom: CGFloat`(浏览时"顶行距活动底部多少行",随 position 变)。
  或等价地:每帧用**当前** `total` 重新计算,`maxTop = total - visible`,
  `topAbsoluteRow = maxTop - distanceRows`,其中 `distanceRows = position / cellH`(position>0 = 向上离底)。
- gesture 开始(从 follow 起):`position` 从 0 开始,`position=0 ⟺ 距底 0 ⟺ topAbsoluteRow=maxTop`(跟随底部)。
- gesture 开始(已在历史):用当前 `browseTopRow` 反算初始 `position`
  = `(maxTop_now - browseTopRow) * cellH`,保证连续。
- 这样向下滚(position→0)**永远能回到当前底部**,不管 total 涨多少。

### B. resolver 改造
`SmoothScrollBrowseResolver.resolve` 输入从 `anchorRow` 改为直接算距底:
- `distanceRows = floor(position / cellH)`(position>0 向上)
- `maxTop = max(0, total - visible)`
- `topAbsoluteRow = clamp(maxTop - distanceRows, 0, maxTop)`
- `atBottomEdge = (distanceRows <= 0)` → 即 position ≤ 0 就是到底(回 follow),稳健且与 total 无关。
- `atTopEdge = (maxTop - distanceRows <= 0)`
- pixelOffset 语义不变([0,cellH))。
- 纯函数,单测友好。

### C. 回 follow 判定
`applyBrowsePosition`:`browseTopRow = resolved.atBottomEdge ? nil : resolved.topAbsoluteRow`。
`atBottomEdge` 现在只看 `position <= 0`,和 total 解耦 → 向下滚必定能触发,卡死消除。

### D. 输出洪流时的锚点稳定(§6 tail-follow)
浏览停在历史时,新输出让 `total` 增大 → `maxTop` 增大 → 若 distanceRows 不变,
`topAbsoluteRow = maxTop - distanceRows` 会**增大**(向下移),内容会向上跑。
这不对——用户停在某段历史,应保持看同一内容。
解决:浏览停留期间(非跟随)锚定**绝对行**保持内容不变;只有跟随态(distance≈0)才追底部。
即:distance 是相对底部,但停留时要用"锚定绝对行"表达"不动"。

→ 结论:**两种状态用两种锚**:
- **following(browseTopRow==nil)**:distance-from-bottom 模型,回底部可达。
- **parked(browseTopRow!=nil)**:absolute-row 模型,内容不随 total 变。
- gesture 进行中:以 gesture 起点为参照积分,松手落定时决定进入 parked 还是 following。

这正是问题的完整解:**gesture 期间用"起点相对"积分,落定时若 position 回到/越过起点下方
(atBottomEdge, position≤0 相对起点)→ following;否则 parked 到某绝对行。**
起点相对 = 每次 gesture `anchorRow` 取**当前** `total-visible`(若 following)或 `browseTopRow`(若 parked)。

关键修正点:**following 态下每次 gesture 的 anchor 必须取当前实时 `maxTop`,而非陈旧值**,
且 `atBottomEdge` 判定用 `position <= 0`(相对本次 gesture anchor),与实时 total 无关。

## 实现步骤
1. resolver 增加/改造:暴露基于 `position ≤ 0 ⟹ atBottomEdge` 的判定(与 total 解耦),
   `topAbsoluteRow` 仍由 anchorRow - rowDelta 得出。**anchorRow 每次 gesture 正确取值是关键**。
2. `startSmoothScrollBrowsing`:following 态 anchor = 当前 `metrics.total - visibleRows`(实时底部),
   parked 态 anchor = `browseTopRow`。(现在错在 following 用 `metrics.topAbsoluteRow`,
   那是 offset 不是 maxTop,且没考虑 gesture 期间 total 增长。)
3. `applyBrowsePosition`:`atBottomEdge → browseTopRow=nil`(follow);否则 parked。
4. 单测:resolver 在 position≤0 恒 atBottomEdge;输出洪流(total 递增)下向下 gesture 能回 follow。
5. 手测:`seq 1 5000` 输出中 fling 上翻再下翻,必定能回底部看到光标 + 实时输出。

## 验收
- 输出洪流中任意上翻后,向下滚必定能回到底部(光标可见、跟随新输出)。
- 停在历史时内容稳定不随新输出跳。
- 不再出现 cursor 消失且无法恢复。
- 滚动丝滑、不冻结不回归。548 测试 + guard 全绿。

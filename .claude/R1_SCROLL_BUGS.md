# R1.2 滚动缺陷与修复记录

> display-link 多行 band 平移(R1.2)实测卡顿的根因分析与修复。
> 每条:症状 → 日志证据 → 根因 → 修复 → 状态。诊断探针见 `scrolltick gapMs/workMs/pos/committed`。

---

## BUG-1:present 未走异步,滚动期每帧同步等 GPU(18fps 主因)

- **症状**:display-link tick `gapMs≈54ms`(18fps),`workMs` 只有 0.02-1ms(代码不慢)。
- **日志证据**:`metalDirectWaited=true` 出现在所有滚动帧(waitReason: cursor-row-dirty / drawable-transient-overlays / texture-resize / first-frame)。本该被 `shouldWait = waitReason != "none" && !prefersAsyncPresent` 里的 `!prefersAsyncPresent` 跳过,却仍同步等。
- **根因**:`scrollActivityHandler` → `engine.prefersAsyncPresent = isScrolling` 的接线没生效(handler 未接通,或 `startScrollDisplayLink` 的 `scrollActivityHandler?(true)` 没到 backend)。每帧同步 `waitUntilCompleted` 阻塞主线程 runloop → display-link 掉到 18fps。
- **修复**:确保 `scrollActivityHandler` 在 backend 正确接线并在启停 display-link 时触发。
- **状态**:待修。

## BUG-2:大纹理在滚动中反复重分配

- **症状**:`metalDirectGPUWaitReason="texture-resize"` 反复出现;每次 resize 触发昂贵重分配 + 强制全重绘。
- **根因**:`renderTargetSize` 高度 = `(overscanTop + viewport + overscanBottom) * cellHeight`,而滚动/提交时 VT 快照的实际 overscan 行数每帧波动(接近边缘时不足 24)→ 纹理尺寸抖动 → 重分配。
- **修复**:纹理按**固定最大 overscan（`pixelScrollOverscanRows`=24）**分配,不随实际返回行数变。实际 overscan 少时,多出的纹理区域留空(composite 只采样有效 band)。尺寸稳定 → 无重分配。
- **状态**:待修。

## BUG-3:position 来回跳（重居中 rebase 与异步提交非原子，致命）

- **症状**:`pos` 在阈值附近反复横跳(242↔263),每次 `committed=true` 后 pos 回跳约一个字高的倍数;视觉剧烈抖动。
- **根因**:`applySmoothScrollPosition` 在 `|position| > safeDepth(0.5*buffer)` 时 `commitViewportScroll` + `rebaseCommittedRows`。但 `commitViewportScroll` 走**异步 vtQueue**（`viewportScrollHandler`），返回 true 只表示"已排队",VT 内容没立即滚动；`rebaseCommittedRows` 却立刻把 position 减回去。引擎下一 tick 继续推进 pos → 再超阈值 → 再 commit → 再 rebase……position 在阈值附近横跳,而内容因异步没跟上。即老 `PIXEL_SCROLL_JITTER_PLAN.md` 的 2b（offset/内容非原子）以更严重形式重现。
- **修复设计**:手势期间**不重居中**。24 行 overscan ≈ 一整屏,一次连续 fling 的位移几乎总在缓冲内。只有 position 真正触及缓冲边界（接近 `renderableDepth`，而非中点 0.5）才提交；提交后**冻结引擎推进**（不再 rebase-then-continue），等异步 `finishQueuedViewportScroll` 内容就位后再解冻。最简起步:阈值从 0.5 提到接近满（如 0.9），先验证低频提交下是否丝滑,再做正确的异步同步。
- **状态**:待修。

---

## 修复顺序
1. BUG-1（present 异步接线）— 单独就能把 18fps→60fps,先验证节拍。
2. BUG-2（纹理固定尺寸）— 消除 resize 抖动。
3. BUG-3（不重居中 / 边界才提交）— 消除 position 横跳。
每步 build+test+guard + release bundle 手测（按 CLAUDE.md 运行前必做清单）。

---

## BUG-3 更深根因（补充,阅码发现）

`finishQueuedViewportScroll`（异步提交回来）末尾调用 `resetViewportStartRowKeepingVisualOffset()`,它把 `viewport.visualOffsetY` 重置为 `scrollController.pixelRemainderY`（≈0，因为 display-link 路径根本不走 scrollController）。而 display-link tick 每帧把 `viewport.visualOffsetY` 设为 `engine.position`。**两个写者抢同一个 `viewport.visualOffsetY`**：tick 设成大值 → 异步提交回来重置成 ≈0 → 下一 tick 又设大值……这才是 position 横跳的真正机制（比"rebase 时序"更根本）。

**含义**：display-link 路径与旧的异步 commit+reset 路径（为事件驱动设计）不能共用 `viewport.visualOffsetY`。R1.2 的提交必须要么走一条不 reset offset 的新路径,要么在提交在途期间让 tick 停止写 offset。

## BUG-1 复核（补充）

texture-resize（BUG-2）本身在滚动中反复触发昂贵 GPU 重分配,即使 `prefersAsyncPresent=true` 也会拖慢 → 先修 BUG-2 可能顺带缓解 BUG-1 的部分 54ms。BUG-2 已修（纹理固定尺寸）后需重测 gapMs 是否回落。


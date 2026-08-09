# Spec: TUI 滚轮输入路由

> **分支：** `fix/tui-scroll-input-plan`
>
> **状态：** Implemented
>
> **日期：** 2026-08-09

## 1. 问题定义

ProGhostty 当前无法在 Vim 等全屏 TUI 中使用滚轮。问题不在 PTY 或 job
control：`forkpty` 已建立 controlling terminal，shell 启动 Vim 后也会把它设为
PTY 前台进程组，因此键盘字节能够正常到达 Vim。

真正缺失的是 GUI 鼠标输入到终端字节的转换。AppKit 始终把 `NSEvent` 滚轮事件
交给终端视图；终端模拟器需要根据当前 VT 模式，把事件编码成鼠标协议或方向键序列，
再写入 PTY。

当前 alternate screen 分支没有完成这个转换：

```swift
if let frame = frameSnapshot, frame.isAlternateScreen {
  super.scrollWheel(with: event)
  return
}
```

`NSView.super.scrollWheel` 只继续 AppKit 响应链，不会调用 `inputHandler`，也不会
生成任何 PTY 字节。因此代码注释所称的“forward wheel events to the PTY”并未发生。

这段分支由提交 `ac2a23a` 在移除 Pattern-1 滚动路径时引入。该重构暴露了一个更早
就存在的能力缺口：ProGhostty 能查询子进程是否开启了 mouse reporting，却不能编码
和转发鼠标输入。

## 2. 目标

1. 让 Vim、Neovim、less、tmux、fzf、htop 等终端程序能够接收纵向滚轮输入。
2. 对齐 Ghostty 的显式鼠标报告与 DEC alternate scroll 路由规则。
3. 保持 primary screen 上现有 Pattern-2 平滑历史滚动不变。
4. 继续以 libghostty-vt 作为屏幕与终端模式的唯一真相源。
5. 使用 libghostty-vt mouse encoder，不在 Swift 中拼接鼠标协议或 VT 序列。
6. 把输入量化和路由逻辑设计成可单测组件，测试不依赖真实 `NSEvent`。

## 3. 非目标

- 本次不实现鼠标按下、释放、移动和拖拽的完整转发。新增的 encoder 基础设施应能被
  后续完整鼠标支持复用。
- 不新增 mouse reporting、滚动倍率或 Shift override 设置。
- 不修改普通 scrollback 的 Pattern-2 物理模型和渲染路径。
- 不修改 vendored Ghostty 源码。
- 不实现本地横向 scrollback；横向 wheel report 留到完整鼠标支持阶段。

## 4. Ghostty 源码调研

### 4.1 AppKit 只负责输入归一化

Ghostty 的 `SurfaceView_AppKit.scrollWheel` 读取：

- `scrollingDeltaX/Y`
- `hasPreciseScrollingDeltas`
- `momentumPhase`

精确滚动设备的 delta 在 macOS 层乘以 2，然后交给 core surface。AppKit 层不判断
事件应归 TUI 还是本地 scrollback。

源码：
`Vendor/ghostty/macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift`

### 4.2 Core surface 负责量化 delta

`Surface.scrollCallback` 把原始 delta 转成整数滚动单位：

- 精确设备：累积像素 delta，达到一个 cell height 后产生滚动单位。
- 离散滚轮：macOS 上把非零小数归一到绝对值至少为 1，再应用默认倍率 3。
- 不足一个 cell 的余数保存在 `mouse.pending_scroll_y`。

当前 Ghostty 会传递 momentum 类型，但 `Surface.scrollCallback` 没有单独解释它；
momentum 事件的 delta 仍进入同一个累加器。

源码：`Vendor/ghostty/src/Surface.zig` 的 `scrollCallback`。

### 4.3 Core surface 的路由顺序

Ghostty 完成量化后按以下顺序处理：

1. **alternate screen + 没有显式 mouse tracking + DEC 1007 开启**：
   转换成上/下方向键。DECCKM 开启时使用 `ESC O A/B`，否则使用 `ESC [ A/B`。
2. **存在任意显式 mouse tracking mode**：把纵向滚动编码为当前位置的 mouse
   button 4/5。输出格式由当前 X10、UTF-8、SGR、URxvt 或 SGR-Pixels 模式决定。
3. **其他情况**：滚动终端模拟器自己的 scrollback viewport。

这个顺序很重要：mouse tracking 即使在 primary screen 也优先于本地 scrollback；
1007 只是在 alternate screen 且没有显式 mouse tracking 时的回退。

源码：`Vendor/ghostty/src/Surface.zig:3507-3573`。

### 4.4 Mouse encoder

Ghostty 从 terminal 与 renderer size 构建 `input.mouse_encode.Options`，再编码标准化的
鼠标事件。libghostty-vt C API 已公开同一套能力：

- `ghostty_mouse_encoder_new`
- `ghostty_mouse_encoder_setopt_from_terminal`
- `ghostty_mouse_encoder_setopt(...SIZE...)`
- `ghostty_mouse_event_new` 与各 event setter
- `ghostty_mouse_encoder_encode`

encoder 已负责 tracking mode 过滤、协议格式、坐标、modifier 和 wheel button code。
ProGhostty 应通过现有 C shim 使用这些 API，而不是重复协议实现。

源码：`Vendor/ghostty/src/input/mouse_encode.zig`、
`Vendor/ghostty/include/ghostty/vt/mouse/`。

## 5. ProGhostty 现状

| 能力 | 位置 | 状态 |
|---|---|---|
| alternate screen 快照 | `GhosttyTerminalFrame.isAlternateScreen` | 已有 |
| mouse mode 查询 | `GhosttyVTBridge.isMouseReportingActive()` | 不完整 |
| View 到 session 输入 | `PTYGridView.inputHandler` | 已有 |
| PTY 写入与前台进程路由 | `PTYTerminalSessionManager.writeInput` | 已有 |
| cell size 与 content inset | `PTYGridView` | 已有 |
| 事件指针位置 | `NSEvent.locationInWindow` | 已有 |

当前 `isMouseReportingActive()` 逐个检查 1000、1002、1003，漏掉 X10 mode 9。
libghostty-vt 已提供 `GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING`，它覆盖 X10，应该替换
现有手工查询。

现有 `mouseReportingActiveHandler` 只用于禁止 click-to-position。即使 TUI 已开启
mouse reporting，`mouseDown`、`mouseDragged`、`mouseUp` 仍执行本地文本选择逻辑。
这是相关但独立的问题，本方案先修滚轮。

## 6. 修改方案

### 6.1 由 VT 状态决定滚动所有权

不能只依赖可能滞后的 `frameSnapshot.isAlternateScreen`。每次滚动开始处理时，通过
Bridge 查询当前 VT 状态并分类：

```swift
public enum TerminalScrollOwnership: Sendable, Equatable {
  case localScrollback
  case mouseReporting
  case alternateCursorKeys(applicationMode: Bool)
  case consumed
}
```

- `.mouseReporting`：任意 tracking mode 激活，不区分 primary/alternate screen。
- `.alternateCursorKeys`：alternate screen、没有 tracking、mode 1007 开启。
- `.consumed`：alternate screen 且 mode 1007 关闭；alternate screen 没有可浏览的
  本地 scrollback，不应误入 Pattern-2。
- `.localScrollback`：primary screen 且没有 mouse tracking。

C shim 在一次调用中读取 active screen、
`GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING`、mode 1007 和 DECCKM。Swift 只消费结果，
不从输出字节或进程名推断状态。

### 6.2 Surface 层量化器

新增纯值类型 `TerminalTUIScrollQuantizer`，由 `PTYGridView` 持有。它只存储尚未达到
一个滚动单位的 X/Y 余数。这属于输入设备状态，不属于 VT 状态，因此不能放入
`GhosttyVTBridge`。

v1 行为：

- 精确 delta 应用 Ghostty macOS 的 2 倍系数，每累计一个 cell height 产生一个单位。
- 离散 delta 的绝对值至少归一为 1，再应用 Ghostty 默认倍率 3。
- 同一 TUI ownership 下保留正负余数，允许反向滚动抵消。
- 切回 local scrollback、surface detach 或 pixel-scroll reset 时清空余数。
- TUI 路由接收系统 momentum delta；本地 Pattern-2 保持现有自合成惯性策略。

低于阈值、暂时没有产生整数单位的 TUI 事件仍必须被消费，否则碎片 delta 会错误进入
本地历史滚动。

### 6.3 Bridge 编码接口

C shim 增加标准化鼠标事件与 geometry 类型，并新增：

```c
int proghostty_vt_encode_mouse(
  ProGhosttyVT *vt,
  const ProGhosttyVTMouseEvent *event,
  const ProGhosttyVTMouseGeometry *geometry,
  uint8_t **out,
  size_t *out_len);

int proghostty_vt_encode_alternate_scroll(
  ProGhosttyVT *vt,
  int direction,
  size_t count,
  uint8_t **out,
  size_t *out_len);
```

wheel unit 的 mouse event 包含：

- action：press
- button：wheel up / wheel down
- modifiers：Shift、Alt/Option、Control
- position：转换为左上角原点的 surface 坐标
- geometry：screen、cell 与 padding 尺寸

`proghostty_vt_encode_mouse` 创建并配置 libghostty-vt encoder，调用
`ghostty_mouse_encoder_setopt_from_terminal`，再返回编码后的 owned bytes。成功但长度为
0 表示当前 tracking mode 按协议过滤了该事件。

`proghostty_vt_encode_alternate_scroll` 在 Bridge 边界内读取 1007 与 DECCKM，并生成
固定方向键序列。这样 Swift/UI 层不会拼接 VT 字节，也不会在查询与编码之间自行保存
终端模式。

两个函数都复用现有 `proghostty_vt_free_bytes` 所定义的内存所有权。

第一版每次调用创建 encoder，优先保证实现简单。只有性能测量证明确有分配热点时，才把
encoder 缓存在 `ProGhosttyVT` 并在每次编码前刷新 terminal/geometry option。

cell 协议只要求坐标与 geometry 单位一致；SGR-Pixels 则要求真实像素。v1 应同时把
position、screen、cell、padding 乘以 window backing scale，避免 Retina 下
SGR-Pixels 坐标错误。

### 6.4 UI 到 PTY 的完整路径

```text
NSEvent.scrollWheel
  -> Registry / Bridge 查询 TerminalScrollOwnership
  -> localScrollback: 现有 feedSmoothScroll(event)
  -> TUI owned: TerminalTUIScrollQuantizer
       -> mouseReporting: Bridge 编码 button 4/5
       -> alternateCursorKeys: Bridge 编码 DECCKM-aware 方向键
       -> consumed / 未达阈值: 不产生字节但消费事件
  -> inputHandler(Data)
  -> PTYTerminalSessionManager.writeInput
  -> PTY 前台进程组读取字节
```

`PTYGridView` 只持有专用 handler，不直接访问 `GhosttyVTBridge`。Registry 继续作为
renderer view、VT bridge 与 session input callback 之间的适配层。

Bridge 编码方法会在锁内重新验证当前模式。若 ownership 查询后模式恰好切换，本次事件
仍按 TUI 输入消费，不得回落到 local scrollback；下一事件再使用新 ownership。

## 7. 文件级改动

### `Sources/ProGhosttyGhosttyVT/include/ProGhosttyGhosttyVT.h`

- 增加 scroll ownership、mouse event、mouse geometry 类型。
- 增加 ownership 查询、mouse encode、alternate-scroll encode API。

### `Sources/ProGhosttyGhosttyVT/ProGhosttyGhosttyVT.c`

- 用 `GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING` 替换不完整的逐 mode 查询。
- 读取 active screen、1007、DECCKM 并返回 ownership。
- 把标准化事件适配到 libghostty-vt mouse event/encoder API。
- 在 Bridge 边界生成 DECCKM-aware alternate-scroll 序列。
- 沿用 paste encoder 的错误与内存管理方式。

### `GhosttyVTBridge.swift`

- 增加 ownership、event、geometry 的 Swift 值类型。
- 增加 locked `scrollOwnership()`、`encodedMouseEvent(...)`、
  `encodedAlternateScroll(...)`。
- 为编码失败扩展 `BridgeError`。

### `PTYTerminalEngine.swift`（`PTYGridView`）

- 增加 `terminalScrollOwnershipHandler`、`terminalMouseEncodeHandler`、
  `terminalAlternateScrollEncodeHandler`。
- 增加 `TerminalTUIScrollQuantizer` 状态。
- 重写 `scrollWheel(with:)`：先按 ownership 路由，再决定是否进入 Pattern-2。
- 把 pointer position 转为左上角原点和 backing pixels。
- 使用现有 `inputHandler` 发送编码字节。
- 在 detach、reset 等生命周期点清理量化器。
- 修正“已转发到 TUI”但实际未转发的 diagnostics 文案。

### `PTYTerminalSurfaceRegistry.swift`

- 把三个 handler 接到对应 session 的 Bridge。
- 保持 UI/renderer 类型不直接依赖 Bridge 或 C API。

### 新增测试文件

- `TerminalTUIScrollQuantizerTests.swift`：纯量化逻辑。
- mouse encoder 与 ownership 测试优先放入现有 `GhosttyVTBridgeTests.swift`。
- view 路由测试放入现有 `TerminalSurfaceTests.swift`。

## 8. 测试方案

### C shim / Bridge

1. `?9h` 能被识别为 mouse tracking，覆盖现有遗漏。
2. `?1002h` + `?1006h` 把上/下滚轮编码为 SGR button 64/65，cell 坐标从 1 开始。
3. X10 tracking 对不支持的 wheel event 返回空输出，而不是错误回落到本地滚动。
4. `?1015h`、`?1016h` 分别使用 URxvt 与 SGR-Pixels 格式。
5. primary screen 关闭 tracking 后 ownership 恢复为 local scrollback。
6. alternate screen + 无 tracking + 1007 开启返回 cursor-key ownership。
7. alternate screen 下 `?1007l` 返回 consumed。
8. DECCKM 开关分别产生 normal/application cursor 序列。

### 纯 Swift 量化器

1. 精确 delta 累积到一个 cell height 才产生单位。
2. 正负余数可保留并互相抵消。
3. 离散 macOS 小数归一后产生默认 3 个单位。
4. ownership 改变时清空 pending remainder。
5. TUI 路由接收 momentum delta。

### View 路由

1. primary screen 且无 tracking 仍进入 Pattern-2。
2. primary screen 有 tracking 时写 mouse bytes，不浏览历史。
3. alternate screen 有 tracking 时写 mouse bytes。
4. alternate screen 无 tracking 时写方向键。
5. 未达阈值的 TUI 精确输入被消费，不触发本地滚动。
6. encoder 失败时不回落到 local scrollback。

### 手动验证矩阵

| 程序 | 场景 | 预期 |
|---|---|---|
| Vim/Neovim，mouse 开启 | 滚轮、触控板 | TUI 在指针位置滚动 |
| Vim，mouse 关闭 | alternate-scroll fallback | 通过方向键移动光标/视口 |
| `less` | 滚轮、触控板 | 内容滚动 |
| tmux mouse mode | pane 内滚动 | tmux 收到 mouse report |
| shell primary screen | 滚轮、触控板 | ProGhostty 历史滚动保持平滑 |
| alternate app + `?1007l` | 滚轮 | 不移动 primary history |

需要同时验证 AppKit cell-grid 与 Metal-direct renderer。两者共享 `PTYGridView`，但
frame geometry 和 backing scale 可能不同。

## 9. 实施阶段

### Phase 1：VT 状态与 encoder

1. 增加 C shim ownership 查询，修正 X10 mouse tracking 遗漏。
2. 接入 libghostty-vt mouse encoder。
3. 在 Bridge 边界实现 alternate-scroll 编码。
4. 添加 mode、format、coordinate、DECCKM 测试。

### Phase 2：纯输入逻辑

1. 新增 AppKit-free `TerminalTUIScrollQuantizer`。
2. 覆盖 precision、discrete、direction、remainder、reset 测试。

### Phase 3：View 集成

1. 接入 Registry handler。
2. 用 ownership 路由替换 `super.scrollWheel` alternate-screen 分支。
3. 增加 view 路由与 diagnostics 测试。

### Phase 4：验证

1. 运行完整 `swift test` 与架构检查。
2. 使用触控板和离散鼠标执行手动验证矩阵。
3. 确认 normal scrollback 的性能、惯性和平滑度没有变化。

## 10. 风险与决策

- **模式切换竞态：** Bridge 编码时必须在锁内重新读取 terminal mode；若模式已切换，
  消费当前事件，下一事件重新路由，不能错误进入本地历史。
- **输出与 UI 并发：** 所有 mode 查询与 encoder 配置都放在
  `GhosttyVTBridge.locked` 内，延续现有访问模型。
- **高频事件分配：** v1 不预先缓存 encoder；先测量再优化。
- **陈旧 frame：** ownership 使用实时 VT 状态而不是 `frameSnapshot`，避免输出已进入
  TUI 但 renderer 尚未呈现时滚动 primary history。
- **完整鼠标所有权仍未实现：** 本方案刻意先解决滚动；press/release/motion 使用同一
  normalized event 与 encoder 基础设施另行实现。

## 11. 验收标准

1. Vim/Neovim 开启 mouse reporting 后可使用纵向滚轮和触控板滚动。
2. 没有显式 mouse reporting 时，alternate-scroll fallback 正常且遵守 DECCKM。
3. primary screen 上的 mouse tracking 优先于本地 scrollback。
4. 普通 shell 的 Pattern-2 平滑历史滚动行为不变。
5. Swift/UI 层不新增 ANSI/VT 解析或协议序列拼接。
6. 自动测试覆盖 ownership、协议编码、delta 量化与 view 路由。

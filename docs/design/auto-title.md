# 自动标题（Auto Title）设计方案

> 分支：`feat/auto-title` · 状态：待实施（Phase 1）
> 本文是开发依据。规则与代码冲突时以代码为准，并回改本文。

---

## 1. 概述

### 目标

pane 标题从"只能手动改名"升级为"默认自动、手动覆盖"：终端里运行的程序（vim、ssh、Claude Code 等）通过 OSC 0/1/2 上报的标题，自动显示在标题栏左侧模块；用户手动命名后自动标题不再覆盖。

对齐产品定位：分屏跑多个 AI CLI 时，扫一眼标题栏即可知道每个 agent 在干什么（Claude Code 会随任务实时更新 OSC 标题）。

### 非目标（Phase 1 明确不做）

- ❌ 工作区切换器里显示各 pane 自动标题（Phase 2）
- ❌ 前台进程名兜底标题（Phase 2）
- ❌ AI 生成语义化标题（Phase 3）
- ❌ pane 本体加标题条 / 任何新增 chrome
- ❌ 改动中间 cwd 模块、右侧工作区模块的任何行为

---

## 2. 产品形态

标题栏三个模块的位置与交互**全部不变**，唯一变化是左侧模块多一个自动数据源：

| 模块 | 现状 | Phase 1 之后 |
|---|---|---|
| 左（红绿灯右侧） | 手动 label，没设则隐藏 | **三态**：手动名 > 程序上报标题 > 隐藏 |
| 中（居中） | cwd 目录名（`📁 xxx`） | 不变（已承担"目录兜底"角色） |
| 右 | toast + 工作区名按钮 | 不变 |

左侧模块三态规则：

1. **手动名**（`pane.label != nil`）：显示手动名，样式不变，自动标题永不覆盖。
2. **自动标题**（无手动名、会话有上报标题）：显示上报标题，用**弱化样式**（`secondaryLabelColor` 同当前，前缀 `✳` 不加——保持上报原文），与手动名视觉可区分（见 §4.6）。
3. **隐藏**（两者皆无）：与现状一致，不重复中间的目录名。

交互：点击左侧模块 → `startRenamePane()`（现状不变）。改名后锁定；把名字清空即回到自动态。

用户故事：开 pane → 左模块隐藏；跑 `claude` → Claude Code 每换任务改一次标题，左模块实时跟随；退出回到 shell → 提示符触发 OSC 7，自动标题清除、模块隐藏；手动命名"发布构建机" → 之后无论程序报什么都显示手动名。

---

## 3. 现状事实（已读代码核实，2026-07）

| 事实 | 位置 |
|---|---|
| PTY 层已解析 OSC 0/1/2 并发 `.titleChanged(session:title:)` | `PTYTerminalEngine.swift:671-676` |
| **App 层未消费该事件**（落入 `default: break`）——功能缺口所在 | `AppModel.handle(_:)` `AppModel.swift:1464` |
| `TerminalPane` 有 `title`（建 pane 时由 cwd 推导）与 `label`（手动名，可持久化） | `TerminalLayout.swift:12-18` |
| 左侧模块数据源 `activePaneLabel` → `paneWorkspaceController.paneLabel(...)` | `AppModel.swift:486-489` |
| 中间模块数据源 `activePaneTitlebarLabel`（cwd 推导） | `AppModel.swift:491-494` |
| 左模块渲染：`paneLabelLabel`，空则隐藏；点击 → `startRenamePane` | `WorkspaceTitlebarView.swift:176-185, 354+` |
| 会话级运行时状态先例：`WorkspaceRuntime.cwdBySession`（不落盘） | `AppModel.swift:13-16` |
| 布局持久化路径：`persistWorkspaceRuntime` → `workspace.layoutSnapshot` | `AppModel.swift:325-337` |
| 设置模型：`AppSettings`（Codable，Core 层） | `Settings/AppSettings.swift` |
| ⚠️ 现存 bug：`parameters.last` 会把含 `;` 的标题截断（`OSC 0;build;deploy` → 只剩 `deploy`）；空标题 `OSC 0;` 会发出空串事件 | `PTYTerminalEngine.swift:673`、`OscParser.swift:96-101` |

架构约束（来自 CLAUDE.md，本设计全部遵守）：不在 VT 层外新增 ANSI 解析（复用引擎既有 OSC 事件路径）；App 层只依赖 Core 协议 + 值类型；不引入重复终端状态。

---

## 4. 设计

### 4.1 状态归属：运行时字典，不落盘

新增状态**只有一处**：

```swift
// AppModel.WorkspaceRuntime
var reportedTitleBySession: [TerminalSessionID: String] = [:]
```

决策与理由：

- **照抄 `cwdBySession` 先例**：会话级、运行时、App 层展示状态。
- **不放进 `TerminalPane`**：`TerminalPane` 是 Codable 且随 `layoutSnapshot` 落盘；上报标题描述的是"正在运行的程序"，重启后程序已不在，持久化必然产生脏数据，还要为排除编码写 CodingKeys 样板。
- **不改 `PaneWorkspaceController`**：Phase 1 标题只在标题栏展示、不进布局树，控制器无需感知。Phase 2 若切换器需要按 pane 展示，用 `leaf.sessionId` join 此字典即可，仍不需要控制器持有。
- 该状态不是终端状态的复制——`libghostty-vt` 不维护"上报标题"这一概念，唯一真相源不受影响；事件源头仍是 PTY 层唯一的 OSC 解析点。

### 4.2 事件流

```
程序输出 OSC 0/1/2
  → PTYTerminalEngine.handleOutput（既有解析点，修 §4.3 的 bug）
  → TerminalEvent.titleChanged(session:title:)（既有事件）
  → AppModel.handle 新增 case（本设计新增）
      ├─ 设置关闭 → 忽略
      ├─ sanitize（§4.4）
      ├─ 与现值相同 → 忽略（防抖第一道，见 §4.7）
      ├─ 空串 → 从字典移除（标准"重置标题"语义）
      └─ 写入 reportedTitleBySession + objectWillChange.send()
  → RootView 传参 → WorkspaceTitlebarView 左模块（§4.6）
```

### 4.3 引擎侧修正（顺手修，不扩权）

`PTYTerminalEngine.swift:673` 的标题提取改为：

```swift
let title = sequence.parameters.joined(separator: ";")
```

修复含分号标题被截断的问题（`OscSequence` 以 `;` 分段是通用行为，标题正文本身可含 `;`）。空标题（`OSC 0;`）继续发事件、载荷为空串，由 App 层解释为"清除"。**引擎不做任何策略过滤**（设置开关、去重都在 App 层），保持 PTY 层无策略。

### 4.4 清洗规则（纯函数）

新增 `AutoTitleSanitizer`（纯值逻辑，放 `ProGhosttyApp/UI/`，与 `TitleFormatting` 同级）：

```swift
enum AutoTitleSanitizer {
  /// 返回 nil 表示"应清除"（空或全不可见字符）。
  static func sanitize(_ raw: String) -> String?
}
```

规则：

1. 去除 C0/C1 控制字符（防转义注入标题栏）。
2. trim 首尾空白。
3. 结果为空 → 返回 nil（= 清除）。
4. 超长截断：> 256 字符时中截（存储上限；显示层另有 `byTruncatingMiddle` + 宽度约束兜底）。

### 4.5 生命周期

| 时机 | 行为 | 理由 |
|---|---|---|
| 收到 OSC 0/1/2 | 设置/清除（§4.2） | 核心路径 |
| 收到 OSC 7（`.cwdChanged`） | **清除该会话的上报标题** | 提示符出现 ⇒ 前台程序已退出，避免"vim 残留"。shell 集成每次 prompt 发 OSC 7，是现成的"回到 shell"信号。无 shell 集成的用户标题会残留——与 iTerm2 等一致，可接受 |
| 会话关闭（pane 关闭路径） | 从字典移除 | 防泄漏 |
| App 重启 | 天然为空（不落盘） | §4.1 |

注意顺序：`.cwdChanged` 分支里先做现有 cwd 更新，再清标题。Claude Code 运行期间 shell 不产生提示符、不会误清；它自己连续上报的标题互相覆盖即可。

### 4.6 UI 变更

`WorkspaceTitlebarView` 增加一个入参 `paneAutoTitle: String?`（与 `paneLabel` 并列，Coordinator 同步存储）。左模块取值：

```swift
displayText = paneLabel ?? paneAutoTitle   // 都为 nil → 隐藏（现状）
```

样式区分（都在现有 `paneLabelLabel` 上切换，不加新视图）：

- 手动名：现状样式（medium、`contentTintColor`）。
- 自动标题：同字号，`secondaryLabelColor` 系（与 `usesDarkAppearance` 配套取弱一档的灰），`toolTip` 显示完整标题。

`AppModel` 增加：

```swift
var activePaneAutoTitle: String? {
  guard settings.programTitleReportingEnabled,
        let session = selectedSessionID else { return nil }
  return activeRuntime?.reportedTitleBySession[session]
}
```

`RootView` 把它接进 `WorkspaceTitlebarView`。焦点 pane 切换时（`selectedPaneID` 变化）SwiftUI 已重算该链路，无需额外接线。

### 4.7 性能

- 标题事件低频（Claude Code 任务级、vim 打开文件时），但需防御恶意/异常高频上报：**同值跳过**（§4.2）为第一道；若实测仍有 spam（如 spinner 动画逐帧改标题），在 AppModel 加 150ms trailing debounce——Phase 1 先不加，观察后决定。
- 路径上无每帧工作、无分配热点；不触碰 render loop。

### 4.8 设置项

`AppSettings` 增加：

```swift
public var programTitleReportingEnabled: Bool   // default true
```

- 解码需向后兼容（旧配置文件无此字段 → true），按 `AppSettings.swift` 现有新增字段模式处理，补 `AppSettingsTests` 用例。
- `SettingsView` 增加开关，文案："允许程序设置标题"（终端页，参考 iTerm2/Ghostty 同名能力）。
- 关闭时：`activePaneAutoTitle` 返回 nil（显示层退化为现状）；事件仍写入字典（保持数据热备，开关打开立即生效）。**采信显示层 gate 而非入口 gate**，避免开关切换时状态不一致。

---

## 5. 实施步骤（按 commit 粒度）

1. `fix(pty): join OSC title parameters so titles containing ';' survive`
   引擎 §4.3 + `PTYTerminalEngine` 相关测试（含 `OSC 0;a;b`、`OSC 2;`、UTF-8 标题）。
2. `feat(settings): add programTitleReportingEnabled (default on)`
   AppSettings 字段 + 兼容解码 + `AppSettingsTests` + SettingsView 开关。
3. `feat(app): track reported titles per session`
   `WorkspaceRuntime.reportedTitleBySession`、`AutoTitleSanitizer` + 测试、`AppModel.handle` 的 `.titleChanged` / `.cwdChanged` 清除逻辑、会话关闭清理。
4. `feat(ui): show auto title in titlebar pane module`
   `activePaneAutoTitle`、`WorkspaceTitlebarView` 入参与样式、RootView 接线。
5. 全绿收工：`swift build` + `swift test` + `scripts/check-architecture.sh`。

每步独立可绿、可回滚；1、2 与 3、4 无耦合，可并行。

---

## 6. 测试计划（swift-testing）

| 层 | 用例 |
|---|---|
| `AutoTitleSanitizerTests`（新） | 控制字符剥离 / trim / 空→nil / 超长中截 / 中文与 emoji 宽字符不截坏 |
| `PTYTerminalEngine`（补） | `OSC 0;a;b` → `"a;b"`；`OSC 2;` → 空串事件；BEL 与 ST 两种终止符 |
| `AppSettingsTests`（补） | 缺字段解码 → 默认 true；roundtrip |
| AppModel 侧 | 优先级（label 覆盖 auto）、cwdChanged 清除、会话关闭清理——若 AppModel 难以直测，将 §4.2 的决策部分提为纯 reducer 后测 reducer |

## 7. 手测验收清单

按 CLAUDE.md 标准流程打包启动（`build-app-bundle.sh release` + 杀旧进程），逐条验证：

```bash
printf '\033]0;你好;世界\007'    # 左模块出现"你好;世界"（分号完整）
printf '\033]2;Hello ST\033\\'  # ST 终止符同样生效
printf '\033]0;\007'            # 标题清除，模块隐藏
```

- [ ] `vim foo.txt` → 标题变化；`:q` 回 shell → 提示符后标题清除
- [ ] 运行 `claude` 跑一个任务 → 标题随任务实时更新；退出后清除
- [ ] 手动改名 → 上述任何操作不再改变显示；清空手动名 → 恢复自动
- [ ] 设置关闭开关 → 左模块行为完全回到现状；重开 → 立即恢复
- [ ] 重启 App → 无残留自动标题；手动名正常恢复
- [ ] 分屏两个 pane 各自跑程序 → 焦点切换时左模块跟随正确会话

## 8. 风险与后续

| 风险 | 缓解 |
|---|---|
| 无 shell 集成用户标题残留（退出 vim 后仍显示） | 与主流终端一致；Phase 2 用前台进程探测兜底 |
| 高频上报导致 UI 抖动 | 同值跳过已挡大半；预留 debounce 方案（§4.7） |
| 上报标题内容不可信（转义/超长/伪装 UI 文案） | Sanitizer 强制过控制字符与长度；显示层截断 |

Phase 2（另立方案）：工作区切换器每行显示 pane 自动标题摘要；前台进程名兜底。Phase 3：AI 语义标题。

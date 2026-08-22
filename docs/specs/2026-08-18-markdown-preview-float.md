# Spec: Markdown Preview Float（Markdown 预览浮层）

> **分支:** `feat/markdown-preview`
> **状态:** Implemented（Phase 1–5 已落地，见 §9 实现记录）
> **日期:** 2026-08-18

---

## 1. 动机（Motivation）

ProGhostty 面向开发者 / AI CLI（Codex / Claude Code）用户。这类工作流里 markdown 无处不在：README、PR 描述、AI 输出的文档、`*.md` 源码。用户需要一个**呼之即来**的只读预览，快速审查渲染后的 markdown 文档——像 macOS 的 Spotlight 一样即时，同时**不打断当前终端输入**。

核心诉求是"审查"而非"编辑"：预览浮层是只读的，用来扫一眼渲染结果、滚动、复制；编辑仍留在 vim / 编辑器里。

### 形态理念

- **呼出方式**：点击终端里的 `.md` 文件名 / 完整路径 / 相对路径，浮层即时出现。
- **退出方式**：双击浮层内部空白处（非文本区）。
- **焦点模型**：浮层**永不抢占焦点**——焦点始终在终端；用户可以点击不同 panel、继续键入。
- **行为模型**：浮空 ↔ 吸附（磁吸）两态。拖到某个 panel 区域可吸附并扩展填充该 panel；浮空时自由拖动、位置/宽高可调、不得超出窗口。

---

## 2. 目标（Goals）

1. 点击 `.md` token 即时呼出渲染后的预览浮层（支持文件名 / 绝对路径 / 相对路径三种 token）。
2. 浮层内可滚动浏览、可选中文本并复制；**只读，不支持编辑**。
3. 浮层**不抢焦点**：焦点永远在终端，跨 panel 键入不受影响。
4. 浮层初始位置自适应，**不遮挡当前 panel 的底部输入区域**。
5. 浮层可手动拖动位置、调整宽高；位置钳制在 ProGhostty 窗口内容区域内。
6. 磁吸：拖到 panel 区域吸附并扩展填充该 panel，跟随 layout 变化；拖离回到浮空态。
7. 不违反项目核心原则（见 §6）。

---

## 3. 非目标（Non-Goals）

- **不支持编辑 / 保存 / 双向同步**：预览只读。编辑交给终端里的 vim 等。
- **不做终端流内 markdown 渲染**（如 Ghostty 上游的富文本 in-stream 方案）：本 spec 是独立预览容器，不改渲染管线。
- **不用 WKWebView 作为渲染表面**：焦点约束把它否了（WebKit 交互的前提是拿焦点）。WebView 留作未来"富交互预览"备选，见 §5.5。
- **不把预览做成工作区树里的 pane 类型**：吸附 = 覆盖填充，不动 `PaneWorkspaceController` 的分屏语义（pane→预览类型的改造是 phase-2 选项，见 §9）。
- **v1 不做图片渲染 / 表格**：见 §7 已知限制。

---

## 4. 现有代码基础（Existing Infrastructure）

### 可直接复用

| 能力 | 现有实现 | 位置 |
|------|----------|------|
| 像素→单元格命中 | `RenderedGridGeometry.coordinate(at:)` | `Sources/ProGhosttyCore/TerminalCore/PTY/RenderedGridGeometry.swift` |
| 鼠标点击入口（mouseDown/up） | `TerminalCanvasView` 的鼠标处理 | `Sources/ProGhosttyApp/UI/TerminalCanvasView.swift` |
| 终端只读快照 | `GhosttyTerminalFrame` / `TerminalRenderFrame`（含行文本） | `Sources/ProGhosttyCore/TerminalCore/Renderer/` |
| VT 桥接 | `GhosttyVTBridge` | `Sources/ProGhosttyCore/TerminalCore/LibGhostty/GhosttyVTBridge.swift` |
| C shim | `proghostty_vt_*` 系列 | `Sources/ProGhosttyGhosttyVT/ProGhosttyGhosttyVT.c` + `.h` |
| 工作区运行时状态 | `PaneWorkspaceController`（panel frame、layout 变更通知） | `Sources/ProGhosttyCore/Workspace/PaneWorkspaceController.swift` |
| 工作区布局值类型 | `WorkspaceLayout` | `Sources/ProGhosttyCore/Workspace/` |
| 屏幕 → HTML 导出 | `ghostty_formatter_*`（`GHOSTTY_FORMATTER_FORMAT_HTML`），bridge 已封装 `proghostty_vt_format_html` | `Sources/ProGhosttyGhosttyVT/ProGhosttyGhosttyVT.c:1310` · `Vendor/ghostty/include/ghostty/vt/formatter.h` |
| cwd 状态（相对路径解析用） | VT 侧 OSC 7 `$PWD` 追踪（formatter 有 `extra.pwd`） | `Vendor/ghostty/include/ghostty/vt/formatter.h:100` |
| 无焦点选区先例 | 终端 grid 的拖选（accent 色、字符 range、不抢焦点） | `Sources/ProGhosttyCore/TerminalCore/Renderer/` |

### 缺失 / 需新增

| 缺失能力 | 所需工作 |
|----------|----------|
| `.md` token 检测 + 点击命中 | 复用 click-to-position 命中，读该行帧快照文本，token 匹配（文件名 / 绝对 / 相对路径） |
| cwd 查询暴露到 Swift | 扩展 C shim 读取 VT 的 OSC 7 状态（若 `GhosttyVTBridge` 未暴露） |
| markdown → 渲染 | 引入解析器 + 自有视图（见 §5.2） |
| 浮层容器 | 窗口内子视图（非独立窗口），见 §5.1 |
| 磁吸 / 吸附 | 拖拽几何 + panel drop target + layout 跟随，见 §5.4 |

---

## 5. 设计方案（Design）

### 5.1 浮层形态与焦点机制

**浮层是 ProGhostty 窗口内的子视图（overlay），不是独立窗口。**

- 理由：同一 `NSWindow` 内，点击浮层**不会让窗口失 key**，键盘焦点天然留在终端；一旦做成独立窗口（哪怕是 `nonactivatingPanel`），会出现窗口失激活、`hidesOnDeactivate`、跨屏、dock 干扰等边缘情形，"焦点永远在终端"就守不住了。且"位置不得超出窗口"对窗口内子视图是天然钳制。
- 浮层视图 `acceptsFirstResponder = false`；拖动、滚动、点击链接**都不走 first-responder 链** → 键盘永不离开终端。
- **明确放弃：浮层内的键盘扩展选区**（Shift+箭头）。鼠标选区 + 复制足够。

焦点模型对比（为什么不用 WebView）：

| 方案 | 焦点行为 | 选中/复制 | 结论 |
|------|----------|-----------|------|
| WKWebView 表面 | 交互即抢焦点 | 免费 | ❌ 违反"焦点永远在终端"（iTerm2 能做是因为浏览器是独立 pane，焦点本该给它） |
| HTML→图片表面 | 无焦点 | 无法选中 | ❌ 杀死多选复制（mdv/mdfried/kittyhtml 路线） |
| **自有视图 + attributed string** | **无焦点、自定义选区** | **悬停 ⌘C + 右键** | ✅ 本 spec 采用 |

### 5.2 渲染管线

```
点击 .md token
  → 读该行帧快照（只读）→ token 匹配 → 解析路径
  → 相对路径 → VT OSC 7 cwd 解析为绝对路径
  → 读取文件内容
  → markdown 解析器 → AST
  → 自有视图：AST → NSAttributedString（主题/字体与终端一致）
  → 滚动视图内渲染（只读）
```

- **解析器**：复用现成 parser，不自写。首选 **swift-markdown**（Apple 官方 SPM 包，纯 Swift，产出 AST），备选 cmark。注：swift-markdown 是 SPM 依赖（非系统 framework），需在 `Package.swift` 添加。
- **渲染表面**：自有视图（`NSTextView` 子类化或自绘），读 `NSAttributedString` 绘制；不引入 HTML/CSS 布局。
- **主题**：复用终端主题色与字体族，代码块保持等宽；深浅色跟随 app。
- **文件监听**：文件变更 → 防抖重渲（v1 可只做打开时读取 + 手动刷新）。

### 5.3 选区与复制（无焦点）

- 选中：**照终端 grid 的模式**——自定义鼠标选区，accent 色，**不依赖 first responder**，选区存**字符 range**（重排/缩放后仍跟住原文本）。
- 复制：
  - **悬停路由 ⌘C**（推荐）：⌘C 时鼠标在浮层上 → 复制预览选区；否则复制终端选区。注意：⌘C 是 App 的 Copy 菜单动作（SIGINT 是 Ctrl+C 走 PTY，两者不同）。
  - **右键菜单复制**：纯鼠标，无需焦点，永远可用。
  - 复制按钮兜底。
- 链接：单击 → 系统默认浏览器打开（不需要焦点）。

### 5.4 交互模型

| 动作 | 行为 |
|------|------|
| 单击 `.md` token（文件名 / 绝对 / 相对路径） | 浮层从锚点浮起，加载渲染 |
| 再点别的 `.md` | 原地替换内容 |
| 浮空态：按住**标题栏**拖动 | 移动位置（钳制在窗口内容区） |
| 浮空态：拖**右下角** | 调整宽高（markdown 按新度量重排，选区按字符 range 保持） |
| 内容区：点击拖动 | 多选文本 |
| 内容区：滚轮 / 触控板双指 | 滚动 |
| 双击浮层内部**空白处**（非文本区） | 退出预览 |
| 点击浮层外部 | **不退出**（持久陪伴） |

**初始位置自适应**：默认落在当前活跃 panel 的右上区域，高度约 panel 60%、宽度取阅读度量（≈60–70ch），且**底边不盖 panel 底部输入区域**。拖拽中不盖输入区约束只约束初始落点；用户主动吸附盖住 panel 是显式选择。

### 5.5 磁吸 / 吸附（Dock）

浮层有两态：**浮空态（free float）** ↔ **吸附态（docked）**。

- **吸附目标**：任意 panel 的边界框（不需要探测"空闲"panel——拖过去就是用户的选择）。
- **吸附手势**：拖拽中，浮层进入某 panel 边界 ~10pt → 该 panel 高亮成 drop target → 松手吸附，浮层 frame 对齐 panel frame。
- **吸附 = 覆盖填充，不是替换**：被盖住的 panel 里的终端**继续运行**（PTY 活着），只是暂时不可见；退出预览后原样露出来。不碰工作区树、不碰终端状态。
- **跟随 layout**：吸附态下浮层 frame 跟随该 panel 的布局变化（拖动分隔条、增删 panel 时同步）。实现：App 层读 `PaneWorkspaceController` 的 panel frame，零 Core 改动。
- **脱离**：从吸附位拖离 → 回到浮空态，位置记忆在窗口内。
- **吸附态双击空白**：直接退出预览（不是退回浮空）。

克制原则：磁吸是**一个明确的动作**（拖向 panel → 高亮 → 松手吸附），不做"万能吸附"（不吸窗口 chrome 边缘、不做磁力 latch）——这是"不突兀"的关键。

### 5.6 与现有系统的边界

| 交互 | 归属 |
|------|------|
| 点击命中 `.md` token | `TerminalCanvasView` 鼠标处理 + `RenderedGridGeometry`（复用 click-to-position 路径，读只读快照） |
| cwd 查询 | `ProGhosttyGhosttyVT.c` shim 小扩展 → `GhosttyVTBridge` |
| 浮层容器 / 拖动 / 吸附 | `Sources/ProGhosttyApp/UI/`（App 层，可用 SwiftUI/AppKit） |
| panel frame 观察 | `PaneWorkspaceController`（App 层只读消费） |

---

## 6. 边界约束（Architecture Compliance）

| 原则 | 合规方式 |
|------|----------|
| libghostty-vt 是唯一真相源 | 预览读**磁盘文件**，不维护任何终端状态；触发只消费帧快照的行文本 |
| 不在 VT 外解析 ANSI | 不解析任何终端字节流；`.md` token 匹配发生在视图层读只读快照，与 ANSI 无关 |
| Renderer 只渲染 | 不改渲染管线；预览浮层是 App 层独立视图 |
| 不复制终端状态 | 浮层是独立文档视图，与光标 / scrollback / 屏幕缓冲无关 |
| 扩展而非重写 | 复用 `RenderedGridGeometry`、`TerminalCanvasView` 鼠标入口、`PaneWorkspaceController`、formatter API |
| Core 不 import SwiftUI | 浮层全部落在 `Sources/ProGhosttyApp`（UI 层），Core 无改动 |
| 相对路径解析不靠猜 | 用 VT 的 OSC 7 cwd 状态 |

---

## 7. 已知限制（Known Limitations）

1. **只读**：不提供编辑、保存、双向同步——这是设计决定，不是缺失。
2. **无键盘选区扩展**：Shift+箭头选字不做（需要焦点），鼠标选区 + 悬停 ⌘C / 右键复制兜底。
3. **图片 / 表格**：v1 渲染管线聚焦文本（标题、段落、代码块、行内 code、链接、列表）。**表格和图片是难件**：表格需自绘网格布局；图片需确认渲染器是否消费 kitty graphics / 内联图片。v1 内做占位，表格/图片排进 phase-2。
4. **相对路径歧义**：OSC 7 未上报 cwd 的会话（某些远程 shell / tmux 场景），相对路径可能解析失败 → 只接受绝对路径与文件名 token，可接受。
5. **多浮层**：v1 单浮层，重复点击替换内容。
6. **持久化**：v1 会话内记忆（上次预览文件、浮层位置）；不跨会话持久化。
7. **双击文本区**：双击文本应触发选词而非退出；空白处双击才退出。需精确区分"空白"（padding / 行间空白）与文本命中。

---

## 8. 测试策略（Testing）

| 层级 | 测试内容 |
|------|----------|
| 单元测试 | `.md` token 检测：文件名 / 绝对路径 / 相对路径 / 带引号 / 尾随标点 |
| 单元测试 | 相对路径 → 绝对路径解析（cwd 拼接、`..` 规约、OSC 7 缺失时的降级） |
| 单元测试 | 浮层初始位置计算：给定 panel frame + 输入区 → 不遮挡、钳制在窗口内 |
| 单元测试 | 吸附几何：drop target 判定（10pt 阈值）、吸附后 frame 对齐、layout 变化跟随 |
| 单元测试 | 选区字符 range 保持：重排/缩放后选区仍正确 |
| 集成测试 | 点击 `.md` token → 浮层出现并渲染正确文档 |
| 手动测试 | 多分屏下跨 panel 键入不被打断；浮空/吸附两态切换；双击空白退出；相对路径在 zsh 下命中 |

---

## 9. 实现步骤（Implementation Plan）

### Phase 1：触发检测
1. `TerminalCanvasView` 点击命中 `.md` token（复用 `RenderedGridGeometry` + 行文本快照）
2. 相对路径解析：C shim 暴露 cwd（OSC 7）→ `GhosttyVTBridge`
3. 单元测试：token 匹配 + 路径解析

### Phase 2：浮层壳
4. 窗口内浮层子视图：拖动（标题栏）、右下角缩放、钳制窗口内
5. 初始位置自适应：避开活跃 panel 底部输入区
6. 双击空白退出 + 点击外部不退出
7. 集成：点击 token → 浮层出现

### Phase 3：渲染管线
8. 引入 swift-markdown（SPM 依赖）
9. AST → `NSAttributedString`（主题 / 字体 / 代码块等宽）+ 滚动视图
10. 文件监听 → 防抖重渲

### Phase 4：选区与复制
11. 无焦点选区（照终端 grid 模式，字符 range）
12. 悬停路由 ⌘C + 右键菜单复制
13. 单元测试：选区 range 在重排后保持

### Phase 5：磁吸 / 吸附
14. 拖拽 → panel drop target 高亮 → 松手吸附（覆盖填充）
15. 吸附态跟随 `PaneWorkspaceController` layout 变化
16. 拖离回浮空、吸附态双击空白退出

### Phase 6（可选，后续阶段）
17. 表格渲染（自绘网格）
18. 图片渲染（确认渲染器对内联图片/kitty graphics 的支持后）
19. WebView 富交互预览（如需，照 iTerm2 隔离模型：禁 JS、独立 process pool、仅 `data:`/`file:` scheme）

---

## 10. 开放问题（Open Questions）

1. ~~**markdown 解析器选型**~~ → **已定：swift-markdown 0.8.0**（项目首个 SPM 依赖，`Package.swift`）。
2. **浮层主题**：严格复用终端主题，还是独立的浅/深跟随？**已定：复用终端主题色与字体。**
3. ~~**文件监听范围**~~ → **已定：DispatchSource 文件监听 + 150ms 防抖重渲**（编辑保存即刷新）。
4. **吸附后焦点**：浮层盖住活跃 panel 时，键盘输入进入被盖住的终端（不可见）。是否需要自动转移焦点？**v1 不转移**，保持"焦点永远在终端"的简单语义。
5. **多 `.md` 命中**：一行里有多个 `.md` token 时，点击最近的一个。

---

## 11. 实现记录（Implementation Record · 2026-08-18）

Phase 1–5 全部落地，`swift build` + `swift test`（729 用例）+ `check-architecture.sh` 全绿。

| Phase | 产物 | 位置 |
|-------|------|------|
| 1 触发检测 | `.md`/`.markdown` 命中 → `openMarkdownPreviewHandler`（复用 `TerminalLinkDetector` + `fileInfoProvider` 解析绝对路径） | `PTYTerminalEngine.swift` · `PTYTerminalSurfaceRegistry.swift` · `AppModel.swift` |
| 2 浮层壳 | 窗口内子视图浮层：标题栏拖动、右下角缩放、钳制窗口、初始右上自适应、双击空白退出、`acceptsFirstResponder = false` | `MarkdownPreviewFloat.swift` · `MarkdownPreviewLayout.swift` |
| 3 渲染管线 | swift-markdown → `NSAttributedString`（终端主题），滚动显示 + 防抖文件监听 | `MarkdownPreviewRenderer.swift` |
| 4 无焦点选区 | 自定义 `MarkdownPreviewTextView`（字符 range、accent 色、重排保持）；悬停 ⌘C + 右键菜单复制 | `MarkdownPreviewTextView.swift` |
| 5 磁吸/吸附 | 拖向 panel（中心进边界 + 12pt 阈值）→ 虚线高亮 → 松手吸附填充；吸附态 30Hz 跟随 layout；拽起即脱离 | `MarkdownPreviewLayout.swift`（纯函数）· `MarkdownPreviewFloat.swift` · `AppModel.swift` |

**实现中的关键决策/偏差：**

- **cwd 解析零新增**：`sessionManager.workingDirectory`（OSC 7）+ `TerminalFilePathResolver` 已存在，Phase 1 未动 C shim。
- **选中不靠 NSTextView**：NSTextView 的选中要 first responder，改为自定义视图照终端 grid 模式实现（这正是设计里"放弃键盘选区、保留鼠标选区"的落地）。
- **浮层坐标全部 y-up**：容器不翻转，与 `window.contentView` 坐标系一致，避免翻转坑。
- **吸附跟随 layout 用 30Hz timer**：仅吸附态运行，捕获分隔条拖动/增删 panel；按 panel index 追踪，树结构中途变动时可能漂移（接受，v1 边角）。
- **悬停 ⌘C 用 local key monitor**：⌘C 时指针在浮层上且有选区 → 复制预览选区并消费事件；否则透传给终端。
- **已知限制**：表格/图片未渲染（图片显示 alt 文本占位）；浮层内无键盘选区扩展；吸附追踪按 index。
- **2026-08-18 修复（手测反馈）**：① 拖动抽搐——拖动点改在稳定容器坐标系计算（原在浮层本地坐标，浮层移动导致 delta 退化为增量）；拖动中不再逐帧 publish AppModel，松手才回写。② 单 panel 松手吸附全屏——`snapTarget` 要求 ≥2 个 panel，单 panel 不提供吸附。


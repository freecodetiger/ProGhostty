# ProGhostty 完成度 & App Store 上架差距审计

> 状态：已完成 · 基于 2026-08-16 对 `main`（HEAD `06c6c9f`）的 5 模块并发审计
> 验证快照：`swift test --no-parallel` **679 tests 全绿** ✅ · CI 完整 ✅ · 无私有 API ✅ · 无非法加密 ✅ · libghostty-vt ReleaseFast 已确认 ✅
>
> 本文是"距上架 App Store 还有哪些质量不达标 / 功能缺陷"的**一次性测绘**。分 5 个模块：①App Store 合规 ②终端功能面 ③VT 桥接 ④渲染/稳定性 ⑤生命周期/持久化/测试。结论含 file:line 锚点，执行时以当前代码为准（规则与代码冲突时以代码为准）。

---

## 0. 总览：完成度打分

| 维度 | 完成度 | 一句话 |
|---|---|---|
| VT 语义正确性（libghostty-vt 桥接） | **85%** | 状态真相源/快照/光标/resize/鼠标/IME 全对且未复制状态；缺口在输入编码 |
| 渲染管线（3 层降级梯） | **80%** | Metal 直渲 + cell-grid + 文本回退齐全，运行时热降级；glyph 缓存无上限是隐患 |
| 终端功能面（对标 iTerm2/Ghostty） | **65%** | 复制粘贴/OSC8/鼠标/alt-screen/滚动/通知齐全；**缺搜索、OSC52、标签页、选择增强** |
| 应用生命周期/工作区/持久化 | **75%** | 多窗口/分屏/PTY 释放/布局恢复都好；无"关窗不退出"、无窗口状态恢复、迁移死代码 |
| 测试 & CI | **80%** | 679 绿 + CI 完整；Metal/AppModel/信号升级路径零覆盖 |
| **App Store 合规** | **5%** | 只有 `codesign --sign -`（ad-hoc），沙盒/证书/公证/provisioning 全缺 |

**一句话总评**：作为终端，核心语义与工程质量已达标（约 75% 完成）；作为"可上架 App Store 的产品"，合规链路是 0，且有一个本质性架构障碍（沙盒 vs forkpty）。缺的不是"写更多代码"，而是三块：① App Store 签名/沙盒流程 ② 专业开发者刚需的 5 个功能 ③ 键盘 VT 编码的补齐。

---

## 1. App Store 硬性阻塞（P0）

这些是**分发/合规**问题，与代码质量无关，每一项单独就能挡住上架。

1. **签名全链路缺失** — `scripts/build-app-bundle.sh:67`、`build-dmg.sh:26/34`、`build-zip.sh:33` 全部 `codesign --sign -`（ad-hoc）。需要 Apple Distribution 证书 + provisioning profile。
2. **App Sandbox 与终端进程模型本质冲突（最硬的 P0）** — `Sources/ProGhosttyPTY/ProGhosttyPTY.c:82/87` 用 `forkpty()` + `execve` 用户 shell。沙盒下子进程继承沙盒，跑 `git`/`vim`/`cat ~/.zshrc` 会全部失效。终端模拟器几乎进不了 Mac App Store 的根源。除非申请非沙盒特批（终端类基本不批），否则当前架构上不了架。
3. **无 Xcode 工程 / 无 Archive 流程** — SwiftPM 裸工程，无 `.entitlements`、无 `xcodebuild archive`、无 Hardened Runtime、无 notarization、无上传脚本。

> ⚠️ **战略决策提醒**：若真上 Mac App Store，第 2 条决定后面所有工作量是否白费。两条路：(a) 申请沙盒豁免特批（成功率极低）；(b) 改成远程/受限 shell（砍核心卖点）。**iTerm2、Ghostty、kitty 都选独立分发 + 自更新而非 App Store**；本仓库已有 GitHub Releases + 自研更新检查（`AppUpdateChecker.swift:81-118`），独立分发形态其实已搭好。

### P1 非阻塞（若走 App Store 才需补）
- Info.plist 缺 `LSApplicationCategoryType`、`NSHumanReadableCopyright`、`ITSAppUsesNonExemptEncryption=NO`（`build-app-bundle.sh:33-63`）
- 只出当前机器架构（`uname -m`），无 universal binary（`build-dmg.sh:8` / `build-zip.sh:8`）
- `terminfo/78/xterm-ghostty` 是 `touch` 出来的**空文件**（`build-app-bundle.sh:31`）；当前 `TERM=xterm-256color` 未用它，属隐患

---

## 2. 功能缺陷（按对真实用户影响排序）

### 高优先级（上架前最该补，专业开发者会立刻遇到）

| 缺陷 | 锚点 | 影响 |
|---|---|---|
| **① 缓冲区搜索完全缺失** | 全仓无 find/prev/next（仅设置页搜索 `SettingsView.swift:78`） | 无法在输出里定位，日常最痛 |
| **② OSC 52 剪贴板未实现** | libghostty-vt 桥接无 clipboard 函数；`ghostty_terminal_new` 未配任何 effect 回调（`ProGhosttyGhosttyVT.c:35`） | tmux/SSH 远端 `printf '\e]52;...'` 静默无果 |
| **③ 键盘编码不完整** | `PTYTerminalEngine.swift:18-68` 只编码方向键/删除/回车/退格/Tab/Ctrl；F1-F12、Home/End/PgUp/PgDn 零编码 | vim/less/tmux 里这些键直接失效 |
| **④ 方向键不尊重 DECCKM + focus 1004 未透传** | 方向键硬编码 `ESC[A/B/C/D`；`ghostty_focus_encode`（`Vendor/ghostty/include/ghostty/vt/focus.h`）未用 | 应用光标键模式、vim focus-reporting 失效 |

> ③④ 救法现成：libghostty 已提供 `ghostty_key_encoder` / `ghostty_focus_encode`，只是 C shim 没暴露、Swift 没用。

### 中优先级
- **Scrollback 上限写死 10000 且不可配置、无清空命令**（`GhosttyVTBridge.swift:286`）
- **选择能力贫弱**：无双击选词/三击选行、无键盘选择（Shift+方向键）、无 Cmd+A 全选（`PTYTerminalEngine.swift:2024` 只处理 `clickCount==1`）
- **无标签页（Tabs）**：分屏 + 多窗口有，tab 缺位
- **配色不可定制**：仅 4 个固定主题，无 16 色 ANSI 调色板/导入导出（`AppSettings.swift:331`）
- **键位绑定只覆盖 8 个 App 级动作**，终端键位不可重绑（`AppSettings.swift:154-166`）
- **Shell 集成只对 zsh 自动激活**，bash/fish/elvish/nushell 只打包未注入（`PTYLaunch.swift:90-99`）
- **resize 硬编码 cell 8×16 像素**（`ProGhosttyGhosttyVT.c:72`），与实际字体 cell 脱节
- **无 bell / visual bell 回调**

### 低优先级
- 无 OSC 9;4 任务进度条、无 cursor 样式/闪烁/key repeat/bell 配置、字体无连字/DPI、DA 能力协商不完整（无 DA2/DA3/kitty 协商）

---

## 3. VT 桥接未完成 / 有风险的点

（详见模块 3 审计，完整 9 项见正文；这里只列缺口，其余 write/frame/光标/resize/鼠标/IME/并发均已核实 ✅）

**高**
1. **键盘输入编码不完整**（同 §2③④）：F1-F12/Home/End/PgUp/PgDn 零编码；DECCKM 未用；Alt/Ctrl+方向键丢失；kitty keyboard 协议未接。
2. **Focus in/out（mode 1004）未透传**：`ghostty_focus_encode` 未用。
3. **OSC 52 剪贴板未处理**：无读写、无回调、无 DA 能力位（`device.h:50` 未报 clipboard 位）。

**中**
4. **OSC 元数据在 libghostty 之外二次解析**（`OscParser.swift` 与 libghostty 内部 title/pwd 双轨）：只涉元数据非终端状态，不违反"grid/cursor/scrollback 唯一真相源"核心，但违背单一来源精神；且 Swift parser 不认 8-bit C1 形式 OSC（0x9D），仅识别 BEL/ST 结尾。
5. **resize 硬编码 cell 8×16 像素**（同 §2）。

**低**
6. **无 bell 回调**：`GHOSTTY_TERMINAL_EFFECT_BELL` 未接。
7. **`writePaste` 的 `vtQueue.sync`**（`PTYTerminalEngine.swift:478`）：大输出快照期间可能卡主线程（交互时延，非正确性问题）。
8. **`PromptCursorInferrer` 启发式与 VT `semanticContent` 并存**（`PTYTerminalEngine.swift:3783-3835`）：UX 推断，非状态复制，无 OSC 133 时可能漂移。
9. **DA/能力协商不完整**：无 DA2/DA3、无 kitty 协商、DA1 不含 clipboard 位。

---

## 4. 稳定性 / 性能风险

整体干净：**无 `preconditionFailure`/`try!`/`as!`**；`fatalError` 全是 `init(coder:)` 样板；无裸 `print`（调试输出全被 `PROGHOSTTY_RENDER_DEBUG` 门控 + 8MB 上限）；渲染三层降级梯有运行时热降级（`handleLiveRendererFailureIfNeeded`）。

值得关注 3 点：

1. **`MetalGlyphAtlas` 缓存无上限 + 主线程同步渲染字形**（`MetalGlyphAtlas.swift:74-75, 227-371`）——长会话涨内存，突发大量 CJK/emoji（`cat` 大文件）会卡 UI。**最可能被用户真实触发的卡顿点。**
2. **Metal 主路径每帧全量重建顶点**（`MetalDirectRenderEngine.swift:337-342`，注释明说设计取舍 ~0.2ms）——与 CLAUDE.md"脏行渲染"主叙事有出入，建议文档点明。
3. **一处潜在崩溃**：`AppSettings.swift:274` `defaults.bindings[action]!` —— 新增快捷键 case 而漏配 defaults 会崩（当前 9 case 全覆盖）。

> 附：Metal 直渲路径每帧全量重建顶点 + 多次数组分配、`CellGridDirtyTracker.diff` 每帧 O(rows×cols) 行哈希（非 O(dirty)）、文本回退每帧全帧重建 `NSAttributedString`（`GhosttyVTTextRendererBackend.swift:96-104`）——均在最坏/非热路径或属有注释的设计取舍，非 bug。

---

## 5. 生命周期 / 持久化 / 测试缺口

**已核实健康**：多窗口隔离干净、分屏树纯值类型、PTY 释放正确（SIGHUP→SIGTERM×5→SIGKILL×20 逐级升级 + waitTimer 兜底）、`TerminalWindowCloseGuard` 解决关窗确认死循环、679 tests 全绿、CI 完整（装 Zig→ReleaseFast 构建 libghostty→架构守卫→测试→打包）。

**缺口**：
1. 无"关窗口不退出"语义（`ProGhosttyApp.swift:188-190` 恒 `true`）
2. 无窗口状态恢复（无 `NSWindowRestoration`），只恢复 sqlite 单一工作区布局
3. `Migrations.swift` 是**死代码**（`currentSchemaVersion=1` 从未被引用），schema 演进无路径
4. **Cmd+W 双绑定冲突**：自定义"Close Pane"默认 Cmd+W 与系统"Close Window"同键（`AppSettings.swift:263`）
5. 更新机制未按分发渠道 gating（App Store 分发会违反自更新禁令）
6. 设置持久化一处硬编码覆盖：`smoothPixelScrollingEnabled` 被 `load()` 强设 true（`AppSettings.swift:319`）

**测试空洞**：
1. Metal 渲染零测试（只有后端**选择逻辑**有测，GPU 绘制无）
2. PTY 信号升级路径无测试（`PTYTerminalEngine.swift:578-616`）
3. AppModel（约 1600 行）几乎无覆盖（仅静态 reducer）
4. AppComposition / WindowCloseGuard 生命周期无覆盖
5. 无 UI/端到端冒烟测试
6. 无迁移/版本兼容测试

---

## 6. 建议的优先级行动清单

**先决策**：App Store vs 独立分发（§1 的沙盒 vs forkpty 冲突）——它决定后续所有工作量是否白费。若独立分发（更现实），重心转 ①→④。

| 优先级 | 事项 | 工作量估 |
|---|---|---|
| **决策** | App Store vs 独立分发（沙盒 vs forkpty） | 半天 |
| ① | 键盘编码补齐（F 键/Home/End/PgUp/Dn + DECCKM + focus 1004）——用现成 `ghostty_key_encoder` | 中 |
| ② | 搜索（find/highlight/上一下一） | 中 |
| ③ | OSC 52 剪贴板读写 + bell 回调（配 `ghostty_terminal_new` 的 effect 回调） | 中 |
| ④ | 选择增强（双击选词/三击选行/Cmd+A）+ scrollback 可配置化 | 小-中 |
| ⑤ | `MetalGlyphAtlas` 设上限/LRU（防长会话涨内存卡顿） | 小 |
| ⑥ | Cmd+W 冲突、迁移死代码、更新 gating 清理 | 小 |

# Plan: Agent 任务完成通知 · Hook 一键安装门控

分支：`feat/agent-notify-hook-onboarding`  
状态：设计（未实现）

---

## 1. 目标

把「通知开关」从 **只控制是否展示 OSC** 升级为 **能力完整可用**：

1. 用户打开「Agent 任务完成通知」时，若 user-level Codex/Claude Stop hook **未就绪** → **必须先看清说明并同意安装**，否则开关保持关 / 非生效态。
2. 同意后由 App **代为安装** hook（等价于今日 `scripts/install-agent-notification-hooks.sh` 的用户级部分）。
3. 关闭功能时可 **可选卸载** hook（默认建议卸，避免幽灵脚本）。
4. **禁止**启动时静默写 `~/.codex` / `~/.claude`。

非目标（本方案不做）：

- 扫描终端文本猜「任务完成」
- 恢复 BEL / shell command-finish 通知
- 改 OSC 777 / `pg notify` 协议本身
- 保证 macOS 系统 banner 亚 100ms（OS 不可控）

---

## 2. 问题陈述

| 层 | 今天 | 缺口 |
|----|------|------|
| 收 OSC + toast/音/系统通知 | App 内置，开关 `notificationsEnabled` | 用户以为开了就有 agent 通知 |
| 发信号 | Codex/Claude **Stop hook** → `pg notify` → TTY OSC | **仅** `scripts/install-agent-notification-hooks.sh` 手动；DMG 用户几乎不会跑 |
| 系统权限 | 设置里灰字 + 跳转 | 与 hook 未装混为一谈，难排查 |

结果：功能「半开」——开关默认 true，但多数机器 hook 不在。

---

## 3. 产品规则

### 3.1 生效定义

通知功能 **已生效（armed）** 当且仅当：

```
settings.notificationsEnabled == true
AND hookStatus.isReady == true
```

`isReady`：user-level 脚本在位 **且** Codex 与 Claude 配置中至少一侧 Stop 指向我们的 command（见 §5）。  
仅装脚本、配置被用户删掉 → **未就绪**。

### 3.2 打开总开关

```
用户拨 ON
  → 若 isReady：直接 ON，必要时再 requestAuthorization
  → 若 !isReady：
       开关视觉回弹到 OFF（或停留 pending）
       弹出「安装 Agent 通知 hook」确认 sheet
       [安装并开启] → install → 成功则 ON + 刷状态
                      失败则 OFF + 错误文案
       [取消] → 保持 OFF
```

**不得**在未确认时写盘。

### 3.3 关闭总开关

```
用户拨 OFF
  → settings.notificationsEnabled = false（立即）
  → 若 hook 仍装在用户配置：
       二次确认：「是否移除 ProGhostty 写入的 Stop hook？」
       [移除] uninstall 我们的 handler（不动他人 hooks）
       [保留] 只关展示，hook 仍可能对其他终端发 OSC（可接受，文案说清）
```

### 3.4 子开关

`notifyWhenFocused`：仅在 **armed** 时可点（沿用 `settingsSubordinate`）。

### 3.5 弹窗频率

- **不**在每次启动弹。
- 仅：用户主动开总开关且未就绪；或设置页点「安装 / 修复」。
- 可选：首次打开通知 pane 且未就绪时 **inline** 状态条（非 modal），避免打扰。

### 3.6 与系统通知权限

两条独立授权，设置页分两行：

1. **Agent hook**：安装状态  
2. **macOS 通知**：`UNUserNotification` 授权  

hook 装好但系统拒绝 → toast+音仍可用；桌面 banner 灰字引导系统设置（现状保留）。

---

## 4. UX（设置 · 通知 pane）

### 4.1 布局（自上而下）

1. **总开关**「Agent 任务完成通知」+ 说明：Claude Code / Codex 任务结束时提醒（需安装 hook）。  
2. **状态行**（只读 + 操作）  
   - 就绪：绿色/次要文案「已安装 Codex · Claude Code hook」  
   - 部分：黄「仅 Codex 已配置 / 仅 Claude…」+「修复」  
   - 未装：灰「未安装 agent hook」+「安装…」  
   - 错误：红 + 上次错误摘要  
3. **聚焦时也通知**（subordinate of armed）  
4. **系统通知权限**提示（现状）  
5. 高级折叠（可选 v1.1）：「复制手动安装命令」`scripts/install-…` 路径说明

### 4.2 确认 sheet 文案要点（中英 AppText）

- 将写入：  
  - `~/.proghostty/hooks/`（脚本）  
  - `~/.codex/hooks.json`（或 `$CODEX_HOME`）Stop  
  - `~/.claude/settings.json`（或 `$CLAUDE_CONFIG_DIR`）hooks.Stop  
- 行为：Agent **Stop** 时调用 `pg notify`，经本终端 OSC 弹出 toast / 声音 / 系统通知  
- 可随时在本页关闭并选择移除  
- 会备份被改配置：`*.proghostty.bak.<timestamp>`（与现脚本一致）

按钮：**安装并开启** / **取消**

### 4.3 测试发送（nice-to-have，可同一 PR 或 follow-up）

「发送测试通知」→ 本进程直接走 `TerminalNotificationCenter`（不经过 hook），验证展示链；hook 链用手跑一次 agent Stop 或 `pg notify`。

---

## 5. 技术设计

### 5.1 边界（遵守 CLAUDE.md）

| 职责 | 位置 | 说明 |
|------|------|------|
| Hook 安装/检测/卸载 | **App 层**（新类型） | 写用户家目录配置；**不进** `ProGhosttyCore`（避免 Core 碰文件系统策略/SwiftUI） |
| OSC 解析与事件 | Core（已有） | 不变 |
| 展示策略 | `TerminalNotificationPolicy` | 仍只看 `notificationsEnabled` + focus；**armed 由设置 UI 保证**：未装不能长期保持 ON。保险：可选在 `desktopNotificationActions` 再要求 `hooksReady` 若注入，但默认靠开关门控即可 |
| `pg` 二进制 | bundle `Contents/MacOS/pg` | 安装时写入 `pg-helper-path` |

不在 Core 引 AppKit 文件面板；安装器用 `FileManager` + JSON。

### 5.2 新类型（建议）

```
Sources/ProGhosttyApp/AgentNotificationHookInstaller.swift  // 或 AgentNotify/
  enum AgentNotifyHookStatus: Equatable {
    case ready(codex: Bool, claude: Bool)  // 至少一侧 true 且 scripts ok → ready
    case missing
    case partial(codex: Bool, claude: Bool)
    case error(String)
  }
  protocol AgentNotificationHookManaging {
    func status() -> AgentNotifyHookStatus
    func install() throws
    func uninstall() throws
  }
  struct AgentNotificationHookManager: AgentNotificationHookManaging { … }
```

**检测（status）** 不修改文件：

- 脚本可执行：  
  `~/.proghostty/hooks/notify_agent.sh`  
  `codex_stop_notify.sh`  
  `claude_stop_notify.sh`  
- 配置 command 包含（或精确等于）安装所用 command 字符串：  
  - Codex：`hooks.Stop[].hooks[].command` 含 `codex_stop_notify.sh`  
  - Claude：同上 `claude_stop_notify.sh`  
- `pg-helper-path` 存在且路径仍可执行；否则 partial + 可修复（重写 path）

**install()** 逻辑对齐现脚本用户级部分，**去掉**强制写 **仓库内** `.codex/` / `.claude/`（那是开发仓便利；App 安装只动 user home）：

1. `mkdir` hooks 目录  
2. 写三个 shell 脚本 + `chmod +x`  
3. 解析 bundle 内 `pg` → `pg-helper-path`  
4. merge JSON：Codex `hooks.json`、Claude `settings.json`（`ensure_hook` 语义，先 backup）  
5. 不依赖 `python3` —— **用 Swift `JSONSerialization`** 实现 merge，减少运行时依赖  

**uninstall()**：

- 从两处 Stop 列表移除 command 含我们 script name 的 handler  
- 可选删除 `~/.proghostty/hooks/*`（若目录仅有我们的文件则删文件，不硬删用户自建）

### 5.3 设置状态机（SettingsModel / AppModel）

```
@Published hooksStatus: AgentNotifyHookStatus
@Published hookInstallError: String?
@Published isInstallingHooks: Bool
@Published pendingEnableAfterInstall: Bool  // sheet 流程

onAppear(notifications pane) / app active: refreshHooksStatus()
toggle notificationsEnabled:
  if newValue == true && !status.isReady { revert; present sheet }
  if newValue == false { maybe present uninstall sheet }
```

绑定：`notificationsEnabled` 仍落 `AppSettings`；**不**把 hook 状态写入 UserDefaults（每次检测磁盘真相）。

### 5.4 默认值调整（建议）

- 现状：`notificationsEnabled` 默认 **true** → 误导  
- 方案：默认改为 **false**，或保留 true 但启动时若 `!isReady` 视为「偏好开但未 armed」，UI 显示三态：  
  - **偏好 ON + 未就绪** → 开关显示 ON 但状态条「需安装」+ 禁用音/桌面？  

**推荐更干净：默认 false**（decode 迁移：`decodeIfPresent ?? false` 会让老用户关掉一次——可接受；或 `?? true` 保持旧默认 + 状态条强提示「未安装」）。  

**拍板（本方案）：保留 decode 默认 true 以兼容**；UI 在未就绪时 **强制展示安装 CTA**，拨到 ON 必经 sheet。若用户曾经 ON 且从未装 hook，下次开设置会看到未就绪（不自动弹）。

### 5.5 脚本与 App 双轨

| 入口 | 用途 |
|------|------|
| App 安装器 | 普通用户主路径 |
| `scripts/install-agent-notification-hooks.sh` | 开发者/CI/文档；可保留 project-local 写入 |

实现后：脚本注释指向 App 设置；长期可让脚本调用同一 merge 规则（非必须同一 PR）。

### 5.6 安全

- 只写约定路径，不跟 symlink 逃逸（解析 `home` 后标准化）  
- backup 再写  
- uninstall 只删 **command 含我们 script basename** 的 handler  
- 不上传、不网络  

---

## 6. 实现步骤（建议 PR 切片）

### Step 1 — Manager + 单测（无 UI）
- `AgentNotificationHookManager`：temp HOME 下 install/status/uninstall  
- 测：空配置安装后 ready；二次 install 幂等；uninstall 清 handler 留他人 hook  

### Step 2 — 设置 UI 门控
- 状态行 + sheet + 开关拦截  
- AppText 中英  
- 系统权限行不动  

### Step 3 — 默认路径接线
- Settings pane `onAppear` refresh  
- install 成功后 `requestAuthorizationIfNeeded`  
- 可选：uninstall sheet  

### Step 4 — 文档
- 更新 `NOTIFICATION_PLAN` 附录或本文件勾选  
- README/设置说明一句  

每步：`swift build` + `swift test` + 手测 bundle。

---

## 7. 手测清单

1. 干净用户（无 hooks）：开通知 → sheet → 取消 → 仍关  
2. 同意安装 → `~/.proghostty/hooks` 有脚本；`hooks.json` / `settings.json` 有 Stop；状态就绪  
3. `pg notify --title T --body B` 在 pane 内 → toast+音（聚焦策略按开关）  
4. 真 Claude/Codex Stop 一轮 → 收到  
5. 关通知 → 选移除 → Stop 条目消失  
6. 系统通知拒绝 → 仍 toast+音；权限灰字在  
7. 无网络/只读 home 失败 → 错误文案，开关不假开  
8. 已有其他 Stop hook → merge 后仍在  

---

## 8. 风险与缓解

| 风险 | 缓解 |
|------|------|
| Claude/Codex hooks schema 变更 | 检测宽松（script name in command）；失败可「打开文档/复制命令」 |
| 用户手改 JSON 损坏 | backup；load 失败 → error 状态不写 |
| bundle 无 `pg` | 安装失败明确提示；开发用 `swift build` 路径可写入 helper path |
| 双开 ProGhostty 竞态写配置 | 写用 temp+replace；低概率可接受 |
| 默认 true 未装 | CTA + 开开关必 sheet |

---

## 9. 明确不做什么（ponytail）

- 不做开机自动装  
- 不做「安装向导」多页 onboarding  
- 不做 per-workspace hook  
- 不把 Manager 放进 Core  
- 不引入新 SPM 依赖  

---

## 10. 验收

- [ ] 未同意安装无法保持「已生效」通知  
- [ ] 同意后 Codex **或** Claude 至少一侧可 Stop 通知  
- [ ] 卸载只移除我们的 handler  
- [ ] 架构守卫绿；相关单测绿  
- [ ] 设置文案中英齐全  

---

## 11. 参考

- 现安装脚本：`scripts/install-agent-notification-hooks.sh`  
- 策略与展示：`TerminalNotificationCenter.swift`、`AppModel` `.desktopNotification`  
- 旧收敛计划：`.claude/NOTIFICATION_PLAN.md`  
- 控制协议：`ProGhosttyControl` / `pg notify` → OSC 777  

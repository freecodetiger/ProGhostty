# 通知系统收敛方案

## 目标（已与你确认）

把通知系统收敛为**单一用途：为 Claude Code / Codex 这类 CLI Agent 服务的"任务完成"提醒**。

- **唯一通知事件** = `pg notify`（agent hook 注入，经 OSC 777 到达）。任务完成时三者并行：**应用内 toast + 系统通知 + piano.mp3 提示音**。
- **彻底删除**：终端 `\a` bell（`NSSound.beep`）、ProGhostty 自检测的"命令完成"通知（含"延迟 N 秒"）。
- **只留两个开关**：① 总开关（是否通知）；② "聚焦时也通知"（默认**关** = 只在未聚焦时通知）。piano 音跟随总开关，不单列。
- **聚焦判定**：按"发通知的 session 是否为当前活动 pane"（`selectedSessionID == session` 且 `NSApp.isActive`）。
- **无系统通知权限**：设置里以低干扰形式（灰字提示）显示未授权。

---

## 关键事实（已验证）

1. **`commandFinished` / bell 是纯通知用**——不驱动任何时长统计、UI、持久化。整链可删。
2. **设置迁移零风险**——`AppSettings.init(from:)` 全用 `decodeIfPresent ?? default`，`SettingsStore.load()` 又 `try?` 兜底。删字段：老 JSON 多余键被忽略；加字段：缺失取默认。**无需版本号、无需迁移代码。**
3. **piano.mp3 当前被 `Package.swift` 的 `exclude: ["Resources"]` 排除**，靠 `#filePath` 开发期回退——打包 app 里其实能通过 `Bundle.main` 找到（build 脚本手动 cp 了），但为稳妥应改成 SwiftPM 正式打包。

---

## 实施步骤

### A. 整文件删除
- `Sources/ProGhosttyCore/TerminalCore/TerminalBellParser.swift`
- `Sources/ProGhosttyCore/TerminalCore/TerminalCommandLifecycle.swift`（parser + marker enum + `TerminalCommandFinished`）

### B. Core 事件管线（PTYTerminalEngine.swift + TerminalModels.swift）
- 删 `TerminalEvent.bell`、`.commandFinished` 两个 case。
- 删 per-session `bellParser` 字段 + 初始化 + `handleOutput` 里的 bell 解析/yield。
- 删 `commandStartedAt` 字段 + OSC 133 lifecycle 块（`.started/.finished/.promptStarted`）。
- **保留** `.desktopNotification` 发射（OSC 9 / OSC 777-notify）+ CwdTracker + title + `.osc`。

### C. 设置模型（AppSettings.swift）
- 删 9 个旧通知字段（含 CodingKeys / init 参数 / 赋值 / decode 行）：`inApp*`、`desktop*`、`notifyOnCommandFinish*`、`notifyOnTerminalBell*`。
- 删 `TerminalNotificationFocusPolicy` 枚举。
- 新增两个 Bool（同 `decodeIfPresent ?? default` 模式）：
  - `notificationsEnabled`（默认 `true`）——总开关
  - `notifyWhenFocused`（默认 `false`）——聚焦时也通知

### D. 通知策略与投递（TerminalNotificationCenter.swift）
- `TerminalNotificationAction` 删 `.bell` case（保留 `.inApp/.sound/.desktop`）。
- 删 `terminalBellActions`、`commandFinishedActions` + 3 个 helper。
- 重写 `desktopNotificationActions`：签名加 `isAppActive` / `isSessionFocused`；逻辑 = 总开关关 → 空；否则若 `notifyWhenFocused==false` 且 `(isAppActive && isSessionFocused)` → 空（聚焦时不打扰）；否则返回 `[.inApp, .sound, .desktop]` 三者并行。
- 保留 center（限流）、`MacTerminalNotificationSender`（UN 授权/投递）、`TerminalNotificationSoundPlayer`。
- 保留 `TerminalNotificationSoundPlayer` 里 piano 缺失时的 `NSSound.beep()` 回退（这是"音频文件加载失败"的兜底，与被删的终端 bell 无关）。

### E. App 层（AppModel.swift）
- `handle` 删 `.bell` / `.commandFinished` 两 case；删 `handleCommandFinished` / `handleTerminalBell`。
- `performNotificationActions` 删 `.bell` 分支。
- 重写 `.desktopNotification` handler：算出 `isAppActive = NSApp.isActive`、`isSessionFocused = (selectedSessionID == session)`，传入新的 `desktopNotificationActions`。

### F. 设置 UI（SettingsView.swift + AppText.swift）
- 通知分区（243-282）替换为：
  - `Toggle` 总开关
  - `Toggle` "聚焦时也通知"
  - 权限未授予时一行低干扰灰字提示（`notificationsEnabled` 开且系统未授权时显示）
- AppText：删旧的 focus-policy/bell/command-finish 文案键；加 3 个新键（总开关标签、聚焦开关标签、权限提示）。保留 `notifications` 分区标题。
- **权限状态**：给 AppModel 加一个只读 `@Published var systemNotificationsAuthorized: Bool`，启动/授权回调时刷新，供设置显示提示。

### G. 打包（Package.swift）
- 把 `ProGhosttyApp` target 的 `exclude: ["Resources"]` 改为 `resources: [.copy("Resources/notification-piano.mp3")]`（确保提示音进 bundle）。需确认 Resources 下其他文件是否也需处理。

### H. 测试
- 删：bell parser 测试、command-finished 测试、OSC 133 lifecycle 测试、bell 事件测试（`TerminalNotificationParserTests` / `TerminalNotificationCenterTests` 中对应项）。
- 改：`AppSettingsTests` 两个（改为断言新的 2 个开关默认值 + round-trip）；`TerminalNotificationCenterTests` 的 pg-notify 策略测试（改为断言"三者并行 + 聚焦门控"）。
- 保留：OSC 9/777 parser 测试、pg notify 映射测试、`PROGHOSTTY_NOTIFY_TTY` 测试、center 限流测试。
- **新增**：一个测试覆盖新 focus 门控（未聚焦→通知；聚焦且 `notifyWhenFocused==false`→不通知；聚焦且开关开→通知）。

### 验证
每步 `swift build` + `swift test`；`./scripts/check-architecture.sh`；最后构建 app bundle，手动发一次 `pg notify` 确认三者并行 + 聚焦门控 + 无权限提示。

---

## 已确认的细节

1. **提示音：两者都响**——系统通知保留默认音（`content.sound = .default` 不改），piano 也一起播放。任务完成时会听到系统提示音 + 钢琴音两声（钢琴音作为 ProGhostty 的辨识度）。
2. **权限提示：灰字 + 去授权按钮**——`notificationsEnabled` 开且系统未授权时，设置里显示一行低干扰灰字 + 一个小按钮，点击跳转 macOS 系统"通知"设置面板（`x-apple.systempreferences:com.apple.preference.notifications` 或对应 URL）。
3. 分支：`refactor/simplify-notifications`（从当前 main 切出）。


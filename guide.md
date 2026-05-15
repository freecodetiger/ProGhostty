
````text
你是一个资深 macOS 原生应用工程师和终端模拟器工程师。请基于以下方案，开发一个基于 libghostty 的 macOS 原生增强终端 MVP。

项目目标：
开发一个 macOS 原生终端应用，底层使用 libghostty 作为终端核心，保留 Ghostty 的稳定、高性能、原生体验；上层只做增强，不颠覆传统终端模型。

本阶段明确不做 AI Mode，不做 Claude Code / Codex 专属 UI，不做 Agent 内部协议适配。当前只实现稳定终端核心、命令历史分块、历史检索、工作区基础管理、设置管理、插件检测基础能力。

产品定位：
这是一个 “Ghostty Core + Developer Experience Layer” 的增强终端。

核心目标：
1. macOS 原生应用。
2. 使用 SwiftUI + AppKit 构建 UI。
3. 使用 libghostty 作为终端渲染和终端仿真核心。
4. 所有 libghostty 调用必须封装在适配层，不允许业务代码直接依赖 libghostty C API。
5. 终端主体验必须保持稳定，增强功能失败时不能影响基础终端可用性。
6. 命令历史分块基于 shell integration / OSC 133 / OSC 7 等语义事件，不要通过猜测 `$`、`%`、`❯` 等 prompt 字符实现。
7. 历史分块第一版采用“旁路索引”方式，不重写终端 scrollback 渲染模型。
8. 插件管理第一版只做检测、建议、配置预览，不要默认修改用户 shell 配置。
9. 所有历史记录和配置默认本地存储，不上传，不联网同步。

技术栈：
- macOS native app
- Swift
- SwiftUI
- AppKit
- libghostty C API
- SQLite
- SQLite FTS5
- UserDefaults / local config file
- Keychain，仅用于未来敏感数据，不在 MVP 中强依赖
- 配置格式优先使用 YAML 或 TOML；如果实现成本高，MVP 可以先用 JSON

重要工程约束：
1. 不要直接假设 libghostty 的具体 C API 函数名。请先阅读项目中 vendored 的 Ghostty/libghostty header 或现有 macOS frontend 示例，再封装。
2. 如果当前环境无法真实链接 libghostty，请先实现清晰的 `TerminalEngine` 协议和 `MockTerminalEngine`，保证 UI、数据层、分块逻辑可以先跑通。
3. 真正接入 libghostty 时，只改 `LibGhosttyTerminalEngine`，不要影响上层业务。
4. 不要为了命令分块重写终端渲染，不要把每条命令输出做成独立终端组件。
5. 命令分块只维护 metadata index，终端内容仍然由 libghostty 正常渲染。
6. 所有功能必须支持降级：如果 shell integration 不可用，则终端仍正常运行，只是分块状态显示为 unavailable 或 partial。

推荐项目目录结构：

EnhancedGhosttyTerminal/
├── App/
│   ├── EnhancedGhosttyTerminalApp.swift
│   ├── AppDelegate.swift
│   └── MainWindowController.swift
│
├── TerminalCore/
│   ├── TerminalEngine.swift
│   ├── TerminalSession.swift
│   ├── TerminalEvent.swift
│   ├── TerminalInputRouter.swift
│   ├── LibGhostty/
│   │   ├── LibGhosttyBridge.swift
│   │   ├── LibGhosttyTerminalEngine.swift
│   │   └── LibGhosttySurfaceView.swift
│   └── Mock/
│       └── MockTerminalEngine.swift
│
├── ShellIntegration/
│   ├── OscParser.swift
│   ├── ShellIntegrationState.swift
│   ├── CommandBlockIndexer.swift
│   └── CwdTracker.swift
│
├── History/
│   ├── CommandBlock.swift
│   ├── HistoryStore.swift
│   ├── HistorySearchService.swift
│   └── HistoryDatabase.swift
│
├── Workspace/
│   ├── Workspace.swift
│   ├── WorkspaceStore.swift
│   ├── WorkspaceManager.swift
│   └── WorkspaceTemplate.swift
│
├── Plugins/
│   ├── ShellEnvironmentScanner.swift
│   ├── PluginRecommendation.swift
│   ├── PluginInstallPlan.swift
│   └── PluginManagerViewModel.swift
│
├── Settings/
│   ├── AppSettings.swift
│   ├── SettingsStore.swift
│   ├── ThemeManager.swift
│   └── FontManager.swift
│
├── UI/
│   ├── RootView.swift
│   ├── SidebarView.swift
│   ├── TerminalView.swift
│   ├── TerminalTabView.swift
│   ├── CommandBlockMarkerView.swift
│   ├── HistoryView.swift
│   ├── WorkspaceView.swift
│   ├── PluginManagerView.swift
│   └── SettingsView.swift
│
├── Persistence/
│   ├── Database.swift
│   └── Migrations.swift
│
└── Tests/
    ├── OscParserTests.swift
    ├── CommandBlockIndexerTests.swift
    ├── HistoryStoreTests.swift
    └── WorkspaceStoreTests.swift

一、核心架构

请实现以下分层：

1. App/UI Layer
负责 macOS 窗口、侧边栏、Tab、Split、设置页、历史页、插件检测页。

2. Product Layer
负责命令分块、历史搜索、工作区、插件检测、设置管理。

3. Terminal Adapter Layer
负责连接 libghostty、PTY、输入输出事件、终端 Surface。

4. libghostty
只作为终端仿真、渲染、字体处理、VT/ANSI/OSC 基础能力提供者。

必须实现的协议：

```swift
protocol TerminalEngine {
    func createSession(config: TerminalSessionConfig) throws -> TerminalSessionID
    func closeSession(_ id: TerminalSessionID)
    func resizeSession(_ id: TerminalSessionID, rows: Int, cols: Int)
    func writeInput(_ data: Data, to id: TerminalSessionID)
    func viewForSession(_ id: TerminalSessionID) -> NSView?
    var events: AsyncStream<TerminalEvent> { get }
}
````

```swift
struct TerminalSessionConfig {
    var shellPath: String
    var workingDirectory: String?
    var environment: [String: String]
    var rows: Int
    var cols: Int
}
```

```swift
enum TerminalEvent {
    case sessionCreated(TerminalSessionID)
    case sessionClosed(TerminalSessionID)
    case output(session: TerminalSessionID, data: Data)
    case osc(session: TerminalSessionID, sequence: OscSequence)
    case cwdChanged(session: TerminalSessionID, cwd: String)
    case commandStarted(session: TerminalSessionID, command: String?)
    case commandFinished(session: TerminalSessionID, exitCode: Int?)
    case titleChanged(session: TerminalSessionID, title: String)
    case error(session: TerminalSessionID, message: String)
}
```

注意：

* 如果 libghostty 自身已经提供 OSC / shell integration 事件，则优先使用。
* 如果 libghostty 没有直接暴露事件，需要在 PTY output 进入 libghostty 前增加旁路 tap，对 Data 做轻量 OSC 解析。
* 旁路解析不得破坏原始字节流，原始 Data 必须继续原样交给 libghostty 渲染。

二、命令历史分块

目标：
把终端会话中的命令按照语义分成 CommandBlock，用于历史查看、搜索、复制、跳转。

不要做：

* 不要把终端渲染区拆成多个独立 block。
* 不要模拟 Warp 的完整输入模型。
* 不要根据 prompt 字符猜测命令边界。

要做：

* 基于 OSC 133 和 OSC 7。
* 维护 command block metadata。
* 在 UI 上显示轻量 marker、状态、耗时、exit code。
* 支持历史页面中查看、搜索、复制命令、复制输出预览。

需要支持的语义：

* prompt start
* prompt end
* command start
* command finish
* exit code
* cwd changed
* title changed，可选

CommandBlock 数据结构：

```swift
struct CommandBlock: Identifiable, Codable {
    let id: UUID
    let workspaceId: UUID?
    let sessionId: TerminalSessionID
    var cwd: String?
    var command: String?
    var outputPreview: String
    var outputStorageRef: String?
    var startedAt: Date
    var endedAt: Date?
    var durationMs: Int?
    var exitCode: Int?
    var status: CommandBlockStatus
    var shellIntegrationReliable: Bool
    var createdAt: Date
}
```

```swift
enum CommandBlockStatus: String, Codable {
    case running
    case success
    case failed
    case cancelled
    case unknown
}
```

CommandBlockIndexer 规则：

1. 收到 command start：创建 running block。
2. command start 前如果已知当前 cwd，则写入 block.cwd。
3. command 文字如果不能可靠获取，允许为空，不要猜。
4. 收到 output data：如果当前有 running block，则追加到 output preview buffer。
5. output preview 默认最多保存 64KB，超过后截断并标记。
6. 收到 command finish：写入 exitCode、endedAt、durationMs、status。
7. 如果 exitCode == 0，status = success。
8. 如果 exitCode != 0，status = failed。
9. 如果会话关闭时仍有 running block，status = cancelled 或 unknown。
10. 如果 shell integration 丢失，状态设为 partial，不要继续假装精确分块。

输出存储策略：

* MVP 默认只保存 outputPreview。
* 不保存完整输出，避免隐私和存储风险。
* 后续可添加“保存完整输出”的用户开关。

三、OSC 解析

实现 `OscParser`：

* 输入是 Data 流。
* 输出是识别出的 OscSequence。
* 必须能处理分片输入，例如 OSC 序列被拆在多个 Data chunk 中。
* 必须不破坏原始 Data。
* 支持 BEL 结束符：ESC ] ... BEL
* 支持 ST 结束符：ESC ] ... ESC \

需要识别：

* OSC 7：当前目录
* OSC 133;A：prompt start
* OSC 133;B：prompt end
* OSC 133;C：command start
* OSC 133;D：command finished，可能带 exit code
* OSC 0/1/2：窗口标题，可选

OscSequence：

```swift
struct OscSequence {
    let raw: String
    let command: String
    let parameters: [String]
}
```

测试要求：

* 单个完整 OSC。
* 多个 OSC 在同一个 chunk。
* OSC 被拆成多个 chunk。
* 普通输出中混有 OSC。
* 非法 OSC 不应 crash。
* 超长 OSC 应有长度限制，避免内存问题。

四、历史存储和检索

使用 SQLite。

表结构建议：

```sql
CREATE TABLE IF NOT EXISTS workspaces (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    root_path TEXT,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS terminal_sessions (
    id TEXT PRIMARY KEY,
    workspace_id TEXT,
    shell_path TEXT,
    initial_cwd TEXT,
    started_at INTEGER NOT NULL,
    ended_at INTEGER
);

CREATE TABLE IF NOT EXISTS command_blocks (
    id TEXT PRIMARY KEY,
    workspace_id TEXT,
    session_id TEXT NOT NULL,
    cwd TEXT,
    command TEXT,
    output_preview TEXT,
    output_storage_ref TEXT,
    started_at INTEGER NOT NULL,
    ended_at INTEGER,
    duration_ms INTEGER,
    exit_code INTEGER,
    status TEXT NOT NULL,
    shell_integration_reliable INTEGER NOT NULL,
    created_at INTEGER NOT NULL
);

CREATE VIRTUAL TABLE IF NOT EXISTS command_blocks_fts
USING fts5(command, output_preview, cwd, content='command_blocks', content_rowid='rowid');
```

如果 FTS5 与 content rowid 处理复杂，MVP 可以使用独立 FTS 表，手动同步插入/更新。

HistoryView 功能：

1. 搜索命令文本。
2. 搜索输出预览。
3. 按 workspace 过滤。
4. 按 cwd 过滤。
5. 按状态过滤：success / failed / running / unknown。
6. 点击历史项可以查看详情。
7. 支持复制 command。
8. 支持复制 output preview。
9. 支持 rerun command：把 command 写入当前 terminal，但默认不自动回车；用户可以在设置中启用自动回车。

五、终端 UI

主界面布局：

* 左侧 Sidebar：

  * Workspaces
  * Terminals
  * History
  * Plugins
  * Settings

* 中间 Terminal Area：

  * Tab 支持
  * Split 可以后置，MVP 可先只做 tabs
  * Terminal surface 使用 libghostty view

* 右侧 Inspector，可选：

  * 当前 session 信息
  * 当前 cwd
  * Shell Integration 状态
  * 最近一条 command block
  * exit code
  * duration

MVP UI 要求：

1. 可以创建新 terminal tab。
2. 可以关闭 terminal tab。
3. 可以设置默认 shell。
4. 可以设置默认工作目录。
5. 可以显示当前 Shell Integration 状态。
6. 可以看到命令 block marker。
7. 可以打开 History 页面搜索历史。

CommandBlock marker 设计：
不要改变终端输出内容。可以在终端区域边缘叠加轻量标记：

* 运行中：spinner 或 running
* 成功：✓ duration
* 失败：✗ duration
* unknown：?

如果无法准确定位 block 在 scrollback 中的位置，MVP 可以先在 Inspector 或下方面板显示“最近命令块”，不强制实现 scrollback 精准 overlay。

六、工作区管理

Workspace 是一等实体。

Workspace 数据结构：

```swift
struct Workspace: Identifiable, Codable {
    let id: UUID
    var name: String
    var rootPath: String?
    var defaultShell: String?
    var createdAt: Date
    var updatedAt: Date
}
```

MVP 功能：

1. 创建 workspace。
2. 选择 root path。
3. 从 workspace 打开 terminal。
4. 新 terminal 默认 cwd = workspace.rootPath。
5. 历史记录按 workspace 归档。
6. 删除 workspace 不删除历史，只解除关联或提示用户选择。

后续可扩展，但 MVP 暂不实现：

* 自动恢复 split layout。
* workspace.yaml。
* 启动命令模板。
* 多 pane 编排。

七、插件检测和配置管理

本阶段不做自动安装，不直接修改用户配置。

目标：
实现 Shell Environment Scanner。

扫描内容：

1. 当前默认 shell。
2. zsh 是否存在。
3. Homebrew 是否存在。
4. oh-my-zsh 是否存在。
5. 常用 zsh 插件是否存在。
6. fzf 是否存在。
7. zoxide 是否存在。
8. starship 是否存在。
9. atuin 是否存在。
10. ripgrep / fd / jq / gh 是否存在。

推荐插件：

* zsh-autosuggestions
* zsh-syntax-highlighting
* fzf
* zoxide
* starship
* atuin
* ripgrep
* fd
* jq
* gh
* lazygit
* delta

PluginManagerView 显示：

* 已安装
* 未安装
* 推荐原因
* 安装命令预览
* 配置建议预览

不要执行安装，除非后续版本用户明确点击“一键安装”。

安装计划结构：

```swift
struct PluginInstallPlan: Codable {
    var name: String
    var reason: String
    var commands: [String]
    var configSnippet: String?
    var riskLevel: PluginRiskLevel
}
```

MVP 中只展示 install plan，不执行。

八、设置系统

AppSettings：

```swift
struct AppSettings: Codable {
    var defaultShell: String
    var defaultWorkingDirectory: String?
    var fontFamily: String
    var fontSize: Double
    var themeName: String
    var commandBlocksEnabled: Bool
    var historyEnabled: Bool
    var saveOutputPreview: Bool
    var maxOutputPreviewKB: Int
    var rerunAutoEnter: Bool
}
```

默认值：

* defaultShell: /bin/zsh
* fontFamily: "JetBrains Mono"；如果不存在，fallback 到 Menlo
* fontSize: 14
* commandBlocksEnabled: true
* historyEnabled: true
* saveOutputPreview: true
* maxOutputPreviewKB: 64
* rerunAutoEnter: false

字体管理：

* 读取系统 monospaced fonts。
* 用户可以选择字体和字号。
* 如果 libghostty 已经读取 Ghostty config，可后续兼容 Ghostty config。
* MVP 可以先在 AppSettings 中维护独立配置。

主题管理：

* MVP 内置 light / dark / system 三种基础模式。
* 终端配色如果接入 libghostty config 较复杂，可先保持 libghostty 默认主题。
* UI 外壳遵守系统 light/dark。

九、隐私和安全

必须满足：

1. 历史记录默认只保存在本地 SQLite。
2. 不上传任何终端输出。
3. 不默认保存完整输出。
4. output preview 有大小限制。
5. 提供“清空历史记录”按钮。
6. 提供“禁用历史记录”开关。
7. 提供“禁用命令分块”开关。
8. 插件管理不自动修改用户配置。
9. rerun 命令默认只粘贴，不自动回车。
10. 对包含明显敏感关键词的输出，后续可增加 redaction；MVP 先预留接口。

预留接口：

```swift
protocol RedactionEngine {
    func redact(_ text: String) -> String
}
```

MVP 实现：

```swift
final class NoopRedactionEngine: RedactionEngine {
    func redact(_ text: String) -> String { text }
}
```

十、测试要求

必须写单元测试：

1. OscParserTests

* parse OSC 133;A
* parse OSC 133;B
* parse OSC 133;C
* parse OSC 133;D;0
* parse OSC 133;D;1
* parse OSC 7 cwd
* chunked OSC
* invalid OSC
* mixed text and OSC

2. CommandBlockIndexerTests

* command start creates running block
* output appends preview
* command finish success
* command finish failed
* cancelled block on session close
* cwd attached correctly
* preview truncation works

3. HistoryStoreTests

* insert command block
* query by command
* query by failed status
* query by workspace
* delete all history

4. WorkspaceStoreTests

* create workspace
* update workspace
* delete workspace
* session associates with workspace

十一、MVP 交付目标

第一阶段必须完成：

1. macOS app 能启动。
2. 能打开一个 terminal session。
3. 能输入命令并看到输出。
4. 能创建多个 terminal tab。
5. 能通过 `TerminalEngine` 协议隔离 libghostty。
6. 能解析 OSC 133 / OSC 7。
7. 能生成 CommandBlock。
8. 能把 CommandBlock 存入 SQLite。
9. 能打开 History 页面搜索历史。
10. 能创建 Workspace，并从 Workspace 打开 terminal。
11. 能打开 Settings 页面修改 shell、字体大小、历史开关。
12. 能打开 Plugins 页面查看环境扫描结果。
13. libghostty 接入失败时，MockTerminalEngine 仍可运行 UI 和数据层 demo。

十二、明确不做

MVP 不做以下功能：

1. AI Mode。
2. 语音输入。
3. Prompt 优化。
4. Claude Code / Codex 专属 UI。
5. 自动安装插件。
6. 自动修改 `.zshrc`。
7. 云同步。
8. 登录账号。
9. 远程 SSH 分块保证。
10. tmux 内部分块保证。
11. TUI 程序内部解析。
12. Warp 式完整 block input 模型。
13. 自研终端渲染引擎。

十三、实现顺序

请按以下顺序开发：

Step 1：搭建 SwiftUI macOS App 骨架

* RootView
* SidebarView
* TerminalAreaView
* HistoryView
* WorkspaceView
* PluginManagerView
* SettingsView

Step 2：定义 TerminalEngine 协议和 MockTerminalEngine

* 先让 UI 可以在 mock 模式下工作
* mock 输出一些模拟 shell 数据和 OSC 数据

Step 3：实现 OscParser

* 完整单元测试

Step 4：实现 CommandBlockIndexer

* 从 mock OSC 事件生成 CommandBlock
* 完整单元测试

Step 5：实现 SQLite HistoryStore

* command_blocks 表
* 基础搜索
* FTS5 如果时间不足可第二阶段实现

Step 6：实现 HistoryView

* 搜索框
* 状态过滤
* command block 列表
* 详情面板
* 复制命令/输出
* rerun 粘贴到当前 terminal

Step 7：实现 Workspace

* WorkspaceStore
* 创建/选择 workspace
* 从 workspace 打开 terminal
* 历史关联 workspace

Step 8：实现 Settings

* AppSettings
* 默认 shell
* 字体大小
* 历史开关
* command block 开关

Step 9：实现 Plugin Scanner

* 检测 Homebrew、zsh、常用 CLI
* 展示推荐，不执行安装

Step 10：接入 libghostty

* 实现 LibGhosttyBridge
* 实现 LibGhosttyTerminalEngine
* 替换 MockTerminalEngine
* 保持上层代码不变

十四、代码质量要求

1. 所有核心模块使用清晰协议抽象。
2. 不要把业务逻辑写在 SwiftUI View 里。
3. 使用 ViewModel 管理 UI 状态。
4. 数据库访问封装在 Store 层。
5. TerminalEvent 使用 AsyncStream 或 Combine 传递。
6. 任何 libghostty C API 调用只能出现在 LibGhosttyBridge / LibGhosttyTerminalEngine 中。
7. 错误必须可见，不要 silent fail。
8. 增强功能失败时，terminal session 不应该崩溃。
9. 所有用户可见破坏性操作必须确认。
10. 保持代码可继续扩展 AI Mode，但不要在本阶段实现它。

十五、验收标准

完成后，我应该能够：

1. 打开这个 macOS App。
2. 新建一个终端 tab。
3. 在终端里运行 `pwd`、`ls`、`echo hello`。
4. 如果 shell integration 可用，运行命令后能在历史中看到 command block。
5. command block 至少包含 cwd、时间、状态、exit code、输出预览。
6. 搜索历史可以搜到刚才的命令。
7. 创建一个 workspace，并从该 workspace 打开 terminal。
8. 打开插件页面，看到当前机器开发环境扫描结果。
9. 打开设置页，修改字体大小和默认 shell。
10. 禁用历史记录后，新命令不再保存到 SQLite。
11. MockTerminalEngine 模式下，所有 UI 和分块逻辑仍然可演示。

```

---

额外建议：你可以先让 Codex 按 **MockTerminalEngine → OSC Parser → CommandBlockIndexer → SQLite History → UI** 的顺序开发。不要一开始就硬接 `libghostty`，因为官方明确说 `libghostty` 还不是稳定独立 API；先把增强层跑通，再替换底层终端引擎，风险最低。:contentReference[oaicite:1]{index=1}
::contentReference[oaicite:2]{index=2}
```

[1]: https://ghostty.org/docs/about "About Ghostty"

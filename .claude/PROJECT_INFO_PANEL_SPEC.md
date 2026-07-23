# 项目信息面板 · 设计文档

> 分支:`feat/interactive-elements`(延续)
> 目标:点击 titlebar 中间的路径,弹出一个**独立的项目信息面板**,快速看清"我在哪个项目、它现在什么状态"——git 分支 / 最近提交 / 是否 dirty / 目录信息,尽量联动远端。
> 定位:这是**项目/仓库仪表盘**,与终端内的文件 popover 是两个不同模块(不同数据、不同锚点、不同 UI),不复用 `SemanticLinkPopover`。

---

## 1. 背景

titlebar 中间的路径是 `WorkspaceTitlebarView` 里的 `subtitleLabel`(`TitlebarHoverLabel`):
- 常态显示 `📁 <cwd 末段>`,hover 展开成完整绝对路径(仅换文字 + 放宽宽度),**目前纯展示,无点击行为**。
- 数据源 `selectedCwd` = 内核实时 per-session cwd(与文件 popover 同源)。

现在要让它**可点击**,点开项目信息面板。hover 展开绝对路径的现有行为**保留**。

## 2. 目标与非目标

**目标**
- 点 subtitle → 弹独立面板,异步展示项目现状。
- 内容:绝对路径(可复制)、git 分支、dirty 状态、最近提交(hash+message+相对时间)、目录修改时间。
- 远端联动(见 §5,分档):至少支持"在浏览器打开远端仓库";ahead/behind 尽量做。
- 不阻塞主线程:面板先秒开(显示路径),git/远端信息后台拉取后填入。

**非目标**
- 不在 titlebar 常显 branch 名(你已确认暂不做)。
- 不做常驻监听 / 后台 poll —— 懒加载,每次点开重新拉。
- 不碰 libghostty-vt、不进 Core —— 纯 App 层仪表盘(git/远端是文件系统 + 网络状态,不是终端状态,不违反边界)。
- 不做 `git fetch`(默认)—— 见 §5 对网络的取舍。

## 3. 触发与 UI

> ⚠️ **修订（2026-07,落地版）**：远端联动整体撤销——"落后 main/master"语义不清、做不好反而误导,`git fetch` 也不做(见文末《修订记录》)。T 面板聚焦本地信息,重点做**当前分支的 commit 历史**。以下 §3 原始布局与 §5 远端档位为历史记录,实际以《修订记录》为准。

- `subtitleLabel` 从纯 label 升级为可点击:加 target/action(或叠透明按钮),`NSPopover` anchor 到它,`preferredEdge: .maxY`(从 titlebar 下方弹出)。
- 保留 hover 展开绝对路径的行为;**点击**才弹面板。
- 面板复用 popover 视觉语言(跟随终端主题、无系统蓝),但是**独立组件** `ProjectInfoPopover`,布局:

```
┌────────────────────────────────┐
│  <repo 名 or 目录名>            │  标题
│  /abs/path/to/project           │  灰字 + 复制按钮
│  ────────────────────────────  │
│   main ↑2 ↓0   ● 3 changed      │  分支 + ahead/behind + dirty
│   a1b2c3 · fix: …  · 2h ago     │  最近提交
│   Modified · yesterday          │  目录修改时间
│  ────────────────────────────  │
│   Open Remote   Copy Path       │  动作
└────────────────────────────────┘
```

不在 git 仓库时:git 区整块隐藏,只留路径 + 修改时间 + Copy Path。

## 4. 数据获取(App 层,后台异步)

**方式:跑 `git` 子进程**(你已选 A + 后台)。原因:准、全、跨版本稳;读 `.git` 文件自己解析 log/status 不现实。

- 面板弹出时,主线程立即渲染"路径 + 加载中",同时在**后台队列**跑一组 git 命令,完成后回主线程填入。若面板已关则丢弃。
- 每个命令设**超时**(如 1.5s),`git` 卡住(大仓库 / 网络 remote)不拖死面板。
- 用绝对 cwd 作为 `-C <cwd>` 传给 git,不改变任何终端进程的目录。

命令集(只读,全部本地、不触网):

| 信息 | 命令 |
|---|---|
| 是否 git 仓库 | `git -C <cwd> rev-parse --is-inside-work-tree` |
| 当前分支 | `git -C <cwd> rev-parse --abbrev-ref HEAD` |
| dirty 文件数 | `git -C <cwd> status --porcelain` → 计行数 |
| 最近提交 | `git -C <cwd> log -1 --format=%h%x1f%s%x1f%cI` |
| ahead/behind(本地已知) | `git -C <cwd> rev-list --left-right --count @{u}...HEAD` |
| 远端 URL | `git -C <cwd> remote get-url origin` |
| 目录修改时间 | `FileManager.attributesOfItem`(非 git) |

**纯函数边界**:命令输出解析(branch/commit/ahead-behind/remote-url → 结构体)抽成 `GitStatusParser` 纯函数,可单测;spawn 子进程的壳不单测。这是本功能唯一有分支的逻辑。

## 5. 远端联动(分档,重点让你选)

"联动远端"有三个层次,代价递增。网络操作是主要风险(慢、要认证、可能弹密码),必须谨慎。

**档位 1 · 在浏览器打开远端(推荐,零网络成本)**
- 读 `git remote get-url origin`(本地,瞬时),把 `git@github.com:a/b.git` / `https://…` 归一成网页 URL,面板给一个 "Open Remote" 打开浏览器。
- 高价值、零风险、不触网。**建议第一步就做。**

**档位 2 · 显示 ahead/behind(推荐,不触网)**
- `git rev-list --left-right --count @{u}...HEAD` 读的是**本地已知的**与上游的差距(不 fetch)。所以显示的是"上次 fetch 以来"的领先/落后。
- 零网络、瞬时。缺点:若很久没 fetch,数字可能过期——可以在旁边标一个"基于本地记录"的弱提示。

**档位 3 · 主动 `git fetch` 拿真实远端状态(默认不做)**
- 只有 fetch 才知道远端真实进度。但:**要网络、可能几秒、可能弹认证(SSH passphrase / HTTPS 凭据)**,在一个"点一下看信息"的轻面板里做自动 fetch 体验很差、还可能卡。
- 建议:**不自动 fetch**。如果你要,做成面板里一个显式按钮 "Fetch & refresh",用户主动点、带 loading、带超时,失败了也不影响其他信息。第一版可以先不做,留钩子。

**我的推荐**:第一版做**档位 1 + 2**(打开远端 + 本地 ahead/behind),既"联动远端"又零网络风险。档位 3(主动 fetch)作为可选按钮后续加。

> GitHub/GitLab API(PR 数、CI 状态等)是更深的联动,需要 token + 网络 + 各家 API 适配,明确排除在本功能之外,未来单独立项。

## 6. 边界与架构归属

- 全部在 **App 层**(`AppModel` 或一个新的 `ProjectInfoService`)。它已持有 cwd、能 import Foundation/`Process`。
- **不进 Core、不碰 libghostty-vt**:git/远端是 `.git` 与网络的状态,不是终端状态,不适用"libghostty-vt 唯一真相源"那条(那条只约束光标/屏幕/scrollback/VT 解析)。
- 子进程执行放后台队列,结果回主线程;`ProjectInfoService` 输出不可变值类型 `ProjectInfo`。

## 7. 测试与验证

- `GitStatusParser`:纯函数,喂样例 git 输出,断言解析出的 branch / commit / ahead-behind / remote-url(含 SSH→HTTPS 归一)。这是唯一有分支的逻辑,配一组小测试。
- 子进程 / 网络壳不单测(靠手测)。
- 三绿:`swift build` + `swift test` + `scripts/check-architecture.sh`。
- 手测:`build-app-bundle.sh release` → 重启;在 git 仓库 / 非仓库 / detached HEAD / 无 remote / dirty 各点一次。

## 8. 风险与权衡

| 风险 | 缓解 |
|---|---|
| 主线程 spawn git 卡 UI | 后台队列 + 超时 + 面板先秒开占位 |
| 大仓库 `status` 慢 | 超时;`--porcelain` 已是最轻;必要时只取前 N 行计数 |
| 自动 fetch 弹认证/卡住 | 默认不 fetch;fetch 仅作显式按钮(第一版可不做) |
| detached HEAD / 无 upstream / 无 remote | 解析器对每项独立降级,缺哪项就隐藏哪行,不报错 |
| cwd 不是 selectedCwd 想象的那样 | 复用现有 `selectedCwd`(内核实时),与文件 popover 同源,已验证 |
| SSH URL 归一化出错 | 解析器对无法识别的 remote 就不显示 "Open Remote",不猜 |

## 9. 实施顺序

1. `ProjectInfo` 值类型 + `GitStatusParser` 纯函数 + 测试。
2. `ProjectInfoService`(后台跑 git 命令 + 超时,组装 `ProjectInfo`)。
3. `subtitleLabel` 可点击 + `ProjectInfoPopover` 独立组件(先渲染路径占位)。
4. 异步填入 git 信息(档位 1+2:分支 / dirty / 最近提交 / ahead-behind / Open Remote / Copy Path)。
5. 三绿 + 手测多种仓库状态。

## 10. 待确认

- [ ] 远端联动第一版做 **档位 1+2**(打开远端 + 本地 ahead/behind,零网络);档位 3(主动 fetch)后续作为显式按钮。同意?
- [ ] 面板动作按钮:**Open Remote / Copy Path** 两个够吗?要不要加 "Reveal in Finder" / "Copy Branch"?
- [ ] 非 git 目录:只显示路径 + 修改时间(git 区隐藏)。同意?
- [ ] 面板文案是否需要中英本地化(和文件 popover 一样跟随设置语言)?我默认要。

---

## 修订记录（2026-07 · 落地版,以本节为准）

多轮手测后对 T 面板重新定位。**撤销**:目录修改时间、ahead/behind、远端"落后 main/master"、`git fetch`、Refresh 按钮——远端主干落后语义不清,做不好反而干扰工作。**聚焦本地**,把当前分支的 commit 历史做好。

### 最终布局

```
┌──────────────────────────────────┐
│  📦 proghostty                     │  仓库名
│  /abs/path                         │  路径(灰字,复制用)
│  ────────────────────────────────  │
│   feature/x-panel                  │  当前分支
│   ● 3 modified · 2 added           │  工作区:改动/新增文件数(clean → ✓ Clean)
│  ────────────────────────────────  │
│   Recent commits                   │  分区标题(小灰字)
│   a1b2c3 · 2h ago · zpc            │   ① 元信息(hash·相对时间·作者)
│   fix(render): file info popover   │   ① subject(整行,最多 2 行)
│   9f8e7d · yesterday · zpc         │   ②
│   feat: project info panel         │   ②
│   …(共 N 条,默认 5)               │
│  ────────────────────────────────  │
│   Open Remote    Copy Path         │  动作(Open Remote 仅有 origin 时)
└──────────────────────────────────┘
```

### 数据（`ProjectInfo` / `ProjectInfoService`,均 App 层、后台、只读、不触网）

- **删字段**:`modified`、`ahead`、`behind`。
- **工作区更改**拆两数:`modifiedCount`(已跟踪改动)、`addedCount`(未跟踪 `??`)。由 porcelain 每行 XY 状态码解析(`??`=untracked,其余=tracked)。
- **commit 历史**:`recentCommits: [GitCommit]`(默认 5 条),命令
  `git log -<N> --format=%h%x1f%s%x1f%cI%x1f%an%x1e`(记录用 `\u{1e}` 分隔,字段用 `\u{1f}`)。
  `GitCommit` 增 `author`;`subject` 独占一行、正常字号、最多 2 行,不再和 hash/time 挤一行。
  > body 暂不取:项目多为 conventional commit 单行,列多条比单条展开 body 更有"历史感"。后续需要再加。
- `branch` / `remoteURL` 不变。

### UI（`ProjectInfoPopoverController`）

- 删"目录修改时间"行、"分支后缀 ahead/behind"。
- 分支行、工作区行各一行(带 icon)。
- commit 历史:一个"Recent commits"分区,每条两行(元信息小灰字 + subject 整行),条目间留一点间距。
- 非 git 目录:只显示路径 + "非 git 仓库",commit 区隐藏。

### 测试

- `GitStatusParser`:新增 `modified/added` 拆分解析;`recentCommits` 多行解析(`\u{1e}` 分记录);`GitCommit` 含 author。
- 三绿 + 手测:普通仓库 / 非仓库 / detached HEAD / 无 remote / 有暂存+未跟踪混合改动 / 提交数 < N。

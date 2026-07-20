# Git 工作流 · Commit / Push 规范

> Agent 与人工共用。目标：从 `git log` / PR 标题 **30 秒摸清现状**。  
> 细节以本文件为准；`CLAUDE.md` 只保留入口指针。

---

## 一句话

**小步、可定位、可回滚；先绿再推；没被要求不 push。**

---

## Commit message

格式（Conventional Commits，与现有历史一致）：

```
<type>(<scope>): <summary>

[optional body]
```

### type

| type | 何时用 |
|------|--------|
| `feat` | 用户可感知的能力 |
| `fix` | 修 bug / 回归 |
| `refactor` | 行为不变的结构调整 |
| `test` | 只动测试 |
| `docs` | 只动文档/规范/计划 |
| `chore` | 构建脚本、依赖、琐事 |
| `ci` | workflow / runner / 发布管线 |
| `perf` | 明确性能优化 |

### scope（常用）

`scroll` · `render` · `pty` · `vt` · `workspace` · `settings` · `ci` · `release` · `arch`

新域先复用上表；没有合适的再加短词，**不要**写文件名当 scope。

### summary

- 祈使句、现在时：`fix false bottom when…`，不要 `fixed` / `fixes`
- ≤ ~72 字符；**说明意图，不堆文件列表**
- 中英文均可；本仓库近期以英文 summary 为主，中文可放 body

### body（建议在这些情况写）

- 非显然的根因（一行：`Root cause: …`）
- 用户可见行为变化 / 手测点
- 刻意不做的事（`ponytail` / 延期项）
- 关联计划：`See .claude/BROWSE_ANCHOR_FIX_PLAN.md`

不要粘贴大 diff；不要 `WIP` 进 main。

### 好 / 坏示例

```
# 好
fix(scroll): stop cursor-rect rebuild thrashing during browse
fix(render): selection overlay already in expanded-frame rows
feat(scroll): distance-from-bottom anchor for return-to-live

# 坏
update stuff
fix bug
WIP
PTYTerminalEngine.swift changes
```

---

## 什么进 commit、什么不进

**进：** 源码、测试、文档、workflow、有意的配置。

**永不进：**

- `.zig-cache*` / `zig-cache` / 本地工具缓存
- `.build/` 产物、`.app`、`.dmg`（除非发布脚本明确生成到 `dist/` 且由 CI 处理）
- 密钥、本机绝对路径、调试噪声日志开关的误提交

不确定 → `git status` / `git diff --stat` 先过一遍。

---

## 拆分粒度

- **一个意图一个 commit**（修选区 ≠ 修滚动卡死）
- 大功能可按「可测台阶」拆（仓库 pattern-2 历史就是 step 1…8）
- 不要把 `docs only` 和行为改动混在同一 commit（除非文档是该改动的契约）

---

## Commit 前检查（改代码时）

```bash
swift build
swift test          # 至少相关 filter；全量更稳
scripts/check-architecture.sh   # 动了分层/import 时必跑
```

手测渲染/滚动：**不要用裸 `swift build` 启动**——用 `./scripts/build-app-bundle.sh release`（见 CLAUDE.md）。

测试红 → 不 commit（除非用户明确要求 WIP 到分支且说明原因）。

---

## 分支与 push

| 规则 | 说明 |
|------|------|
| 默认分支 | `main` |
| push | **仅当用户明确要求** push / 发布 / 开 PR 时才 push |
| force push | 禁止对 `main`；个人分支需用户确认 |
| 上游 | push 后确认 `git status -sb` 与 `origin` 关系 |

本地 commit 可以攒；**push 前**再扫一眼 log，保证历史读得通。

---

## 发布（release）

- 版本靠 tag：`v*`（如 `v0.4.0`）触发 `.github/workflows/release.yml`
- tag 只打在**要发布的 commit**上；消息/notes 写用户可见高光，不写实现流水账
- CI 已 pin `macos-15` + `libghostty-vt` **ReleaseFast**——改 workflow 时勿破坏这两点

---

## Agent 操作清单（每次 commit）

1. `git status` / `git diff` / 最近 `git log` —— 对齐风格与范围  
2. 排除缓存与无关文件  
3. 按意图 stage（必要时多次 commit）  
4. 写符合上文的 message  
5. **不** `git commit --amend` 除非用户要求且 commit 未推送、为你所建  
6. **不** push，除非用户本轮明确说 push / 发布  

用户说「提交并推送」→ commit 完成后 push 当前分支并回报 remote 结果。

---

## 快速摸清现状（给未来的你）

```bash
git log --oneline -20          # 最近意图序列
git status -sb                 # 脏区 + 领先/落后 origin
git diff --stat                # 未提交改动面
```

读 log 时：`type(scope)` = 域，`summary` = 用户/系统发生了什么。  
更深：对应 `.claude/*_PLAN.md` / `docs/` / 本文件。

# 文件链接信息 Popover · 设计文档(精简版)

> 分支:`feat/interactive-elements`(从 `main`)
> 目标:点击文件语义对象弹出的 popover 显示文件基本信息;修复 **Copy Path 复制原始 token 而非绝对路径** 的 bug。
> 原则:能复用就复用,不新造抽象。所有解析/文件系统能力已在项目里存在,本改动只是"接线"。

---

## 1. 问题

文件分支 popover 现在:标题 = `filePath.rawPath`(原始 token),动作 = Reveal in Finder / Copy Path。

- **信息缺失**:看不到修改/创建时间、大小。
- **Copy Path bug**(`PTYTerminalEngine.swift:2031`):复制 `filePath.rawPath`,可能是相对路径 `src/x.swift`、`~/x`、裸词 `README`,不是用户要的绝对路径。

## 2. 已存在、直接复用的东西(不重写)

| 需要 | 已有 | 位置 |
|---|---|---|
| per-session 实时绝对 cwd | `workingDirectory(for:)`(内核 `proc_pidinfo`) | `PTYTerminalEngine.swift:507` |
| 相对/`~`→绝对 + 存在校验 | `TerminalFilePathResolver.resolve(target, cwd:)` → `URL` | `TerminalFilePathResolver.swift:9` |
| App 层 cwd 回退链 | `sessionCwd(for:)` | `AppModel.swift:894` |
| 时间/大小格式化 | `FileManager.attributesOfItem` + `RelativeDateTimeFormatter` / `ByteCountFormatter` | Foundation |
| Core↔App 注入模式 | `pathExistenceValidator` / `openLinkTargetHandler` | 既有 |

## 3. 方案:一个注入闭包,不加结构体

**Core(`PTYGridView`)新增一个闭包**——App 直接返回 popover 要显示/复制的成品,Core 不做解析、不做格式化、不加值类型:

```swift
/// App resolves a clicked file target to (absolute path, human-readable info lines).
/// nil → popover shows only actions, Copy Path falls back to rawPath.
public var fileInfoProvider: ((TerminalFilePathTarget) -> (absolutePath: String, detailLines: [String])?)?
```

Registry 装配镜像 `setPathExistenceProvider`(`PTYTerminalSurfaceRegistry.swift:396`):`configureLiveGridView` 里按 id 绑定 + 新增 `setFileInfoProvider(_:)`。

**App(`AppModel`)实现**——复用现成件,唯一新代码是格式化:

```swift
surfaceRegistry.setFileInfoProvider { [weak self] session, target in
  self?.terminalFileInfo(target, from: session)
}

private func terminalFileInfo(_ target: TerminalFilePathTarget, from session: TerminalSessionID)
    -> (absolutePath: String, detailLines: [String])? {
  guard let url = try? TerminalFilePathResolver.resolve(target, cwd: sessionCwd(for: session))
  else { return nil }
  let a = try? FileManager.default.attributesOfItem(atPath: url.path)
  let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
  return (url.path, FileDetailFormatter.lines(          // ← 唯一新增:纯函数
    path: url.path, isDirectory: isDir,
    modified: a?[.modificationDate] as? Date,
    created: a?[.creationDate] as? Date,
    size: isDir ? nil : a?[.size] as? Int))
}
```

`FileDetailFormatter.lines(...)`:纯函数,`[String]`。行:绝对路径 / `Modified · <相对时间>` / `Created · <相对时间>` / 大小(目录跳过,标 `Folder`)。缺字段跳过该行。有分支 → 配一个 `test_*.py` 级别的小测试(见 §5)。

**Core popover 文件分支**(`presentLinkPopover`):
```swift
case .filePath(let filePath):
  let info = fileInfoProvider?(filePath)
  let absolute = info?.absolutePath ?? filePath.rawPath
  title = (info?.absolutePath).map { URL(fileURLWithPath: $0).lastPathComponent } ?? filePath.rawPath
  detailLines = info?.detailLines ?? []
  items = [
    .init(title: "Reveal in Finder", symbol: "folder") { [weak self] in self?.activateLink(target) },
    .init(title: "Copy Path", symbol: "doc.on.doc") { [weak self] in self?.copyToPasteboard(absolute) }, // 修 bug
  ]
```

**`SemanticLinkPopover.present`** 加一个参数,detail 渲染成灰色小字标签(复用现有 NSStackView):
```swift
func present(title:, detailLines: [String] = [], items:, at:, in:, palette:)
```
detail 为空(URL 分支 / 解析失败)→ 不显示信息区,退回当前样式。

## 4. 相比上一版砍掉了什么

- ❌ `TerminalFileInfo` 值类型 —— 闭包直接返回成品元组,Core 不需要中间结构。
- ❌ `TerminalFileInfoResolver` —— `TerminalFilePathResolver` 已经干这事,不造平行件。
- ❌ Core 内的日期/大小格式化 —— 移到 App(那里已管本地化/toast 文案)。
- 净新增:1 个闭包注入点 + 1 个 registry setter + 1 个纯格式化函数 + popover 一个 `detailLines` 参数。

## 5. 测试与验证

- `FileDetailFormatter.lines(...)`:纯函数,一个小测试——目录跳过大小、nil 时间不产生该行、有路径必有路径行。**这是本改动唯一有分支的逻辑,配一个测试就够**,不测 locale 字符串本身。
- Copy Path 复制绝对路径:`copyToPasteboard(absolute)` 直读,逻辑显然,不单独测。
- 三绿:`swift build` + `swift test` + `scripts/check-architecture.sh`。
- 手测:`build-app-bundle.sh release` → 重启 bundle,点相对路径 / `~` / 裸词,确认标题=文件名、信息行、Copy Path 落绝对路径。

## 6. 待确认

- [ ] 时间用**相对**("2 小时前")还是绝对("2026-07-22 14:03")?默认相对。
- [ ] 是否加 `Copy Name`(复制文件名)第三动作?默认不加。

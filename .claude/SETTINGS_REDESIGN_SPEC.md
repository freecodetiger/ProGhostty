# 技术方案：设置界面重构（侧栏 + 设置项级搜索 + 字体重构）

分支：`refactor/settings-sidebar`（基于 `refactor/simplify-notifications`，含已提交的通知重构）
状态：待实现

## 0. 决策（已确认）

- **侧栏 + 详情面板**（macOS 系统设置 Ventura+ 风格），`NavigationSplitView`。
- **搜索做到设置项级别**（近似 System Settings 搜索）：命中的是"单个设置项"，点击跳到其所属分类并高亮，而非仅过滤分类。
- **字体分区本轮一起重构**（进阶/中文回退折叠）。
- **pg 控制开关移出 UI**（字段保留、默认启用、OSC 仍工作）。
- 危险操作（重置默认）移到详情底部工具条。
- 落实层级一致性、文案统一。
- 不动 `AppSettings` 持久化结构。

---

## 1. 目标架构

```
SettingsWindow (NSHostingController)
└─ SettingsRootView                     // 持 selectedItemID / searchText / 高亮态
   ├─ 顶部: 搜索框 (绑定 searchText)
   └─ NavigationSplitView
      ├─ sidebar: 分类 List(selection: $selectedCategory)
      │            搜索非空时 → 变为"搜索结果列表"(命中设置项，按分类分组)
      └─ detail:  当前分类的 Pane  (+ 底部固定工具条: 重置默认)
                  搜索结果点击 → 切到目标分类 + 滚动/高亮目标项
```

核心抽象：**设置项注册表（SettingsIndex）**——把每个可搜索设置项声明为一条 `SettingsItem`，同时驱动 (a) 搜索、(b) 分类归属、(c) 高亮锚点。这样"设置项级搜索"有单一数据源，不靠散落在视图里的硬编码。

---

## 2. 新增类型

### 2.1 分类
```swift
enum SettingsCategory: String, CaseIterable, Hashable, Identifiable {
  case terminal, appearance, font, shortcuts, notifications, about
  var id: String { rawValue }
  func title(_ t: AppText) -> String
  var systemImage: String   // terminal / paintbrush / textformat / command / bell / info.circle
}
```

### 2.2 设置项索引
```swift
struct SettingsItem: Identifiable {
  let id: String                 // 稳定锚点 id，如 "font.size"
  let category: SettingsCategory
  let title: (AppText) -> String // 用于结果列表显示
  let keywords: (AppText) -> [String] // 中英双语关键词
}

enum SettingsIndex {
  static let all: [SettingsItem]         // 静态声明全部可搜索项
  static func results(query: String, text: AppText) -> [SettingsItem]
  // 大小写/区分音不敏感；匹配 title 或任一 keyword 的子串
}
```
- 快捷键项由 `KeyboardShortcutAction.allCases` 动态展开成索引项（每个 action 一条，category `.shortcuts`）。
- 索引项 id 与详情面板里对应控件的 `.id(...)` 锚点一致，供高亮跳转。

### 2.3 高亮
- `SettingsRootView` 持 `@State highlightedItemID: String?`。
- 点击搜索结果 → 设 `selectedCategory = item.category`、`highlightedItemID = item.id`、清空或保留 searchText（建议清空并聚焦目标）。
- 目标控件用 `.id(item.id)` + `ScrollViewReader.scrollTo` 定位；高亮 = 短暂描边/背景（~1.5s 后淡出，用 `task`/animation）。

---

## 3. 视图拆分

`SettingsView.swift`（现 ~740 行）拆为：

| 文件/类型 | 职责 |
|---|---|
| `SettingsRootView`（重写现 `SettingsView`） | NavigationSplitView 容器、搜索框、侧栏、详情路由、底部工具条、高亮态 |
| `SettingsSidebar` | 分类列表 / 搜索结果列表（两态切换） |
| `TerminalSettingsPane` | 默认 shell、工作目录 |
| `AppearanceSettingsPane` | 语言、主题（跟随系统 + 亮/暗，层级缩进） |
| `FontSettingsPane` | 主字体核心 + 进阶(DisclosureGroup) + 中文回退(DisclosureGroup) + 预览 |
| `ShortcutsSettingsPane` | 快捷键录制列表（迁移现有逻辑） |
| `NotificationsSettingsPane` | 任务完成通知两级开关 + 权限提示（迁移现有） |
| `AboutSettingsPane` | 版本、检查更新 |
| `SettingsIndex` / `SettingsCategory` / `SettingsItem` | 索引与分类（可放一个 `SettingsModel.swift`） |

**复用不动**：`SettingsSection`、`SettingsRow`、`FontPreview`、`ShortcutSettingsRow`、`ShortcutRecorderHost`、`SettingsFocusResetHost`、`ShortcutRecorderState`。

---

## 4. 各分类内容（迁移映射）

以现 `SettingsView` 行号为源：
- **Terminal**：46-69（defaultShell、workingDirectory）→ 原样搬入 pane。
- **Appearance**：71-96（appLanguage segmented、theme）；**改**：亮/暗 Picker 从属"跟随系统"改为缩进18+disabled+opacity0.45（§6 一致性）。
- **Font**：98-215 **重构**（见 §5）。
- **Shortcuts**：217-241（ForEach action + 冲突提示）→ 搬入，逻辑不变。
- **Notifications**：243-274（已是两级开关+权限提示，本轮通知重构产物）→ 搬入。
- **About**：280-303，**去掉**其中的"重置默认"（294-302），版本/更新留下。
- **删除**：pgControlSection（276-278）、顶部大标题+副标题 HStack（29-42）。

---

## 5. 字体分区重构（§5.3 具体化）

现状（98-215）：左右两栏对称（主字体 | 中文回退），每栏 搜索框+"显示全部"复选框+下拉+精确名称输入+状态，底部两条 hint + 预览。10+ 控件同屏。

目标结构（纵向、层次分明）：
```
FontSettingsPane
├─ 主字体 (一等公民，始终展开)
│   ├─ 下拉选择 (含筛选;默认只列终端友好字体)
│   ├─ 字号 Slider + 数值
│   └─ 预览 FontPreview
├─ DisclosureGroup "进阶" (默认收起)
│   ├─ 搜索框 (fontSearchText)
│   ├─ "显示全部已安装字体" 复选框 (showsAllFonts)
│   └─ "精确字体名称" 输入框 + 状态标签
└─ DisclosureGroup "中文回退" (默认收起)
    ├─ 下拉 (系统回退 + 选项)
    ├─ "精确中文回退名称" 输入 + 状态
    └─ cjkFallbackHint
```
- 主字体下拉的选项仍来自 `FontManager.fontOptions`，但搜索/显示全部移入"进阶"——主区下拉默认用筛选后的终端友好集。
- `installedMonospacedFontsHint` / `cjkFallbackHint` 移到各自 DisclosureGroup 内。
- 状态标签（已安装/未安装/可能非等宽）保留。
- 搜索索引项：`font.family`(主字体)、`font.size`(字号)、`font.cjk`(中文回退)、`font.advanced`(进阶/精确名称)。

---

## 6. 层级一致性规则

抽一个复用修饰符，全设置统一"子选项依赖父开关"的表达：
```swift
extension View {
  func settingsSubordinate(enabled: Bool) -> some View {
    self.padding(.leading, 18).disabled(!enabled).opacity(enabled ? 1 : 0.45)
  }
}
```
应用点：Appearance 的亮/暗（父=跟随系统的反义，注意逻辑是 !followSystem 时可用）、Notifications 的"聚焦时也通知"（父=notificationsEnabled，已实现，改用此修饰符统一）。

---

## 7. 搜索行为（设置项级）

- 搜索框常驻侧栏顶部（或窗口顶部工具栏）。
- `searchText` 为空：侧栏 = 分类列表，详情 = 选中分类 pane。
- `searchText` 非空：侧栏 = `SettingsIndex.results(query:)` 命中项列表（按 category 分组、显示项标题 + 所属分类副标）；详情仍展示"当前 selectedCategory"或提示"从左侧选择结果"。
- 点击结果项：`selectedCategory = item.category`、`highlightedItemID = item.id`、清空 searchText、`scrollTo(item.id)`、高亮淡出。
- 匹配规则：query 归一化（小写、去空白）后，子串匹配 `title` 或任一 `keyword`；关键词中英双语都放（因 `appText` 随语言切换，`keywords(text)` 用当前语言 + 固定英文别名）。
- 无结果：侧栏显示"无匹配设置项"。

**索引清单（初版）**：
`terminal.shell` / `terminal.cwd` / `appearance.language` / `appearance.theme` / `font.family` / `font.size` / `font.cjk` / `font.advanced` / `notifications.enable` / `notifications.focused` / `about.version` / `about.updates` / 每个 `shortcut.<action>`。

---

## 8. 窗口与文案

### 8.1 窗口（AppModel.openSettingsWindow, 1051-1078）
- `setContentSize` 640×520 → **760×560**；`minSize` 560×460 → **680×480**。
- 保留 `toolbarStyle = .preference`、`styleMask`、外观应用。

### 8.2 AppText 变更
- **删**：`settingsCaption`、`pgControlSection`、`pgControlCommands`。
- **加**：`settingsSearchPlaceholder`（"Search settings"/"搜索设置"）、`fontAdvanced`（"Advanced"/"进阶"）、侧栏分类名 `notifications`（"Notifications"/"通知"）、`noSearchResults`（"No matching settings"/"无匹配设置项"）、（如底部工具条需要）沿用现有 `restoreDefaults`。
- **改**：侧栏分类统一简洁名词；`taskCompletionNotifications` 降级为通知 pane 内标题（侧栏用 `notifications`）。
- 删键后全仓 grep 确认无残留引用。

---

## 9. 实施步骤（每步 build + test + guard 绿，各一 commit）

1. **低风险文案/结构修正**（不引入侧栏）：删 pg 入口 + 顶部副标题；重置默认移出 About 到底部；Appearance/Notifications 层级统一用 `settingsSubordinate`。→ 现有单列布局上验证。
2. **抽取 6 个 `*SettingsPane` 子视图**（行为不变，仍单列容器），为侧栏铺路。
3. **引入 `SettingsCategory` + `NavigationSplitView`**：侧栏分类 + 详情路由 + 底部工具条。窗口尺寸调整。
4. **字体分区重构**（§5，DisclosureGroup）。
5. **`SettingsIndex` + 设置项级搜索 + 高亮跳转**（§2/§7）。
6. 打磨：图标、间距、高亮动画、无结果态、键盘可达性。

---

## 10. 验证

- 每步：`swift build` + `swift test` + `./scripts/check-architecture.sh`。
- 手动（build app bundle）：
  - 侧栏 6 分类切换；每项设置读写、持久化正常。
  - 搜索"字号/size/中文/shortcut"→出现设置项级结果→点击跳转+高亮。
  - 字体：主字体默认展开、进阶/中文回退折叠；改字体/字号预览更新。
  - 层级：跟随系统时亮暗置灰缩进；通知总开关关时二级置灰缩进。
  - 重置默认在底部、可用；About 只剩版本/更新。
  - pg OSC 命令仍工作（`pg ws`、`pg notify`）。
- 回归：老配置可读、改任一项能存。

---

## 11. 风险

- `NavigationSplitView` 装进 `NSHostingController` 的列宽/最小宽需实测；定 sidebar 与 detail 最小宽，避免压缩。
- `ScrollViewReader.scrollTo` + 高亮在分类切换后需等布局完成（可能要 `DispatchQueue.main.async` 或 `task`）。
- 搜索关键词随 `appLanguage` 切换——`keywords(text)` 要同时含中英，保证任一语言可搜。
- 快捷键 pane 的 `ShortcutRecorderHost`（NSViewRepresentable）换容器后确认录制/焦点正常。
- 大重构：严格按 §9 分步提交，勿一次性合并。

## 12. 开放项（默认已定，如无异议按此执行）

1. 侧栏顺序/图标：按 §1 表。
2. 搜索：设置项级（本方案）。
3. 重置默认：详情面板底部工具条。
4. 字体重构：本轮做。

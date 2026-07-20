# Plan: Soft Dark / Soft Light 主题（终端 + Title Bar + 设置页一体）

状态：已实现（`feat/soft-themes`）  
评审稿：`docs/design/soft-themes-preview.html`  
分支：`feat/soft-themes`

---

## 1. 目标

在现有 **Default Dark / Default Light** 之上增加两套 **整套预设**：

| 预设 id | 显示名 | 气质 | 色值依据 |
|---------|--------|------|----------|
| `dark` | Default Dark | 现有近黑灰 | 现状 `TerminalSurfacePalette.dark` |
| `soft-dark` | Soft Dark | 深色带蓝、柔和 | Ghostty / Atom One Dark 系 · **bg `#23272E`** |
| `light` | Default Light | 现有近纸白 | 现状 `TerminalSurfacePalette.light` |
| `soft-light` | Soft Light | 暖纸、降刺眼 | **Solarized Light** 官方配对 |

用户只选 **主题预设**，不提供单独拧背景/前景。

**一体性硬要求（本方案核心）：**

1. **终端 surface** 色板换主题  
2. **主窗口 title bar / 窗口 chrome** 与终端 **同一底色（或同源 chrome 阶）**，无缝衔接  
3. **设置窗口** 配色与当前主题 **同族**（Soft Dark 时设置页也是蓝深系，不是另一套纯中性灰）

非目标：

- 自定义取色器 / 导入主题文件 / 透明模糊  
- 改 VT ANSI 16 色表（L2 可不动；预览里示意即可）  
- 重做设置 IA 或侧栏结构  

---

## 2. 问题陈述（现状）

| 层 | 现状 | 缺口 |
|----|------|------|
| 终端 | `themeName ∈ {light, dark}` → `TerminalSurfacePalette.light/dark` | 无 Soft 预设 |
| 主窗 chrome | `applyTerminalChrome(backgroundColor: terminalBackgroundColor)` | 已跟终端 bg —— **加 Soft 后会自动跟**，需保证 Soft 色板 `background` 正确 |
| 设置页 | `usesDarkAppearance ? SettingsPalette.dark : .light` **仅 light/dark 二值** | Soft 时设置页仍是 Default 系中性灰 → **与终端/titlebar 脱节** |
| `appColorScheme` / `usesDarkAppearance` | `themeName == "light"` 才 light，否则 dark | Soft 需归入 light/dark **族**，否则系统控件外观会错 |
| 跟随系统 | `effectiveThemeName` 只回 `light`/`dark` | 跟随系统时 Soft 偏好如何保留（见 §4） |

根因：主题只影响 **终端 palette** 与 **二值 dark 标志**；**设置 chrome 未按 `themeName` 分预设**。

---

## 3. 已定配色（评审稿）

### 3.1 Soft Dark（Ghostty / One Dark 气质，略深）

| 角色 | Hex | 用途 |
|------|-----|------|
| background | `#23272E` | 终端底、**主窗 titlebar/content chrome** |
| foreground | `#ABB2BF` | 默认字 |
| faintForeground | `#5C6370` | 弱化字 |
| cursorBackground | `#ABB2BF` | 光标 |
| cursorForeground | `#23272E` | 光标上字（或 `#1B1F24`） |
| selection 视觉 | 半透明叠在 `#353B45` 一带 | 现结构无独立 selection bg 字段则沿用现逻辑 + 调 `selectionForeground` |
| splitDivider | 冷白 ~12% on 蓝深 | 分屏线 |
| chrome 抬升（设置） | `#1B1F24` / `#2A3038` 等 | 设置 window / control / footer（同源） |

### 3.2 Soft Light（Solarized Light）

| 角色 | Hex | 用途 |
|------|-----|------|
| background | `#FDF6E3` base3 | 终端底、**主窗 chrome** |
| foreground | `#657B83` base00 | 默认字 |
| faintForeground | `#93A1A1` base1 | 弱化 |
| cursorBackground | `#586E75` base01 | 光标 |
| cursorForeground | `#FDF6E3` | |
| chrome 抬升 | `#EEE8D5` base2 | 设置控件区 / titlebar 次级 |
| 设置字色 | base01 / base00 / base1 | primary / body / secondary |

### 3.3 Default 不变

保持现有 `calibratedWhite` dark/light，避免迁移惊吓。

### 3.4 验收对比

落地前用 [WebAIM](https://webaim.org/resources/contrastchecker/) 核：

- Soft Dark：`#ABB2BF` on `#23272E` ≥ 4.5:1  
- Soft Light：`#657B83` on `#FDF6E3` ≥ 4.5:1（Solarized 官方 body 对偏柔，若未过 AA 则 fg 略压暗至过线，气质优先贴近官方）

---

## 4. 产品 / UX

### 4.1 设置 · 外观

- **跟随系统**：开 → 系统 light/dark **族**；族内使用用户上次在该族选中的预设（见 4.2）  
- **关闭跟随系统**：四选一（或分组：Dark 下 Default/Soft，Light 下 Default/Soft）  
- 控件形态建议：  
  - 第一行：跟随系统 Toggle（现状）  
  - 第二行：Dark 预设 `Default | Soft`  
  - 第三行：Light 预设 `Default | Soft`  
  - 或单个 `Picker` 四项 + 副标题说明 Soft 气质  
- 文案：`Soft Dark` / `Soft Light`（中文可「柔和深色 / 柔和浅色」）

### 4.2 跟随系统时 Soft 偏好

推荐 **最小状态**（少加字段）：

- `themeName` 存具体预设：`dark` | `soft-dark` | `light` | `soft-light`  
- 跟随系统 ON 时：  
  - 系统 dark → 用「当前 dark 族偏好」：若 `themeName` 是 soft-dark/dark 则用它，否则默认 `dark`（或记住 `preferredDarkTheme` —— **v1 可简化为**：跟随系统时 **强制 Default 族** `light`/`dark`，Soft 仅手动选；  
  - **更佳 v1**：增加  
    - `preferredDarkTheme: dark|soft-dark`（默认 dark）  
    - `preferredLightTheme: light|soft-light`（默认 light）  
    - 跟随系统时 `effectiveThemeName = systemIsLight ? preferredLight : preferredDark`  
    - 手动模式仍写 `themeName`  

**本方案拍板（实现简单且一体）：**

- 仅扩展 `themeName` 四值；  
- `followSystemAppearance == true` 时：  
  `effective = system light ? (themeName 是 light 族 ? themeName : preferred 映射)`  
  简化实现：跟随系统时映射到 **同族 Soft 若用户上次选过 Soft，否则 Default**：

```
if followSystem {
  let darkPref = themeName == "soft-dark" || lastDarkWasSoft ? "soft-dark" : "dark"
  // 实际：用 themeName 的族偏好持久化
  effective = systemLight
    ? (themeName.hasPrefix("soft") && themeName.contains("light") || themeName == "soft-light"
        ? "soft-light" : themeName == "light" || !isDarkFamily(themeName) ? "light" : "soft-light" if soft light preferred…)
}
```

**更干净的 v1 拍板：**

| `followSystem` | 行为 |
|----------------|------|
| false | `effectiveThemeName = themeName`（四选一） |
| true | `effectiveThemeName = systemIsLight ? lightFamilyPick : darkFamilyPick` |

其中 `lightFamilyPick` / `darkFamilyPick` 由 `themeName` 推导并回写：

- 用户在 Soft Light 时打开跟随系统 → light 族偏好 = soft-light  
- 系统切 dark → soft-dark（若 dark 族偏好是 soft）或 dark  

持久化最小集：**只存 `themeName` 四值 + follow 开关**。  
跟随 ON 时 UI 仍显示「Dark: Default|Soft」「Light: Default|Soft」两个分段，写入时更新对应族在 `themeName` 中的编码——或存两个 optional。  

**推荐实现字段（清晰）：**

```swift
// AppSettings
var themeName: String              // 手动模式当前：四选一
var followSystemAppearance: Bool
var softDarkPreferred: Bool        // 默认 false；跟随系统 dark 时用 soft-dark
var softLightPreferred: Bool       // 默认 false
```

- 手动：改 Picker → `themeName`，并同步 `softDarkPreferred` / `softLightPreferred`  
- 跟随：`effective = systemLight ? (softLightPreferred ? soft-light : light) : (softDarkPreferred ? soft-dark : dark)`  

设置 UI：跟随 ON 时两个 Soft 勾选/分段仍可改「族内偏好」。

### 4.3 预览（可选同 PR）

外观页小色块 4 个，点击即选；非必须，有则更好。

---

## 5. 技术设计

### 5.1 单一解析入口

```
effectiveThemeName: String   // dark | soft-dark | light | soft-light
  → terminalPalette: TerminalSurfacePalette
  → isDarkFamily: Bool        // soft-dark, dark → true
  → settingsThemePalette: ProGhosttySettingsThemeColors
  → terminalBackgroundColor   // = terminalPalette.background  // titlebar 已用此
  → appColorScheme / window NSAppearance via isDarkFamily
```

**禁止** 再写 `themeName == "light" ? … : .dark` 这种二值分叉；全部走 `ThemeManager.palette(for:)` / `settingsPalette(for:)`。

### 5.2 ThemeManager（Core 或 App）

放 **Core** 若 palette 纯值无 AppKit 政策问题——现状 `TerminalSurfacePalette` 已在 Core 用 `NSColor`。  
扩展：

```swift
enum ThemeManager {
  static let builtInThemes = ["light", "dark", "soft-light", "soft-dark"]
  static func normalizedThemeName(_:) -> String
  static func isDarkFamily(_ name: String) -> Bool
  static func terminalPalette(for name: String) -> TerminalSurfacePalette
}
```

`TerminalSurfacePalette` 增加：

```swift
static let softDark = ... // #23272E 等
static let softLight = ... // Solarized
```

### 5.3 设置页 palette

`ProGhosttySettingsThemePalette` 从 2 套扩为 4 套（或 `settingsPalette(for themeName:)`）：

| theme | window / control / footer 原则 |
|-------|--------------------------------|
| dark / light | **保持现状** calibratedWhite |
| soft-dark | 同源蓝深：window ≈ `#23272E` 或略抬 `#1B1F24`；control 略浅 `#2A3038`；text 用 Soft Dark fg/faint |
| soft-light | window ≈ `#FDF6E3`；control/footer ≈ `#EEE8D5`；text Solarized base |

`AppModel.settingsThemePalette` → 按 `effectiveThemeName` 取，**不是**只按 `usesDarkAppearance`。

### 5.4 Title bar 一体

现状路径已正确：

```
applyTerminalAppearance()
  → ProGhosttyWindowAppearance.applyTerminalChrome(
       backgroundColor: terminalBackgroundColor,  // palette.background
       usesDarkAppearance: isDarkFamily
     )
```

实现 Soft 后 **无需新 API**；检查：

- `WorkspaceTitlebarView` 传入的 `backgroundColor` 仍是 `terminalBackgroundColor`  
- Toast 仍可按 `isDarkFamily` 选 success/info/error（或以后 per-theme；v1 二值即可）  
- 分屏 divider = `terminalPalette.splitDivider`  

设置窗：

```
applyConfigurationChrome(backgroundColor: settingsThemePalette.windowBackground, usesDarkAppearance: isDarkFamily)
```

保证 Soft 时设置 titlebar 与设置内容区同色族。

### 5.5 AppModel 关键改点

| 成员 | 改法 |
|------|------|
| `terminalPalette` | `ThemeManager.terminalPalette(for: effectiveThemeName)` |
| `usesDarkAppearance` | `ThemeManager.isDarkFamily(effectiveThemeName)` |
| `appColorScheme` | 手动时 `isDarkFamily ? .dark : .light`；跟随 nil |
| `settingsThemePalette` | 按 effective 四套 |
| `effectiveThemeName` | 纳入 soft 偏好（§4.2） |

### 5.6 设置 UI

- `SettingsView` appearance pane：四主题或族内 Soft 开关  
- `AppText`：softDark / softLight 中英  
- `SettingsModel` 搜索关键词：soft、柔和、solarized、nord 不必提  

### 5.7 迁移

- 旧 `themeName: light|dark` 不变  
- 未知 id → `normalized` → `dark`  
- 新字段 `softDarkPreferred` / `softLightPreferred`：`decodeIfPresent ?? false`  

---

## 6. 实现步骤

### Step 1 — 色板 + ThemeManager

- `TerminalSurfacePalette.softDark` / `.softLight`  
- `ThemeManager` 四主题 + `isDarkFamily` + `terminalPalette(for:)`  
- 单测：normalize、family、palette 非 nil / 关键 hex 分量  

### Step 2 — AppModel 解析统一

- 替换所有 light/dark 二值终端分支  
- `effectiveThemeName` + soft 偏好字段  
- 确认 `applyTerminalAppearance` / 设置 chrome 走新 palette  

### Step 3 — 设置 UI

- 外观页选 Soft  
- 文案  
- 手测：切换主题 titlebar 无缝、设置页同族  

### Step 4 — 文档 / 预览

- HTML 稿保持与代码一致（已是 `#23272E` + Solarized）  
- 本 plan 勾选进度  

每步：`swift build` + `swift test` + `build-app-bundle` 手测。

---

## 7. 手测清单

1. Default Dark / Light：与现网一致  
2. Soft Dark：终端底 `#23272E` 感；**titlebar 同色无缝**；分屏线可见  
3. Soft Light：暖纸；titlebar 一体  
4. 设置页在 Soft Dark/Light 下 **不是** Default 中性灰，而是同族  
5. 跟随系统：切 macOS 亮暗，族内 Soft 偏好保持  
6. 重启后主题偏好仍在  
7. Toast / 选区 / 光标在 Soft 下可读  
8. `scripts/check-architecture.sh` 绿  

---

## 8. 风险

| 风险 | 缓解 |
|------|------|
| Soft Light 官方 fg 对比偏柔 | WebAIM；未过 AA 则微调 fg 明度 |
| 设置页控件系统色与自定义底冲突 | 设 `window.appearance` darkAqua/aqua 与 family 一致；关键面用显式 Color |
| 跟随系统 × Soft 状态爆炸 | 用 softDarkPreferred / softLightPreferred 两布尔 |
| 仅改终端忘设置 | Step 2 强制 settingsPalette(for theme) 单测 |

---

## 9. 明确不做（ponytail）

- 不引入完整主题文件格式  
- 不改 ANSI 16 除非后续单开  
- 不把 Settings 色板塞进 Core 若仅 App 用——可与 `ProGhosttySettingsThemePalette` 同文件扩 4 套  
- 不自动迁移用户到 Soft  

---

## 10. 验收

- [x] 四主题可选，Default 行为不变  
- [x] Soft Dark/Light 色值对齐本 plan §3  
- [x] **主窗 titlebar 与终端背景一体**（`terminalPalette.background`）  
- [x] **设置窗 chrome 与当前主题同族**（`ProGhosttySettingsThemePalette.palette(for:)`）  
- [x] 跟随系统 + Soft 偏好正确（`softDarkPreferred` / `softLightPreferred`）  
- [x] 测试与架构守卫绿  
- [x] HTML 稿与代码一致（Soft Dark `#23272E` · Soft Light Solarized） 

---

## 11. 参考

- 评审 HTML：`docs/design/soft-themes-preview.html`  
- 终端色板：`TerminalSurfaceStyle.swift` · `TerminalSurfacePalette`  
- 主题枚举：`ThemeManager` in `AppSettings.swift`  
- 主窗/设置涂色：`ProGhosttyWindowAppearance` · `AppModel.applyTerminalAppearance`  
- 设置色：`ProGhosttySettingsThemePalette`  
- Ghostty / One Dark 气质底：`#23272E`（自 `#282C34` 压深）  
- Solarized Light：https://ethanschoonover.com/solarized/  
- WCAG 对比：https://www.w3.org/WAI/WCAG21/Understanding/contrast-minimum.html  

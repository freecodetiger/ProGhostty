import AppKit
import ProGhosttyCore
import SwiftUI

private struct PluginUsageInstruction: Hashable {
  var title: String
  var body: String
}

struct PluginManagerView: View {
  @EnvironmentObject private var model: AppModel
  @StateObject private var viewModel = ShellEnhancementsViewModel()
  @State private var selectedPluginID: String?
  @State private var isRollbackConfirmationPresented = false
  @State private var showsReloadCommand = false
  @State private var reloadCommandCopied = false

  private let reloadCommand = "source \"$HOME/.your-terminal/shell/zshrc\""

  var body: some View {
    let text = model.appText

    VStack(spacing: 0) {
      header(text)

      Divider()
        .opacity(0.28)

      HStack(spacing: 0) {
        pluginSidebar(text)
          .frame(width: 290)

        Divider()
          .opacity(0.28)

        detailPane(text)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .background(Color(nsColor: .windowBackgroundColor).opacity(0.78))
    .task {
      await viewModel.scanNow()
      selectFirstPluginIfNeeded()
      consumeRequestedPlan()
    }
    .onChange(of: viewModel.plugins) { _ in
      selectFirstPluginIfNeeded()
    }
    .onChange(of: model.requestedPluginPlanID) { _ in
      consumeRequestedPlan()
    }
    .onChange(of: model.requestedPluginScanToken) { _ in
      viewModel.scan()
    }
    .sheet(item: $viewModel.selectedPlan) { plan in
      PluginInstallPlanView(plan: plan, text: text, isApplying: viewModel.isApplying) {
        viewModel.applySelectedPlan()
      }
    }
    .onChange(of: viewModel.appliedPlanToken) { _ in
      showsReloadCommand = true
      reloadCommandCopied = false
    }
    .sheet(isPresented: $isRollbackConfirmationPresented) {
      if let manifest = viewModel.latestRollbackManifest {
        RollbackConfirmationView(manifest: manifest, text: text, isApplying: viewModel.isApplying) {
          viewModel.rollbackLastChange()
        }
      }
    }
  }

  private var orderedPlugins: [DetectedShellPlugin] {
    viewModel.plugins.sorted { lhs, rhs in
      if statusRank(lhs.status) != statusRank(rhs.status) {
        return statusRank(lhs.status) < statusRank(rhs.status)
      }
      if lhs.category != rhs.category {
        return categoryRank(lhs.category) < categoryRank(rhs.category)
      }
      return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }
  }

  private var selectedPlugin: DetectedShellPlugin? {
    guard let selectedPluginID else { return nil }
    return orderedPlugins.first { $0.id == selectedPluginID }
  }

  private func header(_ text: AppText) -> some View {
    HStack(alignment: .center, spacing: 12) {
      VStack(alignment: .leading, spacing: 4) {
        Text(text.shellEnhancements)
          .font(.system(size: 14, weight: .semibold))
        Text(text.shellEnhancementsCaption)
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }

      Spacer()

      if viewModel.isScanning || viewModel.isApplying {
        ProgressView()
          .controlSize(.small)
          .frame(width: 28, height: 28)
      }

      if viewModel.latestRollbackManifest != nil {
        Button(text.rollback) {
          isRollbackConfirmationPresented = true
        }
        .font(.system(size: 12, weight: .medium))
        .buttonStyle(.borderless)
        .disabled(viewModel.isApplying)
      }

      Button {
        viewModel.scan()
      } label: {
        Image(systemName: "arrow.clockwise")
          .font(.system(size: 13, weight: .medium))
          .frame(width: 28, height: 28)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .disabled(viewModel.isScanning)
      .help(text.refresh)
    }
    .padding(.leading, 18)
    .padding(.trailing, 16)
    .padding(.vertical, 14)
  }

  private func pluginSidebar(_ text: AppText) -> some View {
    ScrollView {
      LazyVStack(spacing: 6) {
        ForEach(orderedPlugins) { plugin in
          PluginSidebarRow(
            plugin: plugin,
            isSelected: selectedPluginID == plugin.id,
            isRecommended: viewModel.recommendations.contains { $0.id == plugin.id },
            statusText: statusTitle(plugin.status, text: text),
            statusColor: statusColor(plugin.status),
            categoryText: categoryTitle(plugin.category, text: text),
            recommendedText: text.recommended
          ) {
            selectedPluginID = plugin.id
          }
        }
      }
      .padding(10)
    }
    .background(Color(nsColor: .controlBackgroundColor).opacity(0.34))
  }

  @ViewBuilder
  private func detailPane(_ text: AppText) -> some View {
    if let plugin = selectedPlugin {
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          detailHeader(plugin, text: text)
          metadataGrid(plugin, text: text)

          detailSection(text.description) {
            Text(pluginCopy(plugin.definitionId, text: text).detail)
              .font(.system(size: 12))
              .foregroundStyle(.secondary)
              .lineSpacing(2)
              .fixedSize(horizontal: false, vertical: true)
          }

          if !plugin.detectedPaths.isEmpty {
            detailSection(text.detectedPaths) {
              VStack(alignment: .leading, spacing: 6) {
                ForEach(plugin.detectedPaths, id: \.self) { path in
                  Text(path)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(2)
                }
              }
            }
          }

          if !plugin.issues.isEmpty {
            detailSection(text.issues) {
              VStack(alignment: .leading, spacing: 8) {
                ForEach(plugin.issues) { issue in
                  HStack(alignment: .top, spacing: 8) {
                    Circle()
                      .fill(issue.severity == .error ? Color.red : Color.secondary.opacity(0.65))
                      .frame(width: 6, height: 6)
                      .padding(.top, 5)
                    Text(localizedIssue(issue, text: text))
                      .font(.system(size: 12))
                      .foregroundStyle(issue.severity == .error ? .red : .secondary)
                      .fixedSize(horizontal: false, vertical: true)
                  }
                }
              }
            }
          }

          detailSection(text.usageInstructions) {
            VStack(alignment: .leading, spacing: 7) {
              ForEach(usageInstructions(plugin.definitionId, text: text), id: \.self) { line in
                HStack(alignment: .top, spacing: 8) {
                  Circle()
                    .fill(Color.secondary.opacity(0.65))
                    .frame(width: 4, height: 4)
                    .padding(.top, 7)
                  VStack(alignment: .leading, spacing: 2) {
                    Text(line.title)
                      .font(.system(size: 12, weight: .medium))
                    Text(line.body)
                      .font(.system(size: 12))
                      .foregroundStyle(.secondary)
                      .fixedSize(horizontal: false, vertical: true)
                  }
                }
              }
            }
          }

          if let message = viewModel.message {
            Text(localizedMessage(message, text: text))
              .font(.system(size: 11))
              .foregroundStyle(.secondary)
              .padding(.top, 2)
              .textSelection(.enabled)
          }

          if showsReloadCommand {
            reloadCommandView(text)
          }
        }
        .padding(18)
      }
    } else {
      VStack(spacing: 8) {
        Image(systemName: "puzzlepiece.extension")
          .font(.system(size: 28, weight: .regular))
          .foregroundStyle(.secondary)
        Text(text.selectShellEnhancement)
          .font(.system(size: 13, weight: .medium))
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private func detailHeader(_ plugin: DetectedShellPlugin, text: AppText) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .firstTextBaseline, spacing: 10) {
        Text(plugin.name)
          .font(.system(size: 18, weight: .semibold))
          .lineLimit(1)

        if viewModel.recommendations.contains(where: { $0.id == plugin.id }) {
          Text(text.recommended)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Color.primary.opacity(0.06))
            .clipShape(Capsule())
        }

        Spacer()
      }

      Text(pluginCopy(plugin.definitionId, text: text).summary)
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      HStack(spacing: 10) {
        if canInstall(plugin) {
          Button(text.install) {
            viewModel.previewInstall(pluginID: plugin.definitionId)
          }
          .keyboardShortcut(.defaultAction)
          .disabled(viewModel.applyingPluginIDs.contains(plugin.definitionId))
        }

        if canUninstall(plugin) {
          Button(text.uninstall) {
            viewModel.previewUninstall(pluginID: plugin.definitionId)
          }
          .disabled(viewModel.applyingPluginIDs.contains(plugin.definitionId))
        }

        if viewModel.applyingPluginIDs.contains(plugin.definitionId) {
          Text(text.installing)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }

        if !canInstall(plugin), !canUninstall(plugin) {
          Text(text.noPlanAvailable)
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
        }
      }
    }
  }

  private func metadataGrid(_ plugin: DetectedShellPlugin, text: AppText) -> some View {
    VStack(spacing: 8) {
      MetadataRow(title: text.status, value: statusTitle(plugin.status, text: text), color: statusColor(plugin.status))
      MetadataRow(title: text.category, value: categoryTitle(plugin.category, text: text), color: .secondary)
      MetadataRow(title: text.source, value: sourceTitle(plugin.source, text: text), color: .secondary)
      MetadataRow(title: text.risk, value: riskTitle(plugin.riskLevel, text: text), color: riskColor(plugin.riskLevel))
    }
    .padding(12)
    .background(Color(nsColor: .textBackgroundColor).opacity(0.55))
    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
  }

  private func detailSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title)
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.secondary)
      content()
    }
  }

  private func reloadCommandView(_ text: AppText) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(text.pluginReloadCommandHint)
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      HStack(spacing: 8) {
        Text(reloadCommand)
          .font(.system(size: 11, design: .monospaced))
          .foregroundStyle(.primary)
          .lineLimit(1)
          .truncationMode(.middle)

        if reloadCommandCopied {
          Text(text.pluginReloadCommandCopied)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
        }
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 7)
      .background(Color.primary.opacity(0.055))
      .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
      .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
      .onTapGesture {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(reloadCommand, forType: .string)
        reloadCommandCopied = true
      }
      .help(reloadCommand)
    }
  }

  private func canInstall(_ plugin: DetectedShellPlugin) -> Bool {
    guard let definition = ShellPluginCatalog.definition(id: plugin.definitionId),
      !definition.installCommands.isEmpty
    else {
      return false
    }
    if plugin.status == .notInstalled {
      return true
    }
    return plugin.status == .installedButInactive && !definition.activationSnippets.isEmpty
  }

  private func canUninstall(_ plugin: DetectedShellPlugin) -> Bool {
    guard let definition = ShellPluginCatalog.definition(id: plugin.definitionId),
      !definition.installCommands.isEmpty
    else {
      return false
    }
    return plugin.status == .installed || plugin.status == .activeManaged || plugin.status == .installedButInactive || plugin.source == .homebrew || plugin.source == .binaryPath
  }

  private func consumeRequestedPlan() {
    guard let pluginID = model.requestedPluginPlanID else { return }
    selectedPluginID = pluginID
    viewModel.previewInstall(pluginID: pluginID)
    model.requestedPluginPlanID = nil
  }

  private func selectFirstPluginIfNeeded() {
    if selectedPlugin == nil {
      selectedPluginID = orderedPlugins.first?.id
    }
  }

  private func pluginCopy(_ id: String, text: AppText) -> (summary: String, detail: String) {
    switch id {
    case "zsh-autosuggestions":
      return (
        text.localized("Inline suggestions for zsh based on your history.", "基于历史记录为 zsh 提供行内建议。"),
        text.localized(
          "Shows a muted completion after the cursor while you type. ProGhostty only installs the Homebrew package and sources its zsh file from the managed shell module, so your existing ~/.zshrc remains clean.",
          "输入命令时在光标后显示低调的补全建议。ProGhostty 只通过 Homebrew 安装，并从受管理的 Shell 模块 source 对应 zsh 文件，不把插件配置直接写入 ~/.zshrc。"
        )
      )
    case "zsh-syntax-highlighting":
      return (
        text.localized("Interactive command syntax coloring for zsh.", "为交互式 zsh 命令提供语法着色。"),
        text.localized(
          "Highlights valid commands, paths, quotes, and common mistakes before you press Return. Its source line is kept after other zsh plugins because zsh-syntax-highlighting must run last.",
          "在按下回车前标记命令、路径、引号和常见错误。它的 source 行会被放在其他 zsh 插件之后，因为 zsh-syntax-highlighting 必须最后加载。"
        )
      )
    case "fzf":
      return (
        text.localized("A fuzzy finder for files, history, and interactive shell workflows.", "用于文件、历史和交互式 Shell 工作流的模糊查找器。"),
        text.localized(
          "Installs the Homebrew package. ProGhostty keeps the shell side minimal; you can continue using your own fzf key bindings or add managed activation later.",
          "安装 Homebrew 包。ProGhostty 保持 Shell 侧配置克制，你可以继续使用已有 fzf 快捷键，也可以之后再加入受管理的激活配置。"
        )
      )
    case "zoxide":
      return (
        text.localized("A smarter cd that learns where you actually go.", "一个会学习常用目录的智能 cd。"),
        text.localized(
          "Adds zoxide through Homebrew and activates it from the navigation module with zoxide init zsh. It fits terminal workflows without replacing your shell.",
          "通过 Homebrew 安装 zoxide，并在 navigation 模块中用 zoxide init zsh 激活。它融入终端工作流，但不替代你的 Shell。"
        )
      )
    case "ripgrep":
      return (
        text.localized("Fast recursive text search, exposed as rg.", "快速递归文本搜索工具，命令为 rg。"),
        text.localized(
          "Installs the command line binary only. No shell activation is required, so the install plan contains Homebrew and backup metadata but no heavy rc configuration.",
          "只安装命令行二进制，不需要 Shell 激活。因此安装计划包含 Homebrew 命令和备份元数据，不写入大量 rc 配置。"
        )
      )
    case "fd":
      return (
        text.localized("Fast file search with a friendlier command line interface.", "更快、更友好的文件搜索命令。"),
        text.localized(
          "Installs the fd binary for search-heavy terminal sessions. It does not need shell integration and stays independent from your prompt and history setup.",
          "安装 fd 二进制，适合搜索密集的终端会话。它不需要 Shell 集成，也不会影响你的提示符和历史配置。"
        )
      )
    case "starship":
      return (
        text.localized("A fast cross-shell prompt with a single config file.", "快速的跨 Shell 提示符，使用单独配置文件。"),
        text.localized(
          "Installs starship and activates it from the prompt module. Prompt plugins are treated as mutually exclusive, so conflicts with powerlevel10k or manual prompt setup are surfaced before you apply changes.",
          "安装 starship，并从 prompt 模块激活。提示符插件被视为互斥；如果和 powerlevel10k 或手写提示符配置冲突，会在应用前展示出来。"
        )
      )
    case "powerlevel10k":
      return (
        text.localized("A feature-rich zsh prompt detected for compatibility.", "为兼容性检测的功能型 zsh 提示符。"),
        text.localized(
          "ProGhostty detects powerlevel10k because many existing terminals use it, but this version does not install or take over it. Keeping prompt ownership explicit avoids breaking existing dotfiles.",
          "ProGhostty 会检测 powerlevel10k，因为很多现有终端生态都在使用它，但当前版本不会安装或接管它。保持提示符归属明确，可以避免破坏已有 dotfiles。"
        )
      )
    case "atuin":
      return (
        text.localized("Searchable shell history with optional sync.", "可搜索、可选同步的 Shell 历史。"),
        text.localized(
          "Atuin is powerful, but it changes shell history behavior, key bindings, and storage. ProGhostty marks it as higher risk and never recommends it by default.",
          "Atuin 很强，但会改变 Shell 历史行为、快捷键和存储方式。ProGhostty 将它标记为较高风险，默认不会主动推荐。"
        )
      )
    case "gh":
      return (
        text.localized("GitHub's official CLI for repository workflows.", "GitHub 官方 CLI，用于仓库工作流。"),
        text.localized(
          "Installs the gh binary only. Authentication, aliases, and GitHub account state remain owned by the existing CLI ecosystem.",
          "只安装 gh 二进制。认证、别名和 GitHub 账户状态继续由现有 CLI 生态负责。"
        )
      )
    case "lazygit":
      return (
        text.localized("A terminal UI for day-to-day Git operations.", "用于日常 Git 操作的终端 UI。"),
        text.localized(
          "Installs lazygit as a standalone binary. It does not require shell activation and keeps ProGhostty focused on running terminal sessions.",
          "安装 lazygit 独立二进制。它不需要 Shell 激活，让 ProGhostty 继续专注于运行终端会话。"
        )
      )
    case "delta":
      return (
        text.localized("Readable Git diffs for command line review.", "让命令行 Git diff 更易读。"),
        text.localized(
          "Installs git-delta. ProGhostty does not force Git config changes; you decide whether to set it as your pager in your own Git configuration.",
          "安装 git-delta。ProGhostty 不强制修改 Git 配置；是否把它设为 pager 由你自己的 Git 配置决定。"
        )
      )
    case "nvm", "fnm", "pyenv", "jenv", "sdkman", "direnv":
      return (
        text.localized("Runtime environment tooling detected from your shell ecosystem.", "从现有 Shell 生态中检测运行时环境工具。"),
        text.localized(
          "Runtime managers are deliberately detect-only here. They often own PATH, shims, hooks, and project-local behavior, so ProGhostty reports their status without installing or rewriting their rc setup.",
          "运行时管理器在这里刻意只做检测。它们通常管理 PATH、shims、hooks 和项目级行为，因此 ProGhostty 只报告状态，不安装或重写它们的 rc 配置。"
        )
      )
    default:
      let description = ShellPluginCatalog.definition(id: id)?.description ?? id
      return (description, description)
    }
  }

  private func usageInstructions(_ id: String, text: AppText) -> [PluginUsageInstruction] {
    switch id {
    case "zsh-autosuggestions":
      return [
        PluginUsageInstruction(
          title: text.localized("After install", "安装后"),
          body: text.localized("Open a new ProGhostty terminal session so zsh reads the managed shell module.", "打开新的 ProGhostty 终端会话，让 zsh 读取受管理的 shell 模块。")
        ),
        PluginUsageInstruction(
          title: text.localized("How it appears", "呈现方式"),
          body: text.localized("When you type a command that matches your zsh history, a muted suggestion appears after the cursor.", "当输入内容匹配 zsh 历史命令时，光标后会出现低明度的建议文本。")
        ),
        PluginUsageInstruction(
          title: text.localized("Accepting suggestions", "接受建议"),
          body: text.localized("Use your existing zsh-autosuggestions binding, commonly Right Arrow or Ctrl+F depending on your shell setup.", "使用你现有的 zsh-autosuggestions 按键，通常是右方向键或 Ctrl+F，具体取决于你的 shell 配置。")
        ),
        PluginUsageInstruction(
          title: text.localized("Configuration boundary", "配置边界"),
          body: text.localized("ProGhostty only sources the plugin from ~/.your-terminal/shell/; it does not rewrite your aliases or prompt.", "ProGhostty 只从 ~/.your-terminal/shell/ source 插件，不重写你的 alias 或 prompt。")
        ),
      ]
    case "zsh-syntax-highlighting":
      return [
        PluginUsageInstruction(
          title: text.localized("After install", "安装后"),
          body: text.localized("Open a new terminal session. Highlighting is applied by zsh before commands are submitted.", "打开新的终端会话。高亮由 zsh 在命令提交前应用。")
        ),
        PluginUsageInstruction(
          title: text.localized("What changes", "变化内容"),
          body: text.localized("Commands, paths, strings, and obvious syntax mistakes are colored while you type.", "输入时会对命令、路径、字符串和明显语法错误进行着色。")
        ),
        PluginUsageInstruction(
          title: text.localized("Load order", "加载顺序"),
          body: text.localized("This plugin must be sourced last. ProGhostty keeps its source line after the managed module list.", "这个插件必须最后 source。ProGhostty 会把它放在受管理模块列表之后。")
        ),
        PluginUsageInstruction(
          title: text.localized("Compatibility", "兼容性"),
          body: text.localized("If another framework already loads syntax highlighting, keep only one activation source to avoid duplicate hooks.", "如果其他框架已经加载语法高亮，请只保留一个激活来源，避免重复 hook。")
        ),
      ]
    case "fzf":
      return [
        PluginUsageInstruction(
          title: text.localized("Direct use", "直接使用"),
          body: text.localized("Run fzf to open the fuzzy finder from the current directory or pipe command output into it.", "运行 fzf 可从当前目录打开模糊查找器，也可以把其他命令输出 pipe 给它。")
        ),
        PluginUsageInstruction(
          title: text.localized("Key bindings", "快捷键"),
          body: text.localized("Your existing shell key bindings remain the source of truth. ProGhostty does not replace Ctrl+R, file search, or completion bindings.", "已有 shell 快捷键仍然是唯一来源。ProGhostty 不替换 Ctrl+R、文件搜索或补全绑定。")
        ),
        PluginUsageInstruction(
          title: text.localized("Configuration boundary", "配置边界"),
          body: text.localized("The default install is binary-only unless you explicitly manage shell activation elsewhere.", "默认安装仅提供二进制工具，除非你在其他地方显式管理 shell 激活。")
        ),
      ]
    case "zoxide":
      return [
        PluginUsageInstruction(
          title: text.localized("After install", "安装后"),
          body: text.localized("Open a new terminal session so zoxide init zsh is loaded from the managed navigation module.", "打开新的终端会话，让 zoxide init zsh 从受管理的 navigation 模块加载。")
        ),
        PluginUsageInstruction(
          title: text.localized("Basic command", "基本命令"),
          body: text.localized("Use z <partial-path> to jump to directories after zoxide has learned where you go.", "zoxide 学习过你的目录访问后，可以用 z <partial-path> 快速跳转。")
        ),
        PluginUsageInstruction(
          title: text.localized("Learning behavior", "学习方式"),
          body: text.localized("It improves as you cd around. Early results may be sparse until enough directory history exists.", "它会随着你 cd 到不同目录逐步学习。历史不足时，早期结果可能较少。")
        ),
      ]
    case "starship":
      return [
        PluginUsageInstruction(
          title: text.localized("After install", "安装后"),
          body: text.localized("Open a new terminal session. Starship initializes from the managed prompt module.", "打开新的终端会话。Starship 会从受管理的 prompt 模块初始化。")
        ),
        PluginUsageInstruction(
          title: text.localized("Configuration", "配置"),
          body: text.localized("Customize the prompt in ~/.config/starship.toml. ProGhostty does not generate prompt themes for you.", "在 ~/.config/starship.toml 自定义提示符。ProGhostty 不替你生成 prompt 主题。")
        ),
        PluginUsageInstruction(
          title: text.localized("Conflict rule", "冲突规则"),
          body: text.localized("Keep one prompt framework active. Running starship with powerlevel10k or manual prompt hooks can produce duplicate prompts.", "只保留一个 prompt 框架。Starship 与 powerlevel10k 或手写 prompt hook 并存可能导致重复提示符。")
        ),
      ]
    case "ripgrep":
      return [
        PluginUsageInstruction(
          title: text.localized("Basic command", "基本命令"),
          body: text.localized("Run rg <pattern> from any terminal session to recursively search text.", "在任意终端会话中运行 rg <pattern> 递归搜索文本。")
        ),
        PluginUsageInstruction(
          title: text.localized("Common workflow", "常见用法"),
          body: text.localized("Use rg TODO, rg \"functionName\", or rg --files to inspect a project quickly.", "可用 rg TODO、rg \"functionName\" 或 rg --files 快速检查项目。")
        ),
        PluginUsageInstruction(
          title: text.localized("Configuration boundary", "配置边界"),
          body: text.localized("This is a binary tool. No shell activation or ~/.zshrc change is required.", "这是二进制工具，不需要 shell 激活，也不需要修改 ~/.zshrc。")
        ),
      ]
    case "fd":
      return [
        PluginUsageInstruction(
          title: text.localized("Basic command", "基本命令"),
          body: text.localized("Run fd <name> to find files and directories with a concise, modern interface.", "运行 fd <name> 用更简洁的现代命令搜索文件和目录。")
        ),
        PluginUsageInstruction(
          title: text.localized("Common workflow", "常见用法"),
          body: text.localized("Combine it with fzf or command substitution when you want interactive file selection.", "需要交互式文件选择时，可以与 fzf 或命令替换组合使用。")
        ),
        PluginUsageInstruction(
          title: text.localized("Configuration boundary", "配置边界"),
          body: text.localized("This is a binary-only install. It should show as installed, not installed-but-inactive.", "这是仅二进制安装。它应该显示为已安装，而不是已安装但未启用。")
        ),
      ]
    case "gh":
      return [
        PluginUsageInstruction(
          title: text.localized("Authentication", "认证"),
          body: text.localized("Run gh auth login if GitHub CLI has not been authenticated on this Mac.", "如果这台 Mac 上的 GitHub CLI 尚未认证，请运行 gh auth login。")
        ),
        PluginUsageInstruction(
          title: text.localized("Basic commands", "基本命令"),
          body: text.localized("Use gh repo view, gh pr list, gh pr checkout, and gh issue list inside repository workflows.", "在仓库工作流中使用 gh repo view、gh pr list、gh pr checkout 和 gh issue list。")
        ),
        PluginUsageInstruction(
          title: text.localized("Configuration boundary", "配置边界"),
          body: text.localized("Accounts, tokens, and aliases remain owned by GitHub CLI. ProGhostty only installs or detects the binary.", "账户、token 和 alias 仍由 GitHub CLI 管理。ProGhostty 只安装或检测二进制。")
        ),
      ]
    case "lazygit":
      return [
        PluginUsageInstruction(
          title: text.localized("Basic command", "基本命令"),
          body: text.localized("Run lazygit inside a Git repository to open its terminal UI.", "在 Git 仓库目录中运行 lazygit 打开终端 UI。")
        ),
        PluginUsageInstruction(
          title: text.localized("Workflow", "工作流"),
          body: text.localized("Use it for staging, commits, branch switching, log inspection, and conflict review without leaving the terminal.", "可用于暂存、提交、切换分支、查看日志和检查冲突，全程不离开终端。")
        ),
        PluginUsageInstruction(
          title: text.localized("Configuration boundary", "配置边界"),
          body: text.localized("No shell activation is needed. Existing lazygit config remains outside ProGhostty.", "不需要 shell 激活。已有 lazygit 配置仍在 ProGhostty 之外管理。")
        ),
      ]
    case "delta":
      return [
        PluginUsageInstruction(
          title: text.localized("Basic command", "基本命令"),
          body: text.localized("Use delta directly as a pager or pipe diff output into it for readable syntax-highlighted diffs.", "可直接把 delta 用作 pager，或将 diff 输出 pipe 给它获得更易读的语法高亮 diff。")
        ),
        PluginUsageInstruction(
          title: text.localized("Git integration", "Git 集成"),
          body: text.localized("If you want Git to use it automatically, configure Git yourself, for example as core.pager.", "如果希望 Git 自动使用它，请自行配置 Git，例如设置 core.pager。")
        ),
        PluginUsageInstruction(
          title: text.localized("Configuration boundary", "配置边界"),
          body: text.localized("ProGhostty installs git-delta but does not rewrite ~/.gitconfig.", "ProGhostty 安装 git-delta，但不会重写 ~/.gitconfig。")
        ),
      ]
    default:
      return [
        PluginUsageInstruction(
          title: text.localized("Detection only", "仅检测"),
          body: text.localized("ProGhostty reports this tool's status without taking over your shell configuration.", "ProGhostty 只报告这个工具的状态，不接管你的 Shell 配置。")
        ),
        PluginUsageInstruction(
          title: text.localized("Why", "原因"),
          body: text.localized("Runtime managers often own PATH, shims, and project-local hooks. Those should stay in your existing dotfiles.", "运行时管理器通常管理 PATH、shims 和项目级 hooks，这些应该继续留在你现有的 dotfiles 中。")
        ),
      ]
    }
  }

  private func localizedIssue(_ issue: PluginIssue, text: AppText) -> String {
    switch issue.title {
    case "Duplicate activation":
      text.localized(
        issue.message,
        "该插件同时出现在 ProGhostty 管理配置和外部 Shell 配置中，建议只保留一个激活来源。"
      )
    case "Prompt conflict":
      text.localized(
        issue.message,
        "提示符插件互斥。请只保留一个启用的提示符集成。"
      )
    case "Detect only":
      text.localized(
        issue.message,
        "运行时管理工具当前只检测，不由 ProGhostty 安装或配置。"
      )
    default:
      issue.message
    }
  }

  private func localizedMessage(_ message: String, text: AppText) -> String {
    if message.hasPrefix("Applied.") {
      return text.localized(message, message.replacingOccurrences(of: "Applied. Backup manifest:", with: "已应用。备份清单："))
    }
    if message.hasPrefix("Rolled back files") {
      return text.localized(message, message.replacingOccurrences(of: "Rolled back files from", with: "已从备份恢复："))
    }
    if message == "No backup manifest found." {
      return text.localized(message, "没有找到备份清单。")
    }
    if message.hasPrefix("This enhancement is detect-only") {
      return text.localized(message, "这个增强项当前只检测，或不能由 ProGhostty 安装。")
    }
    if message.hasPrefix("This enhancement cannot be uninstalled") {
      return text.localized(message, "这个增强项不能由 ProGhostty 卸载。")
    }
    return message
  }

  private func statusRank(_ status: PluginStatus) -> Int {
    switch status {
    case .conflict: 0
    case .notInstalled: 1
    case .installedButInactive: 2
    case .installed: 3
    case .activeManaged: 4
    case .activeExternal: 5
    case .unknown: 6
    }
  }

  private func categoryRank(_ category: PluginCategory) -> Int {
    PluginCategory.allCases.firstIndex(of: category) ?? 99
  }

  private func statusTitle(_ status: PluginStatus, text: AppText) -> String {
    switch status {
    case .notInstalled: text.localized("Not installed", "未安装")
    case .installed: text.localized("Installed", "已安装")
    case .installedButInactive: text.localized("Installed but inactive", "已安装但未启用")
    case .activeExternal: text.localized("Active external", "外部配置已启用")
    case .activeManaged: text.localized("Active managed", "由 ProGhostty 启用")
    case .conflict: text.localized("Conflict", "存在冲突")
    case .unknown: text.localized("Unknown", "未知")
    }
  }

  private func categoryTitle(_ category: PluginCategory, text: AppText) -> String {
    switch category {
    case .essential: text.localized("Essential", "基础")
    case .navigation: text.localized("Navigation", "导航")
    case .prompt: text.localized("Prompt", "提示符")
    case .history: text.localized("History", "历史")
    case .git: text.localized("Git", "Git")
    case .runtime: text.localized("Runtime", "运行时")
    }
  }

  private func sourceTitle(_ source: PluginSource, text: AppText) -> String {
    switch source {
    case .homebrew: "Homebrew"
    case .ohMyZsh: "Oh My Zsh"
    case .manualZshrc: text.localized("Manual zshrc", "手动 zshrc")
    case .yourTerminalManaged: text.localized("ProGhostty managed", "ProGhostty 管理")
    case .binaryPath: text.localized("Binary path", "可执行路径")
    case .unknown: text.localized("Unknown", "未知")
    }
  }

  private func riskTitle(_ risk: PluginRiskLevel, text: AppText) -> String {
    switch risk {
    case .low: text.localized("Low", "低")
    case .medium: text.localized("Medium", "中")
    case .high: text.localized("High", "高")
    }
  }

  private func statusColor(_ status: PluginStatus) -> Color {
    switch status {
    case .installed: .green
    case .activeManaged: .green
    case .activeExternal: .secondary
    case .conflict: .red
    case .installedButInactive: .orange
    default: .secondary
    }
  }

  private func riskColor(_ risk: PluginRiskLevel) -> Color {
    switch risk {
    case .low: .secondary
    case .medium: .orange
    case .high: .red
    }
  }
}

private struct PluginSidebarRow: View {
  let plugin: DetectedShellPlugin
  let isSelected: Bool
  let isRecommended: Bool
  let statusText: String
  let statusColor: Color
  let categoryText: String
  let recommendedText: String
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(alignment: .top, spacing: 9) {
        Circle()
          .fill(statusColor)
          .frame(width: 7, height: 7)
          .padding(.top, 6)

        VStack(alignment: .leading, spacing: 3) {
          HStack(spacing: 6) {
            Text(plugin.name)
              .font(.system(size: 13, weight: .medium))
              .lineLimit(1)
            if isRecommended {
              Text(recommendedText)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
          }
          Text("\(statusText) · \(categoryText)")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }

        Spacer(minLength: 0)
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 9)
      .background(isSelected ? Color.primary.opacity(0.08) : Color.clear)
      .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}

private struct MetadataRow: View {
  let title: String
  let value: String
  let color: Color

  var body: some View {
    HStack(alignment: .firstTextBaseline) {
      Text(title)
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
      Spacer()
      Text(value)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(color)
        .lineLimit(1)
    }
  }
}

private struct RollbackConfirmationView: View {
  let manifest: BackupManifest
  let text: AppText
  let isApplying: Bool
  let onConfirm: () -> Void
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .top, spacing: 12) {
        VStack(alignment: .leading, spacing: 4) {
          Text(text.rollbackTitle)
            .font(.headline)
          Text(text.rollbackCaption)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer()
      }
      .padding(16)

      Divider()

      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          VStack(alignment: .leading, spacing: 8) {
            Text(text.backupManifest)
              .font(.subheadline.weight(.medium))
            Text(manifest.backupDirectory)
              .font(.system(.caption, design: .monospaced))
              .textSelection(.enabled)
              .padding(8)
              .frame(maxWidth: .infinity, alignment: .leading)
              .background(Color(nsColor: .textBackgroundColor))
              .clipShape(RoundedRectangle(cornerRadius: 6))
          }

          VStack(alignment: .leading, spacing: 8) {
            Text(text.affectedFiles)
              .font(.subheadline.weight(.medium))
            VStack(alignment: .leading, spacing: 7) {
              ForEach(manifest.entries, id: \.originalPath) { entry in
                VStack(alignment: .leading, spacing: 2) {
                  Text(entry.originalPath)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(2)
                    .textSelection(.enabled)
                  Text(entry.existed ? text.localized("Restore previous file contents.", "恢复文件之前的内容。") : text.localized("Remove file created by the change.", "删除本次变更创建的文件。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
              }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.72))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
          }

          Text(text.localized(
            "Rollback only restores files captured in this manifest. If the change installed or uninstalled Homebrew packages, handle those package changes explicitly.",
            "回滚只恢复这个清单里记录的文件。如果本次变更安装或卸载了 Homebrew 包，需要你单独处理这些包变更。"
          ))
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
      }

      Divider()

      HStack(spacing: 10) {
        Spacer()
        Button(text.cancel) {
          dismiss()
        }
        .buttonStyle(.borderless)

        Button(text.confirmRollback) {
          onConfirm()
          dismiss()
        }
        .keyboardShortcut(.defaultAction)
        .disabled(isApplying)
      }
      .padding(16)
    }
    .frame(width: 620, height: 500)
  }
}

private struct PluginInstallPlanView: View {
  let plan: PluginInstallPlan
  let text: AppText
  let isApplying: Bool
  let onApply: () -> Void
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        VStack(alignment: .leading, spacing: 4) {
          Text(localizedPlanTitle)
            .font(.headline)
          Text(localizedPlanSummary)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer()
        Button(plan.operation == .install ? text.confirmInstall : text.confirmUninstall) {
          onApply()
          dismiss()
        }
        .keyboardShortcut(.defaultAction)
        .disabled(isApplying)
        Button(text.cancel) { dismiss() }
          .buttonStyle(.borderless)
      }
      .padding(16)

      Divider()

      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          planSection(text.commands, lines: plan.commands)
          VStack(alignment: .leading, spacing: 8) {
            Text(text.files)
              .font(.subheadline.weight(.medium))
            if plan.filePatches.isEmpty {
              Text(text.noFileChanges)
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
              ForEach(plan.filePatches) { patch in
                VStack(alignment: .leading, spacing: 6) {
                  Text(patch.filePath)
                    .font(.system(.caption, design: .monospaced))
                  Text(localizedPatchExplanation(patch.explanation))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                  Text(patch.afterPreview)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
              }
            }
          }
          Text("\(text.risk): \(riskTitle(plan.riskLevel))")
            .font(.caption)
            .foregroundStyle(.secondary)
          Text(localizedRollbackDescription)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(16)
      }
    }
    .frame(width: 680, height: 560)
  }

  private var localizedPlanTitle: String {
    if plan.operation == .install {
      return text.localized(plan.title, plan.title.replacingOccurrences(of: "Install", with: "安装"))
    }
    return text.localized(plan.title, plan.title.replacingOccurrences(of: "Uninstall", with: "卸载"))
  }

  private var localizedPlanSummary: String {
    switch plan.operation {
    case .install:
      text.localized(
        plan.summary,
        "通过 Homebrew 安装，把激活配置写入 ~/.your-terminal/shell/，并让 ~/.zshrc 只保留受保护的 source 块。"
      )
    case .uninstall:
      text.localized(
        plan.summary,
        "移除 Homebrew 包，并只删除 ProGhostty 管理的激活块。外部 Shell 配置不会被接管。"
      )
    }
  }

  private var localizedRollbackDescription: String {
    text.localized(
      plan.rollbackDescription,
      "修改任何受管理文件前，ProGhostty 会在 ~/.your-terminal/backups/YYYY-MM-DD-HH-mm-ss/manifest.json 创建备份清单，可用最近一次备份恢复。"
    )
  }

  private func planSection(_ title: String, lines: [String]) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title)
        .font(.subheadline.weight(.medium))
      Text(lines.isEmpty ? text.noCommands : lines.joined(separator: "\n"))
        .font(.system(.caption, design: .monospaced))
        .textSelection(.enabled)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
  }

  private func localizedPatchExplanation(_ explanation: String) -> String {
    if explanation.contains("guarded source block") {
      return text.localized(explanation, "只向 ~/.zshrc 添加受保护的 source 块；插件配置保留在 ~/.your-terminal/shell/。")
    }
    if explanation.contains("entrypoint") {
      return text.localized(explanation, "创建 ProGhostty 管理的 zsh 入口，只按稳定顺序 source 小型模块文件。")
    }
    if explanation.contains("Remove") {
      return text.localized(explanation, "删除所选 Shell 增强的 ProGhostty 管理激活块。")
    }
    return explanation
  }

  private func riskTitle(_ risk: PluginRiskLevel) -> String {
    switch risk {
    case .low: text.localized("Low", "低")
    case .medium: text.localized("Medium", "中")
    case .high: text.localized("High", "高")
    }
  }
}

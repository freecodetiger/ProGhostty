import Foundation

public enum ShellPluginCatalog {
  public static func definition(id: String) -> ShellPluginDefinition? {
    defaultDefinitions().first { $0.id == id }
  }

  public static func defaultDefinitions() -> [ShellPluginDefinition] {
    [
      plugin(
        id: "zsh-autosuggestions",
        name: "zsh-autosuggestions",
        category: .essential,
        description: "Fish-like command suggestions for zsh.",
        homepage: "https://github.com/zsh-users/zsh-autosuggestions",
        detectionCommands: ["command -v brew", "test -f /opt/homebrew/share/zsh-autosuggestions/zsh-autosuggestions.zsh"],
        installCommands: ["brew install zsh-autosuggestions"],
        zshSnippet: "source /opt/homebrew/share/zsh-autosuggestions/zsh-autosuggestions.zsh",
        touched: ["~/.your-terminal/shell/init.zsh", "~/.zshrc"],
        risk: .low
      ),
      plugin(
        id: "zsh-syntax-highlighting",
        name: "zsh-syntax-highlighting",
        category: .essential,
        description: "Syntax highlighting for interactive zsh commands.",
        homepage: "https://github.com/zsh-users/zsh-syntax-highlighting",
        detectionCommands: ["test -f /opt/homebrew/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh"],
        installCommands: ["brew install zsh-syntax-highlighting"],
        zshSnippet: "source /opt/homebrew/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh",
        touched: ["~/.your-terminal/shell/init.zsh", "~/.zshrc"],
        risk: .low,
        notes: ["Should be sourced after other zsh plugins."]
      ),
      binary("fzf", category: .navigation, description: "Fuzzy finder for files and command history.", install: "brew install fzf"),
      plugin(
        id: "zoxide",
        name: "zoxide",
        category: .navigation,
        description: "Smarter directory jumping based on frecency.",
        homepage: "https://github.com/ajeetdsouza/zoxide",
        detectionCommands: ["command -v zoxide"],
        installCommands: ["brew install zoxide"],
        zshSnippet: "eval \"$(zoxide init zsh)\"",
        touched: ["~/.your-terminal/shell/init.zsh", "~/.zshrc"],
        risk: .low
      ),
      binary("ripgrep", category: .navigation, description: "Fast recursive text search.", install: "brew install ripgrep", commandName: "rg"),
      binary("fd", category: .navigation, description: "Fast file search.", install: "brew install fd"),
      plugin(
        id: "starship",
        name: "starship",
        category: .prompt,
        description: "Portable prompt with shell-agnostic configuration.",
        homepage: "https://starship.rs",
        detectionCommands: ["command -v starship"],
        installCommands: ["brew install starship"],
        zshSnippet: "eval \"$(starship init zsh)\"",
        touched: ["~/.your-terminal/shell/init.zsh", "~/.zshrc"],
        conflictGroup: "prompt",
        risk: .medium
      ),
      plugin(
        id: "powerlevel10k",
        name: "powerlevel10k",
        category: .prompt,
        description: "Feature-rich zsh prompt. Detect only in ProGhostty.",
        homepage: "https://github.com/romkatv/powerlevel10k",
        detectionCommands: ["test -f ~/.p10k.zsh"],
        installCommands: [],
        zshSnippet: nil,
        touched: [],
        conflictGroup: "prompt",
        recommend: false,
        risk: .medium,
        notes: ["Detect only. ProGhostty does not actively recommend installing powerlevel10k."]
      ),
      plugin(
        id: "atuin",
        name: "atuin",
        category: .history,
        description: "Searchable shell history with optional sync.",
        homepage: "https://atuin.sh",
        detectionCommands: ["command -v atuin"],
        installCommands: ["brew install atuin"],
        zshSnippet: "eval \"$(atuin init zsh)\"",
        touched: ["~/.your-terminal/shell/init.zsh", "~/.zshrc"],
        recommend: false,
        risk: .high,
        notes: ["Advanced optional plugin. History integrations can significantly change shell key bindings and storage."]
      ),
      binary("gh", category: .git, description: "GitHub CLI.", install: "brew install gh"),
      binary("lazygit", category: .git, description: "Terminal UI for Git workflows.", install: "brew install lazygit"),
      binary("delta", category: .git, description: "Readable Git diffs.", install: "brew install git-delta"),
      runtime("nvm", description: "Node version manager."),
      runtime("fnm", description: "Fast Node version manager."),
      runtime("pyenv", description: "Python version manager."),
      runtime("jenv", description: "Java version manager."),
      runtime("sdkman", description: "SDK version manager."),
      runtime("direnv", description: "Directory-scoped environment loader."),
    ]
  }

  private static func binary(
    _ id: String,
    category: PluginCategory,
    description: String,
    install: String,
    commandName: String? = nil
  ) -> ShellPluginDefinition {
    plugin(
      id: id,
      name: id,
      category: category,
      description: description,
      homepage: nil,
      detectionCommands: ["command -v \(commandName ?? id)"],
      installCommands: [install],
      zshSnippet: nil,
      touched: [],
      risk: .low
    )
  }

  private static func runtime(_ id: String, description: String) -> ShellPluginDefinition {
    plugin(
      id: id,
      name: id,
      category: .runtime,
      description: description,
      homepage: nil,
      detectionCommands: ["command -v \(id)"],
      installCommands: [],
      zshSnippet: nil,
      touched: [],
      recommend: false,
      risk: .medium,
      notes: ["Detect only in this version. ProGhostty does not install or modify runtime manager configuration."]
    )
  }

  private static func plugin(
    id: String,
    name: String,
    category: PluginCategory,
    description: String,
    homepage: String?,
    detectionCommands: [String],
    installCommands: [String],
    zshSnippet: String?,
    touched: [String],
    conflictGroup: String? = nil,
    recommend: Bool = true,
    risk: PluginRiskLevel,
    notes: [String] = []
  ) -> ShellPluginDefinition {
    ShellPluginDefinition(
      id: id,
      name: name,
      category: category,
      description: description,
      homepage: homepage,
      detectionCommands: detectionCommands,
      installCommands: installCommands,
      activationSnippets: zshSnippet.map { [.zsh: $0] } ?? [:],
      configFilesTouched: touched,
      conflictGroup: conflictGroup,
      shouldAutoRecommend: recommend,
      riskLevel: risk,
      notes: notes
    )
  }
}

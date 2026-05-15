import Foundation

public struct ShellEnvironmentScanner {
  private let fileManager: FileManager
  private let environment: [String: String]

  public init(
    fileManager: FileManager = .default,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) {
    self.fileManager = fileManager
    self.environment = environment
  }

  public func scan() -> ShellEnvironmentReport {
    let shell = environment["SHELL"] ?? "/bin/zsh"
    let home = environment["HOME"] ?? NSHomeDirectory()
    let homebrew = firstExisting(["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]) != nil
    let installedNames = Set(
      recommendationPlans().map(\.name).filter {
        commandExists($0) || zshPluginExists($0, home: home)
      })

    let recommendations = recommendationPlans().map { plan in
      PluginRecommendation(plan: plan, isInstalled: installedNames.contains(plan.name))
    }

    return ShellEnvironmentReport(
      defaultShell: shell,
      zshExists: fileManager.isExecutableFile(atPath: "/bin/zsh") || commandExists("zsh"),
      homebrewExists: homebrew,
      ohMyZshExists: fileManager.fileExists(atPath: "\(home)/.oh-my-zsh"),
      recommendations: recommendations
    )
  }

  private func recommendationPlans() -> [PluginInstallPlan] {
    [
      plan(
        "zsh-autosuggestions", reason: "Command suggestions while typing",
        command: "brew install zsh-autosuggestions",
        snippet: "source $(brew --prefix)/share/zsh-autosuggestions/zsh-autosuggestions.zsh"),
      plan(
        "zsh-syntax-highlighting", reason: "Highlights valid and invalid shell syntax",
        command: "brew install zsh-syntax-highlighting",
        snippet: "source $(brew --prefix)/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh"
      ),
      plan(
        "fzf", reason: "Fast fuzzy search for files and history", command: "brew install fzf",
        snippet: nil),
      plan(
        "zoxide", reason: "Smarter directory jumping", command: "brew install zoxide",
        snippet: "eval \"$(zoxide init zsh)\""),
      plan(
        "starship", reason: "Portable shell prompt", command: "brew install starship",
        snippet: "eval \"$(starship init zsh)\""),
      plan(
        "atuin", reason: "Searchable shell history", command: "brew install atuin",
        snippet: "eval \"$(atuin init zsh)\""),
      plan(
        "ripgrep", reason: "Fast recursive text search", command: "brew install ripgrep",
        snippet: nil),
      plan("fd", reason: "Fast file search", command: "brew install fd", snippet: nil),
      plan("jq", reason: "JSON processing in the shell", command: "brew install jq", snippet: nil),
      plan("gh", reason: "GitHub CLI integration", command: "brew install gh", snippet: nil),
      plan(
        "lazygit", reason: "Terminal UI for Git workflows", command: "brew install lazygit",
        snippet: nil),
      plan(
        "delta", reason: "Readable Git diffs", command: "brew install git-delta",
        snippet: "git config --global core.pager delta"),
    ]
  }

  private func plan(_ name: String, reason: String, command: String, snippet: String?)
    -> PluginInstallPlan
  {
    PluginInstallPlan(
      name: name, reason: reason, commands: [command], configSnippet: snippet, riskLevel: .low)
  }

  private func firstExisting(_ paths: [String]) -> String? {
    paths.first { fileManager.isExecutableFile(atPath: $0) }
  }

  private func commandExists(_ command: String) -> Bool {
    let path = environment["PATH"] ?? "/bin:/usr/bin:/usr/local/bin:/opt/homebrew/bin"
    return path.split(separator: ":").contains { dir in
      fileManager.isExecutableFile(atPath: "\(dir)/\(command)")
    }
  }

  private func zshPluginExists(_ name: String, home: String) -> Bool {
    fileManager.fileExists(atPath: "\(home)/.oh-my-zsh/custom/plugins/\(name)")
  }
}

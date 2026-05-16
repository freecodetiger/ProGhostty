import Foundation

public struct InstallPlanGenerator {
  private let definitions: [ShellPluginDefinition]
  private let configWriter: ShellConfigWriter

  public init(
    definitions: [ShellPluginDefinition] = ShellPluginCatalog.defaultDefinitions(),
    configWriter: ShellConfigWriter = ShellConfigWriter()
  ) {
    self.definitions = definitions
    self.configWriter = configWriter
  }

  public func installPlan(
    pluginIds: [String],
    homeDirectory: String,
    existingFiles: [String: String]
  ) -> PluginInstallPlan? {
    let selected = definitions.filter { pluginIds.contains($0.id) }
    guard !selected.isEmpty, selected.allSatisfy({ !$0.installCommands.isEmpty }) else { return nil }

    let commands = selected.flatMap(\.installCommands)
    guard commands.allSatisfy({ $0.hasPrefix("brew install ") }) else { return nil }

    let shellActivated = selected.filter { !$0.activationSnippets.isEmpty }
    let patches = shellActivated.isEmpty
      ? []
      : configWriter.installPatches(
        for: shellActivated,
        homeDirectory: homeDirectory,
        existingFiles: existingFiles
      )

    return PluginInstallPlan(
      pluginIds: selected.map(\.id),
      operation: .install,
      title: selected.count == 1 ? "Install \(selected[0].name)" : "Install \(selected.count) shell enhancements",
      summary: "Install with Homebrew, write activation into ~/.your-terminal/shell/, and keep ~/.zshrc limited to a guarded source block.",
      commands: commands,
      filePatches: patches,
      riskLevel: selected.map(\.riskLevel).max(by: { rank($0) < rank($1) }) ?? .low,
      requiresBackup: true,
      rollbackDescription: "Before any managed file is changed, ProGhostty creates ~/.your-terminal/backups/YYYY-MM-DD-HH-mm-ss/manifest.json. Rollback restores from the latest manifest."
    )
  }

  public func uninstallPlan(
    pluginIds: [String],
    homeDirectory: String,
    existingFiles: [String: String]
  ) -> PluginInstallPlan? {
    let selected = definitions.filter { pluginIds.contains($0.id) }
    guard !selected.isEmpty, selected.allSatisfy({ !$0.installCommands.isEmpty }) else { return nil }

    let commands = selected.flatMap { definition in
      definition.installCommands.compactMap { command -> String? in
        guard command.hasPrefix("brew install ") else { return nil }
        return command.replacingOccurrences(of: "brew install ", with: "brew uninstall ")
      }
    }
    guard commands.count == selected.flatMap(\.installCommands).count else { return nil }

    let patches = configWriter.uninstallPatches(
      for: selected,
      homeDirectory: homeDirectory,
      existingFiles: existingFiles
    )

    return PluginInstallPlan(
      pluginIds: selected.map(\.id),
      operation: .uninstall,
      title: selected.count == 1 ? "Uninstall \(selected[0].name)" : "Uninstall \(selected.count) shell enhancements",
      summary: "Remove Homebrew packages and delete only ProGhostty-managed activation blocks. External shell configuration is left untouched.",
      commands: commands,
      filePatches: patches,
      riskLevel: selected.map(\.riskLevel).max(by: { rank($0) < rank($1) }) ?? .low,
      requiresBackup: true,
      rollbackDescription: "The latest backup manifest can restore files changed by this uninstall plan. Homebrew package reinstall remains explicit."
    )
  }

  private func rank(_ risk: PluginRiskLevel) -> Int {
    switch risk {
    case .low: 0
    case .medium: 1
    case .high: 2
    }
  }
}

import Foundation

public struct ShellPluginInstallPlanner {
  private let generator: InstallPlanGenerator

  public init(generator: InstallPlanGenerator = InstallPlanGenerator()) {
    self.generator = generator
  }

  public func plan(
    for definition: ShellPluginDefinition,
    shell: ShellType,
    homeDirectory: String,
    existingShellRC: String?
  ) -> PluginInstallPlan? {
    guard shell == .zsh else { return nil }
    let writer = ShellConfigWriter()
    let paths = writer.paths(homeDirectory: homeDirectory)
    return generator.installPlan(
      pluginIds: [definition.id],
      homeDirectory: homeDirectory,
      existingFiles: [paths.shellRC: existingShellRC ?? ""]
    )
  }
}

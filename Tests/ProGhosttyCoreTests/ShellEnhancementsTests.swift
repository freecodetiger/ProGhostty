import Foundation
import Testing

@testable import ProGhosttyCore

@Suite("Shell enhancements")
struct ShellEnhancementsTests {
  @Test func catalogContainsOnlySmallCuratedSetWithExpectedRecommendationPolicy() throws {
    let definitions = ShellPluginCatalog.defaultDefinitions()

    #expect(definitions.map(\.id) == [
      "zsh-autosuggestions",
      "zsh-syntax-highlighting",
      "fzf",
      "zoxide",
      "ripgrep",
      "fd",
      "starship",
      "powerlevel10k",
      "atuin",
      "gh",
      "lazygit",
      "delta",
      "nvm",
      "fnm",
      "pyenv",
      "jenv",
      "sdkman",
      "direnv",
    ])

    let powerlevel10k = try #require(definitions.first { $0.id == "powerlevel10k" })
    let atuin = try #require(definitions.first { $0.id == "atuin" })
    let runtime = definitions.filter { $0.category == .runtime }

    #expect(powerlevel10k.shouldAutoRecommend == false)
    #expect(powerlevel10k.installCommands.isEmpty)
    #expect(atuin.shouldAutoRecommend == false)
    #expect(runtime.allSatisfy { $0.installCommands.isEmpty && $0.activationSnippets.isEmpty })
  }

  @Test func detectorDistinguishesManagedExternalInactiveAndNotInstalled() throws {
    let home = "/Users/tester"
    let snapshot = ShellPluginDetectionSnapshot(
      homeDirectory: home,
      defaultShell: "/bin/zsh",
      executableNames: ["fzf", "starship"],
      existingPaths: [
        "\(home)/.oh-my-zsh",
        "/opt/homebrew/share/zsh-autosuggestions/zsh-autosuggestions.zsh",
      ],
      fileContents: [
        "\(home)/.zshrc": "plugins=(git zsh-autosuggestions)\neval \"$(starship init zsh)\"\n",
        "\(home)/.your-terminal/shell/navigation.zsh": "source /opt/homebrew/share/fzf/shell/key-bindings.zsh\n",
      ]
    )

    let detected = ShellPluginDetector().detect(in: snapshot)
    let autosuggestions = try #require(detected.first { $0.definitionId == "zsh-autosuggestions" })
    let fzf = try #require(detected.first { $0.definitionId == "fzf" })
    let ripgrep = try #require(detected.first { $0.definitionId == "ripgrep" })
    let starship = try #require(detected.first { $0.definitionId == "starship" })

    #expect(autosuggestions.status == .activeExternal)
    #expect(autosuggestions.source == .ohMyZsh)
    #expect(fzf.status == .activeManaged)
    #expect(fzf.source == .yourTerminalManaged)
    #expect(ripgrep.status == .notInstalled)
    #expect(starship.status == .activeExternal)
  }

  @Test func detectorMarksInstalledBinaryToolsAsInstalledWithoutActivationRequirement() throws {
    let detected = ShellPluginDetector().detect(in: ShellPluginDetectionSnapshot(
      homeDirectory: "/Users/tester",
      defaultShell: "/bin/zsh",
      executableNames: ["delta"],
      existingPaths: [],
      fileContents: [:]
    ))

    let delta = try #require(detected.first { $0.definitionId == "delta" })

    #expect(delta.status == .installed)
    #expect(delta.source == .binaryPath)
  }

  @Test func detectorMarksPromptConflict() throws {
    let home = "/Users/tester"
    let snapshot = ShellPluginDetectionSnapshot(
      homeDirectory: home,
      defaultShell: "/bin/zsh",
      executableNames: ["starship"],
      existingPaths: [],
      fileContents: [
        "\(home)/.zshrc": "eval \"$(starship init zsh)\"\nsource ~/.p10k.zsh\n"
      ]
    )

    let detected = ShellPluginDetector().detect(in: snapshot)
    let starship = try #require(detected.first { $0.definitionId == "starship" })
    let powerlevel10k = try #require(detected.first { $0.definitionId == "powerlevel10k" })

    #expect(starship.status == .conflict)
    #expect(powerlevel10k.status == .conflict)
    #expect(starship.issues.contains { $0.severity == .error })
  }

  @Test func installPlanUsesManagedConfigAndGuardedSourceBlock() throws {
    let definition = try #require(ShellPluginCatalog.definition(id: "zsh-autosuggestions"))
    let plan = try #require(ShellPluginInstallPlanner().plan(
      for: definition,
      shell: .zsh,
      homeDirectory: "/Users/tester",
      existingShellRC: "# user config\n"
    ))

    #expect(plan.pluginIds == ["zsh-autosuggestions"])
    #expect(plan.operation == .install)
    #expect(plan.commands == ["brew install zsh-autosuggestions"])
    #expect(plan.requiresBackup == true)
    #expect(plan.filePatches.map(\.filePath).contains("/Users/tester/.your-terminal/shell/zshrc"))
    #expect(plan.filePatches.map(\.filePath).contains("/Users/tester/.your-terminal/shell/essential.zsh"))
    #expect(plan.filePatches.map(\.filePath).contains("/Users/tester/.your-terminal/shell/navigation.zsh"))
    #expect(plan.filePatches.map(\.filePath).contains("/Users/tester/.your-terminal/shell/prompt.zsh"))
    #expect(plan.filePatches.map(\.filePath).contains("/Users/tester/.your-terminal/shell/git.zsh"))
    #expect(plan.filePatches.map(\.filePath).contains("/Users/tester/.zshrc"))
    #expect(plan.filePatches.contains { $0.afterPreview.contains("YourTerminal managed shell enhancements") })
    #expect(plan.filePatches.contains { $0.afterPreview.contains("zsh-autosuggestions.zsh") })
    #expect(plan.rollbackDescription.contains("backup"))
  }

  @Test func installPlanKeepsSyntaxHighlightingLast() throws {
    let generator = InstallPlanGenerator()
    let plan = try #require(generator.installPlan(
      pluginIds: ["zsh-autosuggestions", "zsh-syntax-highlighting", "starship"],
      homeDirectory: "/Users/tester",
      existingFiles: [:]
    ))
    let zshrc = try #require(plan.filePatches.first { $0.filePath == "/Users/tester/.your-terminal/shell/zshrc" })

    #expect(zshrc.afterPreview.contains("essential.zsh"))
    #expect(zshrc.afterPreview.contains("zsh-syntax-highlighting.zsh"))
    let gitIndex = try #require(zshrc.afterPreview.range(of: "git.zsh")?.lowerBound)
    let syntaxIndex = try #require(zshrc.afterPreview.range(of: "zsh-syntax-highlighting.zsh")?.lowerBound)
    #expect(gitIndex < syntaxIndex)
  }

  @Test func binaryInstallPlanDoesNotTouchShellConfiguration() throws {
    let plan = try #require(InstallPlanGenerator().installPlan(
      pluginIds: ["delta"],
      homeDirectory: "/Users/tester",
      existingFiles: [:]
    ))

    #expect(plan.commands == ["brew install git-delta"])
    #expect(plan.filePatches.isEmpty)
  }

  @Test func uninstallPlanUsesBrewUninstallAndRemovesManagedBlocksOnly() throws {
    let writer = ShellConfigWriter()
    let paths = writer.paths(homeDirectory: "/Users/tester")
    let existing = """
    # ProGhostty managed shell enhancements.

    # BEGIN YourTerminal plugin: zoxide
    eval "$(zoxide init zsh)"
    # END YourTerminal plugin: zoxide
    """
    let plan = try #require(InstallPlanGenerator().uninstallPlan(
      pluginIds: ["zoxide"],
      homeDirectory: "/Users/tester",
      existingFiles: [paths.navigation: existing]
    ))

    #expect(plan.operation == .uninstall)
    #expect(plan.commands == ["brew uninstall zoxide"])
    #expect(plan.filePatches.first?.afterPreview.contains("zoxide init") == false)
  }

  @Test func installPlanIsUnavailableForRuntimeAndDetectOnlyPromptPlugins() throws {
    let planner = ShellPluginInstallPlanner()
    let pyenv = try #require(ShellPluginCatalog.definition(id: "pyenv"))
    let powerlevel10k = try #require(ShellPluginCatalog.definition(id: "powerlevel10k"))

    #expect(planner.plan(for: pyenv, shell: .zsh, homeDirectory: "/Users/tester", existingShellRC: nil) == nil)
    #expect(planner.plan(for: powerlevel10k, shell: .zsh, homeDirectory: "/Users/tester", existingShellRC: nil) == nil)
  }

  @Test func executorBacksUpBeforeWritingPatchesAndRunsCommands() throws {
    let temp = FileManager.default.temporaryDirectory
      .appendingPathComponent("proghostty-plugin-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temp) }

    let rc = temp.appendingPathComponent(".zshrc").path
    try "# old\n".write(toFile: rc, atomically: true, encoding: .utf8)
    let managed = temp.appendingPathComponent(".your-terminal/shell/zshrc").path
    let plan = PluginInstallPlan(
      pluginIds: ["fzf"],
      title: "Install fzf",
      summary: "test",
      commands: ["echo install"],
      filePatches: [
        FilePatch(filePath: rc, beforePreview: "# old\n", afterPreview: "# new\n", explanation: "update rc"),
        FilePatch(filePath: managed, beforePreview: nil, afterPreview: "source fzf\n", explanation: "managed"),
      ],
      riskLevel: .low,
      requiresBackup: true,
      rollbackDescription: "restore backup"
    )
    var commands: [String] = []

    let receipt = try ShellPluginInstallExecutor(fileManager: .default) { command in
      commands.append(command)
    }.apply(plan: plan, backupDirectory: temp.appendingPathComponent("backups").path)

    #expect(commands == ["echo install"])
    #expect(try String(contentsOfFile: rc) == "# new\n")
    #expect(try String(contentsOfFile: managed) == "source fzf\n")
    #expect(receipt.backupDirectory.hasPrefix(temp.appendingPathComponent("backups").path))
    #expect(FileManager.default.fileExists(atPath: receipt.manifestPath))
    #expect((try? FileManager.default.contentsOfDirectory(atPath: receipt.backupDirectory).isEmpty) == false)
  }

  @Test func backupAndRollbackRestoreFilesFromManifest() throws {
    let temp = FileManager.default.temporaryDirectory
      .appendingPathComponent("proghostty-rollback-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temp) }

    let home = temp.path
    let rc = temp.appendingPathComponent(".zshrc").path
    let created = temp.appendingPathComponent(".your-terminal/shell/zshrc").path
    try "# old\n".write(toFile: rc, atomically: true, encoding: .utf8)

    let manifest = try BackupManager().backup(
      files: [rc, created],
      homeDirectory: home,
      date: Date(timeIntervalSince1970: 1_700_000_000)
    )
    try "# new\n".write(toFile: rc, atomically: true, encoding: .utf8)
    try FileManager.default.createDirectory(
      at: URL(fileURLWithPath: created).deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try "# created\n".write(toFile: created, atomically: true, encoding: .utf8)

    let restored = try RollbackManager().rollbackLatest(homeDirectory: home)

    #expect(restored == manifest)
    #expect(try String(contentsOfFile: rc) == "# old\n")
    #expect(FileManager.default.fileExists(atPath: created) == false)
  }
}

import Foundation

public struct ShellConfigWriter {
  public struct Paths: Equatable, Sendable {
    public var managedRoot: String
    public var zshrc: String
    public var essential: String
    public var navigation: String
    public var prompt: String
    public var git: String
    public var shellRC: String

    public var managedFiles: [String] {
      [zshrc, essential, navigation, prompt, git]
    }
  }

  public init() {}

  public func paths(homeDirectory: String) -> Paths {
    let root = "\(homeDirectory)/.your-terminal/shell"
    return Paths(
      managedRoot: root,
      zshrc: "\(root)/zshrc",
      essential: "\(root)/essential.zsh",
      navigation: "\(root)/navigation.zsh",
      prompt: "\(root)/prompt.zsh",
      git: "\(root)/git.zsh",
      shellRC: "\(homeDirectory)/.zshrc"
    )
  }

  public func installPatches(
    for definitions: [ShellPluginDefinition],
    homeDirectory: String,
    existingFiles: [String: String]
  ) -> [FilePatch] {
    let paths = paths(homeDirectory: homeDirectory)
    var patches = moduleSkeletonPatches(paths: paths, existingFiles: existingFiles)
    patches.append(shellRCPatch(paths: paths, existing: existingFiles[paths.shellRC]))

    let snippets = definitions.compactMap { definition -> (ShellPluginDefinition, String)? in
      guard let snippet = definition.activationSnippets[.zsh] else { return nil }
      return (definition, snippet)
    }

    for (definition, snippet) in snippets where definition.id != "zsh-syntax-highlighting" {
      let path = modulePath(for: definition.category, paths: paths)
      let current = currentAfterPatch(path: path, patches: patches, existingFiles: existingFiles)
      let next = addingManagedBlock(pluginID: definition.id, snippet: snippet, to: current)
      upsertPatch(path: path, after: next, existingFiles: existingFiles, patches: &patches)
    }

    if let syntax = snippets.first(where: { $0.0.id == "zsh-syntax-highlighting" }) {
      let current = currentAfterPatch(path: paths.zshrc, patches: patches, existingFiles: existingFiles)
      let next = addingManagedBlock(pluginID: syntax.0.id, snippet: syntax.1, to: current)
      upsertPatch(path: paths.zshrc, after: next, existingFiles: existingFiles, patches: &patches)
    }

    return patches
  }

  public func uninstallPatches(
    for definitions: [ShellPluginDefinition],
    homeDirectory: String,
    existingFiles: [String: String]
  ) -> [FilePatch] {
    let paths = paths(homeDirectory: homeDirectory)
    var patches: [FilePatch] = []
    let managedPaths = paths.managedFiles

    for path in managedPaths {
      guard let existing = existingFiles[path] else { continue }
      var next = existing
      for definition in definitions {
        next = removingManagedBlock(pluginID: definition.id, from: next)
      }
      if next != existing {
        patches.append(FilePatch(
          filePath: path,
          beforePreview: existing,
          afterPreview: next,
          explanation: "Remove ProGhostty-managed activation blocks for the selected shell enhancement."
        ))
      }
    }

    return patches
  }

  public func readableConfigPaths(homeDirectory: String) -> [String] {
    let paths = paths(homeDirectory: homeDirectory)
    return [
      paths.shellRC,
      "\(homeDirectory)/.zprofile",
      "\(homeDirectory)/.bashrc",
      "\(homeDirectory)/.bash_profile",
      "\(homeDirectory)/.your-terminal/shell/init.zsh",
      "\(homeDirectory)/.your-terminal/shell/init.bash",
      paths.zshrc,
      paths.essential,
      paths.navigation,
      paths.prompt,
      paths.git,
    ]
  }

  private func moduleSkeletonPatches(paths: Paths, existingFiles: [String: String]) -> [FilePatch] {
    [
      FilePatch(
        filePath: paths.zshrc,
        beforePreview: existingFiles[paths.zshrc],
        afterPreview: existingFiles[paths.zshrc] ?? baseManagedZshrc(),
        explanation: "Create the ProGhostty-managed zsh entrypoint. It only sources small module files and keeps shell plugin order stable."
      ),
      FilePatch(
        filePath: paths.essential,
        beforePreview: existingFiles[paths.essential],
        afterPreview: existingFiles[paths.essential] ?? baseModuleHeader("Essential shell enhancements."),
        explanation: "Create the managed essential shell module."
      ),
      FilePatch(
        filePath: paths.navigation,
        beforePreview: existingFiles[paths.navigation],
        afterPreview: existingFiles[paths.navigation] ?? baseModuleHeader("Navigation shell enhancements."),
        explanation: "Create the managed navigation shell module."
      ),
      FilePatch(
        filePath: paths.prompt,
        beforePreview: existingFiles[paths.prompt],
        afterPreview: existingFiles[paths.prompt] ?? baseModuleHeader("Prompt shell enhancements."),
        explanation: "Create the managed prompt shell module."
      ),
      FilePatch(
        filePath: paths.git,
        beforePreview: existingFiles[paths.git],
        afterPreview: existingFiles[paths.git] ?? baseModuleHeader("Git shell enhancements."),
        explanation: "Create the managed Git shell module."
      ),
    ].filter { patch in
      existingFiles[patch.filePath] != patch.afterPreview
    }
  }

  private func shellRCPatch(paths: Paths, existing: String?) -> FilePatch {
    let before = existing ?? ""
    return FilePatch(
      filePath: paths.shellRC,
      beforePreview: existing,
      afterPreview: addingGuardedSourceBlock(to: before),
      explanation: "Add only a guarded source block to ~/.zshrc. Plugin configuration stays under ~/.your-terminal/shell/."
    )
  }

  private func baseManagedZshrc() -> String {
    """
    # ProGhostty managed shell enhancements.
    # Edit the module files in this directory instead of ~/.zshrc.

    for file in \\
      "$HOME/.your-terminal/shell/essential.zsh" \\
      "$HOME/.your-terminal/shell/navigation.zsh" \\
      "$HOME/.your-terminal/shell/prompt.zsh" \\
      "$HOME/.your-terminal/shell/git.zsh"
    do
      [[ -r "$file" ]] && source "$file"
    done

    # zsh-syntax-highlighting must be sourced after other zsh plugins.

    """
  }

  private func baseModuleHeader(_ title: String) -> String {
    "# ProGhostty managed shell enhancements: \(title)\n\n"
  }

  private func addingGuardedSourceBlock(to existing: String) -> String {
    if existing.contains("YourTerminal managed shell enhancements")
      || existing.contains("PROGHOSTTY SHELL ENHANCEMENTS")
    {
      return existing
    }

    let block = """

    # YourTerminal managed shell enhancements
    if [[ "$TERM_PROGRAM" == "YourTerminal" || "$TERM_PROGRAM" == "ProGhostty" ]]; then
      source "$HOME/.your-terminal/shell/zshrc"
    fi
    """
    return existing + block + "\n"
  }

  private func addingManagedBlock(pluginID: String, snippet: String, to existing: String) -> String {
    if existing.contains(beginMarker(pluginID)) { return existing }
    var result = existing
    if !result.hasSuffix("\n") {
      result += "\n"
    }
    result += """

    \(beginMarker(pluginID))
    \(snippet)
    \(endMarker(pluginID))
    """
    result += "\n"
    return result
  }

  private func removingManagedBlock(pluginID: String, from existing: String) -> String {
    let begin = beginMarker(pluginID)
    let end = endMarker(pluginID)
    guard let beginRange = existing.range(of: begin),
      let endRange = existing.range(of: end, range: beginRange.upperBound..<existing.endIndex)
    else {
      return existing
    }

    var result = existing
    let removeRange = beginRange.lowerBound..<endRange.upperBound
    result.removeSubrange(removeRange)
    return result.replacingOccurrences(of: "\n\n\n", with: "\n\n")
  }

  private func beginMarker(_ pluginID: String) -> String {
    "# BEGIN YourTerminal plugin: \(pluginID)"
  }

  private func endMarker(_ pluginID: String) -> String {
    "# END YourTerminal plugin: \(pluginID)"
  }

  private func modulePath(for category: PluginCategory, paths: Paths) -> String {
    switch category {
    case .essential, .runtime, .history:
      paths.essential
    case .navigation:
      paths.navigation
    case .prompt:
      paths.prompt
    case .git:
      paths.git
    }
  }

  private func currentAfterPatch(path: String, patches: [FilePatch], existingFiles: [String: String]) -> String {
    patches.last(where: { $0.filePath == path })?.afterPreview ?? existingFiles[path] ?? baseContent(for: path)
  }

  private func baseContent(for path: String) -> String {
    if path.hasSuffix("/zshrc") {
      return baseManagedZshrc()
    }
    if path.hasSuffix("/essential.zsh") {
      return baseModuleHeader("Essential shell enhancements.")
    }
    if path.hasSuffix("/navigation.zsh") {
      return baseModuleHeader("Navigation shell enhancements.")
    }
    if path.hasSuffix("/prompt.zsh") {
      return baseModuleHeader("Prompt shell enhancements.")
    }
    if path.hasSuffix("/git.zsh") {
      return baseModuleHeader("Git shell enhancements.")
    }
    return ""
  }

  private func upsertPatch(
    path: String,
    after: String,
    existingFiles: [String: String],
    patches: inout [FilePatch]
  ) {
    if let index = patches.lastIndex(where: { $0.filePath == path }) {
      patches[index].afterPreview = after
      return
    }
    guard existingFiles[path] != after else { return }
    patches.append(FilePatch(
      filePath: path,
      beforePreview: existingFiles[path],
      afterPreview: after,
      explanation: "Update ProGhostty-managed activation for the selected shell enhancement."
    ))
  }
}

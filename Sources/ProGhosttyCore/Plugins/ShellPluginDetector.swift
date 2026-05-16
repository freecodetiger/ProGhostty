import Foundation

public struct ShellPluginDetectionSnapshot: Equatable, Sendable {
  public var homeDirectory: String
  public var defaultShell: String
  public var executableNames: Set<String>
  public var existingPaths: Set<String>
  public var fileContents: [String: String]

  public init(
    homeDirectory: String,
    defaultShell: String,
    executableNames: Set<String>,
    existingPaths: Set<String>,
    fileContents: [String: String]
  ) {
    self.homeDirectory = homeDirectory
    self.defaultShell = defaultShell
    self.executableNames = executableNames
    self.existingPaths = existingPaths
    self.fileContents = fileContents
  }
}

public struct ShellPluginDetector {
  private let definitions: [ShellPluginDefinition]

  public init(definitions: [ShellPluginDefinition] = ShellPluginCatalog.defaultDefinitions()) {
    self.definitions = definitions
  }

  public func detect(in snapshot: ShellPluginDetectionSnapshot) -> [DetectedShellPlugin] {
    var detected = definitions.map { detect($0, in: snapshot) }
    applyPromptConflicts(to: &detected)
    return detected
  }

  private func detect(_ definition: ShellPluginDefinition, in snapshot: ShellPluginDetectionSnapshot) -> DetectedShellPlugin {
    let installed = isInstalled(definition, snapshot: snapshot)
    let managed = isManaged(definition, snapshot: snapshot)
    let external = externalSource(definition, snapshot: snapshot)

    var status: PluginStatus
    var source: PluginSource
    var issues: [PluginIssue] = []

    switch (installed, managed, external) {
    case (_, true, .some):
      status = .conflict
      source = .yourTerminalManaged
      issues.append(PluginIssue(
        title: "Duplicate activation",
        message: "\(definition.name) appears in both ProGhostty managed config and external shell config.",
        severity: .error
      ))
    case (_, true, nil):
      status = .activeManaged
      source = .yourTerminalManaged
    case (_, false, .some(let externalSource)):
      status = .activeExternal
      source = externalSource
    case (true, false, nil) where definition.activationSnippets.isEmpty:
      status = .installed
      source = installedSource(definition, snapshot: snapshot)
    case (true, false, nil):
      status = .installedButInactive
      source = installedSource(definition, snapshot: snapshot)
    case (false, false, nil):
      status = .notInstalled
      source = .unknown
    }

    if definition.category == .runtime {
      issues.append(PluginIssue(
        title: "Detect only",
        message: "Runtime managers are detected but not installed or configured by ProGhostty.",
        severity: .info
      ))
    }

    return DetectedShellPlugin(
      id: definition.id,
      definitionId: definition.id,
      name: definition.name,
      category: definition.category,
      status: status,
      source: source,
      detectedPaths: detectedPaths(definition, snapshot: snapshot),
      issues: issues,
      riskLevel: definition.riskLevel
    )
  }

  private func isInstalled(_ definition: ShellPluginDefinition, snapshot: ShellPluginDetectionSnapshot) -> Bool {
    switch definition.id {
    case "zsh-autosuggestions":
      return snapshot.existingPaths.contains("/opt/homebrew/share/zsh-autosuggestions/zsh-autosuggestions.zsh")
        || snapshot.existingPaths.contains("/usr/local/share/zsh-autosuggestions/zsh-autosuggestions.zsh")
        || snapshot.existingPaths.contains("\(snapshot.homeDirectory)/.oh-my-zsh/custom/plugins/zsh-autosuggestions")
    case "zsh-syntax-highlighting":
      return snapshot.existingPaths.contains("/opt/homebrew/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh")
        || snapshot.existingPaths.contains("/usr/local/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh")
        || snapshot.existingPaths.contains("\(snapshot.homeDirectory)/.oh-my-zsh/custom/plugins/zsh-syntax-highlighting")
    case "ripgrep":
      return snapshot.executableNames.contains("rg")
    case "powerlevel10k":
      return joinedConfig(snapshot).contains("powerlevel10k") || joinedConfig(snapshot).contains(".p10k.zsh")
    case "sdkman":
      return snapshot.existingPaths.contains("\(snapshot.homeDirectory)/.sdkman/bin/sdkman-init.sh")
        || snapshot.executableNames.contains("sdk")
    default:
      return snapshot.executableNames.contains(definition.id)
    }
  }

  private func isManaged(_ definition: ShellPluginDefinition, snapshot: ShellPluginDetectionSnapshot) -> Bool {
    managedConfig(snapshot).contains(definition.id) || managedConfig(snapshot).contains(snippetNeedle(definition))
  }

  private func externalSource(_ definition: ShellPluginDefinition, snapshot: ShellPluginDetectionSnapshot) -> PluginSource? {
    let zshrc = snapshot.fileContents["\(snapshot.homeDirectory)/.zshrc"] ?? ""
    let joinedExternal = snapshot.fileContents
      .filter { !$0.key.contains("/.your-terminal/shell/") }
      .map(\.value)
      .joined(separator: "\n")

    if zshrc.contains("plugins=("), zshrc.contains(definition.id) {
      return .ohMyZsh
    }
    if joinedExternal.contains(definition.id)
      || joinedExternal.contains(snippetNeedle(definition))
      || externalActivationAliases(for: definition).contains(where: { joinedExternal.contains($0) })
    {
      return .manualZshrc
    }
    return nil
  }

  private func installedSource(_ definition: ShellPluginDefinition, snapshot: ShellPluginDetectionSnapshot) -> PluginSource {
    if detectedPaths(definition, snapshot: snapshot).contains(where: { $0.contains("homebrew") || $0.contains("/opt/homebrew") || $0.contains("/usr/local") }) {
      return .homebrew
    }
    return .binaryPath
  }

  private func detectedPaths(_ definition: ShellPluginDefinition, snapshot: ShellPluginDetectionSnapshot) -> [String] {
    let paths = snapshot.existingPaths.filter { path in
      path.contains(definition.id)
        || (definition.id == "ripgrep" && path.hasSuffix("/rg"))
        || (definition.id == "sdkman" && path.contains(".sdkman"))
    }
    return Array(paths).sorted()
  }

  private func applyPromptConflicts(to detected: inout [DetectedShellPlugin]) {
    let activePromptIndexes = detected.indices.filter { index in
      detected[index].category == .prompt
        && [.activeExternal, .activeManaged, .conflict].contains(detected[index].status)
    }
    guard activePromptIndexes.count > 1 else { return }
    for index in activePromptIndexes {
      detected[index].status = .conflict
      detected[index].issues.append(PluginIssue(
        title: "Prompt conflict",
        message: "Prompt plugins are mutually exclusive. Keep only one active prompt integration.",
        severity: .error
      ))
    }
  }

  private func managedConfig(_ snapshot: ShellPluginDetectionSnapshot) -> String {
    snapshot.fileContents
      .filter { $0.key.contains("/.your-terminal/shell/") }
      .map(\.value)
      .joined(separator: "\n")
  }

  private func joinedConfig(_ snapshot: ShellPluginDetectionSnapshot) -> String {
    snapshot.fileContents.values.joined(separator: "\n")
  }

  private func snippetNeedle(_ definition: ShellPluginDefinition) -> String {
    definition.activationSnippets[.zsh] ?? definition.id
  }

  private func externalActivationAliases(for definition: ShellPluginDefinition) -> [String] {
    switch definition.id {
    case "powerlevel10k":
      [".p10k.zsh", "p10k"]
    case "starship":
      ["starship init"]
    default:
      []
    }
  }
}

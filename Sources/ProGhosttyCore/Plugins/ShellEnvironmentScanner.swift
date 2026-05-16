import Foundation

public struct ShellEnvironmentScanner {
  private let fileManager: FileManager
  private let environment: [String: String]
  private let detector: ShellPluginDetector
  private let configWriter: ShellConfigWriter

  public init(
    fileManager: FileManager = .default,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    detector: ShellPluginDetector = ShellPluginDetector(),
    configWriter: ShellConfigWriter = ShellConfigWriter()
  ) {
    self.fileManager = fileManager
    self.environment = environment
    self.detector = detector
    self.configWriter = configWriter
  }

  public func scan() -> ShellEnvironmentReport {
    let shell = environment["SHELL"] ?? "/bin/zsh"
    let home = environment["HOME"] ?? NSHomeDirectory()
    let snapshot = ShellPluginDetectionSnapshot(
      homeDirectory: home,
      defaultShell: shell,
      executableNames: executableNames(),
      existingPaths: existingKnownPaths(home: home),
      fileContents: readableShellConfig(home: home)
    )
    let detected = detector.detect(in: snapshot)
    let recommendations = detected.filter { plugin in
      guard let definition = ShellPluginCatalog.definition(id: plugin.definitionId) else { return false }
      return definition.shouldAutoRecommend && plugin.status == .notInstalled
    }

    return ShellEnvironmentReport(
      defaultShell: shell,
      zshExists: fileManager.isExecutableFile(atPath: "/bin/zsh") || executableNames().contains("zsh"),
      homebrewExists: fileManager.isExecutableFile(atPath: "/opt/homebrew/bin/brew")
        || fileManager.isExecutableFile(atPath: "/usr/local/bin/brew"),
      ohMyZshExists: fileManager.fileExists(atPath: "\(home)/.oh-my-zsh"),
      detectedPlugins: detected,
      recommendations: recommendations
    )
  }

  private func executableNames() -> Set<String> {
    let path = environment["PATH"] ?? "/bin:/usr/bin:/usr/local/bin:/opt/homebrew/bin"
    let fallbackDirs = ["/opt/homebrew/bin", "/usr/local/bin", "/bin", "/usr/bin"]
    var names: Set<String> = []
    let dirs = Array(Set(path.split(separator: ":").map(String.init) + fallbackDirs)).sorted()
    for dir in dirs {
      guard let entries = try? fileManager.contentsOfDirectory(atPath: dir) else { continue }
      for entry in entries where fileManager.isExecutableFile(atPath: "\(dir)/\(entry)") {
        names.insert(entry)
      }
    }
    return names
  }

  private func existingKnownPaths(home: String) -> Set<String> {
    let paths = [
      "\(home)/.oh-my-zsh",
      "\(home)/.oh-my-zsh/custom/plugins/zsh-autosuggestions",
      "\(home)/.oh-my-zsh/custom/plugins/zsh-syntax-highlighting",
      "\(home)/.sdkman/bin/sdkman-init.sh",
      "/opt/homebrew/share/zsh-autosuggestions/zsh-autosuggestions.zsh",
      "/usr/local/share/zsh-autosuggestions/zsh-autosuggestions.zsh",
      "/opt/homebrew/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh",
      "/usr/local/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh",
    ]
    return Set(paths.filter { fileManager.fileExists(atPath: $0) })
  }

  private func readableShellConfig(home: String) -> [String: String] {
    let paths = configWriter.readableConfigPaths(homeDirectory: home)

    var contents: [String: String] = [:]
    for path in paths {
      guard let data = fileManager.contents(atPath: path),
        let string = String(data: data, encoding: .utf8)
      else {
        continue
      }
      contents[path] = string
    }
    return contents
  }
}

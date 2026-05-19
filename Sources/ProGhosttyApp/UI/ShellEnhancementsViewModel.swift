import Foundation
import ProGhosttyCore

@MainActor
final class ShellEnhancementsViewModel: ObservableObject {
  @Published private(set) var report: ShellEnvironmentReport?
  @Published var selectedPlan: PluginInstallPlan?
  @Published private(set) var isScanning = false
  @Published private(set) var isApplying = false
  @Published private(set) var applyingPluginIDs: Set<String> = []
  @Published private(set) var message: String?
  @Published private(set) var latestRollbackManifest: BackupManifest?
  @Published private(set) var appliedPlanToken = UUID()

  private let homeDirectory: String
  private let configWriter: ShellConfigWriter
  private let planGenerator: InstallPlanGenerator

  init(
    homeDirectory: String = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory(),
    configWriter: ShellConfigWriter = ShellConfigWriter(),
    planGenerator: InstallPlanGenerator = InstallPlanGenerator()
  ) {
    self.homeDirectory = homeDirectory
    self.configWriter = configWriter
    self.planGenerator = planGenerator
  }

  var plugins: [DetectedShellPlugin] {
    report?.detectedPlugins ?? []
  }

  var recommendations: [DetectedShellPlugin] {
    report?.recommendations ?? []
  }

  func scan() {
    Task { await scanNow() }
  }

  func scanNow() async {
    isScanning = true
    message = nil
    let report = await Task.detached {
      ShellEnvironmentScanner().scan()
    }.value
    let homeDirectory = self.homeDirectory
    let manifest = try? await Task.detached {
      try RollbackManager().latestManifest(homeDirectory: homeDirectory)
    }.value
    self.report = report
    latestRollbackManifest = manifest
    isScanning = false
  }

  func previewInstall(pluginID: String) {
    Task { await preview(pluginID: pluginID, operation: .install) }
  }

  func previewUninstall(pluginID: String) {
    Task { await preview(pluginID: pluginID, operation: .uninstall) }
  }

  func applySelectedPlan() {
    guard let plan = selectedPlan else { return }
    Task { await apply(plan: plan) }
  }

  func rollbackLastChange() {
    Task { await rollback() }
  }

  private func preview(pluginID: String, operation: PluginPlanOperation) async {
    message = nil
    let existingFiles = await readExistingConfigFiles()
    let plan: PluginInstallPlan?
    switch operation {
    case .install:
      plan = planGenerator.installPlan(
        pluginIds: [pluginID],
        homeDirectory: homeDirectory,
        existingFiles: existingFiles
      )
    case .uninstall:
      plan = planGenerator.uninstallPlan(
        pluginIds: [pluginID],
        homeDirectory: homeDirectory,
        existingFiles: existingFiles
      )
    }

    if let plan {
      selectedPlan = plan
    } else {
      selectedPlan = nil
      message = operation == .install
        ? "This enhancement is detect-only or cannot be installed by ProGhostty."
        : "This enhancement cannot be uninstalled by ProGhostty."
    }
  }

  private func apply(plan: PluginInstallPlan) async {
    isApplying = true
    applyingPluginIDs = Set(plan.pluginIds)
    message = nil
    do {
      let receipt = try await Task.detached {
        try ShellPluginInstallExecutor().apply(plan: plan)
      }.value
      selectedPlan = nil
      message = "Applied. Backup manifest: \(receipt.manifestPath)"
      appliedPlanToken = UUID()
      await scanNow()
    } catch {
      message = "Plan failed: \(error.localizedDescription)"
    }
    isApplying = false
    applyingPluginIDs = []
  }

  private func rollback() async {
    isApplying = true
    applyingPluginIDs = []
    message = nil
    do {
      let homeDirectory = self.homeDirectory
      let manifest = try await Task.detached {
        try RollbackManager().rollbackLatest(homeDirectory: homeDirectory)
      }.value
      if let manifest {
        message = "Rolled back files from \(manifest.backupDirectory)"
      } else {
        message = "No backup manifest found."
      }
      await scanNow()
    } catch {
      message = "Rollback failed: \(error.localizedDescription)"
    }
    isApplying = false
  }

  private func readExistingConfigFiles() async -> [String: String] {
    let paths = configWriter.readableConfigPaths(homeDirectory: homeDirectory)
    return await Task.detached {
      let fileManager = FileManager.default
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
    }.value
  }
}

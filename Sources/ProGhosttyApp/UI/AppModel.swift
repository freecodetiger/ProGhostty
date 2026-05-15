import AppKit
import Foundation
import ProGhosttyCore
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
  struct TerminalTab: Identifiable, Equatable {
    let id: TerminalSessionID
    var title: String
    var output: String
    var cwd: String?
    var lastBlock: CommandBlock?
  }

  enum Section: String, CaseIterable, Identifiable {
    case terminals = "Terminals"
    case history = "History"
    case workspaces = "Workspaces"
    case plugins = "Plugins"
    case settings = "Settings"

    var id: String { rawValue }
  }

  @Published var section: Section = .terminals
  @Published var tabs: [TerminalTab] = []
  @Published var selectedTabID: TerminalSessionID?
  @Published var commandLine = ""
  @Published var historySearch = ""
  @Published var historyResults: [CommandBlock] = []
  @Published var workspaces: [Workspace] = []
  @Published var settings: AppSettings
  @Published var pluginReport: ShellEnvironmentReport
  @Published var shellIntegrationState = "partial"

  private let engine: TerminalEngine
  private var indexer: CommandBlockIndexer
  private let historyStore: HistoryStore?
  private let workspaceStore: WorkspaceStore?
  private let settingsStore: SettingsStore
  private let pluginScanner = ShellEnvironmentScanner()

  init() {
    settingsStore = SettingsStore()
    let loadedSettings = settingsStore.load()
    settings = loadedSettings
    if let database = Self.openDatabase() {
      historyStore = HistoryStore(database: database)
      workspaceStore = WorkspaceStore(database: database)
    } else {
      historyStore = nil
      workspaceStore = nil
    }
    engine = MockTerminalEngine()
    indexer = CommandBlockIndexer(maxPreviewBytes: loadedSettings.maxOutputPreviewKB * 1024)
    pluginReport = pluginScanner.scan()

    Task { await consumeEvents() }
    refreshWorkspaces()
    openTerminal()
  }

  func openTerminal(workspace: Workspace? = nil) {
    let cwd =
      workspace?.rootPath ?? settings.defaultWorkingDirectory
      ?? FileManager.default.currentDirectoryPath
    let config = TerminalSessionConfig(
      shellPath: workspace?.defaultShell ?? settings.defaultShell,
      workingDirectory: cwd,
      environment: [:],
      rows: 24,
      cols: 80,
      workspaceId: workspace?.id
    )

    do {
      let id = try engine.createSession(config: config)
      indexer.associate(session: id, workspaceId: workspace?.id)
      tabs.append(TerminalTab(id: id, title: cwd, output: "", cwd: cwd, lastBlock: nil))
      selectedTabID = id
      section = .terminals
    } catch {
      shellIntegrationState = "terminal unavailable: \(error.localizedDescription)"
    }
  }

  func closeSelectedTerminal() {
    guard let selectedTabID else { return }
    engine.closeSession(selectedTabID)
    tabs.removeAll { $0.id == selectedTabID }
    self.selectedTabID = tabs.last?.id
  }

  func sendCommand() {
    guard let selectedTabID else { return }
    let command = commandLine
    commandLine = ""
    engine.writeInput(Data((command + "\n").utf8), to: selectedTabID)
  }

  func rerun(_ block: CommandBlock) {
    guard let command = block.command, let selectedTabID else { return }
    let payload = settings.rerunAutoEnter ? command + "\n" : command
    engine.writeInput(Data(payload.utf8), to: selectedTabID)
    section = .terminals
  }

  func createWorkspace(name: String, rootPath: String?) {
    let workspace = Workspace(name: name.isEmpty ? "Workspace" : name, rootPath: rootPath)
    try? workspaceStore?.save(workspace)
    refreshWorkspaces()
  }

  func deleteWorkspace(_ workspace: Workspace) {
    try? workspaceStore?.delete(id: workspace.id)
    refreshWorkspaces()
  }

  func saveSettings() {
    try? settingsStore.save(settings)
  }

  func searchHistory() {
    historyResults =
      (try? historyStore?.search(HistoryQuery(text: historySearch.isEmpty ? nil : historySearch)))
      ?? []
  }

  func clearHistory() {
    try? historyStore?.deleteAll()
    historyResults = []
  }

  func refreshPlugins() {
    pluginReport = pluginScanner.scan()
  }

  private func refreshWorkspaces() {
    workspaces = (try? workspaceStore?.all()) ?? []
  }

  private func consumeEvents() async {
    for await event in engine.events {
      handle(event)
    }
  }

  private func handle(_ event: TerminalEvent) {
    switch event {
    case .output(let session, let data):
      updateTab(session) { tab in
        tab.output += String(decoding: data, as: UTF8.self)
      }
    case .cwdChanged(let session, let cwd):
      shellIntegrationState = "available"
      updateTab(session) { tab in tab.cwd = cwd }
    case .osc:
      shellIntegrationState = "available"
    case .error(_, let message):
      shellIntegrationState = message
    default:
      break
    }

    guard settings.commandBlocksEnabled else { return }
    let changes = indexer.process(event)
    for block in changes {
      updateTab(block.sessionId) { tab in tab.lastBlock = block }
      if settings.historyEnabled, block.status != .running {
        try? historyStore?.upsert(block)
        searchHistory()
      }
    }
  }

  private func updateTab(_ id: TerminalSessionID, _ update: (inout TerminalTab) -> Void) {
    guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
    update(&tabs[index])
  }

  private static func openDatabase() -> HistoryDatabase? {
    let appSupport = FileManager.default.urls(
      for: .applicationSupportDirectory, in: .userDomainMask
    ).first!
    .appendingPathComponent("ProGhostty", isDirectory: true)
    try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)

    do {
      return try HistoryDatabase(path: appSupport.appendingPathComponent("proghostty.sqlite").path)
    } catch {
      let fallback = FileManager.default.temporaryDirectory
        .appendingPathComponent("proghostty-\(UUID().uuidString).sqlite")
      return try? HistoryDatabase(path: fallback.path)
    }
  }
}

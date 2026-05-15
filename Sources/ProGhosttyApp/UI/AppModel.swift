import AppKit
import Foundation
import ProGhosttyCore
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
  struct WorkspaceRuntime: Identifiable, Equatable {
    var layout: WorkspaceLayout
    var workspace: Workspace?
    var outputBySession: [TerminalSessionID: String]
    var cwdBySession: [TerminalSessionID: String]
    var lastBlockBySession: [TerminalSessionID: CommandBlock]

    var id: UUID {
      layout.id
    }

    var title: String {
      workspace?.name ?? layout.title
    }

    var displayPath: String? {
      workspace?.rootPath ?? cwdBySession.values.first
    }

    @MainActor func selectedSessionID(focusStore: TerminalFocusStore) -> TerminalSessionID? {
      focusStore.focusedSessionId(in: layout)
        ?? PaneTreeReducer.listLeaves(in: layout.root).first?.sessionId
    }

    @MainActor func selectedCwd(focusStore: TerminalFocusStore) -> String? {
      guard let selectedSessionID = selectedSessionID(focusStore: focusStore) else { return nil }
      return cwdBySession[selectedSessionID]
    }

    @MainActor func selectedLastBlock(focusStore: TerminalFocusStore) -> CommandBlock? {
      guard let selectedSessionID = selectedSessionID(focusStore: focusStore) else { return nil }
      return lastBlockBySession[selectedSessionID]
    }

    @MainActor func selectedOutput(focusStore: TerminalFocusStore) -> String {
      guard let selectedSessionID = selectedSessionID(focusStore: focusStore) else { return "" }
      return outputBySession[selectedSessionID] ?? ""
    }
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
  @Published var workspaceRuntimes: [WorkspaceRuntime] = []
  @Published var activeWorkspaceID: UUID?
  @Published var isWorkspaceSwitcherPresented = false
  @Published var workspaceSwitcherState = WorkspaceSwitcherState(workspaces: [], activeWorkspaceID: nil)
  @Published var commandLine = ""
  @Published var historySearch = ""
  @Published var historyResults: [CommandBlock] = []
  @Published var workspaces: [Workspace] = []
  @Published var settings: AppSettings
  @Published var pluginReport: ShellEnvironmentReport
  @Published var shellIntegrationState = "partial"

  private let sessionManager: TerminalSessionManager
  private let surfaceRegistry: TerminalSurfaceRegistry
  private let paneWorkspaceController: PaneWorkspaceController
  private let focusStore = TerminalFocusStore()
  private var indexer: CommandBlockIndexer
  private let historyStore: HistoryStore?
  private let workspaceStore: WorkspaceStore?
  private let settingsStore: SettingsStore
  private let pluginScanner = ShellEnvironmentScanner()

  init() {
    DebugLog.write("AppModel init")
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
    let surfaceRegistry = PTYTerminalSurfaceRegistry()
    let sessionManager = PTYTerminalSessionManager(surfaceRegistry: surfaceRegistry)
    self.surfaceRegistry = surfaceRegistry
    self.sessionManager = sessionManager
    paneWorkspaceController = PaneWorkspaceController(sessionManager: sessionManager, focusStore: focusStore)
    indexer = CommandBlockIndexer(maxPreviewBytes: loadedSettings.maxOutputPreviewKB * 1024)
    pluginReport = pluginScanner.scan()

    surfaceRegistry.setInputHandler { [weak self] sourceSession, data in
      self?.routeTerminalInput(data, from: sourceSession)
    }
    surfaceRegistry.setActivationHandler { [weak self] session in
      self?.selectSession(session)
    }

    Task { await consumeEvents() }
    refreshWorkspaces()
    createAndActivateWorkspace()
  }

  func createAndActivateWorkspace(workspace: Workspace? = nil) {
    let cwd =
      workspace?.rootPath ?? settings.defaultWorkingDirectory
      ?? FileManager.default.currentDirectoryPath

    do {
      let opened = try paneWorkspaceController.openTerminal(
        title: workspace?.name ?? cwd,
        config: sessionConfig(workspace: workspace, workingDirectory: cwd),
        paneTitle: URL(fileURLWithPath: cwd).lastPathComponent,
        cwd: cwd
      )
      indexer.associate(session: opened.pane.sessionId, workspaceId: workspace?.id)
      let runtime = WorkspaceRuntime(
        layout: opened.workspace,
        workspace: workspace,
        outputBySession: [opened.pane.sessionId: ""],
        cwdBySession: [opened.pane.sessionId: cwd],
        lastBlockBySession: [:]
      )
      workspaceRuntimes.append(runtime)
      activeWorkspaceID = paneWorkspaceController.activeWorkspaceID
      syncWorkspaceSwitcherState()
      section = .terminals
    } catch {
      shellIntegrationState = "terminal unavailable: \(error.localizedDescription)"
    }
  }

  func openTerminal(workspace: Workspace? = nil) {
    createAndActivateWorkspace(workspace: workspace)
  }

  func closeSelectedTerminal() {
    guard let closed = paneWorkspaceController.closeSelectedTerminal() else { return }
    workspaceRuntimes.removeAll { $0.id == closed.workspaceID }
    activeWorkspaceID = paneWorkspaceController.activeWorkspaceID
    syncWorkspaceSwitcherState()
  }

  func sendCommand() {
    guard let selectedSessionID else { return }
    let command = commandLine
    commandLine = ""
    sessionManager.writeInput(Data((command + "\n").utf8), to: selectedSessionID)
  }

  func surfaceView(for id: TerminalSessionID) -> NSView? {
    surfaceRegistry.viewForSession(id)
  }

  var activeWorkspace: WorkspaceRuntime? {
    guard let activeWorkspaceID else { return nil }
    return workspaceRuntimes.first { $0.id == activeWorkspaceID }
  }

  var activeWorkspaceTitle: String {
    guard let activeWorkspace else { return "ProGhostty" }
    let title = activeWorkspace.title
    if title == FileManager.default.currentDirectoryPath {
      return URL(fileURLWithPath: title).lastPathComponent
    }
    return title.isEmpty ? "ProGhostty" : title
  }

  var selectedSessionID: TerminalSessionID? {
    activeWorkspace?.selectedSessionID(focusStore: focusStore)
  }

  var selectedPaneID: UUID? {
    guard let activeWorkspaceID else { return nil }
    return focusStore.focusedPaneId(in: activeWorkspaceID)
  }

  var selectedOutput: String {
    activeWorkspace?.selectedOutput(focusStore: focusStore) ?? ""
  }

  var selectedCwd: String? {
    activeWorkspace?.selectedCwd(focusStore: focusStore)
  }

  var selectedLastBlock: CommandBlock? {
    activeWorkspace?.selectedLastBlock(focusStore: focusStore)
  }

  func activateWorkspace(_ workspaceID: UUID) {
    guard workspaceRuntimes.contains(where: { $0.id == workspaceID }) else { return }
    paneWorkspaceController.activeWorkspaceID = workspaceID
    activeWorkspaceID = workspaceID
    syncWorkspaceSwitcherState()
  }

  func selectPane(_ paneID: UUID) {
    DebugLog.write("selectPane requested pane=\(paneID)")
    guard let activeWorkspaceID else {
      DebugLog.write("selectPane ignored: no active workspace")
      return
    }
    guard paneWorkspaceController.selectPane(paneID, in: activeWorkspaceID) else {
      DebugLog.write("selectPane ignored: pane not found")
      return
    }
    self.activeWorkspaceID = paneWorkspaceController.activeWorkspaceID
    syncWorkspaceSwitcherState()
    objectWillChange.send()
  }

  func selectSession(_ sessionID: TerminalSessionID) {
    guard let workspace = paneWorkspaceController.selectSession(sessionID) else { return }
    if activeWorkspaceID != workspace.id {
      activeWorkspaceID = workspace.id
      syncWorkspaceSwitcherState()
    } else {
      objectWillChange.send()
    }
  }

  func splitSelectedTerminal(axis: TerminalSplitAxis) {
    guard let paneID = selectedPaneID else { return }
    splitPane(paneID, axis: axis)
  }

  func splitPane(_ paneID: UUID, axis: TerminalSplitAxis) {
    DebugLog.write("splitPane requested pane=\(paneID) axis=\(axis)")
    guard let activeWorkspaceID, let index = workspaceRuntimes.firstIndex(where: { $0.id == activeWorkspaceID }) else {
      DebugLog.write("splitPane ignored: no active workspace")
      return
    }
    var runtime = workspaceRuntimes[index]
    DebugLog.write("splitPane before leaves=\(PaneTreeReducer.listLeaves(in: runtime.layout.root).count)")
    let workspace = runtime.workspace
    let cwd = runtime.selectedCwd(focusStore: focusStore) ?? workspace?.rootPath ?? settings.defaultWorkingDirectory
      ?? FileManager.default.currentDirectoryPath

    do {
      let split = try paneWorkspaceController.splitPane(
        workspaceID: activeWorkspaceID,
        paneID: paneID,
        axis: axis,
        config: sessionConfig(workspace: workspace, workingDirectory: cwd),
        paneTitle: URL(fileURLWithPath: cwd).lastPathComponent,
        cwd: cwd
      )
      indexer.associate(session: split.pane.sessionId, workspaceId: workspace?.id)
      runtime.layout = split.workspace
      runtime.outputBySession[split.pane.sessionId] = ""
      runtime.cwdBySession[split.pane.sessionId] = cwd
      workspaceRuntimes[index] = runtime
      self.activeWorkspaceID = paneWorkspaceController.activeWorkspaceID
      syncWorkspaceSwitcherState()
      DebugLog.write("splitPane success newPane=\(split.pane.paneId) session=\(split.pane.sessionId) leaves=\(PaneTreeReducer.listLeaves(in: runtime.layout.root).count)")
    } catch {
      shellIntegrationState = "split unavailable: \(error.localizedDescription)"
      DebugLog.write("splitPane failed error=\(error.localizedDescription)")
    }
  }

  func closeSelectedPane() {
    guard let paneID = selectedPaneID else { return }
    closePane(paneID)
  }

  func closePane(_ paneID: UUID) {
    guard
      let activeWorkspaceID,
      let index = workspaceRuntimes.firstIndex(where: { $0.id == activeWorkspaceID })
    else {
      return
    }

    var runtime = workspaceRuntimes[index]
    let leavesBefore = PaneTreeReducer.listLeaves(in: runtime.layout.root)
    DebugLog.write("closePane requested pane=\(paneID) leavesBefore=\(leavesBefore.count)")
    do {
      guard let closed = try paneWorkspaceController.closePane(workspaceID: activeWorkspaceID, paneID: paneID) else {
        DebugLog.write("closePane closing terminal because reducer returned nil")
        closeSelectedTerminal()
        return
      }
      guard let updatedLayout = paneWorkspaceController.workspaceLayout(id: activeWorkspaceID) else { return }
      runtime.layout = updatedLayout
      runtime.outputBySession[closed.sessionId] = nil
      runtime.cwdBySession[closed.sessionId] = nil
      runtime.lastBlockBySession[closed.sessionId] = nil
      workspaceRuntimes[index] = runtime
      let leavesAfter = PaneTreeReducer.listLeaves(in: runtime.layout.root)
      DebugLog.write("closePane success closed=\(closed.paneId) leavesAfter=\(leavesAfter.count) next=\(focusStore.focusedPaneId(in: activeWorkspaceID)?.uuidString ?? "-")")
    } catch {
      DebugLog.write("closePane failed error=\(error)")
    }
  }

  func rerun(_ block: CommandBlock) {
    guard let command = block.command, let selectedSessionID else { return }
    let payload = settings.rerunAutoEnter ? command + "\n" : command
    sessionManager.writeInput(Data(payload.utf8), to: selectedSessionID)
    section = .terminals
  }

  private func routeTerminalInput(_ data: Data, from sourceSession: TerminalSessionID) {
    guard let focusedSessionID = selectedSessionID, focusedSessionID == sourceSession else { return }
    sessionManager.writeInput(data, to: focusedSessionID)
  }

  func createWorkspace(name: String, rootPath: String?) {
    let workspace = Workspace(name: name.isEmpty ? "Workspace" : name, rootPath: rootPath)
    try? workspaceStore?.save(workspace)
    refreshWorkspaces()
  }

  func createAndOpenWorkspace(name: String, rootPath: String? = nil) {
    let workspace = Workspace(name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Workspace" : name, rootPath: rootPath)
    try? workspaceStore?.save(workspace)
    refreshWorkspaces()
    createAndActivateWorkspace(workspace: workspace)
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

  func resizePane(_ paneID: UUID, rows: Int, cols: Int) {
    guard let workspace = activeWorkspace else { return }
    paneWorkspaceController.resizePane(paneID, in: workspace.id, rows: rows, cols: cols)
  }

  func updateSplitRatio(_ splitID: UUID, ratio: Double) {
    guard let activeWorkspaceID, let index = workspaceRuntimes.firstIndex(where: { $0.id == activeWorkspaceID }) else {
      return
    }
    if paneWorkspaceController.updateSplitRatio(splitID, in: activeWorkspaceID, ratio: ratio),
      let layout = paneWorkspaceController.workspaceLayout(id: activeWorkspaceID)
    {
      workspaceRuntimes[index].layout = layout
    }
  }

  func focusNeighbor(offset: Int) {
    guard
      let workspace = activeWorkspace,
      let next = paneWorkspaceController.focusNeighbor(in: workspace.id, offset: offset)
    else {
      return
    }
    selectPane(next)
  }

  func openWorkspaceSwitcher() {
    syncWorkspaceSwitcherState()
    isWorkspaceSwitcherPresented = true
  }

  func closeWorkspaceSwitcher() {
    isWorkspaceSwitcherPresented = false
  }

  func updateWorkspaceSwitcherQuery(_ query: String) {
    workspaceSwitcherState.query = query
  }

  func moveWorkspaceSwitcherSelection(delta: Int) {
    workspaceSwitcherState.moveSelection(delta: delta)
  }

  func activateWorkspaceFromSwitcher(_ workspaceListID: UUID) {
    workspaceSwitcherState.selectedWorkspaceID = workspaceListID
    activateWorkspaceSwitcherSelection()
  }

  func focusWorkspaceNeighbor(offset: Int) {
    let items = workspaceSwitcherState.workspaces
    guard !items.isEmpty else { return }
    let activeID = workspaceSwitcherState.activeWorkspaceID
    let currentIndex = activeID.flatMap { active in
      items.firstIndex { $0.id == active }
    } ?? 0
    let nextIndex = (currentIndex + offset + items.count) % items.count
    activateWorkspaceFromSwitcher(items[nextIndex].id)
  }

  func activateWorkspaceSwitcherSelection() {
    guard let selected = workspaceSwitcherState.selectedWorkspaceID else {
      if workspaceSwitcherState.canCreateWorkspaceFromQuery {
        createAndOpenWorkspace(name: workspaceSwitcherState.query)
        closeWorkspaceSwitcher()
      }
      return
    }

    if let runtime = workspaceRuntimes.first(where: { runtime in
      runtime.workspace?.id == selected || runtime.id == selected
    }) {
      activateWorkspace(runtime.id)
      closeWorkspaceSwitcher()
      return
    }

    if let workspace = workspaces.first(where: { $0.id == selected }) {
      createAndActivateWorkspace(workspace: workspace)
      closeWorkspaceSwitcher()
    }
  }

  func sessionCount(forWorkspaceListID workspaceListID: UUID) -> Int {
    guard let runtime = workspaceRuntimes.first(where: { runtime in
      runtime.workspace?.id == workspaceListID || runtime.id == workspaceListID
    }) else {
      return 0
    }
    return PaneTreeReducer.listLeaves(in: runtime.layout.root).count
  }

  private func refreshWorkspaces() {
    workspaces = (try? workspaceStore?.all()) ?? []
    syncWorkspaceSwitcherState()
  }

  private func syncWorkspaceSwitcherState() {
    let runtimeWorkspaces = workspaceRuntimes.map { runtime in
      runtime.workspace ?? Workspace(
        id: runtime.id,
        name: runtime.title,
        rootPath: runtime.displayPath
      )
    }
    var combined = runtimeWorkspaces
    for workspace in workspaces where !combined.contains(where: { $0.id == workspace.id }) {
      combined.append(workspace)
    }
    let activeID = activeWorkspace?.workspace?.id ?? activeWorkspaceID
    var next = WorkspaceSwitcherState(workspaces: combined, activeWorkspaceID: activeID)
    next.query = workspaceSwitcherState.query
    workspaceSwitcherState = next
  }

  private func sessionConfig(workspace: Workspace?, workingDirectory: String?) -> TerminalSessionConfig {
    TerminalSessionConfig(
      shellPath: workspace?.defaultShell ?? settings.defaultShell,
      workingDirectory: workingDirectory,
      environment: [:],
      rows: 24,
      cols: 80,
      workspaceId: workspace?.id
    )
  }

  private func consumeEvents() async {
    for await event in sessionManager.events {
      handle(event)
    }
  }

  private func handle(_ event: TerminalEvent) {
    switch event {
    case .output(let session, let data):
      updateWorkspaceForSession(session) { workspace in
        workspace.outputBySession[session, default: ""] += String(decoding: data, as: UTF8.self)
      }
    case .cwdChanged(let session, let cwd):
      shellIntegrationState = "available"
      updateWorkspaceForSession(session) { workspace in workspace.cwdBySession[session] = cwd }
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
      updateWorkspaceForSession(block.sessionId) { workspace in workspace.lastBlockBySession[block.sessionId] = block }
      if settings.historyEnabled, block.status != .running {
        try? historyStore?.upsert(block)
        searchHistory()
      }
    }
  }

  private func updateWorkspaceForSession(_ id: TerminalSessionID, _ update: (inout WorkspaceRuntime) -> Void) {
    guard
      let index = workspaceRuntimes.firstIndex(where: { workspace in
        PaneTreeReducer.listLeaves(in: workspace.layout.root).contains { $0.sessionId == id }
      })
    else {
      return
    }
    update(&workspaceRuntimes[index])
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

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
    case plugins = "Plugins"
    case settings = "Settings"

    var id: String { rawValue }
  }

  @Published var section: Section = .terminals
  @Published var workspaceRuntimes: [WorkspaceRuntime] = []
  @Published var activeWorkspaceID: UUID?
  @Published var isWorkspaceSwitcherPresented = false
  @Published var isHistoryPresented = false
  @Published var isPluginManagerPresented = false
  @Published var workspaceSwitcherState = WorkspaceSwitcherState(workspaces: [], activeWorkspaceID: nil)
  @Published var titlebarToast: TitlebarToast?
  @Published var commandLine = ""
  @Published var historySearch = ""
  @Published var historyResults: [CommandBlock] = []
  @Published var workspaces: [Workspace] = []
  @Published var settings: AppSettings {
    didSet {
      applyTerminalAppearance()
    }
  }
  @Published var requestedPluginPlanID: String?
  @Published var shellIntegrationState = "partial"

  private let sessionManager: TerminalSessionManager
  private let surfaceRegistry: TerminalSurfaceRegistry
  private let paneWorkspaceController: PaneWorkspaceController
  private let focusStore = TerminalFocusStore()
  private var indexer: CommandBlockIndexer
  private let historyStore: HistoryStore?
  private let workspaceStore: WorkspaceStore?
  private let settingsStore: SettingsStore
  private let terminalActionDispatcher = TerminalActionDispatcher()
  private var settingsWindowController: NSWindowController?
  private var savedLayoutSnapshots: [UUID: WorkspaceLayout] = [:]
  private var titlebarToastTask: Task<Void, Never>?

  struct TitlebarToast: Equatable, Sendable {
    var message: String
    var style: Style

    enum Style: Equatable, Sendable {
      case success
    }
  }

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

    surfaceRegistry.setInputHandler { [weak self] sourceSession, data in
      self?.routeTerminalInput(data, from: sourceSession)
    }
    surfaceRegistry.setActivationHandler { [weak self] session in
      self?.selectSession(session)
    }
    applyTerminalAppearance()

    Task { await consumeEvents() }
    refreshWorkspaces()
    createAndActivateWorkspace()
  }

  func createAndActivateWorkspace(workspace: Workspace? = nil) {
    let cwd = AppSettings.terminalWorkingDirectory(
      workspaceRootPath: workspace?.rootPath,
      defaultWorkingDirectory: settings.defaultWorkingDirectory
    )

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

  var activeTitlebarLabel: String {
    let workspace = compactTitlebarTitle(activeWorkspaceTitle)
    guard let cwd = compactPathComponent(selectedCwd ?? activeWorkspace?.displayPath),
      cwd != workspace
    else {
      return workspace
    }
    return "\(workspace) · \(cwd)"
  }

  var activeTitlebarTooltip: String? {
    guard activeWorkspace != nil else { return nil }
    let fullPath = displayPath(selectedCwd ?? activeWorkspace?.displayPath) ?? "-"
    let paneCount = activeWorkspacePaneCount
    let workspaceCount = workspaceRuntimes.count
    let paneLabel = paneCount == 1 ? "pane" : "panes"
    let workspaceLabel = workspaceCount == 1 ? "workspace" : "workspaces"
    return """
    \(activeWorkspaceTitle)
    \(fullPath)
    \(paneCount) \(paneLabel) · \(workspaceCount) running \(workspaceLabel)
    """
  }

  var appText: AppText {
    AppText(language: settings.appLanguage)
  }

  var appColorScheme: ColorScheme? {
    guard !settings.followSystemAppearance else { return nil }
    return settings.themeName == "light" ? .light : .dark
  }

  var terminalPalette: TerminalSurfacePalette {
    effectiveThemeName == "light" ? .light : .dark
  }

  var usesDarkAppearance: Bool {
    effectiveThemeName == "dark"
  }

  var terminalBackgroundColor: NSColor {
    terminalPalette.background
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

  private var activeWorkspacePaneCount: Int {
    guard let activeWorkspace else { return 0 }
    return PaneTreeReducer.listLeaves(in: activeWorkspace.layout.root).count
  }

  func activateWorkspace(_ workspaceID: UUID) {
    guard workspaceRuntimes.contains(where: { $0.id == workspaceID }) else { return }
    paneWorkspaceController.activeWorkspaceID = workspaceID
    activeWorkspaceID = workspaceID
    syncWorkspaceSwitcherState()
    closeUtilityOverlays()
  }

  func switchWorkspace(named name: String) {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    if let runtime = workspaceRuntimes.first(where: { $0.title == trimmed }) {
      activateWorkspace(runtime.id)
      return
    }
    if let workspace = workspaces.first(where: { $0.name == trimmed }) {
      createAndActivateWorkspace(workspace: workspace)
    }
  }

  func openWorkspaceCreation(named name: String) {
    syncWorkspaceSwitcherState()
    isWorkspaceSwitcherPresented = true
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
      applyFocusedTerminalSurface()
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
    let cwd = runtime.selectedCwd(focusStore: focusStore) ?? AppSettings.terminalWorkingDirectory(
      workspaceRootPath: workspace?.rootPath,
      defaultWorkingDirectory: settings.defaultWorkingDirectory
    )

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
      applyFocusedTerminalSurface()
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
    closeUtilityOverlays()
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
    let resolvedRootPath = AppSettings.workspaceRootPathForNewWorkspace(
      requestedRootPath: rootPath,
      defaultWorkingDirectory: settings.defaultWorkingDirectory
    )
    let workspace = Workspace(name: normalizedWorkspaceName(name), rootPath: resolvedRootPath)
    try? workspaceStore?.save(workspace)
    refreshWorkspaces()
    createAndActivateWorkspace(workspace: workspace)
  }

  func deleteWorkspace(_ workspace: Workspace) {
    let runtime = workspaceRuntimes.first { runtime in
      runtime.workspace?.id == workspace.id || runtime.id == workspace.id
    }
    let paneCount = runtime.map { PaneTreeReducer.listLeaves(in: $0.layout.root).count } ?? 0
    guard confirmWorkspaceDeletion(workspace, runningPaneCount: paneCount) else { return }

    if let runtime {
      closeWorkspaceRuntime(id: runtime.id)
    }
    try? workspaceStore?.delete(id: workspace.id)
    refreshWorkspaces()
  }

  func deleteWorkspaceFromSwitcher(_ workspaceListID: UUID) {
    let runtime = workspaceRuntimes.first { runtime in
      runtime.workspace?.id == workspaceListID || runtime.id == workspaceListID
    }
    let workspace = workspaces.first { $0.id == workspaceListID } ?? runtime?.workspace
      ?? runtime.map { Workspace(id: workspaceListID, name: $0.title, rootPath: $0.displayPath) }
    guard let workspace else { return }

    let paneCount = runtime.map { PaneTreeReducer.listLeaves(in: $0.layout.root).count } ?? 0
    guard confirmWorkspaceDeletion(workspace, runningPaneCount: paneCount) else { return }

    if let runtime {
      closeWorkspaceRuntime(id: runtime.id)
    }
    try? workspaceStore?.delete(id: workspace.id)
    refreshWorkspaces()
  }

  func createWorkspaceFromSwitcher() {
    createAndOpenWorkspace(name: "")
    closeWorkspaceSwitcher()
  }

  func renameWorkspaceFromSwitcher(_ workspaceListID: UUID, to name: String) {
    let nextName = normalizedWorkspaceName(name)
    if let runtimeIndex = workspaceRuntimes.firstIndex(where: { runtime in
      runtime.workspace?.id == workspaceListID || runtime.id == workspaceListID
    }) {
      var runtime = workspaceRuntimes[runtimeIndex]
      runtime.layout.title = nextName
      if var workspace = runtime.workspace {
        workspace.name = nextName
        workspace.updatedAt = Date()
        try? workspaceStore?.save(workspace)
        runtime.workspace = workspace
      } else {
        let workspace = Workspace(
          id: runtime.id,
          name: nextName,
          rootPath: runtime.displayPath
        )
        try? workspaceStore?.save(workspace)
        runtime.workspace = workspace
      }
      workspaceRuntimes[runtimeIndex] = runtime
      paneWorkspaceController.replaceWorkspaceLayout(runtime.layout)
      refreshWorkspaces()
      return
    }

    guard var workspace = workspaces.first(where: { $0.id == workspaceListID }) else { return }
    workspace.name = nextName
    workspace.updatedAt = Date()
    try? workspaceStore?.save(workspace)
    refreshWorkspaces()
  }

  func saveSettings() {
    try? settingsStore.save(settings)
    showTitlebarToast(appText.settingsSavedToast, style: .success)
  }

  func resetSettings() {
    settings = .defaults
    saveSettings()
  }

  func closeSettingsWindow() {
    settingsWindowController?.window?.close()
  }

  func appVersionString() -> String {
    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
    switch (version?.isEmpty == false ? version : nil, build?.isEmpty == false ? build : nil) {
    case (.some(let version), .some(let build)):
      return "\(version) (\(build))"
    case (.some(let version), .none):
      return version
    case (.none, .some(let build)):
      return build
    case (.none, .none):
      return "0.1.0"
    }
  }

  func openSettingsWindow() {
    if let window = settingsWindowController?.window {
      applySettingsWindowAppearance(to: window)
      window.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
      return
    }

    let controller = NSHostingController(
      rootView: SettingsView()
        .environmentObject(self)
        .preferredColorScheme(appColorScheme)
    )
    let window = NSWindow(contentViewController: controller)
    window.title = "Settings"
    window.styleMask = [.titled, .closable, .miniaturizable]
    window.setContentSize(NSSize(width: 640, height: 520))
    window.minSize = NSSize(width: 560, height: 460)
    window.isReleasedWhenClosed = false
    window.center()
    window.toolbarStyle = .preference
    applySettingsWindowAppearance(to: window)

    let windowController = NSWindowController(window: window)
    settingsWindowController = windowController
    windowController.showWindow(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  private func applyTerminalAppearance() {
    surfaceRegistry.applyPalette(terminalPalette)
    surfaceRegistry.applyFont(family: settings.fontFamily, size: CGFloat(settings.fontSize))
    applyFocusedTerminalSurface()
    for window in NSApp.windows where window !== settingsWindowController?.window {
      ProGhosttyWindowAppearance.applyTerminalChrome(
        to: window,
        backgroundColor: terminalBackgroundColor,
        usesDarkAppearance: usesDarkAppearance
      )
    }
    if let window = settingsWindowController?.window {
      applySettingsWindowAppearance(to: window)
    }
  }

  private func applySettingsWindowAppearance(to window: NSWindow) {
    window.appearance = NSAppearance(named: usesDarkAppearance ? .darkAqua : .aqua)
    window.backgroundColor = .controlBackgroundColor
    window.contentView?.wantsLayer = true
    window.contentView?.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
  }

  private func applyFocusedTerminalSurface() {
    surfaceRegistry.setFocusedSession(selectedSessionID)
  }

  private func restoreTerminalKeyboardFocus() {
    let session = selectedSessionID
    DispatchQueue.main.async { [weak self] in
      self?.surfaceRegistry.focusSessionView(session)
    }
  }

  private func showTitlebarToast(_ message: String, style: TitlebarToast.Style) {
    titlebarToastTask?.cancel()
    titlebarToast = TitlebarToast(message: message, style: style)
    titlebarToastTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: 1_800_000_000)
      await MainActor.run {
        self?.titlebarToast = nil
      }
    }
  }

  private func compactTitlebarTitle(_ title: String) -> String {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "ProGhostty" }
    return compactPathComponent(trimmed) ?? trimmed
  }

  private func compactPathComponent(_ path: String?) -> String? {
    guard let path, !path.isEmpty else { return nil }
    if path == "/" { return "/" }
    if path == NSHomeDirectory() { return "~" }
    guard path.hasPrefix("/") || path.hasPrefix("~") else { return path }
    let component = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath).lastPathComponent
    return component.isEmpty ? path : component
  }

  private func displayPath(_ path: String?) -> String? {
    guard let path, !path.isEmpty else { return nil }
    let home = NSHomeDirectory()
    if path == home { return "~" }
    if path.hasPrefix(home + "/") {
      return "~" + path.dropFirst(home.count)
    }
    return path
  }

  private func normalizedWorkspaceName(_ name: String) -> String {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "Workspace" : trimmed
  }

  private var effectiveThemeName: String {
    guard settings.followSystemAppearance else { return settings.themeName }
    let appearance = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
    return appearance == .aqua ? "light" : "dark"
  }

  func searchHistory() {
    historyResults =
      (try? historyStore?.search(HistoryQuery(text: historySearch.isEmpty ? nil : historySearch)))
      ?? []
  }

  func openHistory(search query: String? = nil) {
    if let query {
      historySearch = query
    }
    isPluginManagerPresented = false
    isWorkspaceSwitcherPresented = false
    isHistoryPresented = true
    searchHistory()
  }

  func closeHistory() {
    isHistoryPresented = false
  }

  func clearHistory() {
    try? historyStore?.deleteAll()
    historyResults = []
  }

  func openPlugins(scan: Bool = false) {
    if let window = settingsWindowController?.window {
      window.close()
      settingsWindowController = nil
    }
    isHistoryPresented = false
    isWorkspaceSwitcherPresented = false
    isPluginManagerPresented = true
    NSApp.activate(ignoringOtherApps: true)
  }

  func openPluginPlan(_ pack: String) {
    openPlugins()
    requestedPluginPlanID = pack
  }

  func closePlugins() {
    isPluginManagerPresented = false
  }

  func closeUtilityOverlays() {
    isHistoryPresented = false
    isPluginManagerPresented = false
    isWorkspaceSwitcherPresented = false
  }

  func resizePane(_ paneID: UUID, rows: Int, cols: Int) {
    guard let workspace = activeWorkspace else { return }
    paneWorkspaceController.resizePane(paneID, in: workspace.id, rows: rows, cols: cols)
  }

  func saveActiveLayoutSnapshot() {
    guard let activeWorkspace else { return }
    savedLayoutSnapshots[activeWorkspace.id] = activeWorkspace.layout
    shellIntegrationState = "layout saved"
  }

  func restoreActiveLayoutSnapshot() {
    guard
      let activeWorkspaceID,
      let saved = savedLayoutSnapshots[activeWorkspaceID],
      let index = workspaceRuntimes.firstIndex(where: { $0.id == activeWorkspaceID })
    else {
      shellIntegrationState = "no saved layout"
      return
    }

    let currentPanes = Set(PaneTreeReducer.listLeaves(in: workspaceRuntimes[index].layout.root).map(\.sessionId))
    let restoredPanes = Set(PaneTreeReducer.listLeaves(in: saved.root).map(\.sessionId))
    let removedSessions = currentPanes.subtracting(restoredPanes)
    if !removedSessions.isEmpty, !confirmLayoutRestoreClosingPanes(count: removedSessions.count) {
      return
    }
    for session in removedSessions {
      sessionManager.closeSession(session)
      workspaceRuntimes[index].outputBySession[session] = nil
      workspaceRuntimes[index].cwdBySession[session] = nil
      workspaceRuntimes[index].lastBlockBySession[session] = nil
    }

    workspaceRuntimes[index].layout = saved
    paneWorkspaceController.replaceWorkspaceLayout(saved)
    if let firstPane = PaneTreeReducer.listLeaves(in: saved.root).first {
      focusStore.focusPane(firstPane.paneId, in: saved.id)
    }
    syncWorkspaceSwitcherState()
    objectWillChange.send()
    shellIntegrationState = "layout restored"
  }

  private func confirmLayoutRestoreClosingPanes(count: Int) -> Bool {
    let alert = NSAlert()
    alert.messageText = "Restore layout?"
    alert.informativeText = "Restoring this layout will close \(count) pane session\(count == 1 ? "" : "s")."
    alert.alertStyle = .warning
    alert.addButton(withTitle: "Restore")
    alert.addButton(withTitle: "Cancel")
    return alert.runModal() == .alertFirstButtonReturn
  }

  private func confirmWorkspaceDeletion(_ workspace: Workspace, runningPaneCount: Int) -> Bool {
    let text = appText
    let alert = NSAlert()
    alert.messageText = text.deleteWorkspaceConfirmationTitle
    alert.informativeText = text.deleteWorkspaceConfirmationMessage(
      workspace.name,
      runningPaneCount: runningPaneCount
    )
    alert.alertStyle = .warning
    alert.addButton(withTitle: text.deleteWorkspace)
    alert.addButton(withTitle: text.cancel)
    alert.buttons.first?.keyEquivalent = "\r"
    return alert.runModal() == .alertFirstButtonReturn
  }

  @discardableResult
  private func closeWorkspaceRuntime(id runtimeID: UUID) -> [TerminalPane] {
    let runtimePanes = workspaceRuntimes
      .first { $0.id == runtimeID }
      .map { PaneTreeReducer.listLeaves(in: $0.layout.root) } ?? []
    guard let closed = paneWorkspaceController.closeWorkspace(workspaceID: runtimeID) else {
      for pane in runtimePanes {
        sessionManager.closeSession(pane.sessionId)
      }
      workspaceRuntimes.removeAll { $0.id == runtimeID }
      savedLayoutSnapshots[runtimeID] = nil
      activeWorkspaceID = paneWorkspaceController.activeWorkspaceID
      syncWorkspaceSwitcherState()
      return runtimePanes
    }
    workspaceRuntimes.removeAll { $0.id == closed.workspaceID }
    savedLayoutSnapshots[closed.workspaceID] = nil
    activeWorkspaceID = paneWorkspaceController.activeWorkspaceID
    syncWorkspaceSwitcherState()
    return closed.panes
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
    isHistoryPresented = false
    isPluginManagerPresented = false
    syncWorkspaceSwitcherState()
    isWorkspaceSwitcherPresented = true
  }

  func closeWorkspaceSwitcher() {
    isWorkspaceSwitcherPresented = false
    restoreTerminalKeyboardFocus()
  }

  func moveWorkspaceSwitcherSelection(delta: Int) {
    workspaceSwitcherState.moveSelection(delta: delta)
  }

  func selectWorkspaceCreationCard() {
    workspaceSwitcherState.selectCreateWorkspace()
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
      createWorkspaceFromSwitcher()
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
      if var workspace = runtime.workspace {
        if workspace.rootPath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
          workspace.rootPath = runtime.displayPath
        }
        return workspace
      }
      return Workspace(
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
    let runningIDs = Set(workspaceRuntimes.map { runtime in runtime.workspace?.id ?? runtime.id })
    let next = WorkspaceSwitcherState(
      workspaces: combined,
      activeWorkspaceID: activeID,
      runningWorkspaceIDs: runningIDs
    )
    workspaceSwitcherState = next
    applyFocusedTerminalSurface()
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
    case .osc(let session, let sequence):
      shellIntegrationState = "available"
      handleProGhosttyControlOsc(session: session, sequence: sequence)
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

  private func handleProGhosttyControlOsc(session: TerminalSessionID, sequence: OscSequence) {
    guard settings.pgControlCommandsEnabled else { return }
    guard let message = ProGhosttyControlOscParser.parse(sequence) else { return }
    guard ProGhosttyControlAuthorizer.isAuthorized(
      message,
      sourceSessionId: session.description,
      expectedToken: sessionManager.controlToken(for: session),
      isEnabled: settings.pgControlCommandsEnabled
    ) else {
      return
    }
    terminalActionDispatcher.dispatch(message, in: self)
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

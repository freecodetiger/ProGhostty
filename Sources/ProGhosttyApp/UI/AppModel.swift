import AppKit
import Foundation
import ProGhosttyCore
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
  struct WorkspaceRuntime: Identifiable, Equatable {
    var layout: WorkspaceLayout
    var workspace: Workspace?
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
  @Published var requestedPluginScanToken = 0
  @Published var isCheckingForUpdates = false
  @Published var shellIntegrationState = "partial"
  @Published var isAICompanionPresented = false
  @Published var activeAISession: AISession?
  @Published var aiErrorMessage: String?
  @Published var commandCapsuleState = CommandCapsuleState()

  private let sessionManager: TerminalSessionManager
  private let surfaceRegistry: TerminalSurfaceRegistry
  private let paneWorkspaceController: PaneWorkspaceController
  private let aiSessionManager: AISessionManager
  private let updateChecker = AppUpdateChecker()
  private let focusStore = TerminalFocusStore()
  private var indexer: CommandBlockIndexer
  private let historyStore: HistoryStore?
  private let workspaceStore: WorkspaceStore?
  private let settingsStore: SettingsStore
  private let terminalActionDispatcher = TerminalActionDispatcher()
  private var settingsWindowController: NSWindowController?
  private var pluginManagerWindowController: NSWindowController?
  private var savedLayoutSnapshots: [UUID: WorkspaceLayout] = [:]
  private var titlebarToastTask: Task<Void, Never>?
  private var commandCapsuleVoiceTask: Task<Void, Never>?
  private var commandCapsuleRefineTask: Task<Void, Never>?

  struct TitlebarToast: Equatable, Sendable {
    var message: String
    var style: Style
    var lifetime: ProGhosttyTitlebarToastLifetime

    enum Style: Equatable, Sendable {
      case success
      case info
      case error
      case update(URL)
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
    aiSessionManager = AISessionManager(
      paneController: paneWorkspaceController,
      terminalSessionManager: sessionManager,
      focusStore: focusStore,
      shellPathProvider: { loadedSettings.defaultShell }
    )
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
    Task { await checkForUpdates(manual: false) }
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

  func selectedTerminalTextForPrompt() -> String? {
    guard let selectedSessionID else { return nil }
    return surfaceRegistry.selectedText(for: selectedSessionID)
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

  var configurationColorScheme: ColorScheme {
    usesDarkAppearance ? .dark : .light
  }

  var settingsThemePalette: ProGhosttySettingsThemeColors {
    usesDarkAppearance ? ProGhosttySettingsThemePalette.dark : ProGhosttySettingsThemePalette.light
  }

  var configurationWindowBackgroundColor: NSColor {
    settingsThemePalette.windowBackground
  }

  var configurationBarBackgroundColor: NSColor {
    settingsThemePalette.footerBackground
  }

  var configurationSectionBackgroundColor: NSColor {
    settingsThemePalette.controlBackground
  }

  var configurationTextBackgroundColor: NSColor {
    settingsThemePalette.textFieldBackground
  }

  var configurationSeparatorColor: NSColor {
    settingsThemePalette.separator
  }

  var configurationPrimaryTextColor: NSColor {
    settingsThemePalette.primaryText
  }

  var configurationSecondaryTextColor: NSColor {
    settingsThemePalette.secondaryText
  }

  var configurationTertiaryTextColor: NSColor {
    settingsThemePalette.tertiaryText
  }

  var selectedSessionID: TerminalSessionID? {
    activeWorkspace?.selectedSessionID(focusStore: focusStore)
  }

  var selectedPaneID: UUID? {
    guard let activeWorkspaceID else { return nil }
    return focusStore.focusedPaneId(in: activeWorkspaceID)
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
    showTitlebarToast(appText.settingsSavedToast, style: .success, lifetime: .settingsSaved)
  }

  func checkForUpdates(manual: Bool) async {
    if manual {
      isCheckingForUpdates = true
    }
    defer {
      if manual {
        isCheckingForUpdates = false
      }
    }

    do {
      let availability = try await updateChecker.check(currentVersion: appShortVersionString())
      switch availability {
      case .upToDate:
        if manual {
          showTitlebarToast(appText.upToDateToast, style: .success, lifetime: .transient(2.4))
        }
      case .available(let update):
        showTitlebarToast(
          "\(appText.updateAvailableToast) \(update.version)",
          style: .update(update.releaseURL),
          lifetime: .persistent
        )
      }
    } catch {
      if manual {
        showTitlebarToast(appText.updateCheckFailedToast, style: .error, lifetime: .transient(2.8))
      }
    }
  }

  func openTitlebarToastAction() {
    guard let titlebarToast else { return }
    switch titlebarToast.style {
    case .update(let url):
      NSWorkspace.shared.open(url)
      self.titlebarToast = nil
      titlebarToastTask?.cancel()
      titlebarToastTask = nil
    case .success, .info, .error:
      break
    }
  }

  func resetSettings() {
    settings = .defaults
    saveSettings()
  }

  func closeSettingsWindow(_ window: NSWindow? = nil) {
    if let window {
      window.close()
      if window === settingsWindowController?.window {
        settingsWindowController = nil
      }
      return
    }

    settingsWindowController?.window?.close()
    settingsWindowController = nil
  }

  func appVersionString() -> String {
    let version = appShortVersionString()
    let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
    switch (version.isEmpty == false ? version : nil, build?.isEmpty == false ? build : nil) {
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

  private func appShortVersionString() -> String {
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
  }

  func openSettingsWindow() {
    if let window = settingsWindowController?.window {
      applyConfigurationWindowAppearance(to: window)
      window.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
      return
    }

    let controller = NSHostingController(
      rootView: SettingsView()
        .environmentObject(self)
        .preferredColorScheme(configurationColorScheme)
    )
    let window = NSWindow(contentViewController: controller)
    window.title = "Settings"
    window.styleMask = [.titled, .closable, .miniaturizable]
    window.setContentSize(NSSize(width: 640, height: 520))
    window.minSize = NSSize(width: 560, height: 460)
    window.isReleasedWhenClosed = false
    window.center()
    window.toolbarStyle = .preference
    applyConfigurationWindowAppearance(to: window)

    let windowController = NSWindowController(window: window)
    settingsWindowController = windowController
    windowController.showWindow(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  private func applyTerminalAppearance() {
    surfaceRegistry.applyPalette(terminalPalette)
    surfaceRegistry.applyFont(family: settings.fontFamily, size: CGFloat(settings.fontSize))
    surfaceRegistry.applyRendererOptions(settings.terminalRendererOptions)
    applyFocusedTerminalSurface()
    for window in NSApp.windows
      where window !== settingsWindowController?.window
        && window !== pluginManagerWindowController?.window
    {
      ProGhosttyWindowAppearance.applyTerminalChrome(
        to: window,
        backgroundColor: terminalBackgroundColor,
        usesDarkAppearance: usesDarkAppearance
      )
    }
    if let window = settingsWindowController?.window {
      applyConfigurationWindowAppearance(to: window)
    }
    if let window = pluginManagerWindowController?.window {
      applyConfigurationWindowAppearance(to: window)
    }
  }

  private func applyConfigurationWindowAppearance(to window: NSWindow) {
    let appearance = NSAppearance(named: usesDarkAppearance ? .darkAqua : .aqua)
    window.appearance = appearance
    window.contentView?.appearance = appearance
    window.contentViewController?.view.appearance = appearance
    let background = settingsThemePalette.windowBackground
    window.backgroundColor = background
    window.contentView?.wantsLayer = true
    window.contentView?.layer?.backgroundColor = background.cgColor
    window.contentViewController?.view.wantsLayer = true
    window.contentViewController?.view.layer?.backgroundColor = background.cgColor
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

  private func showTitlebarToast(
    _ message: String,
    style: TitlebarToast.Style,
    lifetime: ProGhosttyTitlebarToastLifetime = .transient(1.8)
  ) {
    titlebarToastTask?.cancel()
    titlebarToastTask = nil
    titlebarToast = TitlebarToast(message: message, style: style, lifetime: lifetime)
    guard let delay = lifetime.dismissDelay else { return }
    titlebarToastTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
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
    if scan {
      requestedPluginScanToken += 1
    }

    if let window = pluginManagerWindowController?.window {
      applyConfigurationWindowAppearance(to: window)
      window.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
      return
    }

    let controller = NSHostingController(
      rootView: PluginManagerView()
        .environmentObject(self)
        .preferredColorScheme(configurationColorScheme)
    )
    let window = NSWindow(contentViewController: controller)
    window.title = appText.shellEnhancements
    window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
    window.setContentSize(NSSize(
      width: ProGhosttyWindowSizing.pluginManagerDefaultContentWidth,
      height: ProGhosttyWindowSizing.pluginManagerDefaultContentHeight
    ))
    window.minSize = NSSize(
      width: ProGhosttyWindowSizing.pluginManagerMinimumContentWidth,
      height: ProGhosttyWindowSizing.pluginManagerMinimumContentHeight
    )
    window.isReleasedWhenClosed = false
    window.center()
    window.toolbarStyle = .unified
    applyConfigurationWindowAppearance(to: window)

    let windowController = NSWindowController(window: window)
    pluginManagerWindowController = windowController
    windowController.showWindow(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  func openPluginPlan(_ pack: String) {
    requestedPluginPlanID = pack
    openPlugins()
  }

  func closePlugins() {
    pluginManagerWindowController?.window?.close()
    pluginManagerWindowController = nil
  }

  func closeUtilityOverlays() {
    isHistoryPresented = false
    isWorkspaceSwitcherPresented = false
    isAICompanionPresented = false
    commandCapsuleState.dismiss()
  }

  func openCodexCommandCapsule() {
    isHistoryPresented = false
    isWorkspaceSwitcherPresented = false
    isAICompanionPresented = false
    aiErrorMessage = nil
    commandCapsuleState.open()
  }

  func dismissCodexCommandCapsule() {
    commandCapsuleVoiceTask?.cancel()
    commandCapsuleVoiceTask = nil
    commandCapsuleRefineTask?.cancel()
    commandCapsuleRefineTask = nil
    commandCapsuleState.dismiss()
  }

  func toggleCommandCapsuleContext(_ option: AIPromptContextOption) {
    if commandCapsuleState.includedContext.contains(option) {
      commandCapsuleState.includedContext.remove(option)
    } else {
      commandCapsuleState.includedContext.insert(option)
    }
  }

  func useRawCommandCapsuleRequestAsDraft() {
    let trimmed = commandCapsuleState.request.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    commandCapsuleState.finishRefining(draft: trimmed)
  }

  func startCommandCapsuleVoiceInput() {
    guard commandCapsuleState.phase != .listening else { return }
    commandCapsuleState.startListening()
    let service = makeASRService()
    commandCapsuleVoiceTask?.cancel()
    commandCapsuleVoiceTask = Task { [weak self] in
      for await event in service.transcribe() {
        await MainActor.run {
          guard let self else { return }
          switch event {
          case .partial(let text):
            self.commandCapsuleState.updateVoicePartial(text)
          case .final(let text):
            self.commandCapsuleState.appendFinalTranscript(text)
          case .error(let message):
            self.commandCapsuleState.fail(message)
          case .completed:
            self.commandCapsuleState.stopListening()
          }
        }
      }
    }
  }

  func stopCommandCapsuleVoiceInput() {
    commandCapsuleVoiceTask?.cancel()
    commandCapsuleVoiceTask = nil
    commandCapsuleState.stopListening()
  }

  func refineCommandCapsulePrompt() {
    let request = commandCapsuleState.request.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !request.isEmpty else { return }
    commandCapsuleState.startRefining()
    let context = makeAIContext(includeDiff: false)
    let included = commandCapsuleState.includedContext
    let config = OpenAICompatibleProviderConfig(
      baseURL: settings.openAICompatibleBaseURL,
      apiKey: settings.openAICompatibleAPIKey,
      model: settings.openAICompatibleModel
    )
    commandCapsuleRefineTask?.cancel()
    commandCapsuleRefineTask = Task { [weak self] in
      let result = await CodexPromptRefiner().refine(
        userRequest: request,
        context: context,
        includedContext: included,
        config: config
      )
      await MainActor.run {
        guard let self else { return }
        switch result {
        case .refined(let text), .raw(let text):
          self.commandCapsuleState.finishRefining(draft: text)
        case .failed(let message, let fallback):
          self.commandCapsuleState.draft = fallback
          self.commandCapsuleState.fail(message)
        }
      }
    }
  }

  func sendCommandCapsuleDraftToCodex(enter: Bool) {
    let rawDraft = commandCapsuleState.draft.trimmingCharacters(in: .whitespacesAndNewlines)
    let rawRequest = commandCapsuleState.request.trimmingCharacters(in: .whitespacesAndNewlines)
    let draft = rawDraft.isEmpty ? rawRequest : rawDraft
    guard !draft.isEmpty else { return }
    if activeAISession == nil {
      launchAI(profile: .codex, mode: .rightSplit)
    }
    guard let activeAISession else {
      commandCapsuleState.fail("Start Codex before sending this prompt.")
      return
    }
    do {
      try aiSessionManager.sendPrompt(draft, to: activeAISession.id, mode: enter ? .bracketedPasteAndEnter : .bracketedPasteOnly)
      _ = aiSessionManager.focusAISession(id: activeAISession.id)
      restoreTerminalKeyboardFocus()
      commandCapsuleState.markSent()
    } catch {
      commandCapsuleState.fail("Unable to send prompt to Codex: \(error.localizedDescription)")
    }
  }

  func openAICompanion(profile: AICLIProfile = .codex, mode: AIOpenMode = .rightSplit) {
    isHistoryPresented = false
    isWorkspaceSwitcherPresented = false
    aiErrorMessage = nil
    if activeAISession == nil {
      launchAI(profile: profile, mode: mode)
    }
    isAICompanionPresented = true
  }

  func closeAICompanion() {
    isAICompanionPresented = false
  }

  func launchAI(profile: AICLIProfile, mode: AIOpenMode) {
    guard let workspace = aiWorkspaceContext else {
      aiErrorMessage = "No active terminal pane is available for AI Companion."
      return
    }
    do {
      let session = try aiSessionManager.start(profile: profile, workspace: workspace, openMode: mode)
      activeAISession = session
      syncRuntimeLayout(for: workspace.id)
      activeWorkspaceID = paneWorkspaceController.activeWorkspaceID
      syncWorkspaceSwitcherState()
    } catch {
      aiErrorMessage = "Unable to start \(profile.name): \(error.localizedDescription)"
    }
  }

  func pastePromptToAI(_ prompt: String, send: Bool) {
    guard let activeAISession else {
      aiErrorMessage = "Start Codex or Claude Code before pasting a prompt."
      return
    }
    do {
      try aiSessionManager.sendPrompt(prompt, to: activeAISession.id, mode: send ? .bracketedPasteAndEnter : activeAISession.profile.defaultSendMode)
      _ = aiSessionManager.focusAISession(id: activeAISession.id)
      restoreTerminalKeyboardFocus()
    } catch {
      aiErrorMessage = "Unable to paste prompt: \(error.localizedDescription)"
    }
  }

  var aiWorkspacePath: String? {
    aiWorkspaceContext?.rootPath
  }

  func makeAIContext(includeDiff: Bool) -> AIPromptContext {
    let workspacePath = aiWorkspacePath
    var branch: String?
    var status: String?
    var diff: String?
    var files: [GitModifiedFile] = []
    if let workspacePath {
      status = try? GitContextCollector.statusPorcelain(workspacePath: workspacePath)
      branch = try? GitContextCollector.branch(workspacePath: workspacePath)
      files = status.map(GitModifiedFile.parsePorcelain) ?? []
      if includeDiff {
        diff = try? GitContextCollector.diff(workspacePath: workspacePath)
      }
    }
    return AIPromptContext(
      workspacePath: workspacePath,
      gitBranch: branch,
      gitStatus: status,
      gitDiff: diff,
      selectedTerminalText: selectedTerminalTextForPrompt(),
      changedFiles: files
    )
  }

  func loadChangedFileContents(_ files: [GitModifiedFile]) -> String {
    guard let root = aiWorkspacePath else { return "" }
    return files.compactMap { file in
      let url = URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent(file.path)
      guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
      return "File: \(file.path)\n```\n\(text)\n```"
    }.joined(separator: "\n\n")
  }

  func makeASRService() -> AliyunASRService {
    let configuredKey = settings.aliyunASRAPIKey
    return AliyunASRService(apiKeyProvider: AliyunAPIKeyProvider(configuredKeyReader: {
      configuredKey
    }))
  }

  func resizePane(_ paneID: UUID, rows: Int, cols: Int) {
    guard let workspace = activeWorkspace else { return }
    paneWorkspaceController.resizePane(paneID, in: workspace.id, rows: rows, cols: cols)
  }

  func paneIsResizeSensitiveScreen(_ paneID: UUID) -> Bool {
    guard
      let workspace = activeWorkspace,
      let pane = PaneTreeReducer.findPane(in: workspace.layout.root, paneId: paneID)
    else {
      return false
    }
    return surfaceRegistry.rendererDiagnostics(for: pane.sessionId)?.resizeSensitiveScreen == true
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

  private var aiWorkspaceContext: AIWorkspace? {
    guard let activeWorkspace, let selectedPaneID else { return nil }
    let root = activeWorkspace.workspace?.rootPath ?? selectedCwd ?? activeWorkspace.displayPath ?? FileManager.default.currentDirectoryPath
    return AIWorkspace(id: activeWorkspace.id, name: activeWorkspace.title, rootPath: root, currentPaneID: selectedPaneID)
  }

  private func syncRuntimeLayout(for workspaceID: UUID) {
    guard let updated = paneWorkspaceController.workspaceLayout(id: workspaceID),
      let index = workspaceRuntimes.firstIndex(where: { $0.id == workspaceID })
    else { return }
    workspaceRuntimes[index].layout = updated
    for pane in PaneTreeReducer.listLeaves(in: updated.root) {
      workspaceRuntimes[index].cwdBySession[pane.sessionId] = workspaceRuntimes[index].cwdBySession[pane.sessionId] ?? pane.cwd ?? workspaceRuntimes[index].displayPath ?? ""
      indexer.associate(session: pane.sessionId, workspaceId: workspaceRuntimes[index].workspace?.id)
    }
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
    case .output:
      break
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

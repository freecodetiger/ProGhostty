import AppKit
import Combine
import Foundation
import ProGhosttyCore
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
  struct WorkspaceRuntime: Identifiable, Equatable {
    var layout: WorkspaceLayout
    var workspace: Workspace?
    var cwdBySession: [TerminalSessionID: String]
    /// Titles reported by programs via OSC 0/1/2. Runtime-only — programs are
    /// gone after a restart, so this is never persisted (unlike pane labels).
    var reportedTitleBySession: [TerminalSessionID: String] = [:]

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

  }

  enum SessionClosedAction: Equatable {
    case closePane(workspaceID: UUID, paneID: UUID)
    case closeWorkspace(workspaceID: UUID)
    case none
  }

  @Published var workspaceRuntimes: [WorkspaceRuntime] = []
  @Published var activeWorkspaceID: UUID?
  @Published var isWorkspaceSwitcherPresented = false
  @Published var workspaceSwitcherState = WorkspaceSwitcherState(workspaces: [], activeWorkspaceID: nil)
  @Published var commandLine = ""
  @Published var sideInputStore = TerminalSideInputStore.empty
  @Published var isFindBarPresented = false
  @Published var searchState = SearchState()
  var workspaces: [Workspace] { composition.workspaces }
  var settings: AppSettings {
    get { composition.settings }
    set { composition.settings = newValue }
  }

  /// Notification presentation state lives in NotificationPresenter (debt
  /// spec 3-7); objectWillChange is chained in init so these forwarders keep
  /// driving SwiftUI exactly like the former @Published properties.
  let notifications = NotificationPresenter()

  var titlebarToast: TitlebarToast? { notifications.titlebarToast }
  var inAppNotification: InAppNotification? { notifications.inAppNotification }
  var shellIntegrationState: String {
    get { notifications.statusLine }
    set { notifications.statusLine = newValue }
  }
  let composition: AppComposition
  /// The terminal window this model drives; bound from the view layer.
  weak var window: NSWindow?

  // MARK: Markdown preview float (spec: 2026-08-18-markdown-preview-float)

  @Published var isMarkdownPreviewPresented = false
  @Published var markdownPreviewPath: String?
  @Published var markdownPreviewFrame: CGRect?
  /// The `.markdown-body` inner HTML for the current document (local images
  /// inlined as data URLs). The float injects this into its once-loaded shell.
  @Published var markdownPreviewBody: String?
  /// Index of the panel the float is docked into, or nil when floating.
  @Published var markdownPreviewDockedPanelIndex: Int?
  private var previewWatcher: DispatchSourceFileSystemObject?
  private var previewReloadWorkItem: DispatchWorkItem?

  /// Frame of the active pane (window contentView coordinates, y-up) used to
  /// place the float's initial position near where the user clicked. Read when
  /// the float first appears (frame == nil). The float's container converts
  /// these into its own space.
  var markdownPreviewPaneAnchor: CGRect? {
    guard let sessionID = selectedSessionID,
      let surface = surfaceRegistry.viewForSession(sessionID),
      let window = surface.window
    else {
      return nil
    }
    return surface.convert(surface.bounds, to: window.contentView)
  }

  /// Frames of every pane in the active workspace, in window contentView
  /// coordinates (y-up). The float's container converts them into its own
  /// (flipped) space via `convert(_:from:)`.
  var markdownPreviewPanelFrames: [CGRect] {
    guard let runtime = activeWorkspace else { return [] }
    return PaneTreeReducer.listLeaves(in: runtime.layout.root).compactMap { pane in
      guard
        let surface = surfaceRegistry.viewForSession(pane.sessionId),
        let window = surface.window
      else {
        return nil
      }
      return surface.convert(surface.bounds, to: window.contentView)
    }
  }
  private let sessionManager: TerminalSessionManager
  private let surfaceRegistry: TerminalSurfaceRegistry
  private let paneWorkspaceController: PaneWorkspaceController
  private let focusStore = TerminalFocusStore()
  private var searchTask: Task<Void, Never>?
  private let projectInfoPopover = ProjectInfoPopover()
  /// The live settings window, if open — used by the window-close guard to
  /// leave utility windows unguarded.
  var settingsWindow: NSWindow? { composition.utilityWindows.settingsWindow }
  private lazy var windowSizing = TerminalWindowSizingController(
    isExcludedWindow: { [weak self] window in
      window === self?.composition.utilityWindows.settingsWindow
    },
    windowProvider: { [weak self] in self?.window }
  )
  private var savedLayoutSnapshots: [UUID: WorkspaceLayout] = [:]
  private var cancellables: Set<AnyCancellable> = []
  private let paneSplitAvailabilityController = PaneSplitAvailabilityController()
  /// Memoized bare-token existence checks, keyed by "cwd\0token". Bounds the
  /// per-mouse-move disk stats the clickable-path detector would otherwise do.
  private var bareTokenExistenceCache: [String: (exists: Bool, timestamp: CFTimeInterval)] = [:]
  private static let bareTokenExistenceTTL: CFTimeInterval = 2.0
  private static let bareTokenExistenceCacheLimit = 2048
  private static let sideInputHintKey = "hasUsedSideInput"

  struct TitlebarToast: Equatable, Sendable {
    // Unique per presentation so re-showing the *same* message/style is still a
    // distinct value. Without this, @Published's Equatable check swallows a repeat
    // toast (e.g. ⌘-clicking the same invalid path twice) and the view never
    // re-appears — "only the first click shows a toast".
    var id = UUID()
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

  struct InAppNotification: Identifiable, Equatable, Sendable {
    var id = UUID()
    var title: String
    var body: String
    var session: TerminalSessionID
    var source: TerminalDesktopNotification.Source
  }

  init(composition: AppComposition) {
    self.composition = composition
    DebugLog.write("AppModel init")
    let surfaceRegistry = PTYTerminalSurfaceRegistry()
    let sessionManager = PTYTerminalSessionManager(surfaceRegistry: surfaceRegistry)
    self.surfaceRegistry = surfaceRegistry
    self.sessionManager = sessionManager
    paneWorkspaceController = PaneWorkspaceController(sessionManager: sessionManager, focusStore: focusStore)

    surfaceRegistry.setInputHandler { [weak self] sourceSession, data in
      self?.routeTerminalInput(data, from: sourceSession)
    }
    surfaceRegistry.setPasteHandler { [weak self] sourceSession, text in
      self?.routeTerminalPaste(text, from: sourceSession)
    }
    surfaceRegistry.setActivationHandler { [weak self] session in
      self?.selectSession(session)
    }
    surfaceRegistry.setLinkHoverHandler { [weak self] _, isHovering in
      guard let self, isHovering else { return }
      self.showTitlebarToast(self.appText.openLinkHintToast, style: .info, lifetime: .transient(1.4))
    }
    surfaceRegistry.setLinkTargetHandler { [weak self] sourceSession, target in
      self?.openTerminalLinkTarget(target, from: sourceSession)
    }
    surfaceRegistry.setPathExistenceProvider { [weak self] sourceSession, token in
      self?.bareTokenResolvesToExistingPath(token, from: sourceSession) ?? false
    }
    surfaceRegistry.setFileInfoProvider { [weak self] sourceSession, target in
      self?.terminalFileInfo(target, from: sourceSession)
    }
    surfaceRegistry.setMarkdownPreviewHandler { [weak self] sourceSession, path in
      guard let self else { return false }
      return self.openMarkdownPreview(path, from: sourceSession)
    }
    composition.registerWindow(self)
    // Forwarded presenter/controller state must keep publishing through AppModel.
    notifications.objectWillChange
      .sink { [weak self] _ in self?.objectWillChange.send() }
      .store(in: &cancellables)
    composition.objectWillChange
      .sink { [weak self] _ in self?.objectWillChange.send() }
      .store(in: &cancellables)
    applyTerminalAppearance()

    Task { await consumeEvents() }
    refreshWorkspaces()
    if composition.claimInitialWindow() {
      restorePersistedWorkspacesOrCreateDefault()
      showSideInputHintIfNeeded()
    } else {
      createAndActivateWorkspace(workspace: nil)
    }
  }

  /// One-line onboarding hint for the side input, shown on launch until the
  /// user first opens it. Deliberately minimal — just the shortcut, no pitch.
  private func showSideInputHintIfNeeded() {
    guard !UserDefaults.standard.bool(forKey: Self.sideInputHintKey) else { return }
    let shortcut = settings.keyboardShortcuts.shortcut(for: .sideInput).displayString
    showTitlebarToast("\(appText.sideInput) \(shortcut)", style: .info, lifetime: .transient(4.0))
  }

  func createAndActivateWorkspace(workspace: Workspace? = nil) {
    let cwd = AppSettings.terminalWorkingDirectory(
      workspaceRootPath: workspace?.rootPath,
      defaultWorkingDirectory: settings.defaultWorkingDirectory
    )
    let grid = Self.initialGridSize(
      fontFamily: settings.fontFamily,
      fontSize: CGFloat(settings.fontSize)
    )

    do {
      let layout: WorkspaceLayout
      if let workspace {
        layout = try paneWorkspaceController.restoreWorkspace(
          workspace: workspace,
          layoutSnapshot: workspace.layoutSnapshot,
          fallbackShell: settings.defaultShell,
          defaultWorkingDirectory: cwd,
          rows: grid.rows,
          cols: grid.cols
        )
      } else {
        let opened = try paneWorkspaceController.openTerminal(
          title: cwd,
          config: sessionConfig(workspace: nil, workingDirectory: cwd),
          paneTitle: URL(fileURLWithPath: cwd).lastPathComponent,
          cwd: cwd
        )
        layout = opened.workspace
      }
      let runtime = WorkspaceRuntime(
        layout: layout,
        workspace: workspace,
        cwdBySession: cwdMap(for: layout, fallback: cwd)
      )
      workspaceRuntimes.append(runtime)
      persistWorkspaceRuntime(at: workspaceRuntimes.count - 1)
      expandTerminalWindowIfNeeded(for: workspaceRuntimes[workspaceRuntimes.count - 1])
      activeWorkspaceID = paneWorkspaceController.activeWorkspaceID
      syncWorkspaceSwitcherState()
    } catch {
      shellIntegrationState = "terminal unavailable: \(error.localizedDescription)"
    }
  }

  func openTerminal(workspace: Workspace? = nil) {
    createAndActivateWorkspace(workspace: workspace)
  }

  private func restorePersistedWorkspacesOrCreateDefault() {
    guard let workspace = workspaces.max(by: { $0.updatedAt < $1.updatedAt }) else {
      createAndOpenWorkspace(name: "")
      return
    }

    createAndActivateWorkspace(workspace: workspace)
    if workspaceRuntimes.isEmpty {
      createAndOpenWorkspace(name: "")
    }
  }

  private func cwdMap(for layout: WorkspaceLayout, fallback: String?) -> [TerminalSessionID: String] {
    var map: [TerminalSessionID: String] = [:]
    for pane in PaneTreeReducer.listLeaves(in: layout.root) {
      if let cwd = nonEmpty(pane.cwd) ?? nonEmpty(fallback) {
        map[pane.sessionId] = cwd
      }
    }
    return map
  }

  private func persistWorkspaceRuntime(at index: Int) {
    guard workspaceRuntimes.indices.contains(index), var workspace = workspaceRuntimes[index].workspace else {
      return
    }
    var layout = workspaceRuntimes[index].layout
    layout.title = workspace.name
    layout.workspaceId = workspace.id
    workspace.layoutSnapshot = layout
    workspace.updatedAt = Date()
    do {
      try composition.workspaceStore?.save(workspace)
      workspaceRuntimes[index].workspace = workspace
      composition.upsertWorkspace(workspace)
    } catch {
      shellIntegrationState = "workspace save unavailable: \(error.localizedDescription)"
    }
  }

  private func nonEmpty(_ value: String?) -> String? {
    let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? nil : trimmed
  }

  func closeSelectedTerminal() {
    guard let closed = paneWorkspaceController.closeActiveWorkspace() else { return }
    removePaneSplitAvailability(for: closed.panes)
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

  func openSideInput() {
    guard let selectedPaneID, let selectedSessionID else { return }
    UserDefaults.standard.set(true, forKey: Self.sideInputHintKey)
    sideInputStore.open(paneID: selectedPaneID, sessionID: selectedSessionID)
  }

  // MARK: Buffer search (find)

  func toggleFindBar() {
    isFindBarPresented ? closeFindBar() : openFindBar()
  }

  func openFindBar() {
    isFindBarPresented = true
  }

  func closeFindBar() {
    isFindBarPresented = false
    searchTask?.cancel()
    searchTask = nil
    searchState = SearchState()
    if let session = selectedSessionID {
      surfaceRegistry.clearSearchHighlights(for: session)
    }
  }

  func updateSearchQuery(_ query: String) {
    searchState.query = query
    searchState.resetMatches()
    searchTask?.cancel()
    guard !query.isEmpty, let session = selectedSessionID else {
      if let session = selectedSessionID {
        surfaceRegistry.clearSearchHighlights(for: session)
      }
      return
    }
    let caseSensitive = searchState.caseSensitive
    searchState.isSearching = true
    searchTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: 150_000_000)
      guard !Task.isCancelled else { return }
      guard let self, let result = await self.surfaceRegistry.search(query: query, caseSensitive: caseSensitive, in: session)
      else { return }
      guard !Task.isCancelled else { return }
      self.searchState.matches = result.matches
      self.searchState.truncated = result.truncated
      self.searchState.isSearching = false
      self.searchState.currentIndex = result.matches.isEmpty ? nil : 0
      self.surfaceRegistry.applySearchHighlights(result.matches, total: result.totalRows, to: session)
    }
  }

  func toggleSearchCaseSensitivity() {
    searchState.caseSensitive.toggle()
    if !searchState.query.isEmpty {
      updateSearchQuery(searchState.query)
    }
  }

  func nextSearchMatch() {
    searchState.next()
    revealCurrentSearchMatch()
  }

  func previousSearchMatch() {
    searchState.previous()
    revealCurrentSearchMatch()
  }

  private func revealCurrentSearchMatch() {
    guard let match = searchState.currentMatch, let session = selectedSessionID else { return }
    surfaceRegistry.revealSearchMatch(match, in: session)
  }

  // MARK: Pane rename

  func startRenamePane() {
    guard selectedPaneID != nil else { return }
    guard
      let name = confirmationPrompts.promptRenamePane(
        currentLabel: activePaneLabel ?? "",
        text: appText
      )
    else { return }
    commitRenamePane(name)
  }

  func commitRenamePane(_ name: String) {
    guard let activeWorkspaceID, let selectedPaneID else { return }
    let changed = paneWorkspaceController.renamePane(
      workspaceID: activeWorkspaceID,
      paneID: selectedPaneID,
      label: name
    )
    if changed, let index = workspaceRuntimes.firstIndex(where: { $0.id == activeWorkspaceID }) {
      persistWorkspaceRuntime(at: index)
    }
  }

  func updateSideInputText(_ text: String, for paneID: UUID) {
    sideInputStore.updateText(text, for: paneID)
  }

  func submitSideInput(for paneID: UUID) {
    guard let submitted = sideInputStore.submit(paneID: paneID) else { return }
    selectPane(paneID)
    let session = submitted.sessionID
    let text = submitted.text
    sessionManager.writePaste(text, to: session)
    applyFocusedTerminalSurface()
    restoreTerminalKeyboardFocus()
  }

  func closeEmptySideInput(for paneID: UUID) {
    sideInputStore.closeIfEmpty(paneID: paneID)
  }

  func closeSideInputAfterEscape(for paneID: UUID) {
    if sideInputStore.draft(for: paneID)?.isEmpty == true {
      sideInputStore.close(paneID: paneID)
      selectPane(paneID)
      applyFocusedTerminalSurface()
      restoreTerminalKeyboardFocus()
    }
  }

  func markSideInputFocusRequestHandled(paneID: UUID, requestID: Int) {
    sideInputStore.markFocusRequestHandled(paneID: paneID, requestID: requestID)
  }

  func pruneSideInputs(to paneIDs: Set<UUID>) {
    _ = sideInputStore.removeMissingPanes(paneIDs)
  }

  func pasteDroppedPaths(_ text: String, intoPane paneID: UUID) {
    guard
      let activeWorkspaceID,
      let runtime = workspaceRuntimes.first(where: { $0.id == activeWorkspaceID }),
      let pane = PaneTreeReducer.findPane(in: runtime.layout.root, paneId: paneID)
    else {
      DebugLog.write("pasteDroppedPaths ignored: pane not found pane=\(paneID)")
      return
    }

    selectPane(paneID)
    sessionManager.writePaste(text, to: pane.sessionId)
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
    TitleFormatting.compactTitlebarTitle(activeWorkspaceTitle)
  }

  var activeTitlebarTooltip: String? {
    guard activeWorkspace != nil else { return nil }
    let paneCount = activeWorkspacePaneCount
    let workspaceCount = workspaceRuntimes.count
    let paneLabel = paneCount == 1 ? "pane" : "panes"
    let workspaceLabel = workspaceCount == 1 ? "workspace" : "workspaces"
    return """
    \(activeWorkspaceTitle)
    \(paneCount) \(paneLabel) · \(workspaceCount) running \(workspaceLabel)
    """
  }

  /// User-assigned pane label, shown as an independent titlebar module left
  /// of the cwd-derived subtitle (which stays centered).
  var activePaneLabel: String? {
    guard let activeWorkspaceID, let selectedPaneID else { return nil }
    return paneWorkspaceController.paneLabel(workspaceID: activeWorkspaceID, paneID: selectedPaneID)
  }

  private var gitBranchCache: (cwd: String, branch: String?, requested: Bool) = ("", nil, false)

  /// Returns the current git branch for `selectedCwd`, fetching asynchronously if
  /// needed. The first call returns nil (path-only label); a subsequent SwiftUI
  /// update fills the branch once `git rev-parse --abbrev-ref HEAD` completes.
  private var effectiveGitBranch: String? {
    guard let cwd = selectedCwd else {
      gitBranchCache = ("", nil, false)
      return nil
    }
    if gitBranchCache.cwd != cwd {
      gitBranchCache = (cwd, nil, false)
    }
    if !gitBranchCache.requested {
      gitBranchCache.requested = true
      let capturedCwd = cwd
      DispatchQueue.global().async { [weak self] in
        let branch = Self.runGitBranch(cwd: capturedCwd)
        Task { @MainActor [weak self] in
          guard let self, self.gitBranchCache.cwd == capturedCwd else { return }
          self.gitBranchCache.branch = branch
          self.objectWillChange.send()
        }
      }
    }
    return gitBranchCache.branch
  }

  var activePaneTitlebarLabel: String? {
    guard let cwd = selectedCwd, let component = TitleFormatting.compactPathComponent(cwd) else { return nil }
    var label = "📁 \(component)"
    if let branch = effectiveGitBranch {
      label += "  ·  \(branch)"
    }
    return label
  }

  /// Invalidate the git branch cache so the next label render re-fetches. Called
  /// when the CWD has observably changed (.cwdChanged event).
  private func invalidateGitBranchCache() {
    gitBranchCache = ("", nil, false)
  }

  /// One-shot debounce: after the focused session's output goes quiet, if the
  /// shell is back at a prompt, re-derive the git branch in place.
  private var gitBranchIdleRefreshTimer: Timer?

  private func scheduleGitBranchIdleRefresh(for session: TerminalSessionID) {
    guard session == selectedSessionID else { return }
    gitBranchIdleRefreshTimer?.invalidate()
    gitBranchIdleRefreshTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, self.selectedSessionID == session,
          !self.sessionManager.hasForegroundProcess(in: session)
        else { return }
        self.refreshGitBranchInPlace()
      }
    }
  }

  /// Re-run `git rev-parse` for the current cwd WITHOUT clearing the displayed
  /// branch first: the old name stays visible until the new one arrives, so a
  /// branch change (git checkout / git switch) updates the titlebar without a
  /// flicker.
  private func refreshGitBranchInPlace() {
    guard let cwd = selectedCwd else { return }
    // Same-cwd refresh keeps the old branch until the new one arrives. If the
    // cache holds another directory its branch is wrong here — fall back to the
    // normal miss path (no branch shown while fetching).
    if gitBranchCache.cwd != cwd {
      gitBranchCache = (cwd, nil, false)
    }
    guard !gitBranchCache.requested else { return } // a fetch is already in flight
    gitBranchCache.requested = true
    let capturedCwd = cwd
    DispatchQueue.global().async { [weak self] in
      let branch = Self.runGitBranch(cwd: capturedCwd)
      Task { @MainActor [weak self] in
        guard let self, self.gitBranchCache.cwd == capturedCwd else { return }
        if self.gitBranchCache.branch != branch {
          self.gitBranchCache.branch = branch
          self.objectWillChange.send()
        }
      }
    }
  }

  /// Run `git rev-parse --abbrev-ref HEAD` in `cwd`. Returns the branch name,
  /// or the short hash for detached HEAD, or nil on failure / timeout / non-git.
  /// Mirrors the lightweight subprocess pattern from ProjectInfoService.
  private nonisolated static func runGitBranch(cwd: String) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", cwd, "rev-parse", "--abbrev-ref", "HEAD"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    var env = ProcessInfo.processInfo.environment
    env["GIT_TERMINAL_PROMPT"] = "0"
    process.environment = env
    do {
      try process.run()
    } catch {
      return nil
    }
    let deadline = DispatchWorkItem { process.terminate() }
    DispatchQueue.global().asyncAfter(deadline: .now() + 1.5, execute: deadline)
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    deadline.cancel()
    guard process.terminationStatus == 0 else { return nil }
    let raw = String(data: data, encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !raw.isEmpty else { return nil }
    // Detached HEAD reports "HEAD"; resolve to short hash.
    if raw == "HEAD" {
      return runGitShortHash(cwd: cwd) ?? raw
    }
    return raw
  }

  private nonisolated static func runGitShortHash(cwd: String) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", cwd, "rev-parse", "--short", "HEAD"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    var env = ProcessInfo.processInfo.environment
    env["GIT_TERMINAL_PROMPT"] = "0"
    process.environment = env
    do {
      try process.run()
    } catch {
      return nil
    }
    let deadline = DispatchWorkItem { process.terminate() }
    DispatchQueue.global().asyncAfter(deadline: .now() + 1.5, execute: deadline)
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    deadline.cancel()
    guard process.terminationStatus == 0 else { return nil }
    return String(data: data, encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Program-reported (OSC 0/1/2) title for the focused pane. Shown in the
  /// titlebar pane module only when no manual label overrides it.
  var activePaneAutoTitle: String? {
    guard settings.programTitleReportingEnabled,
          let session = selectedSessionID
    else { return nil }
    return activeWorkspace?.reportedTitleBySession[session]
  }

  var activePaneTitlebarTooltip: String? {
    guard let cwd = selectedCwd else { return nil }
    return cwd
  }

  var appText: AppText { composition.appText }
  var appearance: AppearanceViewModel { composition.appearance }
  var appColorScheme: ColorScheme? { composition.appColorScheme }
  var terminalPalette: TerminalSurfacePalette { composition.terminalPalette }
  var usesDarkAppearance: Bool { composition.usesDarkAppearance }
  var terminalBackgroundColor: NSColor { composition.terminalBackgroundColor }
  var configurationColorScheme: ColorScheme { composition.configurationColorScheme }
  var settingsThemePalette: ProGhosttySettingsThemeColors { composition.settingsThemePalette }
  var configurationWindowBackgroundColor: NSColor { composition.configurationWindowBackgroundColor }
  var configurationBarBackgroundColor: NSColor { composition.configurationBarBackgroundColor }
  var configurationSectionBackgroundColor: NSColor { composition.configurationSectionBackgroundColor }
  var configurationTextBackgroundColor: NSColor { composition.configurationTextBackgroundColor }
  var configurationSeparatorColor: NSColor { composition.configurationSeparatorColor }
  var configurationPrimaryTextColor: NSColor { composition.configurationPrimaryTextColor }
  var configurationSecondaryTextColor: NSColor { composition.configurationSecondaryTextColor }
  var configurationTertiaryTextColor: NSColor { composition.configurationTertiaryTextColor }

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

  private var activeWorkspacePaneCount: Int {
    guard let activeWorkspace else { return 0 }
    return PaneTreeReducer.listLeaves(in: activeWorkspace.layout.root).count
  }

  func activateWorkspace(_ workspaceID: UUID) {
    guard let targetRuntime = workspaceRuntimes.first(where: { $0.id == workspaceID }) else { return }
    rememberActiveWorkspaceContentSize()
    expandTerminalWindowIfNeeded(for: targetRuntime)
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
      rememberActiveWorkspaceContentSize()
      if let targetRuntime = workspaceRuntimes.first(where: { $0.id == workspace.id }) {
        expandTerminalWindowIfNeeded(for: targetRuntime)
      }
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

  func updatePaneSplitAvailability(
    _ paneID: UUID,
    size: NSSize,
    canSplitRight: Bool,
    canSplitDown: Bool
  ) {
    paneSplitAvailabilityController.update(
      paneID,
      size: size,
      canSplitRight: canSplitRight,
      canSplitDown: canSplitDown
    )
  }

  func splitPane(_ paneID: UUID, axis: TerminalSplitAxis) {
    DebugLog.write("splitPane requested pane=\(paneID) axis=\(axis)")
    guard let activeWorkspaceID, let index = workspaceRuntimes.firstIndex(where: { $0.id == activeWorkspaceID }) else {
      DebugLog.write("splitPane ignored: no active workspace")
      return
    }
    guard canSplitPaneInCurrentBounds(paneID, axis: axis) else {
      rejectSplitForInsufficientSpace(paneID: paneID, axis: axis, reason: "insufficient pane bounds")
      return
    }
    var runtime = workspaceRuntimes[index]
    DebugLog.write("splitPane before leaves=\(PaneTreeReducer.listLeaves(in: runtime.layout.root).count)")
    let workspace = runtime.workspace
    let liveWorkingDirectory = PaneTreeReducer.findPane(in: runtime.layout.root, paneId: paneID)
      .flatMap { sessionManager.workingDirectory(for: $0.sessionId) }
    let cwd = PaneSplitCwdResolver.cwd(
      forPane: paneID,
      in: runtime.layout.root,
      cwdBySession: runtime.cwdBySession,
      liveWorkingDirectory: liveWorkingDirectory,
      workspaceRootPath: workspace?.rootPath,
      defaultWorkingDirectory: settings.defaultWorkingDirectory
    )

    guard splitCanFitAvailableScreen(root: runtime.layout.root, targetPaneId: paneID, axis: axis) else {
      rejectSplitForInsufficientSpace(paneID: paneID, axis: axis, reason: "insufficient screen space")
      return
    }

    do {
      let split = try paneWorkspaceController.splitPane(
        workspaceID: activeWorkspaceID,
        paneID: paneID,
        axis: axis,
        config: sessionConfig(workspace: workspace, workingDirectory: cwd),
        paneTitle: URL(fileURLWithPath: cwd).lastPathComponent,
        cwd: cwd
      )
      runtime.layout = split.workspace
      runtime.cwdBySession[split.pane.sessionId] = cwd
      seedPaneSplitAvailabilityAfterSplit(originalPaneID: paneID, newPaneID: split.pane.paneId, axis: axis)
      workspaceRuntimes[index] = runtime
      persistWorkspaceRuntime(at: index)
      expandTerminalWindowIfNeeded(for: workspaceRuntimes[index])
      self.activeWorkspaceID = paneWorkspaceController.activeWorkspaceID
      syncWorkspaceSwitcherState()
      DebugLog.write("splitPane success newPane=\(split.pane.paneId) session=\(split.pane.sessionId) leaves=\(PaneTreeReducer.listLeaves(in: runtime.layout.root).count)")
    } catch {
      shellIntegrationState = "split unavailable: \(error.localizedDescription)"
      DebugLog.write("splitPane failed error=\(error.localizedDescription)")
    }
  }

  private func canSplitPaneInCurrentBounds(_ paneID: UUID, axis: TerminalSplitAxis) -> Bool {
    paneSplitAvailabilityController.canSplit(paneID, axis: axis)
  }

  private func rejectSplitForInsufficientSpace(paneID: UUID, axis: TerminalSplitAxis, reason: String) {
    let message = appText.splitRequiresMoreSpaceToast
    shellIntegrationState = message
    showTitlebarToast(message, style: .info, lifetime: .transient(2.0))
    NSSound.beep()
    DebugLog.write("splitPane blocked: \(reason) pane=\(paneID) axis=\(axis)")
  }

  private func seedPaneSplitAvailabilityAfterSplit(
    originalPaneID: UUID,
    newPaneID: UUID,
    axis: TerminalSplitAxis
  ) {
    paneSplitAvailabilityController.seedAfterSplit(
      originalPaneID: originalPaneID,
      newPaneID: newPaneID,
      axis: axis
    )
  }

  private func removePaneSplitAvailability(for panes: [TerminalPane]) {
    paneSplitAvailabilityController.remove(for: panes)
  }

  private func splitCanFitAvailableScreen(
    root: PaneNode,
    targetPaneId: UUID,
    axis: TerminalSplitAxis
  ) -> Bool {
    guard
      let minimum = SplitRatioLayout.windowMinimumContentSizeAfterSplit(
        root: root,
        targetPaneId: targetPaneId,
        axis: axis,
        baseWidth: ProGhosttyWindowSizing.minimumContentWidth,
        baseHeight: ProGhosttyWindowSizing.minimumContentHeight
      ),
      let maximum = terminalWindowMaximumContentSize()
    else {
      return true
    }

    return minimum.width <= Double(maximum.width) + 0.5
      && minimum.height <= Double(maximum.height) + 0.5
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
    // Last pane in a workspace is not closable via "close pane" — keep the
    // workspace alive so the user can still split. Use workspace close instead.
    guard leavesBefore.count > 1 else {
      DebugLog.write("closePane ignored last pane=\(paneID)")
      return
    }
    if
      let pane = leavesBefore.first(where: { $0.paneId == paneID }),
      PaneCloseConfirmationPolicy.requiresConfirmation(for: pane, sessionManager: sessionManager),
      !confirmPaneCloseWithForegroundProcess()
    {
      DebugLog.write("closePane cancelled pane=\(paneID) foregroundProcess=true")
      return
    }
    DebugLog.write("closePane requested pane=\(paneID) leavesBefore=\(leavesBefore.count)")
    do {
      guard let closed = try paneWorkspaceController.closePane(workspaceID: activeWorkspaceID, paneID: paneID) else {
        // Root is a single leaf (or pane not found) — never tear down the workspace here.
        DebugLog.write("closePane no-op reducer returned nil pane=\(paneID)")
        return
      }
      guard let updatedLayout = paneWorkspaceController.workspaceLayout(id: activeWorkspaceID) else { return }
      runtime.layout = updatedLayout
      runtime.cwdBySession[closed.sessionId] = nil
      runtime.reportedTitleBySession[closed.sessionId] = nil
      paneSplitAvailabilityController.remove(paneID: closed.paneId)
      workspaceRuntimes[index] = runtime
      persistWorkspaceRuntime(at: index)
      applyTerminalWindowMinimumContentSize(for: runtime)
      applyFocusedTerminalSurface()
      let leavesAfter = PaneTreeReducer.listLeaves(in: runtime.layout.root)
      DebugLog.write("closePane success closed=\(closed.paneId) leavesAfter=\(leavesAfter.count) next=\(focusStore.focusedPaneId(in: activeWorkspaceID)?.uuidString ?? "-")")
    } catch {
      DebugLog.write("closePane failed error=\(error)")
    }
  }

  private func routeTerminalInput(_ data: Data, from sourceSession: TerminalSessionID) {
    if selectedSessionID != sourceSession {
      selectSession(sourceSession)
    }
    sessionManager.writeInput(data, to: sourceSession)
  }

  private func routeTerminalPaste(_ text: String, from sourceSession: TerminalSessionID) {
    if selectedSessionID != sourceSession {
      selectSession(sourceSession)
    }
    sessionManager.writePaste(text, to: sourceSession)
  }

  private func openTerminalLinkTarget(_ target: TerminalLinkTarget, from sourceSession: TerminalSessionID) {
    DebugLog.write("openTerminalLinkTarget session=\(sourceSession) target=\(target)")
    switch target {
    case .url(let url):
      _ = NSWorkspace.shared.open(url)
    case .filePath(let filePath):
      revealTerminalFilePath(filePath, from: sourceSession)
    }
  }

  /// Opens the markdown preview float for a clicked `.md` path. Frame is reset
  /// so the float re-derives its initial adaptive position on next layout.
  /// Returns false — and the click becomes a normal link interaction — while a
  /// preview float is already showing: only one float exists, and a second click
  /// must not summon or replace it.
  @discardableResult
  func openMarkdownPreview(_ path: String, from sourceSession: TerminalSessionID) -> Bool {
    guard !isMarkdownPreviewPresented else {
      DebugLog.write("markdown-preview skip already-presented path=\(path)")
      return false
    }
    DebugLog.write("markdown-preview open path=\(path) session=\(sourceSession)")
    markdownPreviewPath = path
    markdownPreviewFrame = nil
    markdownPreviewBody = nil
    markdownPreviewDockedPanelIndex = nil
    isMarkdownPreviewPresented = true
    reloadMarkdownPreview()
    startMarkdownPreviewWatcher(at: path)
    return true
  }

  func dismissMarkdownPreview() {
    DebugLog.write("markdown-preview dismiss")
    previewWatcher?.cancel()
    previewWatcher = nil
    previewReloadWorkItem?.cancel()
    previewReloadWorkItem = nil
    isMarkdownPreviewPresented = false
    markdownPreviewPath = nil
    markdownPreviewFrame = nil
    markdownPreviewBody = nil
    markdownPreviewDockedPanelIndex = nil
  }

  /// Docked the float into a panel: record the panel. The float itself keeps
  /// its docked frame pinned to the pane (it knows the container↔contentView
  /// coordinate conversion), so no timer here.
  func dockMarkdownPreview(to index: Int) {
    DebugLog.write("markdown-preview dock panel=\(index)")
    markdownPreviewDockedPanelIndex = index
  }

  func detachMarkdownPreview() {
    DebugLog.write("markdown-preview detach")
    markdownPreviewDockedPanelIndex = nil
  }

  /// Reads the previewed file and publishes the `.markdown-body` inner HTML
  /// (local images inlined as base64) for the float to inject into its shell.
  private func reloadMarkdownPreview() {
    guard let path = markdownPreviewPath else { return }
    let start = CFAbsoluteTimeGetCurrent()
    let content: String
    do {
      content = try String(contentsOfFile: path, encoding: .utf8)
    } catch {
      content = "⚠️ 无法读取 \(path)\n\n\(error.localizedDescription)"
    }
    let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
    let body = MarkdownPreviewRenderer().bodyHTML(for: content, baseDirectory: directory)
    let ms = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
    DebugLog.write("markdown-preview render path=\(path) bytes=\(content.count) htmlChars=\(body.count) ms=\(ms)")
    markdownPreviewBody = body
  }

  /// Live-refresh: watch the previewed file for changes (debounced re-render),
  /// so editing in vim re-renders the preview as you save.
  private func startMarkdownPreviewWatcher(at path: String) {
    previewWatcher?.cancel()
    previewWatcher = nil
    let fd = open(path, O_EVTONLY)
    guard fd >= 0 else { return }
    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: fd,
      eventMask: [.write, .extend, .delete],
      queue: .main
    )
    source.setEventHandler { [weak self] in
      self?.previewReloadWorkItem?.cancel()
      let work = DispatchWorkItem { [weak self] in self?.reloadMarkdownPreview() }
      self?.previewReloadWorkItem = work
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }
    source.setCancelHandler { close(fd) }
    source.resume()
    previewWatcher = source
  }

  /// True if a bare token (e.g. `src`, `dist`) exists as a file/dir under the
  /// session cwd — powers clickable bare-word paths.
  ///
  /// This runs on the main thread for *every* `mouseMoved` (the link detector
  /// probes each bare token on the pointer's row/logical line). A raw
  /// `FileManager.fileExists` there is a synchronous disk stat per token per move,
  /// which stalls pointer tracking on rows full of path-like text. Memoize by
  /// (cwd, token) with a short TTL so repeated moves reuse the result and only a
  /// genuinely new token hits the filesystem.
  private func bareTokenResolvesToExistingPath(_ token: String, from sourceSession: TerminalSessionID) -> Bool {
    guard let cwd = sessionCwd(for: sourceSession), !cwd.isEmpty else { return false }
    let key = cwd + "\u{0}" + token
    let now = CACurrentMediaTime()
    if let cached = bareTokenExistenceCache[key], now - cached.timestamp < Self.bareTokenExistenceTTL {
      return cached.exists
    }
    let base = URL(fileURLWithPath: cwd).standardizedFileURL.path
    let path = URL(fileURLWithPath: cwd).appendingPathComponent(token).standardizedFileURL.path
    // Guard against `..` escaping cwd or resolving to cwd itself.
    let exists = path.hasPrefix(base + "/") && FileManager.default.fileExists(atPath: path)
    if bareTokenExistenceCache.count > Self.bareTokenExistenceCacheLimit {
      bareTokenExistenceCache.removeAll(keepingCapacity: true)
    }
    bareTokenExistenceCache[key] = (exists, now)
    return exists
  }

  private func sessionCwd(for sourceSession: TerminalSessionID) -> String? {
    sessionManager.workingDirectory(for: sourceSession)
      ?? workspaceRuntimes.first { runtime in
        PaneTreeReducer.listLeaves(in: runtime.layout.root).contains { $0.sessionId == sourceSession }
      }?.cwdBySession[sourceSession]
  }

  private func terminalFileInfo(
    _ target: TerminalFilePathTarget,
    from sourceSession: TerminalSessionID
  ) -> TerminalFileFacts? {
    guard let url = try? TerminalFilePathResolver.resolve(target, cwd: sessionCwd(for: sourceSession))
    else { return nil }
    let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
    let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
    return TerminalFileFacts(
      absolutePath: url.path,
      isDirectory: isDir,
      modified: attrs?[.modificationDate] as? Date,
      created: attrs?[.creationDate] as? Date,
      size: isDir ? nil : attrs?[.size] as? Int
    )
  }

  private func revealTerminalFilePath(_ target: TerminalFilePathTarget, from sourceSession: TerminalSessionID) {
    let cwd = sessionManager.workingDirectory(for: sourceSession)
      ?? workspaceRuntimes.first { runtime in
        PaneTreeReducer.listLeaves(in: runtime.layout.root).contains { $0.sessionId == sourceSession }
      }?.cwdBySession[sourceSession]

    do {
      let url = try TerminalFilePathResolver.resolve(target, cwd: cwd)
      NSWorkspace.shared.activateFileViewerSelecting([url])
    } catch TerminalFilePathResolver.Error.missingWorkingDirectory {
      showTitlebarToast(appText.relativePathMissingCwdToast, style: .info, lifetime: .transient(1.8))
      DebugLog.write("revealTerminalFilePath missing cwd path=\(target.rawPath)")
    } catch TerminalFilePathResolver.Error.pathNotFound {
      showTitlebarToast(appText.pathNotFoundToast, style: .info, lifetime: .transient(1.8))
      DebugLog.write("revealTerminalFilePath not found path=\(target.rawPath) cwd=\(cwd ?? "-")")
    } catch {
      showTitlebarToast(appText.revealPathFailedToast, style: .error, lifetime: .transient(2.2))
      DebugLog.write("revealTerminalFilePath failed path=\(target.rawPath) error=\(error)")
    }
  }

  func createWorkspace(name: String, rootPath: String?) {
    let workspace = Workspace(name: name.isEmpty ? "Workspace" : name, rootPath: rootPath)
    try? composition.workspaceStore?.save(workspace)
    refreshWorkspaces()
  }

  func createAndOpenWorkspace(name: String, rootPath: String? = nil) {
    let resolvedRootPath = AppSettings.workspaceRootPathForNewWorkspace(
      requestedRootPath: rootPath,
      defaultWorkingDirectory: settings.defaultWorkingDirectory
    )
    let workspace = Workspace(name: TitleFormatting.normalizedWorkspaceName(name), rootPath: resolvedRootPath)
    try? composition.workspaceStore?.save(workspace)
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
    try? composition.workspaceStore?.delete(id: workspace.id)
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
    try? composition.workspaceStore?.delete(id: workspace.id)
    refreshWorkspaces()
  }

  func createWorkspaceFromSwitcher() {
    createAndOpenWorkspace(name: "")
    closeWorkspaceSwitcher()
  }

  func renameWorkspaceFromSwitcher(_ workspaceListID: UUID, to name: String) {
    let nextName = TitleFormatting.normalizedWorkspaceName(name)
    if let runtimeIndex = workspaceRuntimes.firstIndex(where: { runtime in
      runtime.workspace?.id == workspaceListID || runtime.id == workspaceListID
    }) {
      var runtime = workspaceRuntimes[runtimeIndex]
      if let renamed = paneWorkspaceController.renameWorkspace(workspaceID: runtime.id, title: nextName) {
        runtime.layout = renamed
      } else {
        runtime.layout.title = nextName
      }
      if var workspace = runtime.workspace {
        workspace.name = nextName
        workspace.updatedAt = Date()
        runtime.workspace = workspace
      } else {
        let workspace = Workspace(
          id: runtime.id,
          name: nextName,
          rootPath: runtime.displayPath
        )
        runtime.workspace = workspace
      }
      workspaceRuntimes[runtimeIndex] = runtime
      persistWorkspaceRuntime(at: runtimeIndex)
      refreshWorkspaces()
      return
    }

    guard var workspace = workspaces.first(where: { $0.id == workspaceListID }) else { return }
    workspace.name = nextName
    workspace.updatedAt = Date()
    if var layout = workspace.layoutSnapshot {
      layout.title = nextName
      layout.workspaceId = workspace.id
      workspace.layoutSnapshot = layout
    }
    try? composition.workspaceStore?.save(workspace)
    refreshWorkspaces()
  }

  private func rememberActiveWorkspaceContentSize() {
    guard let activeWorkspaceID else { return }
    windowSizing.rememberContentSize(for: activeWorkspaceID)
  }

  private func expandTerminalWindowIfNeeded(for runtime: WorkspaceRuntime) {
    windowSizing.expandWindowIfNeeded(for: runtime.layout.root, workspaceID: runtime.id)
  }

  private func applyTerminalWindowMinimumContentSize(for runtime: WorkspaceRuntime) {
    windowSizing.applyMinimumContentSize(for: runtime.layout.root)
  }

  private func terminalWindowMaximumContentSize() -> NSSize? {
    windowSizing.maximumContentSize()
  }

  func openTitlebarToastAction() {
    guard let titlebarToast else { return }
    switch titlebarToast.style {
    case .update(let url):
      NSWorkspace.shared.open(url)
      notifications.dismissTitlebarToast()
    case .success, .info, .error:
      break
    }
  }

  func openInAppNotificationAction() {
    guard let notification = inAppNotification else { return }
    selectSession(notification.session)
    notifications.dismissInAppNotification()
    restoreTerminalKeyboardFocus()
  }

  func openSettingsWindow() {
    composition.openSettingsWindow()
  }

  func applyTerminalAppearance() {
    // Only push palette/font/renderer into this window's surfaces. Window chrome
    // is applied by TerminalChromeSyncView / WorkspaceTitlebarView (which target
    // the owning view.window after setup). Applying chrome here ran during
    // per-window AppModel.init, before SwiftUI finished building the titlebar,
    // which corrupted the theme frame and hid the traffic lights.
    surfaceRegistry.applyPalette(terminalPalette)
    surfaceRegistry.applyFont(
      family: settings.fontFamily,
      size: CGFloat(settings.fontSize),
      cjkFallbackFamily: settings.cjkFallbackFontFamily
    )
    surfaceRegistry.applyRendererOptions(settings.terminalRendererOptions)
    surfaceRegistry.applySemanticLinkText(appText.semanticLinkText)
    applyFocusedTerminalSurface()
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

  private var windowCloseObserver: AnyCancellable?

  func bindWindow(_ window: NSWindow?) {
    self.window = window
    windowCloseObserver?.cancel()
    windowCloseObserver = nil
    guard let window else { return }
    windowCloseObserver = NotificationCenter.default
      .publisher(for: NSWindow.willCloseNotification, object: window)
      .sink { [weak self] _ in self?.handleWindowClosed() }
  }

  private func handleWindowClosed() {
    let runtimes = workspaceRuntimes
    for runtime in runtimes {
      _ = paneWorkspaceController.closeWorkspace(workspaceID: runtime.id)
    }
    workspaceRuntimes.removeAll()
    composition.unregisterWindow(self)
  }

  func activateMainWindowAndFocusTerminal() {
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
    let target = window ?? NSApp.windows.first { $0.title == "ProGhostty" || $0.contentViewController != nil }
    target?.makeKeyAndOrderFront(nil)
    restoreTerminalKeyboardFocus()
  }

  private func showTitlebarToast(
    _ message: String,
    style: TitlebarToast.Style,
    lifetime: ProGhosttyTitlebarToastLifetime = .transient(1.8)
  ) {
    notifications.showTitlebarToast(message, style: style, lifetime: lifetime)
  }

  /// Broadcast entry point for app-global toasts (update available, settings
  /// saved) so AppComposition can surface them in each window's titlebar.
  func presentTitlebarToast(_ message: String, style: TitlebarToast.Style, lifetime: ProGhosttyTitlebarToastLifetime) {
    showTitlebarToast(message, style: style, lifetime: lifetime)
  }

  private var effectiveThemeName: String {
    appearance.effectiveThemeName
  }

  func closeUtilityOverlays() {
    isWorkspaceSwitcherPresented = false
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
      workspaceRuntimes[index].reportedTitleBySession[session] = nil
    }

    let restored = paneWorkspaceController.restoreLayout(workspaceID: activeWorkspaceID, layout: saved) ?? saved
    workspaceRuntimes[index].layout = restored
    persistWorkspaceRuntime(at: index)
    expandTerminalWindowIfNeeded(for: workspaceRuntimes[index])
    if let firstPane = PaneTreeReducer.listLeaves(in: saved.root).first {
      focusStore.focusPane(firstPane.paneId, in: saved.id)
    }
    syncWorkspaceSwitcherState()
    objectWillChange.send()
    shellIntegrationState = "layout restored"
  }

  // MARK: Confirmation prompts (thin forwarders → ConfirmationPrompts)

  private let confirmationPrompts = ConfirmationPrompts()

  private func confirmLayoutRestoreClosingPanes(count: Int) -> Bool {
    confirmationPrompts.confirmLayoutRestoreClosingPanes(count: count)
  }

  private func confirmWorkspaceDeletion(_ workspace: Workspace, runningPaneCount: Int) -> Bool {
    confirmationPrompts.confirmWorkspaceDeletion(
      workspace,
      runningPaneCount: runningPaneCount,
      text: appText
    )
  }

  /// Check every pane in every workspace for a foreground process. Called from
  /// the AppDelegate's `applicationShouldTerminate` so ⌘Q gets the same guard as
  /// closing a single pane.
  func hasAnyForegroundSession() -> Bool {
    for runtime in workspaceRuntimes {
      for leaf in PaneTreeReducer.listLeaves(in: runtime.layout.root) {
        if sessionManager.hasForegroundProcess(in: leaf.sessionId) { return true }
      }
    }
    return false
  }

  /// RunLoop-blocking confirmation dialog for ⌘Q-style termination. Mirrors
  /// `confirmPaneCloseWithForegroundProcess` but with a quit-specific message.
  func confirmQuitWithForegroundProcess() -> Bool {
    confirmationPrompts.confirmQuitWithForegroundProcess(text: appText)
  }

  private func confirmPaneCloseWithForegroundProcess() -> Bool {
    confirmationPrompts.confirmPaneCloseWithForegroundProcess(text: appText)
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
      removePaneSplitAvailability(for: runtimePanes)
      workspaceRuntimes.removeAll { $0.id == runtimeID }
      savedLayoutSnapshots[runtimeID] = nil
      windowSizing.forgetContentSize(for: runtimeID)
      activeWorkspaceID = paneWorkspaceController.activeWorkspaceID
      if let activeWorkspace {
        applyTerminalWindowMinimumContentSize(for: activeWorkspace)
      }
      syncWorkspaceSwitcherState()
      return runtimePanes
    }
    removePaneSplitAvailability(for: closed.panes)
    workspaceRuntimes.removeAll { $0.id == closed.workspaceID }
    savedLayoutSnapshots[closed.workspaceID] = nil
    windowSizing.forgetContentSize(for: closed.workspaceID)
    activeWorkspaceID = paneWorkspaceController.activeWorkspaceID
    if let activeWorkspace {
      applyTerminalWindowMinimumContentSize(for: activeWorkspace)
    }
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
      persistWorkspaceRuntime(at: index)
      applyTerminalWindowMinimumContentSize(for: workspaceRuntimes[index])
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

  /// Open the titlebar project-info panel for the active pane's cwd. Seeds the
  /// panel with the path immediately, then fills git info off the main thread.
  func openProjectInfoPanel(from view: NSView, anchor: NSRect) {
    guard let cwd = selectedCwd else { return }
    let url = URL(fileURLWithPath: cwd)
    let initial = ProjectInfo(
      absolutePath: cwd,
      displayName: url.lastPathComponent.isEmpty ? cwd : url.lastPathComponent,
      // Cheap synchronous guess so the panel opens in the right shape: a git repo
      // shows the git structure (loading), a plain dir shows "not a repo" — no
      // shape change when the async result lands. Confirmed/refined by the fetch.
      isGitRepository: Self.isInsideGitWorkTree(cwd),
      branch: nil,
      modifiedCount: 0,
      addedCount: 0,
      recentCommits: [],
      remoteURL: nil
    )
    let callbacks = ProjectInfoPopover.Callbacks(
      openRemote: { NSWorkspace.shared.open($0) },
      copyPath: { path in
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
      },
      revealInFinder: { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: $0)]) }
    )
    projectInfoPopover.present(
      initial: initial,
      anchor: anchor,
      in: view,
      palette: terminalPalette,
      usesDarkAppearance: usesDarkAppearance,
      text: appText,
      callbacks: callbacks,
      load: { ProjectInfoService.fetch(cwd: cwd) }
    )
  }

  /// Cheap synchronous check: is `cwd` inside a git work tree? Walks up looking
  /// for a `.git` entry (dir for a normal repo, file for a worktree/submodule).
  /// Bounded ancestor walk — no subprocess, safe to call on the click.
  private static func isInsideGitWorkTree(_ cwd: String) -> Bool {
    var dir = URL(fileURLWithPath: cwd).standardizedFileURL
    let fm = FileManager.default
    // Cap the walk so a pathological path can't spin; real trees are far shallower.
    for _ in 0..<64 {
      if fm.fileExists(atPath: dir.appendingPathComponent(".git").path) { return true }
      let parent = dir.deletingLastPathComponent()
      if parent.path == dir.path { break }
      dir = parent
    }
    return false
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
    composition.refreshWorkspaces()
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
    let grid = Self.initialGridSize(
      fontFamily: settings.fontFamily,
      fontSize: CGFloat(settings.fontSize)
    )
    return TerminalSessionConfig(
      shellPath: workspace?.defaultShell ?? settings.defaultShell,
      workingDirectory: workingDirectory,
      environment: [:],
      rows: grid.rows,
      cols: grid.cols,
      workspaceId: workspace?.id
    )
  }

  /// Initial PTY grid size derived from the default window content size and the
  /// configured font, so the shell's `$COLUMNS`/`$LINES` are correct from the
  /// first prompt instead of the old hardcoded 24×80.
  private static func initialGridSize(fontFamily: String, fontSize: CGFloat) -> TerminalGridSize {
    let surfaceSize = CGSize(
      width: ProGhosttyWindowSizing.defaultContentWidth,
      height: ProGhosttyWindowSizing.defaultContentHeight
    )
    let scale = NSScreen.main?.backingScaleFactor ?? 2
    return TerminalGridSizer.initialGridSize(
      surfaceSize: surfaceSize,
      fontFamily: fontFamily,
      fontSize: fontSize,
      scale: scale
    )
  }

  private func consumeEvents() async {
    for await event in sessionManager.events {
      handle(event)
    }
  }

  private func handle(_ event: TerminalEvent) {
    switch event {
    case .sessionClosed(let session):
      reconcileClosedSession(session)
    case .output(let session, _):
      // A command finishing without a cwd change (e.g. `git checkout`) emits no
      // OSC 7, so the branch cache never invalidates on its own. Debounce
      // output-idle and, back at a prompt, re-derive the branch in place.
      scheduleGitBranchIdleRefresh(for: session)
    case .cwdChanged(let session, let cwd):
      shellIntegrationState = "available"
      updateWorkspaceForSession(session, persist: true) { workspace in
        workspace.cwdBySession[session] = cwd
        if let updated = paneWorkspaceController.updatePaneCwd(session: session, cwd: cwd) {
          workspace.layout = updated
        } else {
          workspace.layout.root = layoutUpdatingPaneCwd(workspace.layout.root, session: session, cwd: cwd)
        }
      }
      // A fresh prompt fired OSC 7 — the foreground program is gone, so its
      // reported title must not linger (e.g. "vim" after :q).
      updateReportedTitle(nil, for: session)
      invalidateGitBranchCache()
      objectWillChange.send()
    case .titleChanged(let session, let title):
      // Titles belong to foreground programs (vim, ssh, Claude Code). A report
      // arriving while the shell itself is foreground is prompt-time noise
      // (precmd auto-titles) — and proof that any previous program's title is
      // stale, so it clears instead of displaying.
      let sanitized = sessionManager.hasForegroundProcess(in: session)
        ? AutoTitleSanitizer.sanitize(title)
        : nil
      updateReportedTitle(sanitized, for: session)
    case .clipboardWrite(_, let content):
      // OSC 52 clipboard write from a remote program (tmux/SSH). Land it in the
      // system clipboard so a remote copy becomes a local paste.
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(content, forType: .string)
    case .osc(let session, let sequence):
      shellIntegrationState = "available"
      handleProGhosttyControlOsc(session: session, sequence: sequence)
    case .desktopNotification(let session, let notification):
      let actions = TerminalNotificationPolicy.desktopNotificationActions(
        settings: settings,
        notification: notification,
        isAppActive: NSApp.isActive,
        isSessionFocused: selectedSessionID == session
      )
      performNotificationActions(actions, session: session)
    case .error(_, let message):
      shellIntegrationState = message
    default:
      break
    }
  }

  static func sessionClosedAction(
    for session: TerminalSessionID,
    in runtimes: [WorkspaceRuntime]
  ) -> SessionClosedAction {
    guard let runtime = runtimes.first(where: { runtime in
      PaneTreeReducer.listLeaves(in: runtime.layout.root).contains { $0.sessionId == session }
    }) else {
      return .none
    }

    let leaves = PaneTreeReducer.listLeaves(in: runtime.layout.root)
    guard let pane = leaves.first(where: { $0.sessionId == session }) else {
      return .none
    }
    return leaves.count > 1
      ? .closePane(workspaceID: runtime.id, paneID: pane.paneId)
      : .closeWorkspace(workspaceID: runtime.id)
  }

  private func reconcileClosedSession(_ session: TerminalSessionID) {
    switch Self.sessionClosedAction(for: session, in: workspaceRuntimes) {
    case .closePane(let workspaceID, let paneID):
      guard let index = workspaceRuntimes.firstIndex(where: { $0.id == workspaceID }) else { return }
      do {
        guard let closed = try paneWorkspaceController.closePane(workspaceID: workspaceID, paneID: paneID),
          let updatedLayout = paneWorkspaceController.workspaceLayout(id: workspaceID)
        else {
          return
        }
        var runtime = workspaceRuntimes[index]
        runtime.layout = updatedLayout
        runtime.cwdBySession[closed.sessionId] = nil
        runtime.reportedTitleBySession[closed.sessionId] = nil
        paneSplitAvailabilityController.remove(paneID: closed.paneId)
        workspaceRuntimes[index] = runtime
        persistWorkspaceRuntime(at: index)
        applyTerminalWindowMinimumContentSize(for: runtime)
        applyFocusedTerminalSurface()
      } catch {
        DebugLog.write("reconcileClosedSession closePane failed session=\(session) error=\(error)")
      }
    case .closeWorkspace(let workspaceID):
      _ = closeWorkspaceRuntime(id: workspaceID)
      closeTerminalWindowIfNoWorkspace()
    case .none:
      break
    }
  }

  private func closeTerminalWindowIfNoWorkspace() {
    guard workspaceRuntimes.isEmpty else { return }
    guard let window else { return }
    window.performClose(nil)
  }

  private func performNotificationActions(_ actions: [TerminalNotificationAction], session: TerminalSessionID) {
    for action in actions {
      switch action {
      case .inApp(let notification):
        showInAppNotification(notification, session: session)
      case .sound:
        composition.terminalNotificationSoundPlayer.playNotificationSound()
      case .desktop(let notification):
        composition.terminalNotificationCenter.showDesktopNotification(notification, session: session)
      }
    }
  }

  private func showInAppNotification(_ notification: TerminalDesktopNotification, session: TerminalSessionID) {
    notifications.showInAppNotification(InAppNotification(
      title: notification.title,
      body: notification.body,
      session: session,
      source: notification.source
    ))
  }

  /// Records (or clears, with nil) the program-reported title for a session.
  /// Skips identical values so repeated reports don't churn observers.
  private func updateReportedTitle(_ title: String?, for session: TerminalSessionID) {
    guard
      let index = workspaceRuntimes.firstIndex(where: { runtime in
        PaneTreeReducer.listLeaves(in: runtime.layout.root).contains { $0.sessionId == session }
      }),
      workspaceRuntimes[index].reportedTitleBySession[session] != title
    else {
      return
    }
    workspaceRuntimes[index].reportedTitleBySession[session] = title
  }

  private func updateWorkspaceForSession(_ id: TerminalSessionID, persist: Bool = false, _ update: (inout WorkspaceRuntime) -> Void) {
    guard
      let index = workspaceRuntimes.firstIndex(where: { workspace in
        PaneTreeReducer.listLeaves(in: workspace.layout.root).contains { $0.sessionId == id }
      })
    else {
      return
    }
    update(&workspaceRuntimes[index])
    if persist {
      persistWorkspaceRuntime(at: index)
    }
  }

  private func layoutUpdatingPaneCwd(_ root: PaneNode, session: TerminalSessionID, cwd: String) -> PaneNode {
    PaneTreeReducer.mapLeaves(in: root) { pane in
      guard pane.sessionId == session else { return pane }
      var updated = pane
      updated.cwd = cwd
      return updated
    }
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
    composition.terminalActionDispatcher.dispatch(message, in: self)
  }

}

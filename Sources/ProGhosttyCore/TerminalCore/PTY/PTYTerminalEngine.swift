import AppKit
import Darwin
import Foundation

enum TerminalScrollAnchor {
  static func replacementOrigin(
    previousOriginY: CGFloat,
    previousCursorDocumentMinY: CGFloat,
    nextCursorDocumentMinY: CGFloat,
    maxOriginY: CGFloat
  ) -> CGFloat {
    let previousCursorVisibleY = previousCursorDocumentMinY - previousOriginY
    let unclampedOrigin = nextCursorDocumentMinY - previousCursorVisibleY
    return min(max(unclampedOrigin, 0), max(0, maxOriginY))
  }
}

enum TerminalAttributedDiff {
  static func changedRanges(from old: NSAttributedString, to new: NSAttributedString) -> [NSRange] {
    guard old.length == new.length else {
      return new.length == 0 ? [] : [NSRange(location: 0, length: new.length)]
    }
    guard new.length > 0 else { return [] }

    let oldString = old.string as NSString
    let newString = new.string as NSString
    var ranges: [NSRange] = []
    var runStart: Int?

    for index in 0..<new.length {
      let changed = oldString.character(at: index) != newString.character(at: index)
        || !attributesEqual(old.attributes(at: index, effectiveRange: nil), new.attributes(at: index, effectiveRange: nil))
      if changed, runStart == nil {
        runStart = index
      } else if !changed, let start = runStart {
        ranges.append(NSRange(location: start, length: index - start))
        runStart = nil
      }
    }
    if let start = runStart {
      ranges.append(NSRange(location: start, length: new.length - start))
    }
    return ranges
  }

  @discardableResult
  static func apply(_ new: NSAttributedString, to storage: NSTextStorage) -> Int {
    guard storage.length == new.length else {
      storage.setAttributedString(new)
      return new.length == 0 ? 0 : 1
    }
    let old = NSAttributedString(attributedString: storage)
    let ranges = changedRanges(from: old, to: new)
    guard !ranges.isEmpty else { return 0 }
    storage.beginEditing()
    for range in ranges {
      storage.replaceCharacters(in: range, with: new.attributedSubstring(from: range))
    }
    storage.endEditing()
    return ranges.count
  }

  private static func attributesEqual(_ lhs: [NSAttributedString.Key: Any], _ rhs: [NSAttributedString.Key: Any]) -> Bool {
    NSDictionary(dictionary: lhs).isEqual(to: rhs)
  }
}

enum PTYRenderDebugLog {
  private static let url = URL(fileURLWithPath: "/tmp/proghostty-render.log")
  private static let isEnabled = ProcessInfo.processInfo.environment["PROGHOSTTY_RENDER_DEBUG"] == "1"

  static func write(_ message: String) {
    guard isEnabled else { return }
    let line = "[\(Date())] \(message)\n"
    guard let data = line.data(using: .utf8) else { return }
    if FileManager.default.fileExists(atPath: url.path) {
      if let handle = try? FileHandle(forWritingTo: url) {
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
      }
    } else {
      try? data.write(to: url)
    }
  }
}

private let ptyReadQueue = DispatchQueue(label: "dev.proghostty.pty.read", qos: .userInteractive)

@MainActor
public final class PTYTerminalEngine: TerminalSessionManager, TerminalSurfaceRegistry {
  private let sessionManager: PTYTerminalSessionManager
  private let surfaceRegistry: PTYTerminalSurfaceRegistry

  public var events: AsyncStream<TerminalEvent> {
    sessionManager.events
  }

  public init() {
    let surfaceRegistry = PTYTerminalSurfaceRegistry()
    self.surfaceRegistry = surfaceRegistry
    sessionManager = PTYTerminalSessionManager(surfaceRegistry: surfaceRegistry)
  }

  public func createSession(config: TerminalSessionConfig) throws -> TerminalSessionID {
    try sessionManager.createSession(config: config)
  }

  public func closeSession(_ id: TerminalSessionID) {
    sessionManager.closeSession(id)
  }

  public func resizeSession(_ id: TerminalSessionID, rows: Int, cols: Int) {
    sessionManager.resizeSession(id, rows: rows, cols: cols)
  }

  public func writeInput(_ data: Data, to id: TerminalSessionID) {
    sessionManager.writeInput(data, to: id)
  }

  public func controlToken(for id: TerminalSessionID) -> String? {
    sessionManager.controlToken(for: id)
  }

  public func viewForSession(_ id: TerminalSessionID) -> NSView? {
    surfaceRegistry.viewForSession(id)
  }

  public func selectedText(for id: TerminalSessionID) -> String? {
    surfaceRegistry.selectedText(for: id)
  }

  public func rendererDiagnostics(for id: TerminalSessionID) -> TerminalRendererDiagnostics? {
    surfaceRegistry.rendererDiagnostics(for: id)
  }

  public func applyPalette(_ palette: TerminalSurfacePalette) {
    surfaceRegistry.applyPalette(palette)
  }

  public func applyFont(family: String, size: CGFloat) {
    surfaceRegistry.applyFont(family: family, size: size)
  }

  public func applyRendererOptions(_ options: TerminalRendererOptions) {
    surfaceRegistry.applyRendererOptions(options)
  }

  public func setFocusedSession(_ id: TerminalSessionID?) {
    surfaceRegistry.setFocusedSession(id)
  }

  public func focusSessionView(_ id: TerminalSessionID?) {
    surfaceRegistry.focusSessionView(id)
  }

  public func setInputHandler(_ handler: (@MainActor (TerminalSessionID, Data) -> Void)?) {
    surfaceRegistry.setInputHandler(handler)
  }

  public func setActivationHandler(_ handler: (@MainActor (TerminalSessionID) -> Void)?) {
    surfaceRegistry.setActivationHandler(handler)
  }
}

@MainActor
public final class PTYTerminalSessionManager: TerminalSessionManager {
  private struct SessionState {
    var config: TerminalSessionConfig
    var pid: pid_t
    var fileDescriptor: Int32
    var readSource: DispatchSourceRead
    var waitTimer: DispatchSourceTimer
    var oscParser: OscParser
    var vtBridge: GhosttyVTBridge
    var controlToken: String
  }

  private let surfaceRegistry: PTYTerminalSurfaceRegistry
  private var sessions: [TerminalSessionID: SessionState] = [:]
  private var reapTimers: [pid_t: DispatchSourceTimer] = [:]
  private let continuation: AsyncStream<TerminalEvent>.Continuation
  public let events: AsyncStream<TerminalEvent>

  public init(surfaceRegistry: PTYTerminalSurfaceRegistry) {
    self.surfaceRegistry = surfaceRegistry
    var continuation: AsyncStream<TerminalEvent>.Continuation!
    events = AsyncStream { continuation = $0 }
    self.continuation = continuation
  }

  public func createSession(config: TerminalSessionConfig) throws -> TerminalSessionID {
    let id = TerminalSessionID()
    let token = UUID().uuidString
    var launchConfig = config
    launchConfig.environment = Self.controlEnvironment(
      base: config.environment,
      session: id,
      token: token
    )
    let result = try PTYLaunch.spawn(config: launchConfig)
    surfaceRegistry.createSurface(session: id)
    let vtBridge = try GhosttyVTBridge(cols: launchConfig.cols, rows: launchConfig.rows)
    let readSource = makeReadSource(session: id, fileDescriptor: result.fileDescriptor)
    let waitTimer = makeWaitTimer(session: id, pid: result.pid)
    sessions[id] = SessionState(
      config: launchConfig,
      pid: result.pid,
      fileDescriptor: result.fileDescriptor,
      readSource: readSource,
      waitTimer: waitTimer,
      oscParser: OscParser(),
      vtBridge: vtBridge,
      controlToken: token
    )
    readSource.resume()
    waitTimer.resume()
    continuation.yield(.sessionCreated(id))
    if let cwd = config.workingDirectory {
      continuation.yield(.cwdChanged(session: id, cwd: cwd))
    }
    return id
  }

  public func closeSession(_ id: TerminalSessionID) {
    guard let state = sessions.removeValue(forKey: id) else { return }
    state.readSource.cancel()
    state.waitTimer.cancel()
    surfaceRegistry.removeSurface(session: id)
    sendHangup(to: state.pid)
    scheduleReap(pid: state.pid)
    continuation.yield(.sessionClosed(id))
  }

  public func resizeSession(_ id: TerminalSessionID, rows: Int, cols: Int) {
    guard var state = sessions[id] else { return }
    let wasPinnedToBottom = surfaceRegistry.viewportIsPinnedToBottom(id) ?? true
    state.config.rows = rows
    state.config.cols = cols
    state.vtBridge.resize(cols: cols, rows: rows)
    sessions[id] = state
    PTYLaunch.resize(fileDescriptor: state.fileDescriptor, rows: rows, cols: cols)
    _ = Darwin.kill(state.pid, SIGWINCH)
    surfaceRegistry.prepareForPinnedOutput(
      session: id,
      wasPinnedToBottom: wasPinnedToBottom,
      bridge: state.vtBridge
    )
    surfaceRegistry.render(state.vtBridge, session: id)
  }

  public func writeInput(_ data: Data, to id: TerminalSessionID) {
    guard let state = sessions[id] else { return }
    surfaceRegistry.prepareForUserInput(session: id, bridge: state.vtBridge)
    surfaceRegistry.render(state.vtBridge, session: id)
    let fd = state.fileDescriptor
    data.withUnsafeBytes { bytes in
      guard let base = bytes.baseAddress else { return }
      _ = Darwin.write(fd, base, bytes.count)
    }
  }

  public func controlToken(for id: TerminalSessionID) -> String? {
    sessions[id]?.controlToken
  }

  nonisolated static func controlEnvironment(
    base: [String: String],
    session id: TerminalSessionID,
    token: String,
    helperSearchPath: String = helperSearchPath()
  ) -> [String: String] {
    var environment = base
    environment["TERM_PROGRAM"] = "ProGhostty"
    environment["PROGHOSTTY_SESSION_ID"] = id.description
    environment["PROGHOSTTY_SESSION_TOKEN"] = token
    let existingPath = environment["PATH"] ?? ProcessInfo.processInfo.environment["PATH"] ?? ""
    let pathPrefix = helperSearchPath.trimmingCharacters(in: .whitespacesAndNewlines)
    if !pathPrefix.isEmpty {
      environment["PATH"] = existingPath.isEmpty ? pathPrefix : "\(pathPrefix):\(existingPath)"
    }
    return environment
  }

  private nonisolated static func helperSearchPath() -> String {
    guard let executableDirectory = Bundle.main.executableURL?.deletingLastPathComponent().path else {
      return ""
    }
    let packageBuildDirectory = URL(fileURLWithPath: executableDirectory)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .standardized
      .path
    if packageBuildDirectory != executableDirectory {
      return "\(executableDirectory):\(packageBuildDirectory)"
    }
    return executableDirectory
  }

  private nonisolated func makeReadSource(session id: TerminalSessionID, fileDescriptor fd: Int32)
    -> DispatchSourceRead
  {
    let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: ptyReadQueue)
    source.setEventHandler { [weak self] in
      var buffer = [UInt8](repeating: 0, count: 16 * 1024)
      let count = Darwin.read(fd, &buffer, buffer.count)
      guard count > 0 else {
        Task { @MainActor [weak self] in self?.closeSession(id) }
        return
      }
      let data = Data(buffer.prefix(count))
      Task { @MainActor [weak self] in
        self?.handleOutput(data, session: id)
      }
    }
    source.setCancelHandler {
      Darwin.close(fd)
    }
    return source
  }

  private func makeWaitTimer(session id: TerminalSessionID, pid: pid_t) -> DispatchSourceTimer {
    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250))
    timer.setEventHandler { [weak self] in
      guard let exitCode = PTYLaunch.wait(pid: pid) else { return }
      Task { @MainActor [weak self] in
        self?.continuation.yield(.commandFinished(session: id, exitCode: exitCode))
        self?.closeSession(id)
      }
    }
    return timer
  }

  private func sendHangup(to pid: pid_t) {
    if Darwin.kill(-pid, SIGHUP) != 0 {
      _ = Darwin.kill(pid, SIGHUP)
    }
  }

  private func scheduleReap(pid: pid_t) {
    reapTimers[pid]?.cancel()

    final class ReapState {
      var attempts = 0
    }

    let state = ReapState()
    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100))
    timer.setEventHandler { [weak self] in
      guard let self else { return }
      if PTYLaunch.wait(pid: pid) != nil {
        self.reapTimers[pid]?.cancel()
        self.reapTimers[pid] = nil
        return
      }

      state.attempts += 1
      if state.attempts == 5 {
        _ = Darwin.kill(-pid, SIGTERM)
        _ = Darwin.kill(pid, SIGTERM)
      } else if state.attempts == 20 {
        _ = Darwin.kill(-pid, SIGKILL)
        _ = Darwin.kill(pid, SIGKILL)
      } else if state.attempts > 40 {
        self.reapTimers[pid]?.cancel()
        self.reapTimers[pid] = nil
      }
    }
    reapTimers[pid] = timer
    timer.resume()
  }

  private func handleOutput(_ data: Data, session id: TerminalSessionID) {
    guard var state = sessions[id] else { return }
    let wasPinnedToBottom = surfaceRegistry.viewportIsPinnedToBottom(id) ?? true
    state.vtBridge.write(data)
    surfaceRegistry.prepareForPinnedOutput(
      session: id,
      wasPinnedToBottom: wasPinnedToBottom,
      bridge: state.vtBridge
    )
    surfaceRegistry.render(state.vtBridge, session: id)
    let sequences = state.oscParser.parse(data)
    sessions[id] = state
    continuation.yield(.output(session: id, data: data))
    for sequence in sequences {
      continuation.yield(.osc(session: id, sequence: sequence))
      if let cwd = CwdTracker.cwd(from: sequence) {
        continuation.yield(.cwdChanged(session: id, cwd: cwd))
      }
      if sequence.command == "0" || sequence.command == "1" || sequence.command == "2",
        let title = sequence.parameters.last
      {
        continuation.yield(.titleChanged(session: id, title: title))
      }
    }
  }
}

@MainActor
public final class PTYTerminalSurfaceRegistry: TerminalSurfaceRegistry {
  private struct SurfaceState {
    var containerView: PTYTerminalSurfaceView
    var scrollView: NSScrollView
    var textView: PTYTextView
    var gridView: PTYGridView
    var cellGridBackend: GhosttyVTCellGridRendererBackend
    var textBackend: GhosttyVTTextRendererBackend
    var bridge: GhosttyVTBridge? = nil
    var lastFrame: GhosttyTerminalFrame? = nil
    var lastHTMLSnapshot: String? = nil
    var lastCursorFrame: GhosttyTerminalFrame? = nil
  }

  private struct CursorTextPlacement {
    var index: Int
    var filler: String
  }

  private var surfaces: [TerminalSessionID: SurfaceState] = [:]
  private var palette = TerminalSurfacePalette.dark
  private var fontFamily = FontManager.defaultMonospacedFontName()
  private var fontSize: CGFloat = 14
  private var focusedSessionID: TerminalSessionID?
  private var inputHandler: (@MainActor (TerminalSessionID, Data) -> Void)?
  private var activationHandler: (@MainActor (TerminalSessionID) -> Void)?
  private var rendererOptions = TerminalRendererOptions()

  public init() {}

  public func createSurface(session id: TerminalSessionID) {
    let textBackend = GhosttyVTTextRendererBackend(
      palette: palette,
      fontFamily: fontFamily,
      fontSize: fontSize
    )
    textBackend.setInputHandler { [weak self] data in
      guard let self else { return }
      inputHandler?(id, data)
    }
    textBackend.setActivationHandler { [weak self] in
      self?.activationHandler?(id)
    }
    let textView = textBackend.textView
    let scrollView = textBackend.scrollView

    let cellGridBackend = GhosttyVTCellGridRendererBackend(options: rendererOptions)
    let gridView = cellGridBackend.gridView
    gridView.inputHandler = { [weak self] data in
      guard let self else { return }
      inputHandler?(id, data)
    }
    gridView.viewportScrollHandler = { [weak self, weak cellGridBackend] rowDelta in
      guard let self, rowDelta != 0 else { return false }
      return self.scrollViewport(session: id, rowDelta: rowDelta, backend: cellGridBackend)
    }
    gridView.viewportCanScrollHandler = { [weak self] rowDelta in
      guard let self, rowDelta != 0 else { return false }
      return self.canScrollViewport(session: id, rowDelta: rowDelta)
    }
    gridView.activationHandler = { [weak self] in
      self?.activationHandler?(id)
    }
    gridView.pasteboard = .general
    gridView.applyPalette(palette)
    gridView.applyFont(family: fontFamily, size: fontSize)
    gridView.applyRendererOptions(rendererOptions)

    let containerView = PTYTerminalSurfaceView(scrollView: scrollView, liveGridView: gridView)
    containerView.applyPalette(palette)
    surfaces[id] = SurfaceState(
      containerView: containerView,
      scrollView: scrollView,
      textView: textView,
      gridView: gridView,
      cellGridBackend: cellGridBackend,
      textBackend: textBackend
    )
  }

  public func removeSurface(session id: TerminalSessionID) {
    surfaces[id] = nil
  }

  public func viewForSession(_ id: TerminalSessionID) -> NSView? {
    surfaces[id]?.containerView
  }

  public func selectedText(for id: TerminalSessionID) -> String? {
    guard let surface = surfaces[id] else { return nil }
    if surface.containerView.isShowingLiveGrid {
      return surface.gridView.selectedText
    }
    let textView = surface.textView
    let range = textView.selectedRange()
    guard range.length > 0 else { return nil }
    return (textView.string as NSString).substring(with: range)
  }

  public func rendererDiagnostics(for id: TerminalSessionID) -> TerminalRendererDiagnostics? {
    guard let surface = surfaces[id] else { return nil }
    return surface.containerView.isShowingLiveGrid
      ? surface.cellGridBackend.diagnostics
      : surface.textBackend.diagnostics
  }

  public func applyPalette(_ palette: TerminalSurfacePalette) {
    self.palette = palette
    for (sessionID, surface) in surfaces {
      surface.containerView.applyPalette(palette)
      surface.gridView.applyPalette(palette)
      surface.cellGridBackend.applyPalette(palette)
      surface.textBackend.applyPalette(palette)
      if let html = surface.lastHTMLSnapshot,
        let attributed = try? attributedTerminalSnapshot(
          fromHTML: html,
          cursorFrame: surface.lastCursorFrame,
          isFocused: isFocused(sessionID)
        )
      {
        surface.textBackend.render(attributed: attributed, scrollToEnd: false)
      } else if let frame = surface.lastFrame {
        render(frame, in: surface.cellGridBackend, isFocused: isFocused(sessionID))
      }
    }
  }

  public func applyFont(family: String, size: CGFloat) {
    fontFamily = family
    fontSize = size
    for (sessionID, surface) in surfaces {
      surface.textView.font = terminalFont(weight: .regular)
      surface.gridView.applyFont(family: family, size: size)
      surface.cellGridBackend.applyFont(family: family, size: size)
      surface.textBackend.applyFont(family: family, size: size)
      if let html = surface.lastHTMLSnapshot,
        let attributed = try? attributedTerminalSnapshot(
          fromHTML: html,
          cursorFrame: surface.lastCursorFrame,
          isFocused: isFocused(sessionID)
        )
      {
        surface.textBackend.render(attributed: attributed, scrollToEnd: false)
      } else if let frame = surface.lastFrame {
        render(frame, in: surface.cellGridBackend, isFocused: isFocused(sessionID))
      }
      surface.textView.window?.invalidateCursorRects(for: surface.textView)
      surface.gridView.window?.invalidateCursorRects(for: surface.gridView)
    }
  }

  public func applyRendererOptions(_ options: TerminalRendererOptions) {
    rendererOptions = options
    for surface in surfaces.values {
      surface.gridView.applyRendererOptions(options)
      surface.cellGridBackend.applyOptions(options)
    }
  }

  public func flushPendingRenderers() {
    for surface in surfaces.values {
      surface.cellGridBackend.flushPendingFrame()
    }
  }

  public func setFocusedSession(_ id: TerminalSessionID?) {
    guard focusedSessionID != id else { return }
    focusedSessionID = id
    for (sessionID, surface) in surfaces {
      if let html = surface.lastHTMLSnapshot,
        let attributed = try? attributedTerminalSnapshot(
          fromHTML: html,
          cursorFrame: surface.lastCursorFrame,
          isFocused: isFocused(sessionID)
        )
      {
        surface.textBackend.render(attributed: attributed, scrollToEnd: false)
      } else if let frame = surface.lastFrame {
        render(frame, in: surface.cellGridBackend, isFocused: isFocused(sessionID))
      }
    }
  }

  public func focusSessionView(_ id: TerminalSessionID?) {
    guard let id, let surface = surfaces[id] else { return }
    let responder: NSView = surface.containerView.isShowingLiveGrid ? surface.gridView : surface.textView
    responder.window?.makeFirstResponder(responder)
  }

  public func setInputHandler(_ handler: (@MainActor (TerminalSessionID, Data) -> Void)?) {
    inputHandler = handler
  }

  public func setActivationHandler(_ handler: (@MainActor (TerminalSessionID) -> Void)?) {
    activationHandler = handler
  }

  public func render(_ bridge: GhosttyVTBridge, session id: TerminalSessionID) {
    guard var surface = surfaces[id] else { return }
    render(bridge, surface: &surface, session: id)
    surfaces[id] = surface
  }

  private func scrollViewport(
    session id: TerminalSessionID,
    rowDelta: Int,
    backend: GhosttyVTCellGridRendererBackend?
  ) -> Bool {
    guard var surface = surfaces[id], let backend, let bridge = surface.bridge else { return false }
    // The grid controller uses positive deltas for visual downward movement
    // through history; libghostty's viewport API defines upward history
    // movement as negative.
    let terminalDelta = -rowDelta
    if isAtViewportEdge(deltaRows: terminalDelta, bridge: bridge) {
      return false
    }
    bridge.scrollViewport(deltaRows: terminalDelta)
    render(bridge, surface: &surface, session: id)
    backend.flushPendingFrame()
    backend.resetViewportStartRowKeepingVisualOffset()
    surfaces[id] = surface
    return true
  }

  func viewportIsPinnedToBottom(_ id: TerminalSessionID) -> Bool? {
    guard let bridge = surfaces[id]?.bridge, let scrollbar = try? bridge.scrollbar() else {
      return nil
    }
    return scrollbar.offset + scrollbar.length >= scrollbar.total
  }

  func prepareForPinnedOutput(
    session id: TerminalSessionID,
    wasPinnedToBottom: Bool,
    bridge: GhosttyVTBridge
  ) {
    guard wasPinnedToBottom, let surface = surfaces[id] else { return }
    scrollToBottom(bridge)
    surface.cellGridBackend.resetPixelScroll()
  }

  func prepareForUserInput(session id: TerminalSessionID, bridge: GhosttyVTBridge) {
    guard let surface = surfaces[id] else { return }
    scrollToBottom(bridge)
    surface.cellGridBackend.resetPixelScroll(suppressMomentum: true)
  }

  private func canScrollViewport(session id: TerminalSessionID, rowDelta: Int) -> Bool {
    guard let bridge = surfaces[id]?.bridge else { return false }
    return !isAtViewportEdge(deltaRows: -rowDelta, bridge: bridge)
  }

  private func isAtViewportEdge(deltaRows: Int, bridge: GhosttyVTBridge) -> Bool {
    guard let scrollbar = try? bridge.scrollbar(), scrollbar.total > scrollbar.length else {
      return true
    }
    if deltaRows < 0 {
      return scrollbar.offset == 0
    }
    if deltaRows > 0 {
      return scrollbar.offset + scrollbar.length >= scrollbar.total
    }
    return true
  }

  private func scrollToBottom(_ bridge: GhosttyVTBridge) {
    guard let scrollbar = try? bridge.scrollbar(), scrollbar.offset + scrollbar.length < scrollbar.total else {
      return
    }
    let rowsToBottom = scrollbar.total - (scrollbar.offset + scrollbar.length)
    bridge.scrollViewport(deltaRows: Int(min(UInt64(Int.max), rowsToBottom)))
  }

  private func render(_ bridge: GhosttyVTBridge, surface: inout SurfaceState, session id: TerminalSessionID) {
    surface.bridge = bridge
    let shouldFollowOutput = surface.textBackend.isScrolledToBottom
    let frame = try? bridge.frame()
    let rendererMode = rendererMode(for: frame)
    if let frame, rendererMode == .ghosttyVTCellGrid {
      surface.lastHTMLSnapshot = nil
      surface.lastFrame = frame
      surface.lastCursorFrame = nil
      let shouldTransferFocus = surface.textView.window?.firstResponder === surface.textView
      surface.containerView.showLiveGrid()
      PTYRenderDebugLog.write(
        "render session=\(id) mode=live-grid rows=\(frame.rows) cols=\(frame.cols) alt=\(frame.isAlternateScreen) cursor=(\(frame.cursorX),\(frame.cursorY)) shape=\(frame.cursorShape) belowCursor=\(hasRenderedContentBelowCursor(in: frame))"
      )
      if shouldTransferFocus {
        surface.gridView.window?.makeFirstResponder(surface.gridView)
      }
      render(bridge: bridge, fallbackFrame: frame, in: surface.cellGridBackend, isFocused: isFocused(id))
      if let scrollbar = try? bridge.scrollbar(), let scrollFrame = try? bridge.scrollFrame(overscanTop: 2, overscanBottom: 2) {
        PTYRenderDebugLog.write(
          "snapshot session=\(id) scrollbar=(offset:\(scrollbar.offset), length:\(scrollbar.length), total:\(scrollbar.total)) viewportStart=\(String(describing: scrollFrame.viewportStartRow)) tail=\"\(Self.tailText(from: scrollFrame.viewport))\""
        )
      }
      PTYRenderDebugLog.write("diagnostics session=\(id) \(surface.cellGridBackend.diagnostics.debugSummary)")
    } else if let html = try? bridge.htmlText(),
      let attributed = try? attributedTerminalSnapshot(fromHTML: html, cursorFrame: frame, isFocused: isFocused(id))
    {
      surface.containerView.showScrollback()
      PTYRenderDebugLog.write(
        "render session=\(id) mode=scrollback-html rows=\(frame?.rows ?? 0) cols=\(frame?.cols ?? 0) alt=\(frame?.isAlternateScreen ?? false) cursor=(\(frame?.cursorX ?? 0),\(frame?.cursorY ?? 0)) shape=\(String(describing: frame?.cursorShape)) belowCursor=\(frame.map { hasRenderedContentBelowCursor(in: $0) } ?? false)"
      )
      surface.lastHTMLSnapshot = html
      surface.lastFrame = nil
      surface.lastCursorFrame = frame
      surface.textBackend.setFocused(isFocused(id))
      surface.textBackend.render(attributed: attributed, scrollToEnd: shouldFollowOutput)
      PTYRenderDebugLog.write("diagnostics session=\(id) \(surface.textBackend.diagnostics.debugSummary)")
    } else if let text = try? bridge.plainText() {
      surface.containerView.showScrollback()
      PTYRenderDebugLog.write("render session=\(id) mode=plain-text")
      surface.lastHTMLSnapshot = nil
      surface.lastFrame = nil
      surface.lastCursorFrame = nil
      surface.textBackend.render(plainText: text)
      PTYRenderDebugLog.write("diagnostics session=\(id) \(surface.textBackend.diagnostics.debugSummary)")
    }
  }

  private func shouldRenderLiveCellGrid(_ frame: GhosttyTerminalFrame) -> Bool {
    frame.isAlternateScreen || frame.cursorShape != .block || hasRenderedContentBelowCursor(in: frame)
  }

  private func rendererMode(for frame: GhosttyTerminalFrame?) -> TerminalRendererMode {
    switch rendererOptions.mode {
    case .ghosttyVTTextFallback:
      return .ghosttyVTTextFallback
    case .ghosttyVTCellGrid:
      return .ghosttyVTCellGrid
    case .auto:
      guard frame != nil else { return .ghosttyVTTextFallback }
      return .ghosttyVTCellGrid
    }
  }

  private func hasRenderedContentBelowCursor(in frame: GhosttyTerminalFrame) -> Bool {
    let firstRowBelowCursor = max(0, frame.cursorY + 1)
    guard firstRowBelowCursor < frame.rows else { return false }
    for row in firstRowBelowCursor..<frame.rows {
      let rowStart = row * frame.cols
      let rowEnd = min(rowStart + frame.cols, frame.cells.count)
      guard rowStart < rowEnd else { continue }
      if frame.cells[rowStart..<rowEnd].contains(where: isRenderedCell) {
        return true
      }
    }
    return false
  }

  private static func tailText(from frame: GhosttyTerminalFrame, maxRows: Int = 6) -> String {
    guard frame.rows > 0, frame.cols > 0 else { return "" }
    let firstRow = max(0, frame.rows - maxRows)
    return (firstRow..<frame.rows)
      .map { row in
        let start = row * frame.cols
        let end = min(start + frame.cols, frame.cells.count)
        guard start < end else { return "" }
        return frame.cells[start..<end]
          .map { String($0.scalar) }
          .joined()
          .trimmingCharacters(in: .whitespaces)
      }
      .joined(separator: " | ")
  }

  private func render(
    _ frame: GhosttyTerminalFrame,
    in backend: GhosttyVTCellGridRendererBackend,
    isFocused: Bool
  ) {
    backend.setFocused(isFocused)
    backend.render(frame: frame)
  }

  private func render(
    bridge: GhosttyVTBridge,
    fallbackFrame frame: GhosttyTerminalFrame,
    in backend: GhosttyVTCellGridRendererBackend,
    isFocused: Bool
  ) {
    backend.setFocused(isFocused)
    guard let scrollFrame = try? bridge.scrollFrame(overscanTop: 2, overscanBottom: 2) else {
      backend.render(frame: frame)
      backend.updateOverscanDiagnostics(topRows: 0, bottomRows: 0)
      return
    }
    backend.render(scrollFrame: scrollFrame)
  }

  private func render(
    _ frame: GhosttyTerminalFrame,
    in view: NSTextView,
    scrollView: NSScrollView,
    isFocused: Bool,
    scrollToEnd: Bool
  ) {
    let attributed = TerminalAttributedRenderer(
      fontFamily: fontFamily,
      fontSize: fontSize,
      palette: palette,
      isFocused: isFocused
    )
    .attributedString(for: frame)
    replaceText(in: view, with: attributed, scrollView: scrollView, scrollToEnd: scrollToEnd)
  }

  private func replaceText(
    in textView: NSTextView,
    with attributed: NSAttributedString,
    scrollView: NSScrollView,
    scrollToEnd: Bool
  ) {
    let previousOrigin = scrollView.contentView.bounds.origin
    let previousCursorMinY = scrollToEnd ? cursorDocumentMinY(in: textView) : nil
    if let textStorage = textView.textStorage {
      TerminalAttributedDiff.apply(attributed, to: textStorage)
    } else {
      textView.textStorage?.setAttributedString(attributed)
    }
    textView.window?.invalidateCursorRects(for: textView)
    if scrollToEnd {
      if
        let previousCursorMinY,
        let nextCursorMinY = cursorDocumentMinY(in: textView),
        let documentView = scrollView.documentView
      {
        let maxOriginY = max(0, documentView.bounds.maxY - scrollView.contentView.bounds.height)
        let originY = TerminalScrollAnchor.replacementOrigin(
          previousOriginY: previousOrigin.y,
          previousCursorDocumentMinY: previousCursorMinY,
          nextCursorDocumentMinY: nextCursorMinY,
          maxOriginY: maxOriginY
        )
        scrollView.contentView.scroll(to: NSPoint(x: previousOrigin.x, y: originY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
      } else {
        textView.scrollToEndOfDocument(nil)
      }
    } else {
      scrollView.contentView.scroll(to: previousOrigin)
      scrollView.reflectScrolledClipView(scrollView.contentView)
    }
  }

  private func cursorDocumentMinY(in textView: NSTextView) -> CGFloat? {
    guard
      let textStorage = textView.textStorage,
      let layoutManager = textView.layoutManager,
      let textContainer = textView.textContainer,
      textStorage.length > 0
    else {
      return nil
    }
    var cursorRange: NSRange?
    textStorage.enumerateAttribute(
      .proGhosttyCursorShape,
      in: NSRange(location: 0, length: textStorage.length)
    ) { value, range, stop in
      guard value is TerminalCursorShape else { return }
      cursorRange = range
      stop.pointee = true
    }
    guard let cursorRange else { return nil }
    layoutManager.ensureLayout(for: textContainer)
    let glyphRange = layoutManager.glyphRange(
      forCharacterRange: NSRange(location: cursorRange.location, length: 1),
      actualCharacterRange: nil
    )
    guard glyphRange.length > 0 else { return nil }
    let rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
    return textView.textContainerOrigin.y + rect.minY
  }

  private func isScrolledToBottom(_ scrollView: NSScrollView) -> Bool {
    guard let documentView = scrollView.documentView else { return true }
    let visibleMaxY = scrollView.contentView.bounds.maxY
    let documentMaxY = documentView.bounds.maxY
    return documentMaxY - visibleMaxY < 2
  }

  private func isFocused(_ id: TerminalSessionID) -> Bool {
    focusedSessionID.map { $0 == id } ?? true
  }

  private func attributedTerminalSnapshot(from bridge: GhosttyVTBridge) throws -> NSAttributedString {
    try attributedTerminalSnapshot(fromHTML: bridge.htmlText(), cursorFrame: try? bridge.frame(), isFocused: true)
  }

  private func attributedTerminalSnapshot(
    fromHTML html: String,
    cursorFrame: GhosttyTerminalFrame?,
    isFocused: Bool
  ) throws -> NSAttributedString {
    let attributed = try GhosttyHTMLAttributedAdapter(
      palette: palette,
      fontFamily: fontFamily,
      fontSize: fontSize
    ).attributedString(fromHTML: html, isFocused: isFocused)
    return attributedWithCursor(attributed, cursorFrame: cursorFrame, isFocused: isFocused)
  }

  private func attributedWithCursor(
    _ attributed: NSAttributedString,
    cursorFrame: GhosttyTerminalFrame?,
    isFocused: Bool
  ) -> NSAttributedString {
    guard isFocused, let cursorFrame, cursorFrame.cursorVisible else {
      return attributed
    }
    let mutable = NSMutableAttributedString(attributedString: attributed)
    let placement = textPlacementForCursor(frame: cursorFrame, text: mutable.string as NSString)
    ensureCursorPlacement(placement, in: mutable)
    guard mutable.length > 0 else { return mutable }
    let safeIndex = min(placement.index, mutable.length - 1)
    mutable.addAttributes(
      [
        .font: terminalFont(weight: .regular),
        .proGhosttyCursorShape: cursorFrame.cursorShape,
        .proGhosttyCursorColor: palette.cursorBackground,
      ],
      range: NSRange(location: safeIndex, length: 1)
    )
    return mutable
  }

  private func ensureCursorPlacement(_ placement: CursorTextPlacement, in attributed: NSMutableAttributedString) {
    guard placement.index >= attributed.length else { return }
    let missing = placement.index - attributed.length + 1
    let filler = placement.filler.isEmpty
      ? String(repeating: " ", count: missing)
      : placement.filler + String(repeating: " ", count: max(0, missing - (placement.filler as NSString).length))
    attributed.append(NSAttributedString(string: filler, attributes: [
      .font: terminalFont(weight: .regular),
      .foregroundColor: palette.foreground,
      .backgroundColor: palette.background,
    ]))
  }

  private func textPlacementForCursor(frame: GhosttyTerminalFrame, text: NSString) -> CursorTextPlacement {
    let lineStarts = lineStartOffsets(in: text)
    guard !lineStarts.isEmpty else {
      let cursorX = max(0, frame.cursorX)
      return CursorTextPlacement(index: cursorX, filler: String(repeating: " ", count: cursorX + 1))
    }
    let cursorRow = max(0, frame.cursorY)
    let renderedTailRow = lastRenderedViewportRow(in: frame, fallback: cursorRow)
    let rowDeltaFromTail = renderedTailRow - cursorRow
    if rowDeltaFromTail < 0 {
      let missingRows = -rowDeltaFromTail
      let cursorX = max(0, frame.cursorX)
      let filler = String(repeating: "\n", count: missingRows) + String(repeating: " ", count: cursorX + 1)
      return CursorTextPlacement(index: text.length + missingRows + cursorX, filler: filler)
    }

    let targetLine = max(0, lineStarts.count - 1 - rowDeltaFromTail)
    let lineStart = lineStarts[targetLine]
    let lineEndRange = NSRange(location: lineStart, length: max(0, text.length - lineStart))
    let newline = text.range(of: "\n", options: [], range: lineEndRange)
    let lineEnd = newline.location == NSNotFound ? text.length : newline.location
    let desiredIndex = lineStart + max(0, frame.cursorX)
    let canExtendLineAtDocumentEnd = lineEnd == text.length
    let index = canExtendLineAtDocumentEnd ? desiredIndex : min(desiredIndex, lineEnd)
    return CursorTextPlacement(index: index, filler: "")
  }

  private func lastRenderedViewportRow(in frame: GhosttyTerminalFrame, fallback: Int) -> Int {
    var lastRenderedRow: Int?
    for row in 0..<max(0, frame.rows) {
      let rowStart = row * frame.cols
      let rowEnd = min(rowStart + frame.cols, frame.cells.count)
      guard rowStart < rowEnd else { continue }
      if frame.cells[rowStart..<rowEnd].contains(where: isRenderedCell) {
        lastRenderedRow = row
      }
    }
    return lastRenderedRow ?? fallback
  }

  private func isRenderedCell(_ cell: GhosttyTerminalFrame.Cell) -> Bool {
    cell.scalar != " " || !cell.usesDefaultBackground
  }

  private func lineStartOffsets(in text: NSString) -> [Int] {
    var starts = [0]
    var searchLocation = 0
    while searchLocation < text.length {
      let searchRange = NSRange(location: searchLocation, length: text.length - searchLocation)
      let newline = text.range(of: "\n", options: [], range: searchRange)
      guard newline.location != NSNotFound else { break }
      let nextStart = newline.location + 1
      if nextStart <= text.length {
        starts.append(nextStart)
      }
      searchLocation = nextStart
    }
    return starts
  }

  private func terminalFont(weight: NSFont.Weight) -> NSFont {
    if let named = NSFont(name: fontFamily, size: fontSize) {
      if weight == .semibold {
        return NSFontManager.shared.convert(named, toHaveTrait: .boldFontMask)
      }
      return named
    }
    return NSFont.monospacedSystemFont(ofSize: fontSize, weight: weight)
  }

  private static func hexString(for color: NSColor) -> String {
    let rgb = color.usingColorSpace(.deviceRGB) ?? color
    return String(
      format: "#%02X%02X%02X",
      Int(round(rgb.redComponent * 255)),
      Int(round(rgb.greenComponent * 255)),
      Int(round(rgb.blueComponent * 255))
    )
  }
}

public final class PTYTerminalSurfaceView: NSView {
  public let scrollView: NSScrollView
  public let liveGridView: PTYGridView

  public var isShowingLiveGrid: Bool {
    !liveGridView.isHidden
  }

  init(scrollView: NSScrollView, liveGridView: PTYGridView) {
    self.scrollView = scrollView
    self.liveGridView = liveGridView
    super.init(frame: .zero)
    wantsLayer = true
    addFullSizeSubview(scrollView)
    addFullSizeSubview(liveGridView)
    showScrollback()
  }

  required init?(coder: NSCoder) {
    nil
  }

  func applyPalette(_ palette: TerminalSurfacePalette) {
    layer?.backgroundColor = palette.background.cgColor
  }

  func showLiveGrid() {
    scrollView.isHidden = true
    liveGridView.isHidden = false
  }

  func showScrollback() {
    scrollView.isHidden = false
    liveGridView.isHidden = true
  }

  private func addFullSizeSubview(_ subview: NSView) {
    subview.translatesAutoresizingMaskIntoConstraints = false
    addSubview(subview)
    NSLayoutConstraint.activate([
      subview.leadingAnchor.constraint(equalTo: leadingAnchor),
      subview.trailingAnchor.constraint(equalTo: trailingAnchor),
      subview.topAnchor.constraint(equalTo: topAnchor),
      subview.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }
}

public final class PTYGridView: NSView {
  public var inputHandler: ((Data) -> Void)?
  public var viewportScrollHandler: ((Int) -> Bool)?
  public var viewportCanScrollHandler: ((Int) -> Bool)?
  public var activationHandler: (() -> Void)?
  public var pasteboard = NSPasteboard.general

  private var frameSnapshot: GhosttyTerminalFrame?
  private var scrollFrameSnapshot: GhosttyTerminalScrollFrame?
  private var palette = TerminalSurfacePalette.dark
  private var fontFamily = FontManager.defaultMonospacedFontName()
  private var fontSize: CGFloat = 14
  private var font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
  private var boldFont = NSFont.monospacedSystemFont(ofSize: 14, weight: .semibold)
  private var cellSize = CGSize(width: 8, height: 16)
  private var isFocusedTerminalStorage = true
  private var rendererOptions = TerminalRendererOptions()
  private var scrollCoordinator = PaneScrollCoordinator()
  private var suppressMomentumScroll = false
  private(set) public var viewport = TerminalViewport()
  private(set) public var lastDrawDuration: TimeInterval = 0
  private(set) public var maxDrawDuration: TimeInterval = 0
  private var totalDrawDuration: TimeInterval = 0
  private var drawCount = 0
  private var selectionAnchor: GridCoordinate?
  private var selectionHead: GridCoordinate?

  public override var acceptsFirstResponder: Bool { true }
  public override var isFlipped: Bool { true }
  public var isFocusedTerminal: Bool { isFocusedTerminalStorage }

  public var renderedText: String {
    guard let frameSnapshot else { return "" }
    return Self.renderedText(from: frameSnapshot)
  }

  public var cursorCellRect: NSRect? {
    guard let frame = frameSnapshot else { return nil }
    return rectForCell(row: frame.cursorY, col: frame.cursorX)
  }

  public var terminalCellSize: CGSize {
    cellSize
  }

  public var terminalContentInset: CGSize {
    contentInset
  }

  public var averageDrawDuration: TimeInterval {
    guard drawCount > 0 else { return 0 }
    return totalDrawDuration / Double(drawCount)
  }

  public var selectedText: String? {
    guard
      let frame = frameSnapshot,
      let selectionRange = normalizedSelectionRange()
    else {
      return nil
    }
    var lines: [String] = []
    for row in selectionRange.lower.row...selectionRange.upper.row {
      let startCol = row == selectionRange.lower.row ? selectionRange.lower.col : 0
      let endCol = row == selectionRange.upper.row ? selectionRange.upper.col : max(0, frame.cols - 1)
      guard startCol <= endCol else { continue }
      let line = (startCol...endCol).compactMap { col -> String? in
        let index = row * frame.cols + col
        guard index < frame.cells.count else { return nil }
        return String(frame.cells[index].scalar)
      }.joined()
      lines.append(line.trimmingCharacters(in: .whitespaces))
    }
    let value = lines.joined(separator: "\n")
    return value.isEmpty ? nil : value
  }

  public func applyPalette(_ palette: TerminalSurfacePalette) {
    self.palette = palette
    layer?.backgroundColor = palette.background.cgColor
    needsDisplay = true
  }

  public func applyFont(family: String, size: CGFloat) {
    fontFamily = family
    fontSize = size
    font = Self.font(family: family, size: size, weight: .regular)
    boldFont = Self.font(family: family, size: size, weight: .semibold)
    cellSize = Self.cellSize(for: font)
    needsDisplay = true
    window?.invalidateCursorRects(for: self)
  }

  public func applyRendererOptions(_ options: TerminalRendererOptions) {
    rendererOptions = options
    if !options.smoothPixelScrollingEnabled {
      scrollCoordinator.reset(reason: TerminalRendererDiagnostics.smoothScrollDisabledReason)
      viewport = TerminalViewport()
    }
  }

  public func resetViewportStartRowKeepingVisualOffset() {
    viewport = TerminalViewport(visualOffsetY: scrollCoordinator.pixelRemainderY)
  }

  public func resetPixelScroll(suppressMomentum: Bool = false) {
    scrollCoordinator.reset()
    viewport = TerminalViewport()
    suppressMomentumScroll = suppressMomentum
    needsDisplay = true
  }

  public func applyScrollDiagnostics(to diagnostics: inout TerminalRendererDiagnostics) {
    diagnostics.pixelRemainderY = scrollCoordinator.pixelRemainderY
    diagnostics.committedRowDelta = scrollCoordinator.lastCommittedRowDelta
    diagnostics.coalescedWheelEvents = scrollCoordinator.coalescedWheelEvents
    diagnostics.smoothScrollOffset = viewport.visualOffsetY
    if diagnostics.alternateScreenActive {
      diagnostics.pixelSmoothScroll = .unavailable
      diagnostics.pixelSmoothScrollReason = TerminalRendererDiagnostics.alternateScreenScrollReason
    } else if scrollCoordinator.isPixelScrollActive && (diagnostics.overscanTopRows > 0 || diagnostics.overscanBottomRows > 0) {
      diagnostics.pixelSmoothScroll = .experimental
      diagnostics.pixelSmoothScrollReason = TerminalRendererDiagnostics.smoothScrollEnabledReason
    } else if !scrollCoordinator.isPixelScrollActive {
      diagnostics.pixelSmoothScroll = .unavailable
      diagnostics.pixelSmoothScrollReason = scrollCoordinator.lastDisabledReason
    } else {
      diagnostics.pixelSmoothScroll = .unavailable
      diagnostics.pixelSmoothScrollReason = TerminalRendererDiagnostics.missingOverscanRowsReason
    }
  }

  public func setFocused(_ isFocused: Bool) {
    isFocusedTerminalStorage = isFocused
    needsDisplay = true
  }

  public func render(_ frame: GhosttyTerminalFrame, isFocused: Bool) {
    let previous = frameSnapshot
    frameSnapshot = frame
    scrollFrameSnapshot = nil
    isFocusedTerminalStorage = isFocused
    if let previous, previous.rows == frame.rows, previous.cols == frame.cols {
      for rect in Self.dirtyRects(from: previous, to: frame, cellSize: cellSize, inset: contentInset) {
        setNeedsDisplay(rect)
      }
    } else {
      needsDisplay = true
    }
    window?.invalidateCursorRects(for: self)
  }

  public func render(_ frame: GhosttyTerminalFrame, isFocused: Bool, dirty: CellGridDirtyResult) {
    frameSnapshot = frame
    scrollFrameSnapshot = nil
    isFocusedTerminalStorage = isFocused
    if viewport.visualOffsetY != 0 {
      needsDisplay = true
      window?.invalidateCursorRects(for: self)
      return
    }
    switch dirty.mode {
    case .clean:
      break
    case .full:
      needsDisplay = true
    case .dirty:
      for rect in Self.dirtyRects(forRows: dirty.rows, frame: frame, cellSize: cellSize, inset: contentInset) {
        setNeedsDisplay(rect)
      }
    }
    window?.invalidateCursorRects(for: self)
  }

  public func render(_ scrollFrame: GhosttyTerminalScrollFrame, isFocused: Bool, dirty: CellGridDirtyResult) {
    let previous = frameSnapshot
    frameSnapshot = scrollFrame.viewport
    scrollFrameSnapshot = scrollFrame
    isFocusedTerminalStorage = isFocused
    if viewport.visualOffsetY != 0 || !scrollFrame.overscanTop.isEmpty || !scrollFrame.overscanBottom.isEmpty {
      needsDisplay = true
      window?.invalidateCursorRects(for: self)
      return
    }
    if let previous, previous.rows == scrollFrame.viewport.rows, previous.cols == scrollFrame.viewport.cols {
      switch dirty.mode {
      case .clean:
        break
      case .full:
        needsDisplay = true
      case .dirty:
        for rect in Self.dirtyRects(
          forRows: dirty.rows,
          frame: scrollFrame.viewport,
          cellSize: cellSize,
          inset: contentInset
        ) {
          setNeedsDisplay(rect)
        }
      }
    } else {
      needsDisplay = true
    }
    window?.invalidateCursorRects(for: self)
  }

  public override func draw(_ dirtyRect: NSRect) {
    let drawStart = ProcessInfo.processInfo.systemUptime
    defer {
      let duration = ProcessInfo.processInfo.systemUptime - drawStart
      lastDrawDuration = duration
      maxDrawDuration = max(maxDrawDuration, duration)
      totalDrawDuration += duration
      drawCount += 1
    }
    palette.background.setFill()
    dirtyRect.fill()
    guard let viewportFrame = frameSnapshot else { return }
    let topOverscanRows = scrollFrameSnapshot?.overscanTop.count ?? 0
    let drawFrame = scrollFrameSnapshot.map(extendedFrame(from:)) ?? viewportFrame

    NSGraphicsContext.current?.saveGraphicsState()
    Self.terminalContentClipRect(
      cols: viewportFrame.cols,
      rows: viewportFrame.rows,
      cellSize: cellSize,
      inset: contentInset
    )
    .clip()
    let translationY = drawTranslationY(topOverscanRows: topOverscanRows)
    if translationY != 0 {
      let transform = NSAffineTransform()
      transform.translateX(by: 0, yBy: translationY)
      transform.concat()
    }
    let contentDirtyRect = contentDirtyRect(forDrawing: dirtyRect, translationY: translationY)
    let visibleRows = scrollFrameSnapshot == nil ? visibleRowRange(for: drawFrame) : 0..<drawFrame.rows
    for row in visibleRows {
      drawRow(row, frame: drawFrame, dirtyRect: contentDirtyRect)
    }
    drawCursor(viewportFrame, rowOffset: topOverscanRows, dirtyRect: contentDirtyRect)
    NSGraphicsContext.current?.restoreGraphicsState()
  }

  public static func visualScrollTranslationY(for viewport: TerminalViewport) -> CGFloat {
    0
  }

  public static func visualScrollTranslationY(
    for viewport: TerminalViewport,
    hasOverscanRows: Bool,
    cellHeight: CGFloat
  ) -> CGFloat {
    guard hasOverscanRows, cellHeight > 0 else { return 0 }
    return min(max(viewport.visualOffsetY, -cellHeight), cellHeight)
  }

  public static func contentDirtyRect(forDrawing dirtyRect: NSRect, viewport: TerminalViewport) -> NSRect {
    dirtyRect.offsetBy(dx: 0, dy: -visualScrollTranslationY(for: viewport))
  }

  public static func contentDirtyRect(
    forDrawing dirtyRect: NSRect,
    viewport: TerminalViewport,
    hasOverscanRows: Bool,
    cellHeight: CGFloat
  ) -> NSRect {
    dirtyRect.offsetBy(
      dx: 0,
      dy: -visualScrollTranslationY(
        for: viewport,
        hasOverscanRows: hasOverscanRows,
        cellHeight: cellHeight
      )
    )
  }

  public func canRenderPixelScroll(for visualOffsetY: CGFloat) -> Bool {
    guard visualOffsetY != 0, let scrollFrameSnapshot else { return false }
    return visualOffsetY > 0 ? !scrollFrameSnapshot.overscanTop.isEmpty : !scrollFrameSnapshot.overscanBottom.isEmpty
  }

  public static func terminalContentClipRect(
    cols: Int,
    rows: Int,
    cellSize: CGSize,
    inset: CGSize
  ) -> NSRect {
    NSRect(
      x: inset.width,
      y: inset.height,
      width: CGFloat(max(0, cols)) * cellSize.width,
      height: CGFloat(max(0, rows)) * cellSize.height
    )
  }

  public static func textGlyphRects(
    for run: CellDrawRun,
    row: Int,
    cellSize: CGSize,
    inset: CGSize
  ) -> [NSRect] {
    let count = min(run.text.unicodeScalars.count, run.range.count)
    return (0..<count).map { offset in
      textGlyphRect(
        row: row,
        col: run.range.lowerBound + offset,
        cellSize: cellSize,
        inset: inset
      )
    }
  }

  public static func textGlyphRect(row: Int, col: Int, cellSize: CGSize, inset: CGSize) -> NSRect {
    NSRect(
      x: inset.width + CGFloat(max(0, col)) * cellSize.width,
      y: inset.height + CGFloat(max(0, row)) * cellSize.height,
      width: cellSize.width,
      height: cellSize.height
    )
  }

  public override func scrollWheel(with event: NSEvent) {
    if suppressMomentumScroll {
      if !event.momentumPhase.isEmpty {
        PTYRenderDebugLog.write(
          "wheel-ignore reason=suppressed-momentum deltaY=\(String(format: "%.3f", event.scrollingDeltaY)) momentum=\(event.momentumPhase.rawValue)"
        )
        return
      }
      suppressMomentumScroll = false
    }
    PTYRenderDebugLog.write(
      "wheel precise=\(event.hasPreciseScrollingDeltas) deltaY=\(String(format: "%.3f", event.scrollingDeltaY)) phase=\(event.phase.rawValue) momentum=\(event.momentumPhase.rawValue)"
    )
    processScroll(deltaY: event.scrollingDeltaY) {
      super.scrollWheel(with: event)
    }
  }

  private func processScroll(deltaY: CGFloat, forwardToPTY: () -> Void = {}) {
    guard let frame = frameSnapshot else {
      PTYRenderDebugLog.write("wheel-forward reason=no-frame deltaY=\(String(format: "%.3f", deltaY))")
      forwardToPTY()
      return
    }
    if frame.isAlternateScreen {
      _ = scrollCoordinator.scroll(
        deltaY: deltaY,
        cellHeight: cellSize.height,
        alternateScreen: true,
        smoothPixelScrollingEnabled: rendererOptions.smoothPixelScrollingEnabled,
        hasOverscanRowsForProjectedRemainder: false
      )
      viewport = TerminalViewport()
      PTYRenderDebugLog.write(
        "wheel-forward reason=alternate-screen deltaY=\(String(format: "%.3f", deltaY))"
      )
      forwardToPTY()
      return
    }
    if deltaY != 0 {
      let rowDirection = deltaY.sign == .minus ? -1 : 1
      if viewportCanScrollHandler?(rowDirection) == false {
        scrollCoordinator.reset(reason: TerminalRendererDiagnostics.missingOverscanRowsReason)
        viewport = TerminalViewport()
        needsDisplay = true
        PTYRenderDebugLog.write(
          "wheel-ignore reason=edge deltaY=\(String(format: "%.3f", deltaY)) rowDirection=\(rowDirection)"
        )
        return
      }
    }
    let hasOverscanRowsForProjectedRemainder = hasOverscanRows(forVisualOffsetY: viewport.visualOffsetY + deltaY)
    let decision = scrollCoordinator.scroll(
      deltaY: deltaY,
      cellHeight: cellSize.height,
      alternateScreen: false,
      smoothPixelScrollingEnabled: rendererOptions.smoothPixelScrollingEnabled,
      hasOverscanRowsForProjectedRemainder: hasOverscanRowsForProjectedRemainder
    )
    PTYRenderDebugLog.write(
      "wheel-decision deltaY=\(String(format: "%.3f", deltaY)) cellHeight=\(String(format: "%.3f", cellSize.height)) smooth=\(rendererOptions.smoothPixelScrollingEnabled) hasOverscan=\(hasOverscanRowsForProjectedRemainder) decision=\(decision) viewportOffset=\(String(format: "%.3f", viewport.visualOffsetY))"
    )
    switch decision {
    case .consumed(let rowDelta, let pixelRemainderY):
      if rowDelta != 0 {
        let didScroll = viewportScrollHandler?(rowDelta) ?? false
        if didScroll {
          viewport = TerminalViewport(visualOffsetY: pixelRemainderY)
          if pixelRemainderY != 0, !canRenderPixelScroll(for: pixelRemainderY) {
            scrollCoordinator.reset(reason: TerminalRendererDiagnostics.missingOverscanRowsReason)
            viewport = TerminalViewport()
          }
          needsDisplay = true
        } else {
          scrollCoordinator.reset(reason: TerminalRendererDiagnostics.missingOverscanRowsReason)
          viewport = TerminalViewport()
        }
      } else {
        viewport = TerminalViewport(visualOffsetY: pixelRemainderY)
        if canRenderPixelScroll(for: pixelRemainderY) {
          needsDisplay = true
        } else {
          scrollCoordinator.reset(reason: TerminalRendererDiagnostics.missingOverscanRowsReason)
          viewport = TerminalViewport()
        }
      }
    case .forwardToPTY:
      forwardToPTY()
    case .ignored:
      break
    }
  }

  private func hasOverscanRows(forVisualOffsetY visualOffsetY: CGFloat) -> Bool {
    guard visualOffsetY != 0, let scrollFrameSnapshot else { return false }
    return visualOffsetY > 0 ? !scrollFrameSnapshot.overscanTop.isEmpty : !scrollFrameSnapshot.overscanBottom.isEmpty
  }

  public override func keyDown(with event: NSEvent) {
    activationHandler?()
    if let data = encodedInput(for: event) {
      inputHandler?(data)
    } else {
      super.keyDown(with: event)
    }
  }

  public override func performKeyEquivalent(with event: NSEvent) -> Bool {
    guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command),
      let key = event.charactersIgnoringModifiers?.lowercased()
    else {
      return super.performKeyEquivalent(with: event)
    }
    switch key {
    case "c":
      copy(nil)
      return true
    case "v":
      paste(nil)
      return true
    default:
      return super.performKeyEquivalent(with: event)
    }
  }

  public func copy(_ sender: Any?) {
    guard let selectedText else { return }
    pasteboard.clearContents()
    pasteboard.setString(selectedText, forType: .string)
  }

  public func paste(_ sender: Any?) {
    activationHandler?()
    guard let text = pasteboard.string(forType: .string), !text.isEmpty else { return }
    inputHandler?(Data(text.utf8))
  }

  func testScrollViewportRows(_ rowDelta: Int) {
    _ = viewportScrollHandler?(rowDelta)
  }

  func testScrollWheelDeltaY(_ deltaY: CGFloat) {
    processScroll(deltaY: deltaY)
  }

  func testScrollWheelDeltaY(_ deltaY: CGFloat, forwardToPTY: () -> Void) {
    processScroll(deltaY: deltaY, forwardToPTY: forwardToPTY)
  }

  func testMomentumScrollWheelDeltaY(_ deltaY: CGFloat) {
    if suppressMomentumScroll { return }
    processScroll(deltaY: deltaY)
  }

  public override func mouseDown(with event: NSEvent) {
    activationHandler?()
    window?.makeFirstResponder(self)
    let oldDirtyRects = selectionDirtyRects()
    let coordinate = coordinate(at: convert(event.locationInWindow, from: nil))
    selectionAnchor = coordinate
    selectionHead = coordinate
    invalidateSelectionRects(oldDirtyRects)
  }

  public override func mouseDragged(with event: NSEvent) {
    let oldDirtyRects = selectionDirtyRects()
    selectionHead = coordinate(at: convert(event.locationInWindow, from: nil))
    invalidateSelectionRects(oldDirtyRects)
  }

  public override func rightMouseDown(with event: NSEvent) {
    activationHandler?()
    guard let menu else {
      super.rightMouseDown(with: event)
      return
    }
    NSMenu.popUpContextMenu(menu, with: event, for: self)
  }

  public override func resetCursorRects() {
    guard let frame = frameSnapshot else { return }
    for row in 0..<frame.rows {
      for col in 0..<frame.cols {
        let index = row * frame.cols + col
        guard index < frame.cells.count, isRenderedCell(frame.cells[index]) else { continue }
        addCursorRect(rectForCell(row: row, col: col), cursor: .iBeam)
      }
    }
  }

  static func dirtyRects(
    from old: GhosttyTerminalFrame,
    to new: GhosttyTerminalFrame,
    cellSize: CGSize,
    inset: CGSize
  ) -> [NSRect] {
    let dirty = CellGridDirtyTracker.diff(previous: old, next: new)
    return dirtyRects(forRows: dirty.rows, frame: new, cellSize: cellSize, inset: inset)
  }

  static func dirtyRects(
    forRows rows: Set<Int>,
    frame: GhosttyTerminalFrame,
    cellSize: CGSize,
    inset: CGSize
  ) -> [NSRect] {
    rows.sorted().map { row in
      NSRect(
        x: inset.width,
        y: inset.height + CGFloat(max(0, row)) * cellSize.height,
        width: CGFloat(frame.cols) * cellSize.width,
        height: cellSize.height
      )
    }
  }

  public var currentSelectionRowSet: Set<Int> {
    selectionRows()
  }

  private func selectionDirtyRects() -> [NSRect] {
    selectionRows().map(rowRect)
  }

  private func invalidateSelectionRects(_ previous: [NSRect]) {
    for rect in previous + selectionDirtyRects() {
      setNeedsDisplay(rect)
    }
  }

  private func selectionRows() -> Set<Int> {
    guard let range = normalizedSelectionRange() else { return [] }
    return Set(range.lower.row...range.upper.row)
  }

  private func rowRect(_ row: Int) -> NSRect {
    guard let frameSnapshot else {
      return NSRect(
        x: contentInset.width,
        y: contentInset.height + CGFloat(max(0, row)) * cellSize.height,
        width: bounds.width,
        height: cellSize.height
      )
    }
    return NSRect(
      x: contentInset.width,
      y: contentInset.height + CGFloat(max(0, row)) * cellSize.height,
      width: CGFloat(frameSnapshot.cols) * cellSize.width,
      height: cellSize.height
    )
  }

  private var contentInset: CGSize {
    CGSize(width: 14, height: 12)
  }

  private func drawRow(_ row: Int, frame: GhosttyTerminalFrame, dirtyRect: NSRect) {
    let rowStart = row * frame.cols
    let rowEnd = min(rowStart + frame.cols, frame.cells.count)
    guard rowStart < rowEnd else { return }
    let rowRect = NSRect(
      x: contentInset.width,
      y: contentInset.height + CGFloat(row) * cellSize.height,
      width: CGFloat(frame.cols) * cellSize.width,
      height: cellSize.height
    )
    guard dirtyRect.intersects(rowRect) else { return }

    let cells = frame.cells[rowStart..<rowEnd]
    for run in CellRunBuilder.runs(for: cells) {
      drawRun(run, row: row)
    }
    drawSelectedCells(in: row, frame: frame, rowStart: rowStart, rowEnd: rowEnd)
  }

  private func drawRun(_ run: CellDrawRun, row: Int) {
    let rect = NSRect(
      x: contentInset.width + CGFloat(run.range.lowerBound) * cellSize.width,
      y: contentInset.height + CGFloat(row) * cellSize.height,
      width: CGFloat(run.range.count) * cellSize.width,
      height: cellSize.height
    )
    let foregroundBase = color(
      run.style.foreground,
      faint: run.style.faint,
      fallback: run.style.usesDefaultForeground ? palette.foreground : nil
    )
    let backgroundBase = color(
      run.style.background,
      faint: false,
      fallback: run.style.usesDefaultBackground ? palette.background : nil
    )
    let foreground = run.style.inverse ? backgroundBase : foregroundBase
    let background = run.style.inverse ? foregroundBase : backgroundBase
    if run.style.inverse || !run.style.usesDefaultBackground {
      background.setFill()
      rect.fill()
    }
    let attributes = textAttributes(for: run.style, foreground: foreground)
    for (offset, scalar) in run.text.unicodeScalars.enumerated() {
      guard offset < run.range.count else { break }
      guard scalar != " " else { continue }
      let glyphRect = Self.textGlyphRect(
        row: row,
        col: run.range.lowerBound + offset,
        cellSize: cellSize,
        inset: contentInset
      )
      drawText(String(scalar), in: glyphRect, attributes: attributes)
    }
  }

  private func drawSelectedCells(in row: Int, frame: GhosttyTerminalFrame, rowStart: Int, rowEnd: Int) {
    guard normalizedSelectionRange() != nil else { return }
    for col in 0..<frame.cols where isSelected(row: row, col: col) {
      let index = rowStart + col
      guard index < rowEnd else { continue }
      let cellRect = rectForCell(row: row, col: col)
      palette.cursorBackground.withAlphaComponent(0.18).setFill()
      cellRect.fill()
      let cell = frame.cells[index]
      guard cell.scalar != " " else { continue }
      drawCell(cell, in: cellRect, isSelected: true)
    }
  }

  private func drawCell(_ cell: GhosttyTerminalFrame.Cell, in rect: NSRect, isSelected: Bool) {
    let foregroundBase = color(cell.foreground, faint: cell.faint, fallback: cell.usesDefaultForeground ? palette.foreground : nil)
    let backgroundBase = color(cell.background, faint: false, fallback: cell.usesDefaultBackground ? palette.background : nil)
    let foreground = cell.inverse ? backgroundBase : foregroundBase
    let background = cell.inverse ? foregroundBase : backgroundBase
    if cell.inverse || !cell.usesDefaultBackground || isSelected {
      (isSelected ? palette.cursorBackground.withAlphaComponent(0.18) : background).setFill()
      rect.fill()
    }
    guard cell.scalar != " " else { return }
    drawText(String(cell.scalar), in: rect, attributes: textAttributes(for: cell, foreground: foreground))
  }

  private func drawCursor(_ frame: GhosttyTerminalFrame, rowOffset: Int = 0, dirtyRect: NSRect) {
    guard isFocusedTerminalStorage, frame.cursorVisible else { return }
    let rect = rectForCell(row: frame.cursorY + rowOffset, col: frame.cursorX)
    guard dirtyRect.intersects(rect) else { return }
    palette.cursorBackground.setFill()
    switch frame.cursorShape {
    case .block:
      NSBezierPath(rect: rect).fill()
      drawCursorGlyph(frame, in: rect)
    case .bar:
      NSBezierPath(rect: NSRect(x: rect.minX, y: rect.minY, width: max(1.5, rect.width * 0.12), height: rect.height)).fill()
    case .underline:
      NSBezierPath(rect: NSRect(x: rect.minX, y: rect.maxY - max(1.5, rect.height * 0.12), width: rect.width, height: max(1.5, rect.height * 0.12))).fill()
    case .hollowBlock:
      let path = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
      path.lineWidth = 1.5
      path.stroke()
    }
  }

  private func drawCursorGlyph(_ frame: GhosttyTerminalFrame, in rect: NSRect) {
    let index = frame.cursorY * frame.cols + frame.cursorX
    guard index < frame.cells.count else { return }
    let scalar = frame.cells[index].scalar
    guard scalar != " " else { return }
    drawText(
      String(scalar),
      in: rect,
      attributes: [
        .font: frame.cells[index].bold ? boldFont : font,
        .foregroundColor: palette.cursorForeground,
      ]
    )
  }

  private func drawText(_ text: String, in rect: NSRect, attributes: [NSAttributedString.Key: Any]) {
    NSString(string: text).draw(
      at: NSPoint(x: rect.minX, y: rect.minY + baselineOffset),
      withAttributes: attributes
    )
  }

  private func textAttributes(
    for cell: GhosttyTerminalFrame.Cell,
    foreground: NSColor
  ) -> [NSAttributedString.Key: Any] {
    [
      .font: cell.bold ? boldFont : font,
      .foregroundColor: adjustedForeground(foreground),
      .underlineStyle: cell.underline ? NSUnderlineStyle.single.rawValue : 0,
      .obliqueness: cell.italic ? 0.18 : 0,
    ]
  }

  private func rectForCell(row: Int, col: Int) -> NSRect {
    NSRect(
      x: contentInset.width + CGFloat(max(0, col)) * cellSize.width,
      y: contentInset.height + CGFloat(max(0, row)) * cellSize.height,
      width: cellSize.width,
      height: cellSize.height
    )
  }

  private func visibleRowRange(for frame: GhosttyTerminalFrame) -> Range<Int> {
    let controller = ViewportController(
      viewport: viewport,
      visibleRowCount: visibleRowCount(),
      overscan: 1
    )
    return controller.rowRange(totalRows: frame.rows)
  }

  private func drawTranslationY(topOverscanRows: Int) -> CGFloat {
    -CGFloat(topOverscanRows) * cellSize.height + visualScrollTranslationY()
  }

  private func visualScrollTranslationY() -> CGFloat {
    Self.visualScrollTranslationY(
      for: viewport,
      hasOverscanRows: canRenderPixelScroll(for: viewport.visualOffsetY),
      cellHeight: cellSize.height
    )
  }

  private func contentDirtyRect(forDrawing dirtyRect: NSRect, translationY: CGFloat) -> NSRect {
    dirtyRect.offsetBy(dx: 0, dy: -translationY)
  }

  private func extendedFrame(from scrollFrame: GhosttyTerminalScrollFrame) -> GhosttyTerminalFrame {
    var frame = scrollFrame.viewport
    frame.rows = scrollFrame.overscanTop.count + scrollFrame.viewport.rows + scrollFrame.overscanBottom.count
    frame.cursorY += scrollFrame.overscanTop.count
    frame.cells = scrollFrame.overscanTop.flatMap(\.cells)
      + scrollFrame.viewport.cells
      + scrollFrame.overscanBottom.flatMap(\.cells)
    return frame
  }

  private func visibleRowCount() -> Int {
    max(1, Int(ceil(bounds.height / max(1, cellSize.height))))
  }

  private var baselineOffset: CGFloat {
    max(0, (cellSize.height - font.ascender + font.descender) / 2)
  }

  private func coordinate(at point: NSPoint) -> GridCoordinate? {
    guard let frame = frameSnapshot else { return nil }
    let col = Int((point.x - contentInset.width) / cellSize.width)
    let row = Int((point.y - contentInset.height) / cellSize.height)
    guard row >= 0, row < frame.rows, col >= 0, col < frame.cols else { return nil }
    return GridCoordinate(row: row, col: col)
  }

  private func normalizedSelectionRange() -> (lower: GridCoordinate, upper: GridCoordinate)? {
    guard let anchor = selectionAnchor, let head = selectionHead, anchor != head else { return nil }
    if anchor < head {
      return (anchor, head)
    }
    return (head, anchor)
  }

  private func isSelected(row: Int, col: Int) -> Bool {
    guard let range = normalizedSelectionRange() else { return false }
    let coordinate = GridCoordinate(row: row, col: col)
    return coordinate >= range.lower && coordinate <= range.upper
  }

  private func color(_ rgb: GhosttyTerminalFrame.RGB, faint: Bool, fallback: NSColor? = nil) -> NSColor {
    let factor: CGFloat = faint ? 0.48 : 1.0
    if let fallback {
      let rgb = fallback.usingColorSpace(.deviceRGB) ?? fallback
      return NSColor(
        calibratedRed: rgb.redComponent * factor,
        green: rgb.greenComponent * factor,
        blue: rgb.blueComponent * factor,
        alpha: 1
      )
    }
    return NSColor(
      calibratedRed: CGFloat(rgb.r) / 255.0 * factor,
      green: CGFloat(rgb.g) / 255.0 * factor,
      blue: CGFloat(rgb.b) / 255.0 * factor,
      alpha: 1
    )
  }

  private func adjustedForeground(_ color: NSColor) -> NSColor {
    guard isFocusedTerminalStorage else {
      let rgb = color.usingColorSpace(.deviceRGB) ?? color
      let background = palette.background.usingColorSpace(.deviceRGB) ?? palette.background
      let amount = palette.inactiveForegroundBlend
      return NSColor(
        calibratedRed: rgb.redComponent + (background.redComponent - rgb.redComponent) * amount,
        green: rgb.greenComponent + (background.greenComponent - rgb.greenComponent) * amount,
        blue: rgb.blueComponent + (background.blueComponent - rgb.blueComponent) * amount,
        alpha: 1
      )
    }
    return color
  }

  private func encodedInput(for event: NSEvent) -> Data? {
    if event.modifierFlags.contains(.command) {
      return nil
    }

    guard let characters = event.charactersIgnoringModifiers, !characters.isEmpty else {
      return nil
    }

    if characters.count == 1, let scalar = characters.unicodeScalars.first {
      switch scalar.value {
      case UInt32(NSUpArrowFunctionKey):
        return Data("\u{1B}[A".utf8)
      case UInt32(NSDownArrowFunctionKey):
        return Data("\u{1B}[B".utf8)
      case UInt32(NSRightArrowFunctionKey):
        return Data("\u{1B}[C".utf8)
      case UInt32(NSLeftArrowFunctionKey):
        return Data("\u{1B}[D".utf8)
      case UInt32(NSDeleteCharacter):
        return Data([0x7F])
      case UInt32(NSEnterCharacter), UInt32(NSCarriageReturnCharacter):
        return Data([0x0D])
      case UInt32(NSTabCharacter):
        return Data([0x09])
      case UInt32(NSBackspaceCharacter):
        return Data([0x7F])
      case 0x1B:
        return Data([0x1B])
      default:
        break
      }
    }

    return event.characters.flatMap { Data($0.utf8) }
  }

  private static func cellSize(for font: NSFont) -> CGSize {
    let width = max(1, ceil(("W" as NSString).size(withAttributes: [.font: font]).width))
    let height = max(1, ceil(font.ascender - font.descender + font.leading))
    return CGSize(width: width, height: height)
  }

  private static func font(family: String, size: CGFloat, weight: NSFont.Weight) -> NSFont {
    if let named = NSFont(name: family, size: size) {
      if weight == .semibold {
        return NSFontManager.shared.convert(named, toHaveTrait: .boldFontMask)
      }
      return named
    }
    return NSFont.monospacedSystemFont(ofSize: size, weight: weight)
  }

  private static func renderedText(from frame: GhosttyTerminalFrame) -> String {
    var lines: [String] = []
    for row in 0..<frame.rows {
      let rowStart = row * frame.cols
      let rowEnd = min(rowStart + frame.cols, frame.cells.count)
      guard rowStart < rowEnd else {
        lines.append("")
        continue
      }
      lines.append(frame.cells[rowStart..<rowEnd].map { String($0.scalar) }.joined())
    }
    return lines.joined(separator: "\n")
  }

  private static func cellsEqual(_ lhs: GhosttyTerminalFrame.Cell, _ rhs: GhosttyTerminalFrame.Cell) -> Bool {
    lhs.scalar == rhs.scalar
      && lhs.foreground == rhs.foreground
      && lhs.background == rhs.background
      && lhs.bold == rhs.bold
      && lhs.italic == rhs.italic
      && lhs.faint == rhs.faint
      && lhs.underline == rhs.underline
      && lhs.inverse == rhs.inverse
      && lhs.usesDefaultForeground == rhs.usesDefaultForeground
      && lhs.usesDefaultBackground == rhs.usesDefaultBackground
  }

  private func isRenderedCell(_ cell: GhosttyTerminalFrame.Cell) -> Bool {
    cell.scalar != " " || !cell.usesDefaultBackground
  }

  private struct GridCoordinate: Comparable {
    var row: Int
    var col: Int

    static func < (lhs: GridCoordinate, rhs: GridCoordinate) -> Bool {
      if lhs.row == rhs.row {
        return lhs.col < rhs.col
      }
      return lhs.row < rhs.row
    }
  }
}

public typealias CellGridView = PTYGridView

struct GridSelectionCoordinate: Equatable, Sendable {
  var row: Int
  var col: Int

  init(row: Int, col: Int) {
    self.row = row
    self.col = col
  }
}

extension PTYGridView {
  func testSetSelection(anchor: GridSelectionCoordinate, head: GridSelectionCoordinate) {
    selectionAnchor = GridCoordinate(row: anchor.row, col: anchor.col)
    selectionHead = GridCoordinate(row: head.row, col: head.col)
  }
}

final class PTYTextView: NSTextView {
  var inputHandler: ((Data) -> Void)?
  var activationHandler: (() -> Void)?
  var scrollToBottomHandler: (() -> Void)?
  var pasteboard = NSPasteboard.general
  private var isHandlingTextSelection = false
  private var backgroundDragSelectionAnchor: Int?

  override var acceptsFirstResponder: Bool { true }

  override func resetCursorRects() {
    registerSelectableTextCursorRects()
  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    drawTerminalCursorOverlays(in: dirtyRect)
  }

  override func mouseDown(with event: NSEvent) {
    activationHandler?()
    window?.makeFirstResponder(self)
    let location = convert(event.locationInWindow, from: nil)
    guard isSelectableTextPoint(location) else {
      isHandlingTextSelection = false
      backgroundDragSelectionAnchor = characterIndexForSelectionBoundary(at: location)
      clearSelectionForTerminalBackgroundClick()
      return
    }
    isHandlingTextSelection = true
    backgroundDragSelectionAnchor = nil
    super.mouseDown(with: event)
  }

  override func mouseDragged(with event: NSEvent) {
    if isHandlingTextSelection {
      super.mouseDragged(with: event)
      return
    }
    guard
      let anchor = backgroundDragSelectionAnchor,
      let current = characterIndexForSelectionBoundary(at: convert(event.locationInWindow, from: nil))
    else {
      return
    }
    setSelectionRange(from: anchor, to: current)
  }

  override func mouseUp(with event: NSEvent) {
    if isHandlingTextSelection {
      super.mouseUp(with: event)
    }
    isHandlingTextSelection = false
    backgroundDragSelectionAnchor = nil
  }

  override func keyDown(with event: NSEvent) {
    activationHandler?()
    if let data = encodedInput(for: event) {
      scrollToBottomHandler?()
      inputHandler?(data)
    } else {
      super.keyDown(with: event)
    }
  }

  override func rightMouseDown(with event: NSEvent) {
    activationHandler?()
    guard let menu else {
      super.rightMouseDown(with: event)
      return
    }
    NSMenu.popUpContextMenu(menu, with: event, for: self)
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command),
      let key = event.charactersIgnoringModifiers?.lowercased()
    else {
      return super.performKeyEquivalent(with: event)
    }

    switch key {
    case "c":
      copy(nil)
      return true
    case "v":
      paste(nil)
      return true
    default:
      return super.performKeyEquivalent(with: event)
    }
  }

  override func copy(_ sender: Any?) {
    guard let selectedText else { return }
    pasteboard.clearContents()
    pasteboard.setString(selectedText, forType: .string)
  }

  override func paste(_ sender: Any?) {
    activationHandler?()
    guard let text = pasteboard.string(forType: .string), !text.isEmpty else {
      return
    }
    scrollToBottomHandler?()
    inputHandler?(Data(text.utf8))
  }

  private var selectedText: String? {
    let range = selectedRange()
    guard range.length > 0, NSMaxRange(range) <= (string as NSString).length else { return nil }
    return (string as NSString).substring(with: range)
  }

  func isSelectableTextPoint(_ point: NSPoint) -> Bool {
    guard
      let textContainer,
      let layoutManager,
      layoutManager.numberOfGlyphs > 0
    else {
      return false
    }

    layoutManager.ensureLayout(for: textContainer)
    let containerPoint = NSPoint(
      x: point.x - textContainerOrigin.x,
      y: point.y - textContainerOrigin.y
    )
    var fraction: CGFloat = 0
    let glyphIndex = layoutManager.glyphIndex(
      for: containerPoint,
      in: textContainer,
      fractionOfDistanceThroughGlyph: &fraction
    )
    guard glyphIndex < layoutManager.numberOfGlyphs else { return false }

    let glyphRect = layoutManager.boundingRect(
      forGlyphRange: NSRange(location: glyphIndex, length: 1),
      in: textContainer
    ).insetBy(dx: -1, dy: -1)
    guard glyphRect.contains(containerPoint) else { return false }

    let characterIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
    return isSelectableCharacter(at: characterIndex)
  }

  private func registerSelectableTextCursorRects() {
    guard
      let textContainer,
      let layoutManager,
      layoutManager.numberOfGlyphs > 0
    else {
      return
    }

    layoutManager.ensureLayout(for: textContainer)
    for glyphIndex in 0..<layoutManager.numberOfGlyphs {
      let characterIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
      guard isSelectableCharacter(at: characterIndex) else { continue }
      var rect = layoutManager.boundingRect(
        forGlyphRange: NSRange(location: glyphIndex, length: 1),
        in: textContainer
      )
      rect.origin.x += textContainerOrigin.x
      rect.origin.y += textContainerOrigin.y
      addCursorRect(rect.insetBy(dx: -1, dy: -1), cursor: .iBeam)
    }
  }

  private func isSelectableCharacter(at characterIndex: Int) -> Bool {
    let nsString = string as NSString
    guard characterIndex >= 0, characterIndex < nsString.length else { return false }
    guard let scalar = UnicodeScalar(Int(nsString.character(at: characterIndex))) else { return false }
    return !CharacterSet.whitespacesAndNewlines.contains(scalar)
  }

  private func characterIndexForSelectionBoundary(at point: NSPoint) -> Int? {
    guard
      let textContainer,
      let layoutManager,
      layoutManager.numberOfGlyphs > 0
    else {
      return nil
    }

    layoutManager.ensureLayout(for: textContainer)
    let containerPoint = NSPoint(
      x: point.x - textContainerOrigin.x,
      y: point.y - textContainerOrigin.y
    )
    let textLength = (string as NSString).length
    let glyphIndex = layoutManager.glyphIndex(for: containerPoint, in: textContainer)
    guard glyphIndex < layoutManager.numberOfGlyphs else {
      return textLength
    }
    let characterIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
    let glyphRect = layoutManager.boundingRect(
      forGlyphRange: NSRange(location: glyphIndex, length: 1),
      in: textContainer
    )
    if containerPoint.x > glyphRect.midX {
      return min(textLength, characterIndex + 1)
    }
    return characterIndex
  }

  private func setSelectionRange(from anchor: Int, to current: Int) {
    let lower = min(anchor, current)
    let upper = max(anchor, current)
    guard upper > lower else { return }
    setSelectedRange(NSRange(location: lower, length: upper - lower))
    needsDisplay = true
  }

  private func clearSelectionForTerminalBackgroundClick() {
    guard selectedRange().length > 0 else { return }
    setSelectedRange(NSRange(location: 0, length: 0))
    needsDisplay = true
  }

  private func drawTerminalCursorOverlays(in dirtyRect: NSRect) {
    guard
      let textStorage,
      let layoutManager,
      let textContainer,
      textStorage.length > 0
    else {
      return
    }

    layoutManager.ensureLayout(for: textContainer)
    let fullRange = NSRange(location: 0, length: textStorage.length)
    textStorage.enumerateAttribute(.proGhosttyCursorShape, in: fullRange) { value, range, _ in
      guard
        let shape = value as? TerminalCursorShape,
        range.location < textStorage.length
      else {
        return
      }

      let glyphRange = layoutManager.glyphRange(forCharacterRange: NSRange(location: range.location, length: 1), actualCharacterRange: nil)
      guard glyphRange.length > 0 else { return }
      var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
      rect.origin.x += textContainerOrigin.x
      rect.origin.y += textContainerOrigin.y
      guard dirtyRect.intersects(rect) else { return }

      let color = (textStorage.attribute(.proGhosttyCursorColor, at: range.location, effectiveRange: nil) as? NSColor)
        ?? insertionPointColor
        ?? TerminalSurfacePalette.dark.cursorBackground
      color.set()
      switch shape {
      case .block:
        NSBezierPath(rect: rect).fill()
      case .bar:
        NSBezierPath(rect: NSRect(x: rect.minX, y: rect.minY, width: max(1.5, rect.width * 0.12), height: rect.height)).fill()
      case .underline:
        NSBezierPath(rect: NSRect(x: rect.minX, y: rect.maxY - max(1.5, rect.height * 0.12), width: rect.width, height: max(1.5, rect.height * 0.12))).fill()
      case .hollowBlock:
        let path = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
        path.lineWidth = 1.5
        path.stroke()
      }
    }
  }

  private func encodedInput(for event: NSEvent) -> Data? {
    if event.modifierFlags.contains(.command) {
      return nil
    }

    guard let characters = event.charactersIgnoringModifiers, !characters.isEmpty else {
      return nil
    }

    if characters.count == 1, let scalar = characters.unicodeScalars.first {
      switch scalar.value {
      case UInt32(NSUpArrowFunctionKey):
        return Data("\u{1B}[A".utf8)
      case UInt32(NSDownArrowFunctionKey):
        return Data("\u{1B}[B".utf8)
      case UInt32(NSRightArrowFunctionKey):
        return Data("\u{1B}[C".utf8)
      case UInt32(NSLeftArrowFunctionKey):
        return Data("\u{1B}[D".utf8)
      case UInt32(NSDeleteCharacter):
        return Data([0x7F])
      case UInt32(NSEnterCharacter), UInt32(NSCarriageReturnCharacter):
        return Data([0x0D])
      case UInt32(NSTabCharacter):
        return Data([0x09])
      case UInt32(NSBackspaceCharacter):
        return Data([0x7F])
      case 0x1B:
        return Data([0x1B])
      default:
        break
      }
    }

    return event.characters.flatMap { Data($0.utf8) }
  }
}

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

func terminalControlInputData(for event: NSEvent) -> Data? {
  if event.modifierFlags.contains(.command) {
    return nil
  }

  // Tab key — keyCode 48 is always the physical Tab key.
  // macOS maps Shift+Tab to \u{19}, not \t, so keyCode is the only reliable way
  // to identify Tab regardless of modifiers.
  if event.keyCode == 48 {
    return event.modifierFlags.contains(.shift)
      ? Data("\u{1B}[Z".utf8) : Data([0x09])
  }

  if event.modifierFlags.contains(.control),
    let characters = event.characters,
    characters.count == 1,
    let scalar = characters.unicodeScalars.first,
    scalar.value <= 0x1F || scalar.value == 0x7F
  {
    return Data([UInt8(scalar.value)])
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
      return event.modifierFlags.contains(.shift) ? Data([0x0A]) : Data([0x0D])
    case UInt32(NSBackspaceCharacter):
      return Data([0x7F])
    case 0x1B:
      return Data([0x1B])
    default:
      break
    }
  }

  return nil
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
  static let isEnabled = ProcessInfo.processInfo.environment["PROGHOSTTY_RENDER_DEBUG"] == "1"
  private static let maxBytes = Int(ProcessInfo.processInfo.environment["PROGHOSTTY_RENDER_LOG_MAX_BYTES"] ?? "")
    ?? 8 * 1024 * 1024
  private static let sampleRate = max(
    1,
    Int(ProcessInfo.processInfo.environment["PROGHOSTTY_RENDER_LOG_SAMPLE_RATE"] ?? "") ?? 1
  )
  private static let sink = BoundedDebugLogSink(url: url, maxBytes: maxBytes, batchSize: 64)

  static func write(_ message: String) {
    guard isEnabled else { return }
    guard shouldWrite(message) else { return }
    sink.write(message)
  }

  private static func shouldWrite(_ message: String) -> Bool {
    guard sampleRate > 1, isHighFrequency(message) else { return true }
    return Int.random(in: 0..<sampleRate) == 0
  }

  private static func isHighFrequency(_ message: String) -> Bool {
    message.hasPrefix("wheel ")
      || message.hasPrefix("wheel-decision")
      || message.hasPrefix("metalDirectPresent")
      || message.hasPrefix("metalDirectEngine")
      || message.hasPrefix("inputCursor")
      || message.hasPrefix("inputRender")
  }
}

private let ptyReadQueue = DispatchQueue(label: "dev.proghostty.pty.read", qos: .userInteractive)

public struct ResizeRenderSnapshot: Sendable {
  public var frame: GhosttyTerminalFrame?
  public var scrollFrame: GhosttyTerminalScrollFrame?
  public var html: String?
  public var plainText: String?
  public var scrollbar: GhosttyTerminalScrollbar?

  public static func capture(from bridge: GhosttyVTBridge) -> ResizeRenderSnapshot {
    let scrollFrame = try? bridge.scrollFrame(overscanTop: GhosttyTerminalScrollFrame.pixelScrollOverscanRows, overscanBottom: GhosttyTerminalScrollFrame.pixelScrollOverscanRows)
    let frame = scrollFrame?.viewport ?? (try? bridge.frame())
    let html = frame == nil ? try? bridge.htmlText() : nil
    let plainText = frame == nil && html == nil ? try? bridge.plainText() : nil
    return ResizeRenderSnapshot(
      frame: frame,
      scrollFrame: scrollFrame,
      html: html,
      plainText: plainText,
      scrollbar: try? bridge.scrollbar()
    )
  }
}

enum GhosttyVTQueueWork {
  static func viewportIsPinnedToBottom(_ bridge: GhosttyVTBridge) -> Bool {
    guard let scrollbar = try? bridge.scrollbar() else { return true }
    return scrollbar.offset + scrollbar.length >= scrollbar.total
  }

  static func isAtViewportEdge(deltaRows: Int, bridge: GhosttyVTBridge) -> Bool {
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

  static func scrollToBottom(_ bridge: GhosttyVTBridge) {
    guard let scrollbar = try? bridge.scrollbar(), scrollbar.offset + scrollbar.length < scrollbar.total else {
      return
    }
    let rowsToBottom = scrollbar.total - (scrollbar.offset + scrollbar.length)
    bridge.scrollViewport(deltaRows: Int(min(UInt64(Int.max), rowsToBottom)))
  }
}

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

  public func writePaste(_ text: String, to id: TerminalSessionID) {
    sessionManager.writePaste(text, to: id)
  }

  public func workingDirectory(for id: TerminalSessionID) -> String? {
    sessionManager.workingDirectory(for: id)
  }

  public func controlToken(for id: TerminalSessionID) -> String? {
    sessionManager.controlToken(for: id)
  }

  public func hasForegroundProcess(in id: TerminalSessionID) -> Bool {
    sessionManager.hasForegroundProcess(in: id)
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

  public func applyFont(family: String, size: CGFloat, cjkFallbackFamily: String? = nil) {
    surfaceRegistry.applyFont(family: family, size: size, cjkFallbackFamily: cjkFallbackFamily)
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

  public func setPasteHandler(_ handler: (@MainActor (TerminalSessionID, String) -> Void)?) {
    surfaceRegistry.setPasteHandler(handler)
  }

  public func setActivationHandler(_ handler: (@MainActor (TerminalSessionID) -> Void)?) {
    surfaceRegistry.setActivationHandler(handler)
  }

  public func setLinkHoverHandler(_ handler: (@MainActor (TerminalSessionID, Bool) -> Void)?) {
    surfaceRegistry.setLinkHoverHandler(handler)
  }

  public func setLinkTargetHandler(_ handler: (@MainActor (TerminalSessionID, TerminalLinkTarget) -> Void)?) {
    surfaceRegistry.setLinkTargetHandler(handler)
  }

  public func setPathExistenceProvider(_ provider: (@MainActor (TerminalSessionID, String) -> Bool)?) {
    surfaceRegistry.setPathExistenceProvider(provider)
  }

  public func setFileInfoProvider(_ provider: (@MainActor (TerminalSessionID, TerminalFilePathTarget) -> TerminalFileFacts?)?) {
    surfaceRegistry.setFileInfoProvider(provider)
  }

  public func applySemanticLinkText(_ text: SemanticLinkText) {
    surfaceRegistry.applySemanticLinkText(text)
  }
}

@MainActor
public final class PTYTerminalSessionManager: TerminalSessionManager {
  private struct PendingResizeJob {
    var rows: Int
    var cols: Int
    var generation: UInt64
    var bridge: GhosttyVTBridge
    var fileDescriptor: Int32
    var pid: pid_t
    var vtQueue: DispatchQueue
  }

  private struct SessionState {
    var config: TerminalSessionConfig
    var pid: pid_t
    var fileDescriptor: Int32
    var readSource: DispatchSourceRead
    var waitTimer: DispatchSourceTimer
    var oscParser: OscParser
    var vtBridge: GhosttyVTBridge
    var controlToken: String
    var vtQueue: DispatchQueue
    var resizeGeneration: UInt64 = 0
  }

  private let surfaceRegistry: PTYTerminalSurfaceRegistry
  private var sessions: [TerminalSessionID: SessionState] = [:]
  private var lastInputUptimeBySession: [TerminalSessionID: TimeInterval] = [:]
  private var reapTimers: [pid_t: DispatchSourceTimer] = [:]
  private let continuation: AsyncStream<TerminalEvent>.Continuation
  public let events: AsyncStream<TerminalEvent>
  private lazy var resizeScheduler: TerminalResizeScheduler<PendingResizeJob> = TerminalResizeScheduler { [weak self] session, job in
    self?.performScheduledResize(session: session, job: job)
  }
  private lazy var outputBatchCoordinator: TerminalOutputBatchCoordinator = TerminalOutputBatchCoordinator(
    coalescingDelayNanoseconds: TerminalOutputCoordinator.pipelineStageDelayNanoseconds
  ) { [weak self] data, session, delivery in
    self?.flushOutput(data, session: session, delivery: delivery)
  }
  /// After VT resize we stage the first snapshot but delay presenting until the
  /// shell's SIGWINCH redraw has a chance to replace that stage. One present at
  /// settle avoids "reflow flash + second flash when content settles".
  private var resizePresentSettleTasks: [TerminalSessionID: Task<Void, Never>] = [:]
  private nonisolated static let interactiveInputByteLimit = 16
  private nonisolated static let interactiveEchoOutputByteLimit = 96
  private nonisolated static let interactiveEchoWindowSeconds: TimeInterval = 0.15
  private nonisolated static let resizePresentSettleNanoseconds: UInt64 = 64_000_000

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
      controlToken: token,
      vtQueue: DispatchQueue(label: "dev.proghostty.vt.\(id.rawValue.uuidString)", qos: .userInteractive)
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
    lastInputUptimeBySession[id] = nil
    outputBatchCoordinator.cancel(session: id)
    cancelResizePresentSettle(session: id)
    state.readSource.cancel()
    state.waitTimer.cancel()
    resizeScheduler.cancel(session: id)
    surfaceRegistry.removeSurface(session: id)
    sendHangup(to: state.pid)
    scheduleReap(pid: state.pid)
    continuation.yield(.sessionClosed(id))
  }

  public func resizeSession(_ id: TerminalSessionID, rows: Int, cols: Int) {
    guard var state = sessions[id] else { return }
    guard state.config.rows != rows || state.config.cols != cols else { return }
    outputBatchCoordinator.flush(session: id)
    // A newer resize supersedes any settle that would present an older stage.
    cancelResizePresentSettle(session: id)
    state.config.rows = rows
    state.config.cols = cols
    state.resizeGeneration &+= 1
    let generation = state.resizeGeneration
    let bridge = state.vtBridge
    let vtQueue = state.vtQueue
    let fd = state.fileDescriptor
    let pid = state.pid
    sessions[id] = state
    surfaceRegistry.markResizePending(session: id)
    resizeScheduler.schedule(
      request: PendingResizeJob(
        rows: rows,
        cols: cols,
        generation: generation,
        bridge: bridge,
        fileDescriptor: fd,
        pid: pid,
        vtQueue: vtQueue
      ),
      session: id
    )
  }

  public func writeInput(_ data: Data, to id: TerminalSessionID) {
    guard let state = sessions[id] else { return }
    outputBatchCoordinator.flush(session: id)
    if data.count <= Self.interactiveInputByteLimit {
      lastInputUptimeBySession[id] = ProcessInfo.processInfo.systemUptime
    }
    data.withUnsafeBytes { bytes in
      guard let base = bytes.baseAddress else { return }
      _ = Darwin.write(state.fileDescriptor, base, bytes.count)
    }
    guard surfaceRegistry.prepareForUserInput(session: id) else { return }
    let bridge = state.vtBridge
    let vtQueue = state.vtQueue
    let generation = state.resizeGeneration
    vtQueue.async { [weak self] in
      GhosttyVTQueueWork.scrollToBottom(bridge)
      let snapshot = ResizeRenderSnapshot.capture(from: bridge)
      Task { @MainActor [weak self] in
        guard let self, let current = self.sessions[id], current.resizeGeneration == generation else {
          return
        }
        self.surfaceRegistry.render(snapshot, bridge: bridge, session: id)
      }
    }
  }

  public func writePaste(_ text: String, to id: TerminalSessionID) {
    guard let state = sessions[id], !text.isEmpty else { return }
    let bridge = state.vtBridge
    let encoded = state.vtQueue.sync {
      Result { try bridge.encodedPaste(text) }
    }

    switch encoded {
    case .success(let data):
      writeInput(data, to: id)
    case .failure(let error):
      continuation.yield(.error(session: id, message: "Paste encode failed: \(error)"))
    }
  }

  public func workingDirectory(for id: TerminalSessionID) -> String? {
    guard let state = sessions[id] else { return nil }
    return Self.processWorkingDirectory(pid: state.pid)
      ?? state.config.workingDirectory
  }

  public func controlToken(for id: TerminalSessionID) -> String? {
    sessions[id]?.controlToken
  }

  public func hasForegroundProcess(in id: TerminalSessionID) -> Bool {
    guard let state = sessions[id] else { return false }
    let foregroundProcessGroup = tcgetpgrp(state.fileDescriptor)
    guard foregroundProcessGroup > 0 else { return false }
    let shellProcessGroup = getpgid(state.pid)
    guard shellProcessGroup > 0 else { return false }
    return foregroundProcessGroup != shellProcessGroup
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
    environment["PROGHOSTTY_NOTIFY_TTY"] = environment["PROGHOSTTY_NOTIFY_TTY"] ?? "/dev/tty"
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
      guard PTYLaunch.wait(pid: pid) != nil else { return }
      Task { @MainActor [weak self] in
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
    let secondsSinceLastInput = lastInputUptimeBySession[id].map {
      ProcessInfo.processInfo.systemUptime - $0
    }
    let delivery: TerminalOutputCoordinator.Delivery = Self.isInteractiveEchoOutput(
      data,
      secondsSinceLastInput: secondsSinceLastInput
    ) ? .immediate : .coalesced
    if delivery == .immediate {
      // A keystroke grants exactly ONE low-latency immediate echo. Consume the
      // timestamp so a burst triggered by that keystroke (e.g. pressing Return
      // to run `seq 1 30000`) doesn't keep matching the echo window and flush
      // every small read chunk separately — the rest coalesces into big batches.
      lastInputUptimeBySession[id] = nil
    }
    let sequences = state.oscParser.parse(data)
    sessions[id] = state
    continuation.yield(.output(session: id, data: data))
    for sequence in sequences {
      continuation.yield(.osc(session: id, sequence: sequence))
      if let notification = TerminalDesktopNotificationParser.parse(sequence) {
        continuation.yield(.desktopNotification(session: id, notification: notification))
      }
      if let cwd = CwdTracker.cwd(from: sequence) {
        state.config.workingDirectory = cwd
        sessions[id] = state
        continuation.yield(.cwdChanged(session: id, cwd: cwd))
      }
      if let title = TitleTracker.title(from: sequence) {
        continuation.yield(.titleChanged(session: id, title: title))
      }
    }

    outputBatchCoordinator.receive(data, session: id, delivery: delivery)
  }

  private func flushOutput(
    _ data: Data,
    session id: TerminalSessionID,
    delivery: TerminalOutputCoordinator.Delivery
  ) {
    guard let state = sessions[id] else { return }
    let bridge = state.vtBridge
    let vtQueue = state.vtQueue
    let generation = state.resizeGeneration
    vtQueue.async { [weak self] in
      bridge.write(data)
      let wasPinnedToBottom = GhosttyVTQueueWork.viewportIsPinnedToBottom(bridge)
      if wasPinnedToBottom {
        GhosttyVTQueueWork.scrollToBottom(bridge)
      }
      let snapshot = ResizeRenderSnapshot.capture(from: bridge)
      Task { @MainActor [weak self] in
        guard let self, let current = self.sessions[id], current.resizeGeneration == generation else {
          return
        }
        self.surfaceRegistry.renderOutput(
          snapshot,
          bridge: bridge,
          session: id,
          wasPinnedToBottom: wasPinnedToBottom,
          delivery: delivery
        )
      }
    }
  }

  public nonisolated static func isInteractiveEchoOutput(
    _ data: Data,
    secondsSinceLastInput: TimeInterval?
  ) -> Bool {
    guard let secondsSinceLastInput else { return false }
    return secondsSinceLastInput <= interactiveEchoWindowSeconds
      && !data.isEmpty
      && data.count <= interactiveEchoOutputByteLimit
  }

  private func finishResize(
    session id: TerminalSessionID,
    generation: UInt64,
    wasPinnedToBottom: Bool,
    bridge: GhosttyVTBridge,
    snapshot: ResizeRenderSnapshot,
    diagnostics: TerminalResizeDiagnostics
  ) {
    guard let state = sessions[id], state.resizeGeneration == generation else { return }
    surfaceRegistry.prepareForPinnedOutput(
      session: id,
      wasPinnedToBottom: wasPinnedToBottom
    )
    // Stage only — still pendingResize, so Metal does not present yet.
    surfaceRegistry.render(snapshot, bridge: bridge, session: id)
    scheduleResizePresentSettle(session: id, generation: generation, diagnostics: diagnostics)
  }

  private func cancelResizePresentSettle(session id: TerminalSessionID) {
    resizePresentSettleTasks[id]?.cancel()
    resizePresentSettleTasks[id] = nil
  }

  private func scheduleResizePresentSettle(
    session id: TerminalSessionID,
    generation: UInt64,
    diagnostics: TerminalResizeDiagnostics
  ) {
    cancelResizePresentSettle(session: id)
    resizePresentSettleTasks[id] = Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: Self.resizePresentSettleNanoseconds)
      guard !Task.isCancelled, let self else { return }
      self.resizePresentSettleTasks[id] = nil
      guard let state = self.sessions[id], state.resizeGeneration == generation else { return }
      // Present whichever frame is staged (VT snapshot and/or SIGWINCH redraw).
      self.surfaceRegistry.applyResizeDiagnostics(diagnostics, session: id)
    }
  }

  private func performScheduledResize(session id: TerminalSessionID, job: PendingResizeJob) {
    job.vtQueue.async { [weak self] in
      let totalStart = Date()
      let wasPinnedToBottom = GhosttyVTQueueWork.viewportIsPinnedToBottom(job.bridge)
      let vtStart = Date()
      job.bridge.resize(cols: job.cols, rows: job.rows)
      PTYLaunch.resize(fileDescriptor: job.fileDescriptor, rows: job.rows, cols: job.cols)
      _ = Darwin.kill(job.pid, SIGWINCH)
      let vtDuration = Date().timeIntervalSince(vtStart)

      let snapshotStart = Date()
      if wasPinnedToBottom {
        GhosttyVTQueueWork.scrollToBottom(job.bridge)
      }
      let snapshot = ResizeRenderSnapshot.capture(from: job.bridge)
      let snapshotDuration = Date().timeIntervalSince(snapshotStart)
      let diagnostics = TerminalResizeDiagnostics(
        totalDuration: Date().timeIntervalSince(totalStart),
        vtDuration: vtDuration,
        snapshotDuration: snapshotDuration
      )

      Task { @MainActor [weak self] in
        guard let self,
          let current = self.sessions[id],
          current.resizeGeneration == job.generation
        else {
          return
        }
        self.finishResize(
          session: id,
          generation: job.generation,
          wasPinnedToBottom: wasPinnedToBottom,
          bridge: job.bridge,
          snapshot: snapshot,
          diagnostics: diagnostics
        )
      }
    }
  }

  nonisolated static func processWorkingDirectory(pid: pid_t) -> String? {
    var info = proc_vnodepathinfo()
    let size = proc_pidinfo(
      pid,
      PROC_PIDVNODEPATHINFO,
      0,
      &info,
      Int32(MemoryLayout<proc_vnodepathinfo>.size)
    )
    guard size == MemoryLayout<proc_vnodepathinfo>.size else {
      return nil
    }
    return withUnsafeBytes(of: info.pvi_cdir.vip_path) { rawBuffer in
      guard let base = rawBuffer.bindMemory(to: CChar.self).baseAddress else { return nil }
      let path = String(cString: base)
      return path.isEmpty ? nil : path
    }
  }
}

@MainActor
public final class PTYTerminalSurfaceView: NSView {
  public let scrollView: NSScrollView
  public private(set) var liveGridView: PTYGridView
  var onWindowAvailable: (() -> Void)?

  public var isShowingLiveGrid: Bool {
    !liveGridView.isHidden
  }

  // MARK: App-facing surface operations
  // The App layer talks to the surface, not to the grid view inside it — cell
  // geometry and selection/interaction stay renderer-domain implementation
  // details (debt spec D3 smell fix).

  public var terminalCellSize: CGSize { liveGridView.terminalCellSize }
  public var terminalContentInset: CGSize { liveGridView.terminalContentInset }
  public var hasTextSelection: Bool { liveGridView.selectedText?.isEmpty == false }

  public func setInteractionEnabled(_ enabled: Bool) {
    liveGridView.setInteractionEnabled(enabled)
  }

  public func copySelection() {
    liveGridView.copy(nil)
  }

  public func pasteFromPasteboard() {
    liveGridView.paste(nil)
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

  public override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard window != nil else { return }
    onWindowAvailable?()
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

  func replaceLiveGridView(with newLiveGridView: PTYGridView) {
    let shouldShowLiveGrid = isShowingLiveGrid
    liveGridView.removeFromSuperview()
    liveGridView = newLiveGridView
    addFullSizeSubview(newLiveGridView)
    if shouldShowLiveGrid {
      showLiveGrid()
    } else {
      showScrollback()
    }
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

struct GridCoordinate: Comparable {
  var row: Int
  var col: Int

  static func < (lhs: GridCoordinate, rhs: GridCoordinate) -> Bool {
    if lhs.row == rhs.row {
      return lhs.col < rhs.col
    }
    return lhs.row < rhs.row
  }
}

public class PTYGridView: NSView {
  private static let selectionAutoScrollEdgeInset: CGFloat = 24
  private static let selectionAutoScrollInterval: TimeInterval = 1.0 / 15.0

  public var inputHandler: ((Data) -> Void)?
  public var pasteHandler: ((String) -> Void)?
  public var viewportDidChangeHandler: (() -> Void)?
  public var transientOverlayDidChangeHandler: (() -> Void)?
  /// Fired when smooth-scroll activity starts (true) / stops (false). The
  /// backend forwards this to the render engine's `prefersAsyncPresent` so the
  /// display-link tick never blocks the main thread on GPU completion while
  /// scrolling, and reverts to the low-latency synchronous present when idle.
  public var scrollActivityHandler: ((Bool) -> Void)?
  /// Pattern-2 browse metrics: total scrollback rows + the absolute row at the
  /// viewport top RIGHT NOW. Read from the VT scrollbar by the session (the view
  /// never owns VT state). Returns nil if unavailable.
  public var browseScrollMetricsHandler: (() -> (total: UInt64, topAbsoluteRow: UInt64)?)?
  /// Pattern-2 browse present: fetch `visibleRows (+1 above/below)` rows starting
  /// at `topAbsoluteRow` directly from scrollback and present them, shifted by
  /// the view's current `viewport.visualOffsetY`. The VT viewport does NOT move.
  public var browsePresentHandler: ((_ topAbsoluteRow: UInt64, _ visibleRows: Int) -> Void)?
  /// Pattern-2 resume-follow: the user scrolled back to the live tail, so stop
  /// presenting a history window and render the LIVE frame (with cursor, tracking
  /// new output). Fired instead of `browsePresentHandler` when the tick resolves
  /// to the bottom edge.
  public var browseFollowResumeHandler: (() -> Void)?
  /// Fetch arbitrary rows from the VT scrollback by absolute row number. Used
  /// by `selectedText` to copy selection rows that fall outside the visible
  /// frame. Wired to `bridge.rows(at:count:)` by the surface registry.
  public var rowFetchHandler: ((_ startRow: UInt64, _ count: Int) -> GhosttyTerminalRowWindow?)?
  public var activationHandler: (() -> Void)?
  public var openURLHandler: ((URL) -> Void)? = { url in
    _ = NSWorkspace.shared.open(url)
  }
  public var openLinkTargetHandler: ((TerminalLinkTarget) -> Void)?
  public var linkHoverHandler: ((Bool) -> Void)?
  /// Returns true if a bare token (no `/`) resolves to an existing file/dir under
  /// the session cwd, so `dist`, `src`, `README` become clickable. Provided by the
  /// registry (which knows the cwd). Nil disables bare-word path detection.
  public var pathExistenceValidator: ((String) -> Bool)?
  /// Resolves a clicked file target to its absolute path + quiet detail lines
  /// (path, modified/created times, size) for the popover. Provided by the
  /// registry (which knows the session cwd + filesystem). Nil → popover shows
  /// only actions and Copy Path falls back to the raw token.
  /// Resolves a clicked file target to its raw filesystem facts (absolute path,
  /// isDirectory, dates, size). Provided by the registry (which knows the session
  /// cwd + filesystem). Core's view layer formats + iconifies them for the
  /// popover. Nil → popover shows only actions and Copy Path falls back to the
  /// raw token.
  public var fileInfoProvider: ((TerminalFilePathTarget) -> TerminalFileFacts?)?
  /// Returns true when the running application has enabled mouse reporting
  /// (modes 1000/1002/1003). When active, clicks should be forwarded to the
  /// PTY as mouse reports rather than interpreted as click-to-position.
  public var mouseReportingActiveHandler: (() -> Bool)?
  public var terminalScrollOwnershipHandler: (() -> TerminalScrollOwnership)?
  public var terminalMouseEncodeHandler: ((TerminalMouseScrollEvent, TerminalMouseGeometry) -> Data?)?
  public var terminalAlternateScrollEncodeHandler: ((_ wheelUp: Bool, _ count: Int) -> Data?)?
  /// Localized popover labels, pushed from the App layer (which owns the language
  /// setting). Defaults to English so Core works standalone.
  public var semanticLinkText = SemanticLinkText()
  public var pasteboard = NSPasteboard.general

  private var frameSnapshot: GhosttyTerminalFrame?
  private var scrollFrameSnapshot: GhosttyTerminalScrollFrame?
  private var palette = TerminalSurfacePalette.dark
  private var fontFamily = FontCatalog.defaultMonospacedFontName()
  private var cjkFallbackFamily: String?
  private var fontSize: CGFloat = 14
  private var font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
  private var boldFont = NSFont.monospacedSystemFont(ofSize: 14, weight: .semibold)
  private var cjkFont: NSFont?
  private var cjkBoldFont: NSFont?
  private var cellSize = CGSize(width: 8, height: 16)
  private var isFocusedTerminalStorage = true
  private var rendererOptions = TerminalRendererOptions()
  private var suppressMomentumScroll = false
  private var tuiScrollQuantizer = TerminalTUIScrollQuantizer()
  private var tuiScrollOwnership: TerminalScrollOwnership?
  /// Pattern-2 smooth-scroll physics (display-link driven). Sole owner of how
  /// the browse position evolves over time; the display-link tick is the ONLY
  /// writer of `viewport.visualOffsetY` while browsing, so there is no async
  /// commit racing it (the R1.2 BUG-3 double-writer cannot occur here).
  private var smoothScrollEngine = SmoothScrollEngine()
  /// Absolute scrollback row that sat at the viewport top when the current
  /// gesture began. `engine.position == 0` maps here.
  private var browseAnchorRow: UInt64 = 0
  /// Persistent pattern-2 browse position: the absolute top row the user has
  /// settled on while viewing history. `nil` means "following the live bottom".
  /// This is pattern 2's source of truth for "am I viewing history" — the VT
  /// viewport never moves, so scrollbar.offset always reports the bottom and
  /// cannot be used for it. A new gesture continues from here; reaching the
  /// bottom edge clears it back to live-follow.
  private var browseTopRow: UInt64?
  /// Total scrollback rows captured at gesture start (refreshed each tick from
  /// the metrics handler so live output growth is tracked).
  private var browseTotalRows: UInt64 = 0
  private var scrollDisplayLink: CADisplayLink?
  /// True while pattern-2 display-link browsing is active.
  private var isSmoothScrollBrowsing = false
  /// While true, a viewport change updates state but does NOT trigger an
  /// immediate re-present. Used during a row commit so the offset can be set
  /// without flashing a frame that pairs the rebased (small) offset with the
  /// still-un-scrolled old content; the commit renders the correct atomic frame.
  private var suppressViewportChangePresent = false

  private(set) public var viewport = TerminalViewport() {
    didSet {
      guard oldValue != viewport else { return }
      currentInputPresentation = nil
      latestPromptInputCursorRect = nil
      if !suppressViewportChangePresent {
        viewportDidChangeHandler?()
        needsDisplay = true
        invalidateCursorAndIMEIfSettled()
      }
    }
  }
  private(set) public var lastDrawDuration: TimeInterval = 0
  private(set) public var lastScrollCommitDuration: TimeInterval = 0
  private(set) public var maxDrawDuration: TimeInterval = 0
  private var totalDrawDuration: TimeInterval = 0
  private var drawCount = 0
  private var selection = GridSelectionModel()
  private var isDraggingSelectionStorage = false
  private var selectionAutoScrollTimer: Timer?
  private var selectionAutoScrollDirection = 0
  private var selectionDragPoint: NSPoint?
  /// A plain (non-⌘) click landed on a link/file. We do NOT open the popover on
  /// mouseDown — a drag or macOS three-finger-drag also begins with mouseDown, and
  /// opening there would hijack selection and fire on every drag. Instead we hold
  /// the hit here, cancel it if the pointer actually drags, and open on mouseUp
  /// only if it survived as a genuine single click.
  private var pendingLinkClick: (hit: TerminalLinkHit, origin: NSPoint)?
  /// Tracks the press point for single-click detection (click-to-position).
  private var clickToPositionDownPoint: NSPoint?
  private var commandLinkMode = false
  private var isHoveringLink = false
  private var hoveredLinkHit: TerminalLinkHit?
  private var hoveredLinkObject: SemanticLinkObject?
  /// Dwell state for the object currently under the pointer (spec: dwell-gated,
  /// not proximity). Owns the 300ms Awake / 500ms ActionHint timing.
  private var dwell = SemanticDwell()
  /// One-shot timer that re-evaluates dwell for a stationary pointer so it still
  /// crosses the 300/500ms thresholds without a mouse event.
  private var dwellWakeupTimer: Timer?
  /// Last pointer location (view coords), so the display-link tick can recompute
  /// the puck as the dwell state advances without a fresh mouse event.
  private var lastPointer: NSPoint?
  /// 0…1 animated reveal intensity: drives the glyph weight boost (spec §4) and
  /// the ↗ opacity. Tweened by the display link toward `linkHoverIntensityTarget`,
  /// which the dwell phase (or ⌘ Explore Mode) sets to 0 or 1.
  private var linkHoverIntensity: CGFloat = 0
  private var linkHoverIntensityTarget: CGFloat = 0
  private var linkHoverDisplayLink: CADisplayLink?
  private var linkHoverLastTickTime: CFTimeInterval = 0
  private let linkPopover = SemanticLinkPopover()
  /// Ring cursor shown over an awoken semantic object. It is an independent
  /// `CALayer` composited by Core Animation ABOVE the Metal content — moving it is
  /// one `position` assignment, wrapped in a no-actions transaction, so it never
  /// enters the terminal's full-rebuild Metal present path (which drops/blocks
  /// frames and made the old GPU puck stutter). Same compositor path as the
  /// hardware cursor → smooth by construction. While it shows, the arrow is hidden.
  private lazy var ringCursorLayer: CALayer = makeRingCursorLayer()
  private var ringCursorVisible = false
  /// TEMP kill-switch for the GPU ring cursor. When false, interactive content
  /// keeps the plain arrow (the real cursor is never hidden/swapped).
  private let ringCursorEnabled = false
  private var isCursorHidden = false
  /// When false, the grid is inert to the mouse: no link hover ring, no dwell
  /// weight reveal, no ⌘ Explore, only the plain iBeam cursor. The ⌘P side-input
  /// box sets this off so typing isn't fought by terminal hover interaction. A
  /// single flag (vs. tracking a sibling overlay's geometry) keeps it stable.
  private var interactionEnabled = true
  private var mouseTrackingArea: NSTrackingArea?
  private var markedText = NSAttributedString(string: "")
  private var markedTextRange = NSRange(location: NSNotFound, length: 0)
  private var markedTextSelectionRange = NSRange(location: NSNotFound, length: 0)
  private var markedTextCompositionActive = false
  private var markedTextRevision = 0
  private var inputRenderGeneration = 0
  private var inputStateMachine = TerminalInputStateMachine()
  private var currentInputPresentation: TerminalInputPresentationSnapshot?
  private var latestPromptInputCursorRect: NSRect?

  public override var acceptsFirstResponder: Bool { true }
  public override var isFlipped: Bool { true }
  public var isFocusedTerminal: Bool { isFocusedTerminalStorage }

  public var isViewingHistory: Bool {
    viewport != TerminalViewport() || browseTopRow != nil
  }

  /// The absolute scrollback row the user has settled on while browsing history
  /// via pattern-2 smooth scroll, or nil when following the live bottom. The
  /// registry reads this to re-present the SAME browse window when new output
  /// arrives, instead of freezing the display (pattern-1 behavior) or snapping
  /// to the tail. See `.claude/UNFREEZE_HISTORY_PLAN.md`.
  public var browseTopAbsoluteRow: UInt64? { browseTopRow }

  /// True while a pattern-2 display-link browse gesture/inertia is in flight.
  /// During this window the display link re-presents every tick, so the output
  /// path must not present concurrently.
  public var isSmoothScrollBrowsingActive: Bool { isSmoothScrollBrowsing }

  public var isDraggingSelection: Bool { isDraggingSelectionStorage }

  public var renderedText: String {
    guard let frameSnapshot else { return "" }
    return Self.renderedText(from: frameSnapshot)
  }

  public var cursorCellRect: NSRect? {
    let presentation = resolvedInputPresentation()
    guard !presentation.cursorSuppressed else { return nil }
    return presentation.cursorRect
  }

  public var isIMECompositionCursorSuppressed: Bool {
    resolvedInputPresentation().cursorSuppressed
  }

  public var currentInputPresentationSnapshot: TerminalInputPresentationSnapshot {
    resolvedInputPresentation()
  }

  public var isComposingMarkedText: Bool {
    markedTextCompositionActive
  }

  public var markedTextStateRevision: Int {
    markedTextRevision
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
    guard let absoluteRange = selection.unclampedAbsoluteRange() else { return nil }
    guard let geometry = renderedGeometry() else { return nil }
    let frame = geometry.frame
    let firstAbsoluteRow = geometry.absoluteBaseRow
    let lastAbsoluteRow = firstAbsoluteRow + frame.rows - 1

    // Group absolute rows into visible (read from frame) and out-of-viewport
    // fetches (one bridge call per contiguous block).
    struct FetchBlock {
      let absoluteStart: Int
      let rows: Int
      let cells: [GhosttyTerminalFrame.Cell]  // row-major
      let cols: Int
    }

    var blocks: [FetchBlock] = []
    let lower = absoluteRange.lower.absoluteRow
    let upper = absoluteRange.upper.absoluteRow

    var cursor = lower
    while cursor <= upper {
      let inFrame = cursor >= firstAbsoluteRow && cursor <= lastAbsoluteRow
      // Find contiguous same-kind run.
      var runEnd = cursor
      while runEnd + 1 <= upper {
        let nextInFrame = (runEnd + 1) >= firstAbsoluteRow && (runEnd + 1) <= lastAbsoluteRow
        guard nextInFrame == inFrame else { break }
        runEnd += 1
      }

      if inFrame {
        // Visible rows — pull from the geometry frame cells.
        let viewportStart = cursor - firstAbsoluteRow
        let viewportEnd = runEnd - firstAbsoluteRow
        var blockCells: [GhosttyTerminalFrame.Cell] = []
        blockCells.reserveCapacity((viewportEnd - viewportStart + 1) * frame.cols)
        for vr in viewportStart...viewportEnd {
          let rowStart = vr * frame.cols
          let rowEnd = min(rowStart + frame.cols, frame.cells.count)
          if rowStart < frame.cells.count {
            blockCells.append(contentsOf: frame.cells[rowStart..<rowEnd])
          }
        }
        blocks.append(FetchBlock(absoluteStart: cursor,
                                  rows: runEnd - cursor + 1,
                                  cells: blockCells, cols: frame.cols))
        cursor = runEnd + 1
      } else if let rowFetchHandler,
                let window = rowFetchHandler(UInt64(max(0, cursor)),
                                              runEnd - cursor + 1),
                !window.rows.isEmpty
      {
        // Out-of-viewport — batch-fetch from the VT bridge.
        var blockCells: [GhosttyTerminalFrame.Cell] = []
        blockCells.reserveCapacity(window.rows.count * window.cols)
        for row in window.rows { blockCells.append(contentsOf: row.cells) }
        blocks.append(FetchBlock(absoluteStart: Int(window.startRow),
                                  rows: window.rows.count,
                                  cells: blockCells, cols: window.cols))
        cursor = Int(window.startRow) + window.rows.count
      } else {
        // Can't fetch this range — skip it.
        cursor = runEnd + 1
      }
    }

    // Walk the blocks in order to build lines.
    var lines: [String] = []
    for block in blocks {
      let blockLower = block.absoluteStart
      for offset in 0..<block.rows {
        let absoluteRow = blockLower + offset
        let startCol = absoluteRow == lower ? absoluteRange.lower.col : 0
        let endCol = absoluteRow == upper ? absoluteRange.upper.col : max(0, block.cols - 1)
        guard startCol <= endCol else { continue }
        let rowStart = offset * block.cols
        let line = (startCol...endCol).compactMap { col -> String? in
          let index = rowStart + col
          guard index < block.cells.count else { return nil }
          return String(block.cells[index].scalar)
        }.joined()
        lines.append(line.trimmingCharacters(in: .whitespaces))
      }
    }

    let value = lines.joined(separator: "\n")
    return value.isEmpty ? nil : value
  }

  public func applyPalette(_ palette: TerminalSurfacePalette) {
    self.palette = palette
    layer?.backgroundColor = palette.background.cgColor
    needsDisplay = true
  }

  public func applyFont(family: String, size: CGFloat, cjkFallbackFamily: String? = nil) {
    fontFamily = family
    self.cjkFallbackFamily = Self.normalizedFontFamily(cjkFallbackFamily)
    fontSize = size
    font = Self.font(family: family, size: size, weight: .regular)
    boldFont = Self.font(family: family, size: size, weight: .semibold)
    cjkFont = self.cjkFallbackFamily.flatMap { Self.installedFont(family: $0, size: size, weight: .regular) }
    cjkBoldFont = self.cjkFallbackFamily.flatMap { Self.installedFont(family: $0, size: size, weight: .semibold) }
    cellSize = Self.cellSize(for: font)
    currentInputPresentation = nil
    needsDisplay = true
    window?.invalidateCursorRects(for: self)
    invalidateIMECharacterCoordinates()
  }

  public func applyRendererOptions(_ options: TerminalRendererOptions) {
    rendererOptions = options
  }

  public func resetViewportStartRowKeepingVisualOffset() {
    // With pattern-1 removed, pattern-2 owns visualOffsetY exclusively via
    // display-link ticks. Nothing to reset here; callers are no-ops or will be
    // removed in subsequent phases.
  }

  public func resetPixelScroll(suppressMomentum: Bool = false) {
    viewport = TerminalViewport()
    resetTUIScrollInput()
    // Return to live-follow: drop the persisted pattern-2 browse anchor and stop
    // any in-flight display-link browsing.
    browseTopRow = nil
    if isSmoothScrollBrowsing {
      smoothScrollEngine.reset()
      stopSmoothScrollBrowsing()
    }
    suppressMomentumScroll = suppressMomentum
    needsDisplay = true
  }

  public func applyScrollDiagnostics(to diagnostics: inout TerminalRendererDiagnostics) {
    diagnostics.pixelRemainderY = 0
    diagnostics.committedRowDelta = 0
    diagnostics.coalescedWheelEvents = 0
    diagnostics.scrollCommitMode = .coalesced
    diagnostics.pendingScrollRowDelta = 0
    diagnostics.pendingScrollWheelEvents = 0
    diagnostics.lastScrollCommitDuration = lastScrollCommitDuration
    diagnostics.lastScrollRenderDuration = lastDrawDuration
    diagnostics.smoothScrollOffset = viewport.visualOffsetY
    if diagnostics.alternateScreenActive {
      diagnostics.pixelSmoothScroll = .unavailable
      diagnostics.pixelSmoothScrollReason = TerminalRendererDiagnostics.alternateScreenScrollReason
    } else if browseTopRow != nil || isSmoothScrollBrowsing {
      diagnostics.pixelSmoothScroll = .experimental
      diagnostics.pixelSmoothScrollReason = TerminalRendererDiagnostics.smoothScrollEnabledReason
    } else {
      diagnostics.pixelSmoothScroll = .experimental
      diagnostics.pixelSmoothScrollReason = TerminalRendererDiagnostics.smoothScrollEnabledReason
    }
  }

  public func setFocused(_ isFocused: Bool) {
    isFocusedTerminalStorage = isFocused
    needsDisplay = true
    applyInputPresentation(inputStateMachine.handle(.focusChanged(isFocused)))
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
    invalidateCursorAndIMEIfSettled()
    ingestInputRenderSnapshot()
  }

  public func render(_ frame: GhosttyTerminalFrame, isFocused: Bool, dirty: CellGridDirtyResult) {
    frameSnapshot = frame
    scrollFrameSnapshot = nil
    isFocusedTerminalStorage = isFocused
    if viewport.visualOffsetY != 0 {
      needsDisplay = true
      // Browse/pixel-scroll ticks update content every frame; skip O(rows×cols)
      // cursor-rect rebuild (see invalidateCursorAndIMEIfSettled).
      invalidateCursorAndIMEIfSettled()
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
    invalidateCursorAndIMEIfSettled()
    ingestInputRenderSnapshot()
  }

  public func render(_ scrollFrame: GhosttyTerminalScrollFrame, isFocused: Bool, dirty: CellGridDirtyResult) {
    let previous = frameSnapshot
    frameSnapshot = scrollFrame.viewport
    scrollFrameSnapshot = scrollFrame
    isFocusedTerminalStorage = isFocused
    if viewport.visualOffsetY != 0 {
      needsDisplay = true
      invalidateCursorAndIMEIfSettled()
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
    invalidateCursorAndIMEIfSettled()
    ingestInputRenderSnapshot()
  }

  /// Cursor rects are O(rows×cols). Pattern-2 browse presents ~120×/s; rebuilding
  /// them every tick freezes the main thread and thrash-flips arrow↔I-beam under
  /// the mouse. Defer until the gesture/inertia settles.
  private func invalidateCursorAndIMEIfSettled() {
    guard !isSmoothScrollBrowsing else { return }
    window?.invalidateCursorRects(for: self)
    invalidateIMECharacterCoordinates()
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
    renderedClipRect(for: viewportFrame, fallbackFrame: drawFrame).clip()
    let translationY = drawTranslationY(topOverscanRows: topOverscanRows)
    if translationY != 0 {
      let transform = NSAffineTransform()
      transform.translateX(by: 0, yBy: translationY)
      transform.concat()
    }
    let contentDirtyRect = contentDirtyRect(forDrawing: dirtyRect, translationY: translationY)
    let visibleRows = scrollFrameSnapshot == nil ? visibleRowRange(for: drawFrame) : 0..<drawFrame.rows
    let selectionRange = renderedGeometry().flatMap { normalizedSelectionRange(in: $0) }
    for row in visibleRows {
      drawRow(row, frame: drawFrame, dirtyRect: contentDirtyRect, selectionRange: selectionRange)
    }
    drawCursor(viewportFrame, rowOffset: topOverscanRows, dirtyRect: contentDirtyRect)
    drawMarkedText(viewportFrame, rowOffset: topOverscanRows, dirtyRect: contentDirtyRect)
    NSGraphicsContext.current?.restoreGraphicsState()
  }

  public static func visualScrollTranslationY(for viewport: TerminalViewport) -> CGFloat {
    RenderedGridGeometry.visualScrollTranslationY(for: viewport)
  }

  public static func visualScrollTranslationY(
    for viewport: TerminalViewport,
    hasOverscanRows: Bool,
    cellHeight: CGFloat
  ) -> CGFloat {
    RenderedGridGeometry.visualScrollTranslationY(
      for: viewport,
      hasOverscanRows: hasOverscanRows,
      cellHeight: cellHeight
    )
  }

  public static func contentDirtyRect(forDrawing dirtyRect: NSRect, viewport: TerminalViewport) -> NSRect {
    RenderedGridGeometry.contentDirtyRect(forDrawing: dirtyRect, viewport: viewport)
  }

  public static func contentDirtyRect(
    forDrawing dirtyRect: NSRect,
    viewport: TerminalViewport,
    hasOverscanRows: Bool,
    cellHeight: CGFloat
  ) -> NSRect {
    RenderedGridGeometry.contentDirtyRect(
      forDrawing: dirtyRect,
      viewport: viewport,
      hasOverscanRows: hasOverscanRows,
      cellHeight: cellHeight
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
    RenderedGridGeometry.terminalContentClipRect(cols: cols, rows: rows, cellSize: cellSize, inset: inset)
  }

  public static func textGlyphRects(
    for run: CellDrawRun,
    row: Int,
    cellSize: CGSize,
    inset: CGSize
  ) -> [NSRect] {
    RenderedGridGeometry.textGlyphRects(for: run, row: row, cellSize: cellSize, inset: inset)
  }

  public static func textGlyphRect(row: Int, col: Int, cellSize: CGSize, inset: CGSize) -> NSRect {
    RenderedGridGeometry.textGlyphRect(row: row, col: col, cellSize: cellSize, inset: inset)
  }

  public static func urlCursorRects(
    frame: GhosttyTerminalFrame,
    cellSize: CGSize,
    inset: CGSize,
    verticalOffsetY: CGFloat = 0,
    linkInteractionActive: Bool = true
  ) -> [NSRect] {
    RenderedGridGeometry.urlCursorRects(
      frame: frame,
      cellSize: cellSize,
      inset: inset,
      verticalOffsetY: verticalOffsetY,
      linkInteractionActive: linkInteractionActive
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
    let ownership = terminalScrollOwnershipHandler?() ?? fallbackScrollOwnership
    PTYRenderDebugLog.write("wheel-route ownership=\(String(describing: ownership))")
    guard ownership == .localScrollback else {
      handleTUIScroll(event, ownership: ownership)
      return
    }
    resetTUIScrollInput()
    // Normal screen: pattern-2 smooth scroll (display-link driven browse)
    guard browseScrollMetricsHandler != nil, browsePresentHandler != nil, cellSize.height > 0 else { return }
    feedSmoothScroll(event)
  }

  private var fallbackScrollOwnership: TerminalScrollOwnership {
    frameSnapshot?.isAlternateScreen == true ? .consumed : .localScrollback
  }

  private func handleTUIScroll(_ event: NSEvent, ownership: TerminalScrollOwnership) {
    guard ownership != .consumed else {
      resetTUIScrollInput()
      return
    }
    if tuiScrollOwnership != ownership {
      tuiScrollQuantizer.reset()
      tuiScrollOwnership = ownership
    }
    let units = tuiScrollQuantizer.consume(
      delta: Double(event.scrollingDeltaY),
      precise: event.hasPreciseScrollingDeltas,
      cellHeight: Double(cellSize.height)
    )
    guard units != 0 else {
      let pending = String(format: "%.3f", tuiScrollQuantizer.pendingDelta)
      PTYRenderDebugLog.write(
        "wheel-tui ownership=\(String(describing: ownership)) units=0 pending=\(pending)"
      )
      return
    }

    let wheelUp = units > 0
    let count = abs(units)
    let encoded: Data?
    switch ownership {
    case .mouseReporting:
      let point = convert(event.locationInWindow, from: nil)
      let scale = max(1, window?.backingScaleFactor ?? 1)
      let mouseEvent = TerminalMouseScrollEvent(
        wheelUp: wheelUp,
        shift: event.modifierFlags.contains(.shift),
        control: event.modifierFlags.contains(.control),
        alt: event.modifierFlags.contains(.option),
        x: Float(point.x * scale),
        y: Float(point.y * scale)
      )
      let geometry = TerminalMouseGeometry(
        screenWidth: Self.pixelDimension(bounds.width, scale: scale),
        screenHeight: Self.pixelDimension(bounds.height, scale: scale),
        cellWidth: Self.pixelDimension(cellSize.width, scale: scale),
        cellHeight: Self.pixelDimension(cellSize.height, scale: scale),
        paddingTop: Self.pixelDimension(contentInset.height, scale: scale),
        paddingBottom: Self.pixelDimension(contentInset.height, scale: scale),
        paddingRight: Self.pixelDimension(contentInset.width, scale: scale),
        paddingLeft: Self.pixelDimension(contentInset.width, scale: scale)
      )
      if let unit = terminalMouseEncodeHandler?(mouseEvent, geometry), !unit.isEmpty {
        var repeated = Data(capacity: unit.count * count)
        for _ in 0..<count { repeated.append(unit) }
        encoded = repeated
      } else {
        encoded = nil
      }
    case .alternateCursorKeys:
      encoded = terminalAlternateScrollEncodeHandler?(wheelUp, count)
    case .localScrollback, .consumed:
      encoded = nil
    }
    if let encoded, !encoded.isEmpty {
      PTYRenderDebugLog.write(
        "wheel-tui ownership=\(String(describing: ownership)) units=\(units) encodedBytes=\(encoded.count)"
      )
      inputHandler?(encoded)
    } else {
      PTYRenderDebugLog.write(
        "wheel-tui ownership=\(String(describing: ownership)) units=\(units) encodedBytes=0"
      )
    }
  }

  private func resetTUIScrollInput() {
    tuiScrollQuantizer.reset()
    tuiScrollOwnership = nil
  }

  private static func pixelDimension(_ value: CGFloat, scale: CGFloat) -> UInt32 {
    let pixels = max(1, (value * scale).rounded())
    return UInt32(min(pixels, CGFloat(UInt32.max)))
  }

  // MARK: Pattern-2 display-link smooth scroll

  private func feedSmoothScroll(_ event: NSEvent) {
    // We synthesize our own inertia, so drop OS momentum events (matches
    // Ghostty). A momentum-phase event is the tail of a fling we already seeded.
    if !event.momentumPhase.isEmpty { return }

    let now = event.timestamp
    let delta = event.scrollingDeltaY
    let phase: WheelPhase
    if event.phase.contains(.began) {
      phase = .began
    } else if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
      phase = .ended
    } else if event.phase.contains(.changed) {
      phase = .changed
    } else {
      // No gesture phase → discrete mouse wheel.
      phase = .discrete
    }

    if !isSmoothScrollBrowsing {
      startSmoothScrollBrowsing()
    }
    if phase == .discrete {
      smoothScrollEngine.addDiscreteScroll(delta: delta, time: now)
    } else {
      smoothScrollEngine.addWheelInput(delta: delta, phase: phase, time: now)
    }
  }

  private func startSmoothScrollBrowsing() {
    guard let metrics = browseScrollMetricsHandler?() else { return }
    isSmoothScrollBrowsing = true
    browseTotalRows = metrics.total
    // Distance-from-bottom model (see `.claude/BROWSE_ANCHOR_FIX_PLAN.md`):
    // `position == 0` is the live tail; positive = points up into history.
    // Anchor at the *current* live bottom page. Prefer the larger of
    // (total-visible) and VT scrollbar.offset so we never underestimate how
    // far down content goes (false bottom with rows still below).
    // When already parked, seed position from that distance so a small
    // downward flick continues through the remaining history instead of
    // snapping to follow.
    let visible = max(1, frameSnapshot?.rows ?? visibleRowCount())
    let liveBottom = Self.liveBottomTopRow(
      total: metrics.total,
      visibleRows: visible,
      vtOffset: metrics.topAbsoluteRow
    )
    browseAnchorRow = liveBottom

    let seedPosition: CGFloat
    if let parked = browseTopRow, cellSize.height > 0 {
      let clampedParked = min(parked, liveBottom)
      let rowsFromBottom = liveBottom &- clampedParked
      // Preserve sub-row offset so re-seeding doesn't jump by a fraction of a row.
      let fractional = max(0, min(viewport.visualOffsetY, cellSize.height - 0.001))
      seedPosition = CGFloat(rowsFromBottom) * cellSize.height + fractional
    } else {
      seedPosition = 0
    }
    smoothScrollEngine.reset(to: seedPosition)
    // Flip the engine to async present BEFORE the first tick so the very first
    // scroll frame already avoids blocking the main thread on GPU completion.
    scrollActivityHandler?(true)
    startScrollDisplayLink()
  }

  /// Live page-top row for distance-from-bottom math. VT stays pinned at the
  /// bottom during pattern-2 browse, so `vtOffset` is normally the live page.
  /// Prefer the larger of `total - visible` and VT offset so a short/stale
  /// length cannot invent a false bottom with rows still below.
  private static func liveBottomTopRow(total: UInt64, visibleRows: Int, vtOffset: UInt64) -> UInt64 {
    guard total > 0 else { return 0 }
    let visible = UInt64(max(1, visibleRows))
    let byTotal = total > visible ? total - visible : 0
    let cappedVT = min(vtOffset, total - 1)
    return max(byTotal, cappedVT)
  }

  private func startScrollDisplayLink() {
    guard scrollDisplayLink == nil else { return }
    // A display link requires a hosting window; without one (e.g. unit tests)
    // NSView.displayLink is invalid. Callers drive ticks manually in that case.
    guard window != nil else { return }
    let link = displayLink(target: self, selector: #selector(handleScrollDisplayLink(_:)))
    // Allow the full ProMotion range; without this the link is capped at 60Hz.
    link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
    link.add(to: .main, forMode: .common)
    scrollDisplayLink = link
  }

  @objc private func handleScrollDisplayLink(_ link: CADisplayLink) {
    // Physics steps to the frame we are PRESENTING (targetTimestamp), not the
    // last vsync — smoother on variable-refresh displays (WWDC21).
    smoothScrollEngine.tick(now: link.targetTimestamp)
    let resolved = applyBrowseTick()

    // Soft-stop only when the physics is actually at/over the edge AND not
    // actively tracking the other way (e.g. first upward ticks still near 0
    // must not kill the gesture as "bottom").
    let trackingUp = smoothScrollEngine.target > smoothScrollEngine.position + 0.5
    let trackingDown = smoothScrollEngine.target < smoothScrollEngine.position - 0.5
    if resolved.atBottomEdge, !trackingUp {
      smoothScrollEngine.reset(to: 0)
      applyBrowsePosition(resolved)
      stopSmoothScrollBrowsing()
      return
    }
    if resolved.atTopEdge, !trackingDown {
      let topDistance = cellSize.height > 0
        ? CGFloat(browseAnchorRow) * cellSize.height
        : 0
      smoothScrollEngine.reset(to: topDistance)
      applyBrowsePosition(resolved)
      stopSmoothScrollBrowsing()
      return
    }

    if !smoothScrollEngine.isActive {
      stopSmoothScrollBrowsing()
    }
  }


  /// Resolve the current physics position to a browse window, apply it (viewport
  /// offset + persisted browse row), and present. Shared by the display-link
  /// callback and test hooks. Returns the resolved window.
  @discardableResult
  private func applyBrowseTick() -> SmoothScrollBrowseResolver.Resolved {
    // Keep distance-from-bottom aligned with the *current* live bottom. If
    // scrollback grew/pruned mid-gesture, shift position by the same delta so
    // the absolute row under the viewport does not jump — and so scrolling to
    // position 0 always reaches the real latest page (not a stale frozen maxTop).
    let visible = max(1, frameSnapshot?.rows ?? visibleRowCount())
    if let metrics = browseScrollMetricsHandler?() {
      browseTotalRows = metrics.total
      let liveBottom = Self.liveBottomTopRow(
        total: metrics.total,
        visibleRows: visible,
        vtOffset: metrics.topAbsoluteRow
      )
      if liveBottom != browseAnchorRow, cellSize.height > 0 {
        let deltaRows = Int64(liveBottom) - Int64(browseAnchorRow)
        smoothScrollEngine.offsetPosition(by: CGFloat(deltaRows) * cellSize.height)
        browseAnchorRow = liveBottom
      } else {
        browseAnchorRow = liveBottom
      }
    }
    let resolved = SmoothScrollBrowseResolver.resolve(
      position: smoothScrollEngine.position,
      cellHeight: cellSize.height,
      anchorRow: browseAnchorRow,
      total: browseTotalRows,
      visibleRows: visible
    )
    applyBrowsePosition(resolved)
    if resolved.atBottomEdge {
      // Back at the live tail: render the live frame (cursor + new output),
      // not a history window. viewport offset was cleared in applyBrowsePosition.
      browseFollowResumeHandler?()
    } else {
      browsePresentHandler?(resolved.topAbsoluteRow, visible)
    }
    return resolved
  }

  private func applyBrowsePosition(_ resolved: SmoothScrollBrowseResolver.Resolved) {
    // The display-link tick is the SOLE writer of visualOffsetY while browsing.
    // At the bottom edge we resume follow, so the offset must return to 0 (the
    // live frame is drawn un-shifted).
    suppressViewportChangePresent = true
    viewport = TerminalViewport(visualOffsetY: resolved.atBottomEdge ? 0 : resolved.pixelOffset)
    suppressViewportChangePresent = false

    // Persist the browse position so a settled history view survives new output
    // and the next gesture continues from here. atBottomEdge means the user
    // scrolled back to the live tail (position ≤ 0) → resume follow (nil). This
    // is decoupled from `total`, so a growing tail can't strand us in history.
    browseTopRow = resolved.atBottomEdge ? nil : resolved.topAbsoluteRow
  }

  private func stopSmoothScrollBrowsing() {
    isSmoothScrollBrowsing = false
    scrollDisplayLink?.invalidate()
    scrollDisplayLink = nil
    scrollActivityHandler?(false)
    // Per-frame cursor-rect / IME invalidation is skipped during browsing (it is
    // O(rows×cols) and would run every tick). Refresh once now that we've
    // settled so hit regions match the final scroll position.
    window?.invalidateCursorRects(for: self)
    invalidateIMECharacterCoordinates()
  }

  private func hasOverscanRows(forVisualOffsetY visualOffsetY: CGFloat) -> Bool {
    guard visualOffsetY != 0, let scrollFrameSnapshot else { return false }
    return visualOffsetY > 0 ? !scrollFrameSnapshot.overscanTop.isEmpty : !scrollFrameSnapshot.overscanBottom.isEmpty
  }

  public override func keyDown(with event: NSEvent) {
    activationHandler?()
    if isComposingMarkedText, !event.modifierFlags.contains(.command) {
      interpretKeyEvents([event])
      return
    }
    if let data = terminalControlInputData(for: event) {
      applyInputPresentation(inputStateMachine.handle(.unmarkText))
      inputHandler?(data)
      return
    }
    applyInputPresentation(inputStateMachine.handle(.keyDown(isCompositionMethod: false)))
    interpretKeyEvents([event])
  }

  public override func doCommand(by selector: Selector) {
    if isComposingMarkedText {
      return
    }
    switch selector {
    case #selector(insertNewline(_:)):
      if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
        inputHandler?(Data([0x0A]))
      } else {
        inputHandler?(Data([0x0D]))
      }
    case #selector(deleteBackward(_:)):
      inputHandler?(Data([0x7F]))
    case #selector(insertTab(_:)):
      if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
        inputHandler?(Data("\u{1B}[Z".utf8))
      } else {
        inputHandler?(Data([0x09]))
      }
    default:
      super.doCommand(by: selector)
    }
  }

  public override func performKeyEquivalent(with event: NSEvent) -> Bool {
    guard canHandleCommandKeyEquivalent else {
      return super.performKeyEquivalent(with: event)
    }
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

  private var canHandleCommandKeyEquivalent: Bool {
    guard let window else { return true }
    return window.firstResponder === self
  }

  public func copy(_ sender: Any?) {
    guard let selectedText else { return }
    pasteboard.clearContents()
    pasteboard.setString(selectedText, forType: .string)
  }

  public func paste(_ sender: Any?) {
    activationHandler?()
    guard let text = pasteboard.string(forType: .string), !text.isEmpty else { return }
    if let pasteHandler {
      pasteHandler(text)
    } else {
      inputHandler?(Data(text.utf8))
    }
  }

  /// Test hook: begin a pattern-2 browse gesture (captures anchor/total from the
  /// metrics handler) and seed the engine with `delta` points, without a real
  /// display link. Pair with `testTickSmoothScroll(now:)`.
  func testBeginSmoothScroll(delta: CGFloat, time: TimeInterval) {
    guard browseScrollMetricsHandler != nil, browsePresentHandler != nil else { return }
    if !isSmoothScrollBrowsing {
      startSmoothScrollBrowsing()
      // Tests drive ticks manually; drop the real display link the start created.
      scrollDisplayLink?.invalidate()
      scrollDisplayLink = nil
    }
    smoothScrollEngine.addWheelInput(delta: delta, phase: .began, time: time)
  }

  /// Test hook: run one physics tick + browse present at `now`, standing in for
  /// the display-link callback. Returns the resolved top absolute row.
  @discardableResult
  func testTickSmoothScroll(now: TimeInterval) -> UInt64 {
    smoothScrollEngine.tick(now: now)
    return applyBrowseTick().topAbsoluteRow
  }

  var testIsSmoothScrollBrowsing: Bool { isSmoothScrollBrowsing }
  var testEngineActiveForTests: Bool { smoothScrollEngine.isActive }
  var testBrowseTopRow: UInt64? { browseTopRow }

  /// Test hook: the hit-testing geometry the view currently reports. The
  /// pattern-2 red line is that this must describe the SAME `(topAbsoluteRow, P)`
  /// the renderer draws — i.e. the absolute row at viewport row 0 equals
  /// `absoluteBaseRow + overscanTop.count`, and translation matches the engine's.
  func testRenderedGeometry() -> (absoluteBaseRow: Int, translationY: CGFloat, rows: Int)? {
    guard let g = renderedGeometry() else { return nil }
    return (g.absoluteBaseRow, g.translationY, g.frame.rows)
  }

  /// Test hook: the absolute row a click at viewport-local `(row, col)` maps to.
  func testAbsoluteRow(forViewportRow row: Int) -> Int? {
    guard let g = renderedGeometry() else { return nil }
    let overscanTop = scrollFrameSnapshot?.overscanTop.count ?? 0
    return g.absoluteBaseRow + overscanTop + row
  }

  /// Test hook: set the sub-row viewport offset (as the display-link tick would)
  /// without a real gesture, so geometry/present can be exercised together.
  func testSetViewportOffsetForTests(_ offset: CGFloat) {
    suppressViewportChangePresent = true
    viewport = TerminalViewport(visualOffsetY: offset)
    suppressViewportChangePresent = false
  }

  /// Test hook: end the current browse gesture (feeds `.ended`, entering inertia
  /// or settling). Mirror the display link with `testTickSmoothScroll` after.
  func testEndSmoothScroll(time: TimeInterval) {
    smoothScrollEngine.addWheelInput(delta: 0, phase: .ended, time: time)
  }

  /// Test hook: run one tick and, if the engine has come to rest, perform the
  /// same teardown the real display-link callback would (stop browsing + flip
  /// scroll activity off).
  func testTickSmoothScrollWithStop(now: TimeInterval) {
    testTickSmoothScroll(now: now)
    if !smoothScrollEngine.isActive {
      stopSmoothScrollBrowsing()
    }
  }

  public override func mouseDown(with event: NSEvent) {
    activationHandler?()
    window?.makeFirstResponder(self)
    stopSelectionAutoScroll()
    pendingLinkClick = nil
    clickToPositionDownPoint = nil
    let eventPoint = convert(event.locationInWindow, from: nil)
    if event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command) {
      // ⌘-click opens immediately — the power-user path (spec §6, decided).
      logCommandLinkHit(at: eventPoint)
      if let hit = linkHit(at: eventPoint) {
        if let openLinkTargetHandler {
          openLinkTargetHandler(hit.target)
        } else if case .url(let url) = hit.target {
          openURLHandler?(url)
        }
        return
      }
    } else if event.clickCount == 1, let hit = linkHit(at: eventPoint) {
      // Plain single click on a link: defer to mouseUp. A drag (incl. macOS
      // three-finger-drag) also starts here — opening now would hijack selection
      // and fire mid-drag. Hold the hit; mouseDragged cancels it, mouseUp opens it.
      pendingLinkClick = (hit, eventPoint)
    }
    // Record press point for click-to-position (consumed in mouseUp).
    if event.clickCount == 1 {
      clickToPositionDownPoint = eventPoint
    }
    // Always establish the selection anchor at the press point — even on a link.
    // Otherwise a drag beginning on a link keeps a stale anchor from a prior
    // interaction and selects a huge unintended span.
    let oldDirtyRects = selectionDirtyRects()
    let geometry = renderedGeometry()
    let point = geometry?.selectionPoint(at: eventPoint)
    selection.begin(at: point)
    isDraggingSelectionStorage = point != nil
    invalidateSelectionRects(oldDirtyRects)
  }

  private func presentLinkPopover(for target: TerminalLinkTarget, at point: NSPoint) {
    let items: [SemanticLinkPopover.Item]
    let title: String
    var detailRows: [FileDetailFormatter.Row] = []
    var headerIcon: NSImage?
    switch target {
    case .url(let url):
      title = url.absoluteString
      headerIcon = NSImage(systemSymbolName: "safari", accessibilityDescription: nil)
      items = [
        SemanticLinkPopover.Item(title: semanticLinkText.openInBrowser, symbol: "safari") { [weak self] in
          self?.activateLink(target)
        },
        SemanticLinkPopover.Item(title: semanticLinkText.copyLink, symbol: "link") { [weak self] in
          self?.copyToPasteboard(url.absoluteString)
        },
      ]
    case .filePath(let filePath):
      let facts = fileInfoProvider?(filePath)
      let absolute = facts?.absolutePath ?? filePath.rawPath
      title = facts.map { URL(fileURLWithPath: $0.absolutePath).lastPathComponent } ?? filePath.rawPath
      if let facts {
        detailRows = FileDetailFormatter.rows(for: facts, text: semanticLinkText)
        // System file icon (Finder-accurate) for existing paths; symbol fallback.
        headerIcon = NSWorkspace.shared.icon(forFile: facts.absolutePath)
      } else {
        headerIcon = NSImage(systemSymbolName: "doc", accessibilityDescription: nil)
      }
      let revealTitle = facts?.isDirectory == true ? semanticLinkText.openFolder : semanticLinkText.revealInFinder
      items = [
        SemanticLinkPopover.Item(title: revealTitle, symbol: "folder") { [weak self] in
          self?.activateLink(target)
        },
        SemanticLinkPopover.Item(title: semanticLinkText.copyPath, symbol: "doc.on.clipboard") { [weak self] in
          self?.copyToPasteboard(absolute)
        },
      ]
    }
    linkPopover.present(title: title, headerIcon: headerIcon, detailRows: detailRows, items: items, at: point, in: self, palette: palette)
  }

  private func activateLink(_ target: TerminalLinkTarget) {
    if let openLinkTargetHandler {
      openLinkTargetHandler(target)
    } else if case .url(let url) = target {
      openURLHandler?(url)
    }
  }

  private func copyToPasteboard(_ string: String) {
    pasteboard.clearContents()
    pasteboard.setString(string, forType: .string)
  }

  public override func mouseDragged(with event: NSEvent) {
    let oldDirtyRects = selectionDirtyRects()
    let point = convert(event.locationInWindow, from: nil)
    // A real drag means this gesture is a selection / three-finger-drag, not a
    // click: cancel the pending link open so mouseUp won't fire the popover.
    if let pending = pendingLinkClick, point.distance(to: pending.origin) > 3 {
      pendingLinkClick = nil
    }
    // Cancel click-to-position on drag.
    if let downPoint = clickToPositionDownPoint, point.distance(to: downPoint) > 3 {
      clickToPositionDownPoint = nil
    }
    selectionDragPoint = point
    updateSelectionHead(at: point)
    updateSelectionAutoScroll(at: point)
    invalidateSelectionRects(oldDirtyRects)
  }

  public override func mouseUp(with event: NSEvent) {
    isDraggingSelectionStorage = false
    selectionDragPoint = nil
    stopSelectionAutoScroll()
    // A plain single click that stayed on the link (never dragged) → open now.
    if let pending = pendingLinkClick {
      pendingLinkClick = nil
      clickToPositionDownPoint = nil
      // Clear the empty anchor-only selection created in mouseDown so it doesn't
      // linger as a zero-width selection under the popover.
      selection.clear()
      presentLinkPopover(for: pending.hit.target, at: pending.origin)
      return
    }
    // Click-to-position: if this was a genuine single click (not a drag, not a
    // double/triple click), attempt to move the shell cursor to the clicked column.
    if let downPoint = clickToPositionDownPoint, event.clickCount == 1 {
      clickToPositionDownPoint = nil
      let upPoint = convert(event.locationInWindow, from: nil)
      if upPoint.distance(to: downPoint) < 3 {
        if handleClickToPosition(at: upPoint) {
          selection.clear()
          super.mouseUp(with: event)
          return
        }
      }
    } else {
      clickToPositionDownPoint = nil
    }
    super.mouseUp(with: event)
  }

  /// Attempts click-to-position cursor movement. Returns true if the click was
  /// consumed (arrow sequences sent to PTY), false if it should fall through.
  private func handleClickToPosition(at point: NSPoint) -> Bool {
    // Guard: mouse reporting active (vim/tmux owns the mouse).
    if mouseReportingActiveHandler?() == true { return false }
    // Guard: alternate screen (full-screen apps).
    guard let frame = frameSnapshot, !frame.isAlternateScreen else { return false }
    // Guard: cursor must be visible (indicates an active input line).
    guard frame.cursorVisible else { return false }
    // Guard: viewport must be at rest on the live bottom. While browsing history
    // or mid pixel-scroll-fling, clicks land on drawn (browsed/overscan) content
    // but frameSnapshot holds live-viewport cells — a coordinate-space mismatch
    // that would move the cursor by a wrong amount.
    guard browseTopRow == nil, !isSmoothScrollBrowsing, viewport.visualOffsetY == 0 else {
      return false
    }
    // Guard: must be able to resolve click to a grid coordinate.
    guard let geometry = renderedGeometry(),
          let clickCoord = geometry.coordinate(at: point) else { return false }

    // Ghostty's promptClickMove gate: only move while the cursor is on a live
    // input prompt — either the cursor's own semantic state is .input, or the
    // cell under it is .input. After OSC 133;C the cursor semantic flips to
    // .output even though written input cells stay .input, so a click while a
    // command is running (cursor parked on its stale line) is rejected instead
    // of emitting arrows the running program doesn't read.
    let cursorIdx = frame.cursorY * frame.cols + frame.cursorX
    let cursorCellIsInput = cursorIdx < frame.cells.count
      && frame.cells[cursorIdx].semanticContent == .input
    guard frame.cursorSemanticContent == .input || cursorCellIsInput else {
      return false
    }

    return handleSemanticClickToPosition(clickCoord: clickCoord, frame: frame)
  }

  // MARK: - Semantic path (OSC 133 shell integration)

  /// Click-to-position using per-cell semantic_content markers from libghostty-vt.
  /// Only counts .input cells (skips .prompt and .output cells, and spacerTails).
  private func handleSemanticClickToPosition(
    clickCoord: GridCoordinate,
    frame: GhosttyTerminalFrame
  ) -> Bool {
    let cursorRow = frame.cursorY
    let cursorCol = frame.cursorX
    let cols = frame.cols

    // Snap click to character head if on a spacerTail.
    var targetRow = clickCoord.row
    var targetCol = clickCoord.col
    let targetIdx = targetRow * cols + targetCol
    if targetIdx < frame.cells.count, frame.cells[targetIdx].width == .spacerTail, targetCol > 0 {
      targetCol -= 1
    }

    // The click must land on an .input cell, OR anywhere after the input region
    // (in which case we snap to end-of-input).
    let clickIdx = targetRow * cols + targetCol
    guard clickIdx < frame.cells.count else { return false }
    if frame.cells[clickIdx].semanticContent != .input {
      // Snap to end-of-input: find the last .input cell in the entire frame
      // before the click, then set target to one past it.
      let searchEnd = min(clickIdx, frame.cells.count - 1)
      var lastInputPos = -1
      for i in stride(from: searchEnd, through: 0, by: -1) {
        if frame.cells[i].semanticContent == .input {
          lastInputPos = i
          break
        }
      }
      // If no .input found before click, or the last .input is before the cursor
      // (click is in a region we can't reach by going right), reject.
      guard lastInputPos >= 0 else { return false }
      // Snap target to one past the last input cell (the end-of-input position).
      let snappedPos = lastInputPos + (frame.cells[lastInputPos].width == .wide ? 2 : 1)
      targetRow = snappedPos / cols
      targetCol = snappedPos % cols
    }

    // Count .input characters between cursor and click target.
    let charMoves = countSemanticMoves(
      fromRow: cursorRow, fromCol: cursorCol,
      toRow: targetRow, toCol: targetCol,
      cols: cols, cells: frame.cells
    )

    guard charMoves != 0 else { return false }
    emitArrowSequences(count: charMoves)
    return true
  }

  /// Count character moves between two positions, only counting .input cells.
  /// Skips .spacerTail and non-.input cells. Returns positive for right, negative for left.
  private func countSemanticMoves(
    fromRow: Int, fromCol: Int,
    toRow: Int, toCol: Int,
    cols: Int, cells: [GhosttyTerminalFrame.Cell]
  ) -> Int {
    let fromLinear = fromRow * cols + fromCol
    let toLinear = toRow * cols + toCol
    guard fromLinear != toLinear else { return 0 }

    let movingRight = toLinear > fromLinear
    var charCount = 0

    if movingRight {
      // Walk forward from cursor to target.
      var pos = fromLinear
      while pos < toLinear {
        guard pos < cells.count else { break }
        let cell = cells[pos]
        // Skip non-input cells and spacerTails.
        if cell.semanticContent != .input || cell.width == .spacerTail {
          pos += 1
          continue
        }
        charCount += 1
        pos += (cell.width == .wide) ? 2 : 1
      }
      return charCount
    } else {
      // Walk backward from cursor to target.
      var pos = fromLinear - 1
      while pos >= toLinear {
        guard pos >= 0, pos < cells.count else { break }
        let cell = cells[pos]
        // Skip non-input cells.
        if cell.semanticContent != .input {
          pos -= 1
          continue
        }
        // If on spacerTail, step to head (still one char move).
        if cell.width == .spacerTail {
          pos -= 1
        }
        charCount += 1
        pos -= 1
      }
      return -charCount
    }
  }


  // MARK: - Shared helpers

  private func emitArrowSequences(count: Int) {
    let arrow: Data
    let n: Int
    if count > 0 {
      arrow = Data("\u{1B}[C".utf8)
      n = count
    } else {
      arrow = Data("\u{1B}[D".utf8)
      n = -count
    }
    var sequences = Data(capacity: arrow.count * n)
    for _ in 0..<n {
      sequences.append(arrow)
    }
    inputHandler?(sequences)
  }

  public override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window == nil {
      isDraggingSelectionStorage = false
      selectionDragPoint = nil
      pendingLinkClick = nil
      clickToPositionDownPoint = nil
      stopSelectionAutoScroll()
      // Tear down the display link when detached; a live link retaining the view
      // off-window leaks and fires against a dead render path.
      stopSmoothScrollBrowsing()
      resetTUIScrollInput()
      stopLinkHoverDisplayLink()
      hoveredLinkObject = nil
      hoveredLinkHit = nil
      dwell.setObject(nil, at: CACurrentMediaTime())
      lastPointer = nil
      linkHoverIntensity = 0
      linkHoverIntensityTarget = 0
      updateRingCursor(pointer: .zero, show: false)
      setCursorHidden(false)
    }
  }

  public override func mouseMoved(with event: NSEvent) {
    // Input mode (the ⌘P side-input box is open): the grid is inert to the mouse —
    // no link ring, no dwell, no Explore. One flag, checked here, so we never have
    // to keep the grid's hover state in sync with a sibling overlay's geometry.
    guard interactionEnabled else { return }
    // Self-heal a stale Explore Mode: if ⌘ was released while we were defocused
    // (e.g. ⌘-click opened an external app), the key-up flagsChanged never reached
    // us. Reconcile from live modifier state so the first move after returning
    // behaves correctly instead of staying stuck "⌘ held".
    reconcileCommandLinkMode()
    updateLinkHover(at: convert(event.locationInWindow, from: nil))
  }

  public override func mouseExited(with event: NSEvent) {
    updateLinkHover(isHovering: false)
  }

  public override func flagsChanged(with event: NSEvent) {
    guard interactionEnabled else {
      super.flagsChanged(with: event)
      return
    }
    // Bare ⌘ only is an Explore gesture. Any other modifier present means this is
    // (part of) a keyboard shortcut, not "I want to explore" — don't wake objects.
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    let isBareCommand = flags == .command
    setCommandLinkMode(isBareCommand)
    updateLinkHover(at: convert(event.locationInWindow, from: nil))
    super.flagsChanged(with: event)
  }

  /// Focus left us (e.g. ⌘P moved focus into the side-input box, or a ⌘-shortcut
  /// opened/closed something). That means a held ⌘'s key-up will never reach us,
  /// which would otherwise strand Explore Mode "on". Exit it now. This is the
  /// general cure for "⌘ + another key leaves everything expanded".
  public override func resignFirstResponder() -> Bool {
    setCommandLinkMode(false)
    clearHover()
    return super.resignFirstResponder()
  }

  /// Enable/disable all mouse-driven link interaction (hover ring, dwell weight,
  /// ⌘ Explore, pointing-hand cursor rects). The side-input box turns this off so
  /// the terminal becomes inert "plain text" while typing — see the class-level
  /// `interactionEnabled` note. Disabling immediately clears any live hover and
  /// rebuilds cursor rects (so the ring/hidden-cursor state can't strand).
  public func setInteractionEnabled(_ enabled: Bool) {
    guard interactionEnabled != enabled else { return }
    interactionEnabled = enabled
    if !enabled {
      setCommandLinkMode(false)
      clearHover()
    }
    window?.invalidateCursorRects(for: self)
  }

  /// Enter/leave Explore Mode (⌘ held). Idempotent, so it can also be called to
  /// *correct* a stale mode — e.g. after a ⌘-click opened an external app and the
  /// window lost focus before the ⌘ key-up `flagsChanged` arrived.
  private func setCommandLinkMode(_ isActive: Bool) {
    guard commandLinkMode != isActive else { return }
    commandLinkMode = isActive
    window?.invalidateCursorRects(for: self)
    // Explore Mode (spec §13): holding ⌘ wakes every semantic object on screen at
    // once, releasing returns them to silence. Animate the reveal intensity so the
    // weight fades in/out rather than popping.
    linkHoverIntensityTarget = isActive ? 1 : (isHoveringLink ? 1 : 0)
    if reduceMotionEnabled {
      linkHoverIntensity = linkHoverIntensityTarget
    }
    startLinkHoverDisplayLinkIfNeeded()
    needsDisplay = true
    transientOverlayDidChangeHandler?()
  }

  /// Reconcile Explore Mode with the *live* keyboard state. Called on mouse moves
  /// so a lost ⌘ key-up (window defocused by opening a link) self-corrects on the
  /// next pointer motion instead of staying stuck "up".
  private func reconcileCommandLinkMode() {
    // Bare ⌘ only — a ⌘+X combo is a shortcut, not an Explore gesture.
    let isBareCommand = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
    setCommandLinkMode(isBareCommand)
  }

  /// All semantic-object segments to reveal (weight gain). In Explore Mode (⌘ held)
  /// this is every detected link on screen; otherwise just the dwelled object.
  public var currentExploreModeCellRanges: [GridSelectionCellRange] {
    // Use the SAME geometry as hover (renderedGeometry → expanded frame, in
    // expanded-frame row space). frameSnapshot is the viewport-only frame (0-based
    // rows); mixing it with the renderer's expanded-frame row space shifted every
    // link by overscanTopRows once scrolled off the top.
    guard commandLinkMode, let geometry = renderedGeometry() else { return [] }
    let hitsByRow = RenderedGridGeometry.urlHitsByRow(in: geometry.frame, pathValidator: pathExistenceValidator)
    return hitsByRow.keys.sorted().flatMap { row in
      (hitsByRow[row] ?? []).map { GridSelectionCellRange(row: $0.row, cols: $0.range) }
    }
  }

  public override func rightMouseDown(with event: NSEvent) {
    activationHandler?()
    guard let menu else {
      super.rightMouseDown(with: event)
      return
    }
    menu.removeTerminalIncompatibleSystemItems()
    NSMenu.popUpContextMenu(menu, with: event, for: self)
  }

  public override func resetCursorRects() {
    // While browsing, never rebuild per-cell cursor regions. AppKit may still
    // call us if something else invalidates; keep it O(1) so scroll stays live.
    if isSmoothScrollBrowsing {
      addCursorRect(bounds, cursor: .arrow)
      return
    }
    guard let geometry = renderedGeometry() else { return }
    let frame = geometry.frame
    let clipRect = geometry.clipRect
    // Full-screen link detection (urlHitsByRow) is only needed to carve out
    // pointing-hand regions when ⌘ is held. Running it every time cursor rects
    // are invalidated — which happens on every scroll tick — is pure waste and,
    // on a full screen of path-like text, heavy enough to stall the main thread.
    let urlHitsByRow = commandLinkMode ? RenderedGridGeometry.urlHitsByRow(in: frame, pathValidator: pathExistenceValidator) : [:]
    if commandLinkMode {
      for rect in RenderedGridGeometry.urlCursorRects(
        urlHitsByRow: urlHitsByRow,
        cellSize: cellSize,
        inset: contentInset,
        verticalOffsetY: geometry.translationY
      ) {
        guard let clipped = clippedCursorRect(rect, to: clipRect) else { continue }
        addCursorRect(clipped, cursor: .pointingHand)
      }
    }
    // Cells covered by the dwelled object get pointing-hand (added above); skip
    // them here so the iBeam doesn't fight the hand on the same cell.
    let hoveredCols: [Int: Range<Int>] = hoveredLinkObject.map { obj in
      Dictionary(obj.segments.map { ($0.row, $0.cols) }, uniquingKeysWith: { a, _ in a })
    } ?? [:]
    for row in 0..<frame.rows {
      for col in 0..<frame.cols {
        let index = row * frame.cols + col
        guard index < frame.cells.count, isRenderedCell(frame.cells[index]) else { continue }
        if commandLinkMode, urlHitsByRow[row]?.contains(where: { $0.range.contains(col) }) == true { continue }
        if hoveredCols[row]?.contains(col) == true { continue }
        let rect = geometry.rectForCell(row: row, col: col)
        guard let clipped = clippedCursorRect(rect, to: clipRect) else { continue }
        addCursorRect(clipped, cursor: .iBeam)
      }
    }
  }

  public override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let mouseTrackingArea {
      removeTrackingArea(mouseTrackingArea)
    }
    let area = NSTrackingArea(
      rect: .zero,
      options: [.activeAlways, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited],
      owner: self,
      userInfo: nil
    )
    addTrackingArea(area)
    mouseTrackingArea = area
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

  public var currentSelectionCellRanges: [GridSelectionCellRange] {
    guard
      let geometry = renderedGeometry(),
      let range = normalizedSelectionRange(in: geometry)
    else {
      return []
    }
    let frame = geometry.frame
    return (range.lower.row...range.upper.row).compactMap { row in
      let lowerCol = row == range.lower.row ? range.lower.col : 0
      let upperCol = row == range.upper.row ? range.upper.col : max(0, frame.cols - 1)
      guard lowerCol <= upperCol else { return nil }
      return GridSelectionCellRange(row: row, cols: lowerCol..<(upperCol + 1))
    }
  }

  public var currentLinkHoverCellRanges: [GridSelectionCellRange] {
    // Explore Mode (⌘ held): wash every detected semantic object on screen.
    let exploreRanges = currentExploreModeCellRanges
    if !exploreRanges.isEmpty {
      // Whole hovered object still included (dedup by row+bounds).
      let hoverRanges: [GridSelectionCellRange] = hoveredLinkObject.map { obj in
        obj.segments.map { GridSelectionCellRange(row: $0.row, cols: $0.cols) }
      } ?? []
      var seen = Set<String>()
      return (exploreRanges + hoverRanges).filter { range in
        seen.insert("\(range.row):\(range.cols.lowerBound):\(range.cols.upperBound)").inserted
      }
    }
    // Whole semantic object (all wrapped segments), not just the clicked row.
    if let hoveredLinkObject {
      return hoveredLinkObject.segments.map { GridSelectionCellRange(row: $0.row, cols: $0.cols) }
    }
    guard let hoveredLinkHit else { return [] }
    return [GridSelectionCellRange(row: hoveredLinkHit.row, cols: hoveredLinkHit.range)]
  }

  /// 0…1 animated reveal intensity for the renderer — drives the glyph weight
  /// boost (spec §4) and the ↗ opacity.
  public var currentLinkHoverIntensity: CGFloat { linkHoverIntensity }

  /// Placement for the trailing ↗ Action Hint (spec §5): the cell just past the
  /// logical end of the dwelled URL object. Fades in place by opacity only. Only
  /// URLs; not shown in Explore Mode (⌘) to avoid one arrow per link on screen.
  public struct ActionHint: Equatable, Sendable {
    public var row: Int
    public var col: Int
    /// 0…1 opacity of the arrow (tracks the reveal intensity tween).
    public var intensity: CGFloat
  }

  public var currentActionHint: ActionHint? {
    guard !commandLinkMode, let object = hoveredLinkObject else { return nil }
    // Appears together with the weight boost (Awake), not the later ActionHint
    // dwell — the ↗ rides the same reveal so it fades in as the glyphs thicken.
    guard dwell.phase(at: CACurrentMediaTime()) >= .awake else { return nil }
    guard case .url = object.target, let end = object.logicalEnd else { return nil }
    return ActionHint(row: end.row, col: end.cols.upperBound, intensity: linkHoverIntensity)
  }

  public var currentMarkedTextOverlay: GridMarkedTextOverlay? {
    resolvedInputPresentation().markedTextOverlay
  }

  public var currentMarkedTextString: String? {
    resolvedInputPresentation().markedTextString
  }

  public var currentCursorOverlay: GridMarkedTextOverlay? {
    guard let cursorRect = resolvedInputPresentation().cursorRect, let frame = frameSnapshot else {
      return nil
    }
    return gridOverlay(anchorRect: cursorRect, width: cellSize.width, frame: frame)
  }

  public var currentIMECompositionCursorOverlay: GridMarkedTextOverlay? {
    guard isComposingMarkedText, let cursorRect = resolvedInputPresentation().cursorRect, let frame = frameSnapshot else {
      return nil
    }
    return gridOverlay(anchorRect: cursorRect, width: cellSize.width, frame: frame)
  }

  private func selectionDirtyRects() -> [NSRect] {
    selectionRows().map(rowRect)
  }

  private func invalidateSelectionRects(_ previous: [NSRect]) {
    for rect in previous + selectionDirtyRects() {
      setNeedsDisplay(rect)
    }
    transientOverlayDidChangeHandler?()
  }

  private func selectionRows() -> Set<Int> {
    guard let geometry = renderedGeometry(), let range = normalizedSelectionRange(in: geometry) else { return [] }
    return Set(range.lower.row...range.upper.row)
  }

  private func rowRect(_ row: Int) -> NSRect {
    guard let geometry = renderedGeometry() else {
      return NSRect(
        x: contentInset.width,
        y: contentInset.height + CGFloat(max(0, row)) * cellSize.height,
        width: bounds.width,
        height: cellSize.height
      )
    }
    return geometry.rowRect(row)
  }

  private var contentInset: CGSize {
    CGSize(width: 14, height: 12)
  }

  private func drawRow(
    _ row: Int,
    frame: GhosttyTerminalFrame,
    dirtyRect: NSRect,
    selectionRange: (lower: GridCoordinate, upper: GridCoordinate)?
  ) {
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
    drawSelectedCells(in: row, frame: frame, rowStart: rowStart, rowEnd: rowEnd, selectionRange: selectionRange)
  }

  private func drawRun(_ run: CellDrawRun, row: Int) {
    let rect = NSRect(
      x: contentInset.width + CGFloat(run.range.lowerBound) * cellSize.width,
      y: contentInset.height + CGFloat(row) * cellSize.height,
      width: CGFloat(run.range.count) * cellSize.width,
      height: cellSize.height
    )
    let colors = TerminalColorResolver.resolvedColors(
      for: run.style,
      palette: palette,
      isFocused: isFocusedTerminalStorage
    )
    if run.style.inverse || !run.style.usesDefaultBackground {
      colors.background.setFill()
      rect.fill()
    }
    for (offset, scalar) in run.text.unicodeScalars.enumerated() {
      guard offset < run.range.count else { break }
      guard scalar != " " else { continue }
      let glyphRect = Self.textGlyphRect(
        row: row,
        col: run.range.lowerBound + offset,
        cellSize: cellSize,
        inset: contentInset
      )
      drawText(String(scalar), in: glyphRect, attributes: textAttributes(for: run.style, scalar: scalar, foreground: colors.foreground))
    }
  }

  private func drawSelectedCells(
    in row: Int,
    frame: GhosttyTerminalFrame,
    rowStart: Int,
    rowEnd: Int,
    selectionRange: (lower: GridCoordinate, upper: GridCoordinate)?
  ) {
    guard let range = selectionRange else { return }
    for col in 0..<frame.cols where isSelected(row: row, col: col, in: range) {
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
    let colors = TerminalColorResolver.resolvedColors(
      for: cell,
      palette: palette,
      isFocused: isFocusedTerminalStorage
    )
    if cell.inverse || !cell.usesDefaultBackground || isSelected {
      (isSelected ? palette.cursorBackground.withAlphaComponent(0.18) : colors.background).setFill()
      rect.fill()
    }
    guard cell.scalar != " " else { return }
    drawText(String(cell.scalar), in: rect, attributes: textAttributes(for: cell, scalar: cell.scalar, foreground: colors.foreground))
  }

  private func drawMarkedText(_ frame: GhosttyTerminalFrame, rowOffset: Int = 0, dirtyRect: NSRect) {
    guard isComposingMarkedText, !markedText.string.isEmpty else { return }
    let anchorRect = resolvedInputPresentation().cursorRect ?? renderedCursorRect() ?? rectForCell(row: frame.cursorY, col: frame.cursorX)
    let originCell = anchorRect
    let terminalRect = Self.terminalContentClipRect(
      cols: frame.cols,
      rows: frame.rows,
      cellSize: cellSize,
      inset: contentInset
    )
    let text = markedText.string as NSString
    let attributes = markedTextAttributes()
    let textSize = text.size(withAttributes: attributes)
    let rect = NSRect(
      x: originCell.minX,
      y: originCell.minY,
      width: min(max(cellSize.width, ceil(textSize.width) + 4), max(0, terminalRect.maxX - originCell.minX)),
      height: cellSize.height
    )
    guard rect.width > 0, dirtyRect.intersects(rect) else { return }
    PTYRenderDebugLog.write(
      "drawMarkedText cursor=(\(frame.cursorX),\(frame.cursorY)) rowOffset=\(rowOffset) rect=\(NSStringFromRect(rect)) dirty=\(NSStringFromRect(dirtyRect)) text=\"\(markedText.string)\""
    )
    palette.cursorBackground.withAlphaComponent(0.12).setFill()
    NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
    text.draw(
      at: NSPoint(x: rect.minX + 2, y: rect.minY + baselineOffset),
      withAttributes: attributes
    )
  }

  private func markedTextAttributes() -> [NSAttributedString.Key: Any] {
    [
      .font: font(forCJKText: markedText.string, bold: false),
      .foregroundColor: palette.foreground.withAlphaComponent(isFocusedTerminalStorage ? 0.92 : 0.62),
      .underlineStyle: NSUnderlineStyle.single.rawValue,
    ]
  }

  private func markedTextCaretRect(for range: NSRange) -> NSRect? {
    guard isComposingMarkedText, !markedText.string.isEmpty, let frame = frameSnapshot else { return nil }
    let originCell = resolvedInputPresentation().cursorRect ?? renderedCursorRect() ?? rectForCell(row: frame.cursorY, col: frame.cursorX)
    let terminalRect = Self.terminalContentClipRect(
      cols: frame.cols,
      rows: frame.rows,
      cellSize: cellSize,
      inset: contentInset
    )
    let location = clampedMarkedTextLocation(range.location)
    let caretX = min(originCell.minX + markedTextWidth(upTo: location), terminalRect.maxX)
    let selectionWidth = min(
      markedTextWidth(in: clampedMarkedTextRange(location: location, length: range.length)),
      max(0, terminalRect.maxX - caretX)
    )
    return NSRect(x: caretX, y: originCell.minY, width: selectionWidth, height: originCell.height)
  }

  private func markedTextWidth(upTo length: Int) -> CGFloat {
    markedTextWidth(in: NSRange(location: 0, length: min(max(0, length), markedText.length)))
  }

  private func markedTextWidth(in range: NSRange) -> CGFloat {
    guard range.length > 0 else { return 0 }
    let text = (markedText.string as NSString).substring(with: range) as NSString
    return ceil(text.size(withAttributes: markedTextAttributes()).width)
  }

  private func clampedMarkedTextLocation(_ location: Int) -> Int {
    if location == NSNotFound {
      return markedTextSelectionRange.location == NSNotFound ? 0 : clampedMarkedTextLocation(markedTextSelectionRange.location)
    }
    return min(max(0, location), markedText.length)
  }

  private func clampedMarkedTextRange(location: Int, length: Int) -> NSRange {
    let lower = clampedMarkedTextLocation(location)
    let upper = min(max(lower, lower + max(0, length)), markedText.length)
    return NSRange(location: lower, length: upper - lower)
  }

  private func markedTextDirtyRect() -> NSRect? {
    guard isComposingMarkedText, let frame = frameSnapshot else { return nil }
    let originCell = resolvedInputPresentation().cursorRect ?? renderedCursorRect() ?? rectForCell(row: frame.cursorY, col: frame.cursorX)
    let terminalRect = Self.terminalContentClipRect(
      cols: frame.cols,
      rows: frame.rows,
      cellSize: cellSize,
      inset: contentInset
    )
    let width = min(
      max(cellSize.width, ceil((markedText.string as NSString).size(withAttributes: markedTextAttributes()).width) + 4),
      max(0, terminalRect.maxX - originCell.minX)
    )
    guard width > 0 else { return nil }
    return NSRect(x: originCell.minX, y: originCell.minY, width: width, height: cellSize.height)
  }

  private func drawCursor(_ frame: GhosttyTerminalFrame, rowOffset: Int = 0, dirtyRect: NSRect) {
    guard !isIMECompositionCursorSuppressed else { return }
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

  private func invalidateIMECharacterCoordinates() {
    inputContext?.invalidateCharacterCoordinates()
  }

  private func ingestInputRenderSnapshot() {
    inputRenderGeneration &+= 1
    let proposedCursorRect = inputCursorRect()
    let inputSnapshot = TerminalInputRenderSnapshot(
      generation: inputRenderGeneration,
      cursorRect: proposedCursorRect,
      isFocused: isFocusedTerminalStorage,
      hasMarkedText: hasMarkedText()
    )
    let previousPresentation = currentInputPresentation
    let stateSnapshot = inputStateMachine.ingestRenderSnapshot(inputSnapshot)
    applyInputPresentation(stateSnapshot)
    if PTYRenderDebugLog.isEnabled {
      logInputRenderSnapshot(
        inputSnapshot: inputSnapshot,
        proposedCursorRect: proposedCursorRect,
        previousPresentation: previousPresentation,
        stateSnapshot: stateSnapshot,
        resolvedPresentation: currentInputPresentation
      )
    }
  }

  private func applyInputPresentation(_ snapshot: TerminalInputPresentationSnapshot) {
    let resolved = resolvedInputPresentation(from: snapshot)
    currentInputPresentation = resolved
    rememberPromptCursorRect(from: resolved.cursorRect)
    markedTextCompositionActive = resolved.cursorSuppressed
    if !resolved.cursorSuppressed && resolved.markedTextString == nil {
      markedText = NSAttributedString(string: "")
      markedTextRange = NSRange(location: NSNotFound, length: 0)
      markedTextSelectionRange = NSRange(location: NSNotFound, length: 0)
    }
  }

  private func resolvedInputPresentation() -> TerminalInputPresentationSnapshot {
    if let currentInputPresentation {
      return currentInputPresentation
    }
    let snapshot = inputStateMachine.ingestRenderSnapshot(
      TerminalInputRenderSnapshot(
        generation: inputRenderGeneration,
        cursorRect: inputCursorRect(),
        isFocused: isFocusedTerminalStorage,
        hasMarkedText: hasMarkedText()
      )
    )
    let resolved = resolvedInputPresentation(from: snapshot)
    currentInputPresentation = resolved
    return resolved
  }

  private func resolvedInputPresentation(
    from snapshot: TerminalInputPresentationSnapshot
  ) -> TerminalInputPresentationSnapshot {
    let text = snapshot.markedTextString ?? ((snapshot.cursorSuppressed && hasMarkedText() && !markedText.string.isEmpty) ? markedText.string : nil)
    let cursorRect = snapshot.cursorRect ?? inputCursorRect()
    let overlay: GridMarkedTextOverlay?
    if let text, !text.isEmpty, let cursorRect, let frame = frameSnapshot {
      let textWidth = ceil((text as NSString).size(withAttributes: markedTextAttributes()).width) + 4
      overlay = gridOverlay(anchorRect: cursorRect, width: max(cellSize.width, textWidth), frame: frame)
    } else {
      overlay = nil
    }
    return TerminalInputPresentationSnapshot(
      cursorRect: cursorRect,
      markedTextOverlay: overlay,
      markedTextString: text?.isEmpty == false ? text : nil,
      cursorSuppressed: snapshot.cursorSuppressed
    )
  }

  private func gridOverlay(anchorRect: NSRect, width requestedWidth: CGFloat, frame: GhosttyTerminalFrame) -> GridMarkedTextOverlay? {
    let terminalRect = Self.terminalContentClipRect(
      cols: frame.cols,
      rows: frame.rows,
      cellSize: cellSize,
      inset: contentInset
    )
    let width = min(
      max(cellSize.width, requestedWidth),
      max(0, terminalRect.maxX - anchorRect.minX)
    )
    guard width > 0 else { return nil }
    let row = Int(round((anchorRect.minY - contentInset.height) / cellSize.height))
    let col = Int(round((anchorRect.minX - contentInset.width) / cellSize.width))
    return GridMarkedTextOverlay(
      row: min(max(0, row), max(0, frame.rows - 1)),
      col: min(max(0, col), max(0, frame.cols - 1)),
      width: width
    )
  }

  private func textAttributes(
    for cell: GhosttyTerminalFrame.Cell,
    scalar: UnicodeScalar,
    foreground: NSColor
  ) -> [NSAttributedString.Key: Any] {
    [
      .font: font(forCJKText: String(scalar), bold: cell.bold),
      .foregroundColor: foreground,
      .underlineStyle: cell.underline ? NSUnderlineStyle.single.rawValue : 0,
      .obliqueness: cell.italic ? 0.18 : 0,
    ]
  }

  private func font(forCJKText text: String, bold: Bool) -> NSFont {
    guard FontCatalog.containsCJK(text) else {
      return bold ? boldFont : font
    }
    return (bold ? cjkBoldFont : cjkFont) ?? (bold ? boldFont : font)
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

  private func renderedClipRect(for viewportFrame: GhosttyTerminalFrame?, fallbackFrame: GhosttyTerminalFrame) -> NSRect {
    Self.terminalContentClipRect(
      cols: viewportFrame?.cols ?? fallbackFrame.cols,
      rows: viewportFrame?.rows ?? fallbackFrame.rows,
      cellSize: cellSize,
      inset: contentInset
    )
  }

  private func extendedFrame(from scrollFrame: GhosttyTerminalScrollFrame) -> GhosttyTerminalFrame {
    RenderedGridGeometry.extendedFrame(from: scrollFrame)
  }

  private func absoluteBaseRow(for scrollFrame: GhosttyTerminalScrollFrame) -> Int {
    RenderedGridGeometry.absoluteBaseRow(for: scrollFrame)
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

  private func linkHit(at point: NSPoint) -> TerminalLinkHit? {
    guard let geometry = renderedGeometry(),
      let coordinate = geometry.coordinate(at: point)
    else {
      return nil
    }
    return TerminalLinkDetector.hitTest(row: coordinate.row, col: coordinate.col, in: geometry.frame, pathValidator: pathExistenceValidator)
  }

  private func logCommandLinkHit(at point: NSPoint) {
    guard let geometry = renderedGeometry() else {
      PTYRenderDebugLog.write("cmd-link point=\(NSStringFromPoint(point)) geometry=nil")
      return
    }
    guard let coordinate = geometry.coordinate(at: point) else {
      PTYRenderDebugLog.write("cmd-link point=\(NSStringFromPoint(point)) coordinate=nil frameRows=\(geometry.frame.rows) frameCols=\(geometry.frame.cols)")
      return
    }
    let hit = TerminalLinkDetector.hitTest(row: coordinate.row, col: coordinate.col, in: geometry.frame)
    let hits = TerminalLinkDetector.hits(inRow: coordinate.row, frame: geometry.frame)
    PTYRenderDebugLog.write(
      "cmd-link point=\(NSStringFromPoint(point)) row=\(coordinate.row) col=\(coordinate.col) absRow=\(geometry.absoluteBaseRow + coordinate.row) rowText=\"\(Self.debugText(inRow: coordinate.row, frame: geometry.frame))\" hit=\(Self.debugDescription(for: hit)) hits=\(hits.map(Self.debugDescription(for:)).joined(separator: " | "))"
    )
  }

  private static func debugText(inRow row: Int, frame: GhosttyTerminalFrame) -> String {
    guard row >= 0, row < frame.rows, frame.cols > 0 else { return "" }
    let rowStart = row * frame.cols
    let rowEnd = min(rowStart + frame.cols, frame.cells.count)
    guard rowStart < rowEnd else { return "" }
    return frame.cells[rowStart..<rowEnd].map { String($0.scalar) }.joined()
  }

  private func logInputRenderSnapshot(
    inputSnapshot: TerminalInputRenderSnapshot,
    proposedCursorRect: NSRect?,
    previousPresentation: TerminalInputPresentationSnapshot?,
    stateSnapshot: TerminalInputPresentationSnapshot,
    resolvedPresentation: TerminalInputPresentationSnapshot?
  ) {
    let viewportCursor = frameSnapshot.map { "(\($0.cursorX),\($0.cursorY))" } ?? "nil"
    let viewportShape = frameSnapshot.map { "\($0.cursorShape)" } ?? "nil"
    let geometry = renderedGeometry()
    let geometryCursor = geometry.map { "(\($0.frame.cursorX),\($0.frame.cursorY))" } ?? "nil"
    let overscanTop = scrollFrameSnapshot?.overscanTop.count ?? 0
    let cursorRow = geometry?.frame.cursorY ?? frameSnapshot?.cursorY ?? -1
    let rowText = geometry.map { Self.debugLogText(inRow: cursorRow, frame: $0.frame) } ?? ""
    let overlay = resolvedPresentation.flatMap { presentation -> GridMarkedTextOverlay? in
      guard let cursorRect = presentation.cursorRect, let frame = frameSnapshot else { return nil }
      return gridOverlay(anchorRect: cursorRect, width: cellSize.width, frame: frame)
    }
    PTYRenderDebugLog.write(
      "inputRender gen=\(inputSnapshot.generation) focused=\(inputSnapshot.isFocused) marked=\(inputSnapshot.hasMarkedText) composing=\(isComposingMarkedText) viewportCursor=\(viewportCursor) shape=\(viewportShape) geometryCursor=\(geometryCursor) overscanTop=\(overscanTop) proposedRect=\(Self.debugDescription(for: proposedCursorRect)) beforeRect=\(Self.debugDescription(for: previousPresentation?.cursorRect)) stateRect=\(Self.debugDescription(for: stateSnapshot.cursorRect)) resolvedRect=\(Self.debugDescription(for: resolvedPresentation?.cursorRect)) suppressed=\(resolvedPresentation?.cursorSuppressed ?? false) markedString=\(resolvedPresentation?.markedTextString.map { "\"\(Self.debugLogText($0))\"" } ?? "nil") cursorOverlay=\(Self.debugDescription(for: overlay)) row=\(cursorRow) rowText=\"\(rowText)\""
    )
  }

  private static func debugLogText(inRow row: Int, frame: GhosttyTerminalFrame) -> String {
    debugLogText(debugText(inRow: row, frame: frame))
  }

  private static func debugLogText(_ text: String) -> String {
    let sanitized = text
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
      .replacingOccurrences(of: "\n", with: "\\n")
      .replacingOccurrences(of: "\r", with: "\\r")
    let maxLength = 120
    guard sanitized.count > maxLength else { return sanitized }
    return String(sanitized.prefix(maxLength)) + "..."
  }

  private static func debugDescription(for rect: NSRect?) -> String {
    rect.map(NSStringFromRect) ?? "nil"
  }

  private static func debugDescription(for overlay: GridMarkedTextOverlay?) -> String {
    guard let overlay else { return "nil" }
    return "(row:\(overlay.row),col:\(overlay.col),width:\(String(format: "%.1f", overlay.width)))"
  }

  private static func debugDescription(for hit: TerminalLinkHit?) -> String {
    guard let hit else { return "nil" }
    return "row=\(hit.row) range=\(hit.range.lowerBound)..<\(hit.range.upperBound) text=\"\(hit.text)\" target=\(debugDescription(for: hit.target))"
  }

  private static func debugDescription(for target: TerminalLinkTarget) -> String {
    switch target {
    case .url(let url):
      return "url(\(url.absoluteString))"
    case .filePath(let path):
      return "filePath(raw=\"\(path.rawPath)\", line=\(path.line.map(String.init) ?? "nil"), column=\(path.column.map(String.init) ?? "nil"))"
    }
  }

  private func updateLinkHover(at point: NSPoint) {
    // Dwell model (spec: URL_TYPOGRAPHIC_DWELL). We do NOT react to proximity or
    // motion. We find the object *under* the pointer and hand its identity + the
    // current time to the dwell clock; the clock decides Rest/Awake/ActionHint.
    lastPointer = point
    guard let geometry = renderedGeometry() else {
      clearHover()
      return
    }
    let object = objectUnderPointer(point, geometry: geometry)
    let hoverChanged = object?.id != hoveredLinkObject?.id
    hoveredLinkObject = object
    hoveredLinkHit = object.flatMap { obj in
      obj.segments.first.map { TerminalLinkHit(target: obj.target, row: $0.row, range: $0.cols, text: obj.text) }
    }
    // The hovered object's cells are carved out of the iBeam field in
    // resetCursorRects (they get the plain arrow). That carve is only reflected
    // once cursor rects rebuild — so when the hovered object *changes*, invalidate
    // them now, in this same mouse event, or the pointer shows a stale iBeam for a
    // frame before some unrelated invalidation rebuilds them (the visible flicker).
    if hoverChanged {
      window?.invalidateCursorRects(for: self)
    }
    // Hover *signal* (drives the lightweight open-link toast) reflects the pointer
    // being over an interactive object — immediate. The *visual* reveal (weight) is
    // still strictly dwell-gated below; only the non-visual signal is instant.
    setHoveringLink(object != nil)
    dwell.setObject(object?.id, at: CACurrentMediaTime())
    applyDwellState(pointer: point, object: object, geometry: geometry)
  }

  private func setHoveringLink(_ isHovering: Bool) {
    guard isHoveringLink != isHovering else { return }
    isHoveringLink = isHovering
    linkHoverHandler?(isHovering)
  }

  /// The semantic object whose cells the pointer is directly over, or nil. Unlike
  /// the old flashlight model there is no neighbor scan and no distance — dwell
  /// only wakes what the pointer actually rests on.
  private func objectUnderPointer(
    _ point: NSPoint,
    geometry: RenderedGridGeometry
  ) -> SemanticLinkObject? {
    let frame = geometry.frame
    guard frame.rows > 0, frame.cols > 0, let coordinate = geometry.coordinate(at: point) else {
      return nil
    }
    return SemanticLinkObjectResolver.object(
      at: coordinate.row,
      col: coordinate.col,
      in: frame,
      pathValidator: pathExistenceValidator
    )
  }

  /// Translate the current dwell phase (or ⌘ Explore Mode) into the reveal
  /// intensity target and the GPU ring cursor, then keep the display-link tween
  /// and a wake-up scheduled so a still pointer still crosses the dwell thresholds.
  private func applyDwellState(
    pointer: NSPoint,
    object: SemanticLinkObject?,
    geometry: RenderedGridGeometry
  ) {
    let now = CACurrentMediaTime()
    let phase = dwell.phase(at: now)
    // Explore Mode forces full reveal regardless of dwell; otherwise the object
    // must have reached Awake for the *weight* boost.
    let awake = commandLinkMode || phase >= .awake

    // The ring cursor appears the INSTANT the pointer is over an object — decoupled
    // from the dwell-gated weight boost, so contact feels immediate while the
    // glyph thickening still waits out its dwell delay.
    updateRingCursor(pointer: pointer, show: object != nil)

    setRevealTarget(awake ? 1 : 0)
    scheduleDwellWakeup(at: now)
  }

  /// Move/show/hide the ring cursor layer. Centered on the pointer, no magnetism.
  /// Wrapped in a no-actions `CATransaction` so `position` changes are exact
  /// (Core Animation's implicit position animation would make the ring lag). This
  /// touches ONLY the compositor — no Metal present, no `transientOverlayDidChange`.
  private func updateRingCursor(pointer: NSPoint, show: Bool) {
    // TEMP: ring cursor disabled — keep the plain arrow on interactive content.
    // Force the hide path so the real cursor is never swapped for the GPU ring.
    let show = show && ringCursorEnabled
    guard show else {
      if ringCursorVisible {
        ringCursorVisible = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ringCursorLayer.isHidden = true
        CATransaction.commit()
      }
      setCursorHidden(false)
      return
    }
    ensureRingCursorAttached()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    if !ringCursorVisible {
      ringCursorVisible = true
      applyRingCursorColor()
      ringCursorLayer.isHidden = false
    }
    // Layer coords match the view's flipped/unflipped space; PTYGridView is not
    // flipped, so view point maps straight to layer position.
    ringCursorLayer.position = pointer
    CATransaction.commit()
    setCursorHidden(true)
  }

  private func ensureRingCursorAttached() {
    if ringCursorLayer.superlayer == nil {
      wantsLayer = true
      layer?.addSublayer(ringCursorLayer)
    }
  }

  private func makeRingCursorLayer() -> CALayer {
    let layer = CALayer()
    let diameter = cellSize.height * 0.56
    let ringWidth: CGFloat = 1.25
    layer.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
    layer.backgroundColor = NSColor.clear.cgColor
    layer.borderWidth = ringWidth
    layer.cornerRadius = diameter / 2
    layer.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    layer.isHidden = true
    // Zero delegate so it never runs implicit content actions from its host view.
    layer.actions = ["position": NSNull(), "hidden": NSNull(), "bounds": NSNull()]
    return layer
  }

  /// Solid two-tone ring chosen from the background's brightness (not theme name,
  /// so custom themes work): light bg → dark-grey ring, dark bg → near-white ring.
  private func applyRingCursorColor() {
    let lightBackground = palette.background.relativeLuminanceValue >= 0.5
    let tone = lightBackground
      ? NSColor(calibratedWhite: 0.24, alpha: 1)
      : NSColor(calibratedWhite: 0.96, alpha: 1)
    ringCursorLayer.borderColor = tone.cgColor
  }

  /// Transition-guarded cursor hide so `NSCursor.hide()`/`unhide()` stay balanced
  /// (they are counted — a repeated hide would strand the cursor).
  private func setCursorHidden(_ hidden: Bool) {
    guard hidden != isCursorHidden else { return }
    isCursorHidden = hidden
    if hidden {
      NSCursor.hide()
    } else {
      NSCursor.unhide()
    }
  }

  /// Schedule a single wake-up at the next dwell threshold so a *stationary*
  /// pointer still transitions Rest→Awake→ActionHint without a mouse event. Uses
  /// the display link (already running while a tween is live) plus a one-shot
  /// timer for the idle case.
  private func scheduleDwellWakeup(at now: TimeInterval) {
    guard !commandLinkMode, let delay = dwell.timeUntilNextTransition(at: now), delay > 0 else { return }
    dwellWakeupTimer?.invalidate()
    let timer = Timer(timeInterval: delay + 0.001, repeats: false) { [weak self] _ in
      guard let self else { return }
      MainActor.assumeIsolated {
        self.dwellTick()
      }
    }
    RunLoop.main.add(timer, forMode: .common)
    dwellWakeupTimer = timer
  }

  /// Re-evaluate dwell for the stationary pointer (fired by the wake-up timer).
  private func dwellTick() {
    guard let point = lastPointer, let geometry = renderedGeometry() else { return }
    applyDwellState(pointer: point, object: hoveredLinkObject, geometry: geometry)
  }

  private func clearHover() {
    hoveredLinkObject = nil
    hoveredLinkHit = nil
    dwell.setObject(nil, at: CACurrentMediaTime())
    dwellWakeupTimer?.invalidate()
    dwellWakeupTimer = nil
    updateRingCursor(pointer: .zero, show: false)
    setCursorHidden(false)
    setHoveringLink(false)
    setRevealTarget(commandLinkMode ? 1 : 0)
  }

  private func updateLinkHover(isHovering: Bool) {
    if !isHovering {
      lastPointer = nil
      clearHover()
    }
  }

  /// Drive the reveal intensity toward `target` (0 or 1). In Explore Mode (⌘ held)
  /// the target stays 1 regardless. The display link owns the 120–180ms tween;
  /// Reduce Motion snaps.
  private func setRevealTarget(_ target: CGFloat) {
    let clamped = min(1, max(0, commandLinkMode ? 1 : target))
    if reduceMotionEnabled {
      linkHoverIntensity = clamped
      linkHoverIntensityTarget = clamped
      needsDisplay = true
      transientOverlayDidChangeHandler?()
    } else {
      linkHoverIntensityTarget = clamped
      startLinkHoverDisplayLinkIfNeeded()
    }
  }

  private var reduceMotionEnabled: Bool {
    NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
  }

  private func startLinkHoverDisplayLinkIfNeeded() {
    let atTarget = abs(linkHoverIntensity - linkHoverIntensityTarget) < 0.001
    guard !atTarget else { return }
    guard linkHoverDisplayLink == nil, window != nil else { return }
    let link = displayLink(target: self, selector: #selector(handleLinkHoverDisplayLink(_:)))
    link.add(to: .main, forMode: .common)
    linkHoverLastTickTime = CACurrentMediaTime()
    linkHoverDisplayLink = link
  }

  @objc private func handleLinkHoverDisplayLink(_ link: CADisplayLink) {
    let now = link.targetTimestamp
    // Ease toward target (fade-out on leave, ⌘ Explore in/out).
    let dt = max(0, now - linkHoverLastTickTime)
    linkHoverLastTickTime = now
    let animationDuration: CGFloat = 0.16
    let step = animationDuration > 0 ? CGFloat(dt) / animationDuration : 1
    let delta = linkHoverIntensityTarget - linkHoverIntensity
    if abs(delta) < 0.004 {
      linkHoverIntensity = linkHoverIntensityTarget
    } else {
      linkHoverIntensity += delta * min(1, step * 2.0)
    }
    needsDisplay = true
    transientOverlayDidChangeHandler?()

    if abs(linkHoverIntensity - linkHoverIntensityTarget) < 0.001 {
      link.invalidate()
      linkHoverDisplayLink = nil
    }
  }

  private func stopLinkHoverDisplayLink() {
    linkHoverDisplayLink?.invalidate()
    linkHoverDisplayLink = nil
  }

  private func updateSelectionHead(at point: NSPoint) {
    guard let geometry = renderedGeometry() else {
      selection.head = nil
      return
    }
    selection.head = geometry.selectionPoint(at: clampedSelectionPoint(point, geometry: geometry))
  }

  private func clampedSelectionPoint(_ point: NSPoint, geometry: RenderedGridGeometry) -> NSPoint {
    let minX = geometry.inset.width
    let maxX = geometry.inset.width + CGFloat(max(0, geometry.frame.cols)) * geometry.cellSize.width - 1
    let minY = geometry.clipRect.minY
    let maxY = geometry.clipRect.maxY - 1
    return NSPoint(
      x: min(max(point.x, minX), max(minX, maxX)),
      y: min(max(point.y, minY), max(minY, maxY))
    )
  }

  private func updateSelectionAutoScroll(at point: NSPoint) {
    guard isDraggingSelectionStorage,
      frameSnapshot?.isAlternateScreen == false,
      let geometry = renderedGeometry()
    else {
      stopSelectionAutoScroll()
      return
    }

    let direction: Int
    if point.y < geometry.clipRect.minY + Self.selectionAutoScrollEdgeInset {
      direction = 1
    } else if point.y > geometry.clipRect.maxY - Self.selectionAutoScrollEdgeInset {
      direction = -1
    } else {
      direction = 0
    }

    guard direction != 0, selectionAutoScrollCanScroll(direction: direction) else {
      stopSelectionAutoScroll()
      return
    }

    selectionAutoScrollDirection = direction
    performSelectionAutoScrollTick()
    startSelectionAutoScrollTimer()
  }

  private func startSelectionAutoScrollTimer() {
    guard selectionAutoScrollTimer == nil else { return }
    let timer = Timer(timeInterval: Self.selectionAutoScrollInterval, repeats: true) { [weak self] _ in
      Task { @MainActor in
        self?.performSelectionAutoScrollTick()
      }
    }
    RunLoop.main.add(timer, forMode: .common)
    selectionAutoScrollTimer = timer
  }

  private func stopSelectionAutoScroll() {
    selectionAutoScrollTimer?.invalidate()
    selectionAutoScrollTimer = nil
    selectionAutoScrollDirection = 0
  }

  private func performSelectionAutoScrollTick() {
    guard isDraggingSelectionStorage, selectionAutoScrollDirection != 0 else {
      stopSelectionAutoScroll()
      return
    }
    let didScroll = stepBrowseForSelectionAutoScroll(direction: selectionAutoScrollDirection)
    guard didScroll else {
      stopSelectionAutoScroll()
      return
    }
    if let selectionDragPoint {
      updateSelectionHead(at: selectionDragPoint)
    }
    needsDisplay = true
    transientOverlayDidChangeHandler?()
  }

  private func selectionAutoScrollCanScroll(direction: Int) -> Bool {
    return canStepBrowseForSelectionAutoScroll(direction: direction)
  }

  private func canStepBrowseForSelectionAutoScroll(direction: Int) -> Bool {
    guard let metrics = browseScrollMetricsHandler?() else { return false }
    let visible = max(1, frameSnapshot?.rows ?? visibleRowCount())
    let liveBottom = Self.liveBottomTopRow(
      total: metrics.total,
      visibleRows: visible,
      vtOffset: metrics.topAbsoluteRow
    )
    let currentTop = browseTopRow ?? liveBottom
    if direction > 0 {
      // Into history.
      return currentTop > 0
    }
    if direction < 0 {
      // Toward live tail — only while parked above the live page.
      return browseTopRow != nil && currentTop < liveBottom
    }
    return false
  }

  /// Discrete whole-row history step for selection edge auto-scroll (Pattern-2).
  /// Reuses browse present/follow handlers; does not move the VT viewport.
  @discardableResult
  private func stepBrowseForSelectionAutoScroll(direction: Int) -> Bool {
    guard let metrics = browseScrollMetricsHandler?() else { return false }
    let visible = max(1, frameSnapshot?.rows ?? visibleRowCount())
    let liveBottom = Self.liveBottomTopRow(
      total: metrics.total,
      visibleRows: visible,
      vtOffset: metrics.topAbsoluteRow
    )
    let currentTop = browseTopRow ?? liveBottom

    let nextTop: UInt64
    if direction > 0 {
      guard currentTop > 0 else { return false }
      nextTop = currentTop - 1
    } else if direction < 0 {
      guard let parked = browseTopRow, parked < liveBottom else { return false }
      nextTop = min(parked + 1, liveBottom)
    } else {
      return false
    }

    // Don't dual-write visualOffsetY with a live display-link tick.
    if isSmoothScrollBrowsing {
      smoothScrollEngine.reset()
      stopSmoothScrollBrowsing()
    }

    if nextTop >= liveBottom {
      browseTopRow = nil
      suppressViewportChangePresent = true
      viewport = TerminalViewport()
      suppressViewportChangePresent = false
      browseFollowResumeHandler?()
    } else {
      browseTopRow = nextTop
      // Whole-row discrete step: clear sub-row remainder (tick is sole writer otherwise).
      suppressViewportChangePresent = true
      viewport = TerminalViewport()
      suppressViewportChangePresent = false
      browsePresentHandler?(nextTop, visible)
    }
    return true
  }

  private func renderedGeometry() -> RenderedGridGeometry? {
    if let scrollFrameSnapshot {
      let frame = extendedFrame(from: scrollFrameSnapshot)
      return RenderedGridGeometry(
        frame: frame,
        translationY: drawTranslationY(topOverscanRows: scrollFrameSnapshot.overscanTop.count),
        cellSize: cellSize,
        inset: contentInset,
        clipRect: renderedClipRect(for: frameSnapshot, fallbackFrame: frame),
        absoluteBaseRow: absoluteBaseRow(for: scrollFrameSnapshot)
      )
    }
    guard let frameSnapshot else { return nil }
    return RenderedGridGeometry(
      frame: frameSnapshot,
      translationY: 0,
      cellSize: cellSize,
      inset: contentInset,
      clipRect: renderedClipRect(for: frameSnapshot, fallbackFrame: frameSnapshot),
      absoluteBaseRow: 0
    )
  }

  private func renderedCursorRect() -> NSRect? {
    guard let geometry = renderedGeometry() else { return nil }
    return geometry.rectForCell(row: geometry.frame.cursorY, col: geometry.frame.cursorX)
  }

  private func inputCursorRect() -> NSRect? {
    inferredPromptCursorRect() ?? preservedPromptCursorRectForBlankTransient() ?? renderedCursorRect()
  }

  private func inferredPromptCursorRect() -> NSRect? {
    guard
      let viewportFrame = frameSnapshot,
      viewportFrame.cursorX == 0,
      let geometry = renderedGeometry(),
      PromptCursorInferrer.shouldInferPromptCursor(for: viewportFrame, in: geometry),
      let coordinate = (viewportFrame.cursorY != 0 ? PromptCursorInferrer.inferredPromptCursorCoordinateOnCursorRow(in: geometry) : nil)
        ?? PromptCursorInferrer.inferredPromptCursorCoordinate(in: geometry)
    else {
      return nil
    }
    if viewportFrame.cursorY != 0,
      let currentCursorRect = currentInputPresentation?.cursorRect,
      abs(currentCursorRect.minY - geometry.rowRect(geometry.frame.cursorY).minY) < 0.5
    {
      PTYRenderDebugLog.write(
        "inputCursor preservedPromptCursor rect=\(NSStringFromRect(currentCursorRect)) frameCursor=(\(viewportFrame.cursorX),\(viewportFrame.cursorY))"
      )
      return currentCursorRect
    }
    let rect = geometry.rectForCell(row: coordinate.row, col: coordinate.col)
    PTYRenderDebugLog.write(
      "inputCursor inferredPromptCursor=(\(coordinate.col),\(coordinate.row)) rect=\(NSStringFromRect(rect)) frameCursor=(\(viewportFrame.cursorX),\(viewportFrame.cursorY))"
    )
    return rect
  }

  private func preservedPromptCursorRectForBlankTransient() -> NSRect? {
    guard
      let viewportFrame = frameSnapshot,
      viewportFrame.cursorX == 0,
      let currentCursorRect = currentInputPresentation?.cursorRect,
      let geometry = renderedGeometry()
    else {
      return nil
    }
    let cursorRow = geometry.frame.cursorY
    guard
      let currentCoordinate = geometry.coordinate(at: NSPoint(x: currentCursorRect.midX, y: currentCursorRect.midY)),
      currentCoordinate.row > cursorRow,
      PromptCursorInferrer.rowIsBlank(cursorRow, in: geometry),
      PromptCursorInferrer.rowIsInPromptInputRegion(currentCoordinate.row, in: geometry)
        || PromptCursorInferrer.rect(currentCursorRect, approximatelyEquals: latestPromptInputCursorRect)
    else {
      return nil
    }
    PTYRenderDebugLog.write(
      "inputCursor preservedBlankTransient rect=\(NSStringFromRect(currentCursorRect)) frameCursor=(\(viewportFrame.cursorX),\(viewportFrame.cursorY)) promptRow=\(currentCoordinate.row) transientRow=\(cursorRow)"
    )
    return currentCursorRect
  }

  private func rememberPromptCursorRect(from rect: NSRect?) {
    guard
      let rect,
      let geometry = renderedGeometry(),
      let coordinate = geometry.coordinate(at: NSPoint(x: rect.midX, y: rect.midY)),
      PromptCursorInferrer.rowIsInPromptInputRegion(coordinate.row, in: geometry)
    else {
      return
    }
    latestPromptInputCursorRect = rect
  }

  private func clippedCursorRect(_ rect: NSRect, to clipRect: NSRect) -> NSRect? {
    let clipped = rect.intersection(clipRect)
    guard clipped.width > 0, clipped.height > 0 else { return nil }
    return clipped
  }

  private func normalizedSelectionPointRange() -> (lower: GridSelectionPoint, upper: GridSelectionPoint)? {
    selection.normalizedPointRange()
  }

  private func normalizedSelectionRange(in geometry: RenderedGridGeometry) -> (lower: GridCoordinate, upper: GridCoordinate)? {
    selection.normalizedRange(in: geometry)
  }

  private func isSelected(
    row: Int,
    col: Int,
    in range: (lower: GridCoordinate, upper: GridCoordinate)
  ) -> Bool {
    GridSelectionModel.isSelected(row: row, col: col, in: range)
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

  private static func installedFont(family: String, size: CGFloat, weight: NSFont.Weight) -> NSFont? {
    guard let named = NSFont(name: family, size: size) else { return nil }
    if weight == .semibold {
      return NSFontManager.shared.convert(named, toHaveTrait: .boldFontMask)
    }
    return named
  }

  private static func normalizedFontFamily(_ family: String?) -> String? {
    let trimmed = family?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? nil : trimmed
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

}

public typealias CellGridView = PTYGridView

extension PTYGridView: @preconcurrency NSTextInputClient {
  public func insertText(_ string: Any, replacementRange: NSRange) {
    activationHandler?()
    let oldRect = markedTextDirtyRect()
    unmarkText()
    if let oldRect {
      setNeedsDisplay(oldRect)
    }
    applyInputPresentation(inputStateMachine.handle(.insertText(committedText(from: string) ?? "")))
    transientOverlayDidChangeHandler?()
    guard let text = committedText(from: string), !text.isEmpty else { return }
    inputHandler?(Data(text.utf8))
  }

  public func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
    let oldRect = markedTextDirtyRect()
    let nextMarkedText: NSAttributedString
    if let attributed = string as? NSAttributedString {
      nextMarkedText = attributed
    } else if let text = string as? String {
      nextMarkedText = NSAttributedString(string: text)
    } else {
      nextMarkedText = NSAttributedString(string: "")
    }
    guard nextMarkedText.length > 0 else {
      PTYRenderDebugLog.write(
        "setMarkedText empty -> unmark oldRect=\(oldRect.map(NSStringFromRect) ?? "nil") frameCursor=\(frameSnapshot.map { "(\($0.cursorX),\($0.cursorY))" } ?? "nil")"
      )
      unmarkText()
      return
    }
    if !isComposingMarkedText {
      applyInputPresentation(inputStateMachine.handle(.keyDown(isCompositionMethod: true)))
    }
    markedTextCompositionActive = true
    markedTextRevision &+= 1
    markedText = nextMarkedText
    markedTextRange = markedText.length > 0 ? NSRange(location: 0, length: markedText.length) : NSRange(location: NSNotFound, length: 0)
    let selectedLocation = selectedRange.location == NSNotFound ? 0 : selectedRange.location
    markedTextSelectionRange = clampedMarkedTextRange(location: selectedLocation, length: selectedRange.length)
    PTYRenderDebugLog.write(
      "setMarkedText text=\"\(markedText.string)\" selected=\(NSStringFromRange(selectedRange)) stored=\(NSStringFromRange(markedTextSelectionRange)) oldRect=\(oldRect.map(NSStringFromRect) ?? "nil") frameCursor=\(frameSnapshot.map { "(\($0.cursorX),\($0.cursorY))" } ?? "nil")"
    )
    if let oldRect {
      setNeedsDisplay(oldRect)
    }
    if let newRect = markedTextDirtyRect() {
      setNeedsDisplay(newRect)
    }
    applyInputPresentation(inputStateMachine.handle(.setMarkedText(markedText.string, selectedRange: selectedRange)))
    invalidateIMECharacterCoordinates()
    transientOverlayDidChangeHandler?()
  }

  public func unmarkText() {
    let oldRect = markedTextDirtyRect()
    PTYRenderDebugLog.write(
      "unmarkText oldRect=\(oldRect.map(NSStringFromRect) ?? "nil") selection=\(NSStringFromRange(markedTextSelectionRange))"
    )
    markedText = NSAttributedString(string: "")
    markedTextRange = NSRange(location: NSNotFound, length: 0)
    markedTextSelectionRange = NSRange(location: NSNotFound, length: 0)
    markedTextCompositionActive = false
    markedTextRevision &+= 1
    if let oldRect {
      setNeedsDisplay(oldRect)
    }
    applyInputPresentation(inputStateMachine.handle(.unmarkText))
    invalidateIMECharacterCoordinates()
    transientOverlayDidChangeHandler?()
  }

  public func selectedRange() -> NSRange {
    if isComposingMarkedText, markedTextSelectionRange.location != NSNotFound {
      return markedTextSelectionRange
    }
    return NSRange(location: 0, length: 0)
  }

  public func markedRange() -> NSRange {
    markedTextRange
  }

  public func hasMarkedText() -> Bool {
    markedTextRange.location != NSNotFound && markedTextRange.length > 0
  }

  public func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
    actualRange?.pointee = NSRange(location: NSNotFound, length: 0)
    return nil
  }

  public func validAttributesForMarkedText() -> [NSAttributedString.Key] {
    []
  }

  public func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
    actualRange?.pointee = selectedRange()
    guard let window, let rect = markedTextCaretRect(for: range) ?? cursorCellRect else { return .zero }
    let screenRect = convert(rect, to: nil)
    PTYRenderDebugLog.write(
      "firstRect range=\(NSStringFromRange(range)) actual=\(NSStringFromRange(actualRange?.pointee ?? NSRange(location: NSNotFound, length: 0))) viewRect=\(NSStringFromRect(rect)) screenRect=\(NSStringFromRect(screenRect))"
    )
    return window.convertToScreen(screenRect)
  }

  public func characterIndex(for point: NSPoint) -> Int {
    let presentation = resolvedInputPresentation()
    guard let anchorRect = presentation.cursorRect ?? renderedCursorRect(), let frame = frameSnapshot, frame.cols > 0 else { return 0 }
    let viewPoint: NSPoint
    if let window {
      viewPoint = convert(window.convertPoint(fromScreen: point), from: nil)
    } else {
      viewPoint = point
    }
    let relativeRow = max(0, Int(floor((viewPoint.y - anchorRect.minY) / cellSize.height)))
    let relativeCol = max(0, Int(floor((viewPoint.x - anchorRect.minX) / cellSize.width)))
    let maxIndex = max(0, (presentation.markedTextString?.count ?? 0) - 1)
    return min(maxIndex, relativeRow * frame.cols + relativeCol)
  }

  private func committedText(from string: Any) -> String? {
    if let attributed = string as? NSAttributedString {
      return attributed.string
    }
    return string as? String
  }
}

struct GridSelectionCoordinate: Equatable, Sendable {
  var row: Int
  var col: Int

  init(row: Int, col: Int) {
    self.row = row
    self.col = col
  }
}

public struct GridSelectionCellRange: Equatable, Sendable {
  public var row: Int
  public var cols: Range<Int>

  public init(row: Int, cols: Range<Int>) {
    self.row = row
    self.cols = cols
  }
}

public struct GridMarkedTextOverlay: Equatable, Sendable {
  public var row: Int
  public var col: Int
  public var width: CGFloat

  public init(row: Int, col: Int, width: CGFloat) {
    self.row = row
    self.col = col
    self.width = width
  }
}

extension PTYGridView {
  func testSetSelection(anchor: GridSelectionCoordinate, head: GridSelectionCoordinate) {
    selection = GridSelectionModel(
      anchor: GridSelectionPoint(absoluteRow: anchor.row, col: anchor.col),
      head: GridSelectionPoint(absoluteRow: head.row, col: head.col)
    )
  }
}

final class PTYTextView: NSTextView {
  var inputHandler: ((Data) -> Void)?
  var pasteHandler: ((String) -> Void)?
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
    if let data = terminalControlInputData(for: event) {
      scrollToBottomHandler?()
      inputHandler?(data)
    } else {
      interpretKeyEvents([event])
    }
  }

  override func rightMouseDown(with event: NSEvent) {
    activationHandler?()
    guard let menu else {
      super.rightMouseDown(with: event)
      return
    }
    menu.removeTerminalIncompatibleSystemItems()
    NSMenu.popUpContextMenu(menu, with: event, for: self)
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    guard canHandleCommandKeyEquivalent else {
      return super.performKeyEquivalent(with: event)
    }
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

  private var canHandleCommandKeyEquivalent: Bool {
    guard let window else { return true }
    return window.firstResponder === self
  }

  override func copy(_ sender: Any?) {
    guard let selectedText else { return }
    pasteboard.clearContents()
    pasteboard.setString(selectedText, forType: .string)
  }

  override func insertText(_ insertString: Any, replacementRange: NSRange) {
    activationHandler?()
    scrollToBottomHandler?()
    guard let text = committedText(from: insertString), !text.isEmpty else { return }
    inputHandler?(Data(text.utf8))
  }

  override func paste(_ sender: Any?) {
    activationHandler?()
    guard let text = pasteboard.string(forType: .string), !text.isEmpty else {
      return
    }
    scrollToBottomHandler?()
    if let pasteHandler {
      pasteHandler(text)
    } else {
      inputHandler?(Data(text.utf8))
    }
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

  private func committedText(from string: Any) -> String? {
    if let attributed = string as? NSAttributedString {
      return attributed.string
    }
    return string as? String
  }
}

private extension NSMenu {
  func removeTerminalIncompatibleSystemItems() {
    allowsContextMenuPlugIns = false
    autoenablesItems = false
    for item in items {
      item.submenu?.removeTerminalIncompatibleSystemItems()
    }
    for item in items.reversed() where item.isTerminalIncompatibleSystemItem {
      removeItem(item)
    }
    trimRedundantSeparators()
  }

  private func trimRedundantSeparators() {
    while items.first?.isSeparatorItem == true {
      removeItem(at: 0)
    }
    while items.last?.isSeparatorItem == true {
      removeItem(at: max(0, numberOfItems - 1))
    }

    var previousWasSeparator = false
    for index in stride(from: numberOfItems - 1, through: 0, by: -1) {
      let item = items[index]
      if item.isSeparatorItem, previousWasSeparator {
        removeItem(at: index)
      }
      previousWasSeparator = item.isSeparatorItem
    }
  }
}

private extension NSMenuItem {
  var isTerminalIncompatibleSystemItem: Bool {
    let normalizedTitle = title
      .replacingOccurrences(of: " ", with: "")
      .replacingOccurrences(of: "-", with: "")
      .lowercased()
    return normalizedTitle.contains("autofill")
      || normalizedTitle.contains("自动填充")
  }
}

private extension NSPoint {
  func distance(to other: NSPoint) -> CGFloat {
    hypot(x - other.x, y - other.y)
  }
}

import AppKit
import Darwin
import Foundation

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

  public func applyPalette(_ palette: TerminalSurfacePalette) {
    surfaceRegistry.applyPalette(palette)
  }

  public func applyFont(family: String, size: CGFloat) {
    surfaceRegistry.applyFont(family: family, size: size)
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
    state.config.rows = rows
    state.config.cols = cols
    state.vtBridge.resize(cols: cols, rows: rows)
    sessions[id] = state
    PTYLaunch.resize(fileDescriptor: state.fileDescriptor, rows: rows, cols: cols)
    _ = Darwin.kill(state.pid, SIGWINCH)
  }

  public func writeInput(_ data: Data, to id: TerminalSessionID) {
    guard let fd = sessions[id]?.fileDescriptor else { return }
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

  private func makeReadSource(session id: TerminalSessionID, fileDescriptor fd: Int32)
    -> DispatchSourceRead
  {
    let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
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
    state.vtBridge.write(data)
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
    var scrollView: NSScrollView
    var textView: PTYTextView
    var lastFrame: GhosttyTerminalFrame? = nil
    var lastHTMLSnapshot: String? = nil
    var lastCursorFrame: GhosttyTerminalFrame? = nil
  }

  private var surfaces: [TerminalSessionID: SurfaceState] = [:]
  private var palette = TerminalSurfacePalette.dark
  private var fontFamily = FontManager.defaultMonospacedFontName()
  private var fontSize: CGFloat = 14
  private var focusedSessionID: TerminalSessionID?
  private var inputHandler: (@MainActor (TerminalSessionID, Data) -> Void)?
  private var activationHandler: (@MainActor (TerminalSessionID) -> Void)?

  public init() {}

  public func createSurface(session id: TerminalSessionID) {
    let textView = PTYTextView()
    textView.inputHandler = { [weak self] data in
      guard let self else { return }
      inputHandler?(id, data)
    }
    textView.activationHandler = { [weak self] in
      self?.activationHandler?(id)
    }
    textView.scrollToBottomHandler = { [weak textView] in
      textView?.scrollToEndOfDocument(nil)
    }
    textView.isEditable = false
    textView.isSelectable = true
    textView.font = terminalFont(weight: .regular)
    TerminalSurfaceStyle.configureTextView(textView, palette: palette)
    textView.autoresizingMask = [.width, .height]
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.minSize = NSSize(width: 0, height: 0)
    textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    textView.textContainer?.widthTracksTextView = true
    textView.textContainer?.heightTracksTextView = false
    textView.textContainerInset = NSSize(width: 14, height: 12)

    let scrollView = NSScrollView()
    TerminalSurfaceStyle.configureScrollView(scrollView, backgroundColor: palette.background)
    scrollView.documentView = textView
    surfaces[id] = SurfaceState(scrollView: scrollView, textView: textView)
  }

  public func removeSurface(session id: TerminalSessionID) {
    surfaces[id] = nil
  }

  public func viewForSession(_ id: TerminalSessionID) -> NSView? {
    surfaces[id]?.scrollView
  }

  public func selectedText(for id: TerminalSessionID) -> String? {
    guard let textView = surfaces[id]?.textView else { return nil }
    let range = textView.selectedRange()
    guard range.length > 0 else { return nil }
    return (textView.string as NSString).substring(with: range)
  }

  public func applyPalette(_ palette: TerminalSurfacePalette) {
    self.palette = palette
    for (sessionID, surface) in surfaces {
      TerminalSurfaceStyle.configureTextView(surface.textView, palette: palette)
      TerminalSurfaceStyle.configureScrollView(surface.scrollView, backgroundColor: palette.background)
      if let html = surface.lastHTMLSnapshot,
        let attributed = try? attributedTerminalSnapshot(
          fromHTML: html,
          cursorFrame: surface.lastCursorFrame,
          isFocused: isFocused(sessionID)
        )
      {
        replaceText(in: surface.textView, with: attributed, scrollView: surface.scrollView, scrollToEnd: false)
      } else if let frame = surface.lastFrame {
        render(frame, in: surface.textView, isFocused: isFocused(sessionID), scrollToEnd: false)
      }
    }
  }

  public func applyFont(family: String, size: CGFloat) {
    fontFamily = family
    fontSize = size
    for (sessionID, surface) in surfaces {
      surface.textView.font = terminalFont(weight: .regular)
      if let html = surface.lastHTMLSnapshot,
        let attributed = try? attributedTerminalSnapshot(
          fromHTML: html,
          cursorFrame: surface.lastCursorFrame,
          isFocused: isFocused(sessionID)
        )
      {
        replaceText(in: surface.textView, with: attributed, scrollView: surface.scrollView, scrollToEnd: false)
      } else if let frame = surface.lastFrame {
        render(frame, in: surface.textView, isFocused: isFocused(sessionID), scrollToEnd: false)
      }
      surface.textView.window?.invalidateCursorRects(for: surface.textView)
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
        replaceText(in: surface.textView, with: attributed, scrollView: surface.scrollView, scrollToEnd: false)
      } else if let frame = surface.lastFrame {
        render(frame, in: surface.textView, isFocused: isFocused(sessionID), scrollToEnd: false)
      }
    }
  }

  public func focusSessionView(_ id: TerminalSessionID?) {
    guard let id, let textView = surfaces[id]?.textView else { return }
    textView.window?.makeFirstResponder(textView)
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

  private func render(_ bridge: GhosttyVTBridge, surface: inout SurfaceState, session id: TerminalSessionID) {
    let shouldFollowOutput = isScrolledToBottom(surface.scrollView)
    let cursorFrame = try? bridge.frame()
    if let html = try? bridge.htmlText(),
      let attributed = try? attributedTerminalSnapshot(fromHTML: html, cursorFrame: cursorFrame, isFocused: isFocused(id))
    {
      surface.lastHTMLSnapshot = html
      surface.lastFrame = nil
      surface.lastCursorFrame = cursorFrame
      replaceText(
        in: surface.textView,
        with: attributed,
        scrollView: surface.scrollView,
        scrollToEnd: shouldFollowOutput
      )
    } else if let frame = try? bridge.frame() {
      surface.lastHTMLSnapshot = nil
      surface.lastFrame = frame
      surface.lastCursorFrame = nil
      render(frame, in: surface.textView, isFocused: isFocused(id), scrollToEnd: shouldFollowOutput)
    } else if let text = try? bridge.plainText() {
      surface.lastHTMLSnapshot = nil
      surface.lastFrame = nil
      surface.lastCursorFrame = nil
      replaceText(
        in: surface.textView,
        with: NSAttributedString(string: text, attributes: [
          .font: terminalFont(weight: .regular),
          .foregroundColor: palette.foreground,
          .backgroundColor: palette.background,
        ]),
        scrollView: surface.scrollView,
        scrollToEnd: shouldFollowOutput
      )
    }
  }

  private func render(_ frame: GhosttyTerminalFrame, in view: NSTextView, isFocused: Bool, scrollToEnd: Bool) {
    view.textStorage?.setAttributedString(
      TerminalAttributedRenderer(
        fontFamily: fontFamily,
        fontSize: fontSize,
        palette: palette,
        isFocused: isFocused
      )
        .attributedString(for: frame)
    )
    view.window?.invalidateCursorRects(for: view)
    if scrollToEnd {
      view.scrollToEndOfDocument(nil)
    }
  }

  private func replaceText(
    in textView: NSTextView,
    with attributed: NSAttributedString,
    scrollView: NSScrollView,
    scrollToEnd: Bool
  ) {
    let previousOrigin = scrollView.contentView.bounds.origin
    textView.textStorage?.setAttributedString(attributed)
    textView.window?.invalidateCursorRects(for: textView)
    if scrollToEnd {
      textView.scrollToEndOfDocument(nil)
    } else {
      scrollView.contentView.scroll(to: previousOrigin)
      scrollView.reflectScrolledClipView(scrollView.contentView)
    }
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
    let cursorIndex = textIndexForCursor(frame: cursorFrame, text: mutable.string as NSString)
    ensureCursorIndex(cursorIndex, in: mutable)
    guard mutable.length > 0 else { return mutable }
    let safeIndex = min(cursorIndex, mutable.length - 1)
    mutable.addAttributes(
      [
        .font: terminalFont(weight: .regular),
        .foregroundColor: palette.cursorForeground,
        .backgroundColor: palette.cursorBackground,
      ],
      range: NSRange(location: safeIndex, length: 1)
    )
    return mutable
  }

  private func ensureCursorIndex(_ cursorIndex: Int, in attributed: NSMutableAttributedString) {
    guard cursorIndex >= attributed.length else { return }
    let missing = cursorIndex - attributed.length + 1
    let filler = String(repeating: " ", count: missing)
    attributed.append(NSAttributedString(string: filler, attributes: [
      .font: terminalFont(weight: .regular),
      .foregroundColor: palette.foreground,
      .backgroundColor: palette.background,
    ]))
  }

  private func textIndexForCursor(frame: GhosttyTerminalFrame, text: NSString) -> Int {
    let targetRow = max(0, frame.cursorY)
    var row = 0
    var lineStart = 0
    while row < targetRow {
      let searchRange = NSRange(location: lineStart, length: max(0, text.length - lineStart))
      let newline = text.range(of: "\n", options: [], range: searchRange)
      guard newline.location != NSNotFound else {
        return text.length
      }
      lineStart = newline.location + 1
      row += 1
    }
    let lineEndRange = NSRange(location: lineStart, length: max(0, text.length - lineStart))
    let newline = text.range(of: "\n", options: [], range: lineEndRange)
    let lineEnd = newline.location == NSNotFound ? text.length : newline.location
    return min(lineStart + max(0, frame.cursorX), lineEnd)
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

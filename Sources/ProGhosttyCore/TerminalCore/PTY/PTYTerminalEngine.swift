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

  public func viewForSession(_ id: TerminalSessionID) -> NSView? {
    surfaceRegistry.viewForSession(id)
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
  }

  private let surfaceRegistry: PTYTerminalSurfaceRegistry
  private var sessions: [TerminalSessionID: SessionState] = [:]
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
    let result = try PTYLaunch.spawn(config: config)
    surfaceRegistry.createSurface(session: id)
    let vtBridge = try GhosttyVTBridge(cols: config.cols, rows: config.rows)
    let readSource = makeReadSource(session: id, fileDescriptor: result.fileDescriptor)
    let waitTimer = makeWaitTimer(session: id, pid: result.pid)
    sessions[id] = SessionState(
      config: config,
      pid: result.pid,
      fileDescriptor: result.fileDescriptor,
      readSource: readSource,
      waitTimer: waitTimer,
      oscParser: OscParser(),
      vtBridge: vtBridge
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
    _ = Darwin.kill(state.pid, SIGHUP)
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
  }

  private var surfaces: [TerminalSessionID: SurfaceState] = [:]
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
    textView.isEditable = false
    textView.isSelectable = false
    textView.selectedTextAttributes = [
      .backgroundColor: NSColor.clear,
      .foregroundColor: NSColor(calibratedWhite: 0.86, alpha: 1),
    ]
    textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    textView.textColor = NSColor(calibratedWhite: 0.86, alpha: 1)
    textView.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 1)
    textView.autoresizingMask = [.width, .height]
    textView.isVerticallyResizable = false
    textView.isHorizontallyResizable = false
    textView.textContainerInset = NSSize(width: 14, height: 12)
    textView.insertionPointColor = NSColor(calibratedWhite: 0.9, alpha: 1)

    let scrollView = NSScrollView()
    TerminalSurfaceStyle.configureScrollView(scrollView, backgroundColor: textView.backgroundColor)
    scrollView.documentView = textView
    surfaces[id] = SurfaceState(scrollView: scrollView, textView: textView)
  }

  public func removeSurface(session id: TerminalSessionID) {
    surfaces[id] = nil
  }

  public func viewForSession(_ id: TerminalSessionID) -> NSView? {
    surfaces[id]?.scrollView
  }

  public func setInputHandler(_ handler: (@MainActor (TerminalSessionID, Data) -> Void)?) {
    inputHandler = handler
  }

  public func setActivationHandler(_ handler: (@MainActor (TerminalSessionID) -> Void)?) {
    activationHandler = handler
  }

  public func render(_ bridge: GhosttyVTBridge, session id: TerminalSessionID) {
    guard let textView = surfaces[id]?.textView else { return }
    render(bridge, in: textView)
  }

  private func render(_ bridge: GhosttyVTBridge, in view: NSTextView) {
    if let frame = try? bridge.frame() {
      view.textStorage?.setAttributedString(TerminalAttributedRenderer().attributedString(for: frame))
    } else if let attributed = try? attributedTerminalSnapshot(from: bridge) {
      view.textStorage?.setAttributedString(attributed)
    } else if let text = try? bridge.plainText() {
      view.string = text
    }
    view.scrollToEndOfDocument(nil)
  }

  private func attributedTerminalSnapshot(from bridge: GhosttyVTBridge) throws -> NSAttributedString {
    let html = try bridge.htmlText()
    let wrapped =
      """
      <!doctype html>
      <html>
      <head>
      <meta charset="utf-8">
      <style>
      body {
        margin: 0;
        background: #141416;
        color: #dbdbdb;
        font-family: -apple-system-monospaced, Menlo, monospace;
        font-size: 13px;
        white-space: pre;
      }
      pre { margin: 0; }
      </style>
      </head>
      <body><pre>\(html)</pre></body>
      </html>
      """
    let data = Data(wrapped.utf8)
    let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
      .documentType: NSAttributedString.DocumentType.html,
      .characterEncoding: String.Encoding.utf8.rawValue,
    ]
    let rendered = try NSMutableAttributedString(data: data, options: options, documentAttributes: nil)
    rendered.addAttributes(
      [
        .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
        .backgroundColor: NSColor(calibratedWhite: 0.08, alpha: 1),
      ],
      range: NSRange(location: 0, length: rendered.length)
    )
    return rendered
  }
}

private final class PTYTextView: NSTextView {
  var inputHandler: ((Data) -> Void)?
  var activationHandler: (() -> Void)?

  override var acceptsFirstResponder: Bool { true }

  override func mouseDown(with event: NSEvent) {
    activationHandler?()
    window?.makeFirstResponder(self)
    super.mouseDown(with: event)
  }

  override func keyDown(with event: NSEvent) {
    activationHandler?()
    if let data = encodedInput(for: event) {
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

  override func paste(_ sender: Any?) {
    activationHandler?()
    guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
      return
    }
    inputHandler?(Data(text.utf8))
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

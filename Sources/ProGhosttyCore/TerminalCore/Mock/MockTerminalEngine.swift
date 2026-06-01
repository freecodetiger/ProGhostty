import AppKit
import Foundation

@MainActor
public final class MockTerminalEngine: TerminalSessionManager, TerminalSurfaceRegistry {
  private struct SessionState {
    var config: TerminalSessionConfig
    var view: NSTextView
    var inputBuffer: String = ""
  }

  private var sessions: [TerminalSessionID: SessionState] = [:]
  private var palette = TerminalSurfacePalette.dark
  private var fontFamily = FontManager.defaultMonospacedFontName()
  private var fontSize: CGFloat = 14
  private let continuation: AsyncStream<TerminalEvent>.Continuation
  private var inputHandler: (@MainActor (TerminalSessionID, Data) -> Void)?
  private var pasteHandler: (@MainActor (TerminalSessionID, String) -> Void)?
  private var activationHandler: (@MainActor (TerminalSessionID) -> Void)?
  public let events: AsyncStream<TerminalEvent>

  public init() {
    var continuation: AsyncStream<TerminalEvent>.Continuation!
    events = AsyncStream { continuation = $0 }
    self.continuation = continuation
  }

  public func createSession(config: TerminalSessionConfig) throws -> TerminalSessionID {
    let id = TerminalSessionID()
    let textView = NSTextView()
    textView.isEditable = false
    textView.isSelectable = true
    textView.font = terminalFont()
    TerminalSurfaceStyle.configureTextView(textView, palette: palette)
    textView.string =
      "ProGhostty mock terminal\n\(config.workingDirectory ?? FileManager.default.currentDirectoryPath) $ "
    sessions[id] = SessionState(config: config, view: textView)
    continuation.yield(.sessionCreated(id))
    if let cwd = config.workingDirectory {
      continuation.yield(.cwdChanged(session: id, cwd: cwd))
    }
    return id
  }

  public func closeSession(_ id: TerminalSessionID) {
    sessions.removeValue(forKey: id)
    continuation.yield(.sessionClosed(id))
  }

  public func resizeSession(_ id: TerminalSessionID, rows: Int, cols: Int) {
    sessions[id]?.config.rows = rows
    sessions[id]?.config.cols = cols
  }

  public func writeInput(_ data: Data, to id: TerminalSessionID) {
    guard var state = sessions[id] else { return }
    let text = String(decoding: data, as: UTF8.self)
    append(text, to: state.view)
    state.inputBuffer += text

    guard state.inputBuffer.contains("\n") else {
      sessions[id] = state
      return
    }

    let pieces = state.inputBuffer.split(separator: "\n", omittingEmptySubsequences: false)
    let pending = pieces.last.map(String.init) ?? ""
    let commands = pieces.dropLast().map(String.init)
    state.inputBuffer = pending
    sessions[id] = state

    for command in commands where !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      run(command: command, session: id)
    }
  }

  public func writePaste(_ text: String, to id: TerminalSessionID) {
    writeInput(Data(text.utf8), to: id)
  }

  public func workingDirectory(for id: TerminalSessionID) -> String? {
    sessions[id]?.config.workingDirectory ?? FileManager.default.currentDirectoryPath
  }

  public func controlToken(for id: TerminalSessionID) -> String? {
    nil
  }

  public func hasForegroundProcess(in id: TerminalSessionID) -> Bool {
    false
  }

  public func viewForSession(_ id: TerminalSessionID) -> NSView? {
    guard let textView = sessions[id]?.view else {
      return nil
    }

    let scrollView = NSScrollView()
    TerminalSurfaceStyle.configureScrollView(
      scrollView,
      backgroundColor: palette.background
    )
    scrollView.documentView = textView
    return scrollView
  }

  public func selectedText(for id: TerminalSessionID) -> String? {
    guard let textView = sessions[id]?.view else { return nil }
    let range = textView.selectedRange()
    guard range.length > 0 else { return nil }
    return (textView.string as NSString).substring(with: range)
  }

  public func rendererDiagnostics(for id: TerminalSessionID) -> TerminalRendererDiagnostics? {
    nil
  }

  public func applyPalette(_ palette: TerminalSurfacePalette) {
    self.palette = palette
    for state in sessions.values {
      TerminalSurfaceStyle.configureTextView(state.view, palette: palette)
    }
  }

  public func applyFont(family: String, size: CGFloat, cjkFallbackFamily: String? = nil) {
    fontFamily = family
    fontSize = size
    for state in sessions.values {
      state.view.font = terminalFont()
    }
  }

  public func applyRendererOptions(_ options: TerminalRendererOptions) {}

  public func setFocusedSession(_ id: TerminalSessionID?) {}
  public func focusSessionView(_ id: TerminalSessionID?) {}

  public func setInputHandler(_ handler: (@MainActor (TerminalSessionID, Data) -> Void)?) {
    inputHandler = handler
  }

  public func setPasteHandler(_ handler: (@MainActor (TerminalSessionID, String) -> Void)?) {
    pasteHandler = handler
  }

  public func setActivationHandler(_ handler: (@MainActor (TerminalSessionID) -> Void)?) {
    activationHandler = handler
  }

  public func setLinkHoverHandler(_ handler: (@MainActor (TerminalSessionID, Bool) -> Void)?) {}
  public func setLinkTargetHandler(_ handler: (@MainActor (TerminalSessionID, TerminalLinkTarget) -> Void)?) {}

  private func run(command: String, session id: TerminalSessionID) {
    guard let state = sessions[id] else { return }
    let cwd = state.config.workingDirectory ?? FileManager.default.currentDirectoryPath

    let shell = state.config.shellPath
    let environment = state.config.environment
    Task { [weak self] in
      let result = await Task.detached {
        Self.execute(command: command, shell: shell, cwd: cwd, environment: environment)
      }.value

      guard let self else { return }
      if !result.output.isEmpty {
        self.append(result.output, toSession: id)
        self.continuation.yield(.output(session: id, data: Data(result.output.utf8)))
      }
      self.append("\(cwd) $ ", toSession: id)
    }
  }

  private nonisolated static func execute(
    command: String, shell: String, cwd: String, environment: [String: String]
  ) -> (output: String, exitCode: Int) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: shell)
    process.arguments = ["-lc", command]
    process.currentDirectoryURL = URL(fileURLWithPath: cwd)
    process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }

    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe

    do {
      try process.run()
      process.waitUntilExit()
      let data = pipe.fileHandleForReading.readDataToEndOfFile()
      return (String(decoding: data, as: UTF8.self), Int(process.terminationStatus))
    } catch {
      return ("proghostty: \(error.localizedDescription)\n", 127)
    }
  }

  private func append(_ text: String, toSession id: TerminalSessionID) {
    guard let view = sessions[id]?.view else { return }
    append(text, to: view)
  }

  private func append(_ text: String, to view: NSTextView) {
    view.textStorage?.append(NSAttributedString(string: text))
    view.scrollToEndOfDocument(nil)
  }

  private func terminalFont() -> NSFont {
    NSFont(name: fontFamily, size: fontSize)
      ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
  }
}

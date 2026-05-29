import AppKit
import Foundation

public struct TerminalInputRenderSnapshot: Equatable {
  public var generation: Int
  public var cursorRect: NSRect?
  public var isFocused: Bool
  public var hasMarkedText: Bool

  public init(generation: Int, cursorRect: NSRect?, isFocused: Bool, hasMarkedText: Bool) {
    self.generation = generation
    self.cursorRect = cursorRect
    self.isFocused = isFocused
    self.hasMarkedText = hasMarkedText
  }
}

public enum TerminalInputEvent {
  case keyDown(isCompositionMethod: Bool)
  case setMarkedText(String, selectedRange: NSRange)
  case insertText(String)
  case unmarkText
  case render(TerminalInputRenderSnapshot)
  case focusChanged(Bool)
}

public struct TerminalInputPresentationSnapshot: Equatable {
  public var cursorRect: NSRect?
  public var markedTextOverlay: GridMarkedTextOverlay?
  public var markedTextString: String?
  public var cursorSuppressed: Bool

  var compositionAnchorRect: NSRect? {
    cursorRect
  }

  var markedText: String? {
    markedTextString
  }

  public init(
    cursorRect: NSRect?,
    markedTextOverlay: GridMarkedTextOverlay?,
    markedTextString: String?,
    cursorSuppressed: Bool
  ) {
    self.cursorRect = cursorRect
    self.markedTextOverlay = markedTextOverlay
    self.markedTextString = markedTextString
    self.cursorSuppressed = cursorSuppressed
  }
}

public final class TerminalInputStateMachine {
  private enum CompositionPhase: Equatable {
    case idle
    case pending(anchorRect: NSRect?)
    case active(anchorRect: NSRect?)

    var anchorRect: NSRect? {
      switch self {
      case .idle:
        return nil
      case .pending(let anchorRect), .active(let anchorRect):
        return anchorRect
      }
    }

    var isComposing: Bool {
      self != .idle
    }
  }

  private var phase: CompositionPhase = .idle
  private var latestRenderSnapshot: TerminalInputRenderSnapshot?
  private var lastStableCursorRect: NSRect?
  private var lastCommittedCursorRect: NSRect?
  private var markedTextString: String?
  private var cursorSuppressed = false

  public init() {}

  @discardableResult
  public func ingestRenderSnapshot(_ snapshot: TerminalInputRenderSnapshot) -> TerminalInputPresentationSnapshot {
    handle(.render(snapshot))
  }

  @discardableResult
  public func handle(_ event: TerminalInputEvent) -> TerminalInputPresentationSnapshot {
    switch event {
    case .keyDown(let isCompositionMethod):
      handleKeyDown(isCompositionMethod: isCompositionMethod)
    case .setMarkedText(let string, _):
      beginOrUpdateComposition(markedText: string)
    case .insertText(let string):
      finishComposition(committedText: string)
    case .unmarkText:
      finishComposition()
    case .render(let snapshot):
      ingest(snapshot)
    case .focusChanged(let isFocused):
      handleFocusChanged(isFocused)
    }

    return presentationSnapshot()
  }

  private func handleKeyDown(isCompositionMethod: Bool) {
    guard isCompositionMethod else {
      if markedTextString == nil {
        cursorSuppressed = false
        phase = .idle
      }
      return
    }

    if !phase.isComposing {
      phase = .pending(anchorRect: preferredAnchorRect())
    }
  }

  private func beginOrUpdateComposition(markedText: String) {
    let anchorRect = phase.anchorRect ?? preferredAnchorRect()
    phase = .active(anchorRect: anchorRect)
    markedTextString = markedText
    cursorSuppressed = true
  }

  private func finishComposition(committedText: String? = nil) {
    if let committedText, let anchorRect = phase.anchorRect ?? preferredAnchorRect() {
      lastCommittedCursorRect = advance(anchorRect: anchorRect, committedText: committedText)
      lastStableCursorRect = nil
    }
    phase = .idle
    markedTextString = nil
    cursorSuppressed = false
  }

  private func ingest(_ snapshot: TerminalInputRenderSnapshot) {
    latestRenderSnapshot = snapshot

    guard snapshot.isFocused else {
      finishComposition()
      return
    }

    guard !phase.isComposing, !snapshot.hasMarkedText, let cursorRect = snapshot.cursorRect else {
      return
    }

    lastStableCursorRect = cursorRect
    lastCommittedCursorRect = cursorRect
  }

  private func handleFocusChanged(_ isFocused: Bool) {
    guard !isFocused else {
      return
    }

    finishComposition()
  }

  private func preferredAnchorRect() -> NSRect? {
    lastStableCursorRect ?? lastCommittedCursorRect ?? latestRenderSnapshot?.cursorRect
  }

  private func advance(anchorRect: NSRect, committedText: String) -> NSRect {
    let columns = committedText.terminalEstimatedColumnCount
    guard columns > 0 else { return anchorRect }
    return anchorRect.offsetBy(dx: CGFloat(columns) * anchorRect.width, dy: 0)
  }

  private func presentationSnapshot() -> TerminalInputPresentationSnapshot {
    TerminalInputPresentationSnapshot(
      cursorRect: phase.anchorRect ?? lastCommittedCursorRect ?? lastStableCursorRect,
      markedTextOverlay: nil,
      markedTextString: markedTextString,
      cursorSuppressed: cursorSuppressed
    )
  }
}

private extension String {
  var terminalEstimatedColumnCount: Int {
    guard !isEmpty else { return 0 }
    return reduce(0) { partialResult, character in
      partialResult + (character.unicodeScalars.allSatisfy(\.isASCII) ? 1 : 2)
    }
  }
}

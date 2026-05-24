import Foundation

public struct TerminalSideInputDraft: Equatable, Sendable {
  public var paneID: UUID
  public var sessionID: TerminalSessionID
  public var text: String
  public var focusRequestID: Int

  public init(paneID: UUID, sessionID: TerminalSessionID, text: String, focusRequestID: Int) {
    self.paneID = paneID
    self.sessionID = sessionID
    self.text = text
    self.focusRequestID = focusRequestID
  }

  public var isEmpty: Bool {
    text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }
}

public struct TerminalSideInputFocusRequest: Equatable, Sendable {
  public var paneID: UUID
  public var requestID: Int

  public init(paneID: UUID, requestID: Int) {
    self.paneID = paneID
    self.requestID = requestID
  }
}

public struct TerminalSideInputStore: Equatable, Sendable {
  private var draftsByPaneID: [UUID: TerminalSideInputDraft]
  private var nextFocusRequestID: Int
  public private(set) var pendingFocusRequest: TerminalSideInputFocusRequest?

  public static let empty = TerminalSideInputStore()

  public var drafts: [TerminalSideInputDraft] {
    Array(draftsByPaneID.values)
  }

  public var paneIDs: Set<UUID> {
    Set(draftsByPaneID.keys)
  }

  public init(
    draftsByPaneID: [UUID: TerminalSideInputDraft] = [:],
    nextFocusRequestID: Int = 0,
    pendingFocusRequest: TerminalSideInputFocusRequest? = nil
  ) {
    self.draftsByPaneID = draftsByPaneID
    self.nextFocusRequestID = nextFocusRequestID
    self.pendingFocusRequest = pendingFocusRequest
  }

  public func draft(for paneID: UUID) -> TerminalSideInputDraft? {
    draftsByPaneID[paneID]
  }

  public mutating func open(paneID: UUID, sessionID: TerminalSessionID) {
    nextFocusRequestID += 1
    if draftsByPaneID[paneID] == nil {
      draftsByPaneID[paneID] = TerminalSideInputDraft(
        paneID: paneID,
        sessionID: sessionID,
        text: "",
        focusRequestID: nextFocusRequestID
      )
    } else {
      draftsByPaneID[paneID]?.sessionID = sessionID
      draftsByPaneID[paneID]?.focusRequestID = nextFocusRequestID
    }
    pendingFocusRequest = TerminalSideInputFocusRequest(paneID: paneID, requestID: nextFocusRequestID)
  }

  public mutating func updateText(_ text: String, for paneID: UUID) {
    guard draftsByPaneID[paneID] != nil else { return }
    draftsByPaneID[paneID]?.text = text
  }

  public mutating func closeIfEmpty(paneID: UUID) {
    guard draftsByPaneID[paneID]?.isEmpty == true else { return }
    close(paneID: paneID)
  }

  public mutating func close(paneID: UUID) {
    draftsByPaneID[paneID] = nil
    if pendingFocusRequest?.paneID == paneID {
      pendingFocusRequest = nil
    }
  }

  @discardableResult public mutating func removeMissingPanes(_ paneIDs: Set<UUID>) -> Bool {
    let before = draftsByPaneID.count
    draftsByPaneID = draftsByPaneID.filter { paneIDs.contains($0.key) }
    if let pendingFocusRequest, !paneIDs.contains(pendingFocusRequest.paneID) {
      self.pendingFocusRequest = nil
    }
    return draftsByPaneID.count != before
  }

  public mutating func submit(paneID: UUID) -> (sessionID: TerminalSessionID, text: String)? {
    guard let draft = draftsByPaneID[paneID] else { return nil }
    close(paneID: paneID)
    guard !draft.isEmpty else { return nil }
    return (draft.sessionID, draft.text)
  }

  public mutating func markFocusRequestHandled(paneID: UUID, requestID: Int) {
    guard pendingFocusRequest == TerminalSideInputFocusRequest(paneID: paneID, requestID: requestID) else {
      return
    }
    pendingFocusRequest = nil
  }
}

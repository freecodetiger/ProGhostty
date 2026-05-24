import Foundation
import Testing

@testable import ProGhosttyCore

@Suite("Terminal side input store")
struct TerminalSideInputStoreTests {
  @Test func openCreatesIndependentDraftsPerPane() {
    let paneA = UUID()
    let paneB = UUID()
    let sessionA = TerminalSessionID()
    let sessionB = TerminalSessionID()
    var store = TerminalSideInputStore.empty

    store.open(paneID: paneA, sessionID: sessionA)
    store.updateText("from A", for: paneA)
    store.open(paneID: paneB, sessionID: sessionB)

    #expect(store.draft(for: paneA)?.text == "from A")
    #expect(store.draft(for: paneA)?.sessionID == sessionA)
    #expect(store.draft(for: paneB)?.text == "")
    #expect(store.draft(for: paneB)?.sessionID == sessionB)
  }

  @Test func openRequestsFocusForOpenedPaneOnly() {
    let paneA = UUID()
    let paneB = UUID()
    var store = TerminalSideInputStore.empty

    store.open(paneID: paneA, sessionID: TerminalSessionID())
    let firstRequest = store.pendingFocusRequest
    store.markFocusRequestHandled(paneID: paneA, requestID: firstRequest?.requestID ?? -1)
    store.open(paneID: paneB, sessionID: TerminalSessionID())

    #expect(firstRequest?.paneID == paneA)
    #expect(store.pendingFocusRequest?.paneID == paneB)
    #expect(store.pendingFocusRequest?.requestID != firstRequest?.requestID)
  }

  @Test func reopeningExistingDraftPreservesTextAndRequestsFocusAgain() {
    let paneID = UUID()
    let firstSession = TerminalSessionID()
    let secondSession = TerminalSessionID()
    var store = TerminalSideInputStore.empty
    store.open(paneID: paneID, sessionID: firstSession)
    store.updateText("draft", for: paneID)
    let firstRequestID = store.pendingFocusRequest?.requestID

    store.open(paneID: paneID, sessionID: secondSession)

    #expect(store.draft(for: paneID)?.text == "draft")
    #expect(store.draft(for: paneID)?.sessionID == secondSession)
    #expect(store.pendingFocusRequest?.paneID == paneID)
    #expect(store.pendingFocusRequest?.requestID != firstRequestID)
  }

  @Test func handledFocusRequestIsClearedOnlyWhenItStillMatches() {
    let paneID = UUID()
    var store = TerminalSideInputStore.empty
    store.open(paneID: paneID, sessionID: TerminalSessionID())
    let staleRequestID = store.pendingFocusRequest?.requestID ?? -1
    store.open(paneID: paneID, sessionID: TerminalSessionID())

    store.markFocusRequestHandled(paneID: paneID, requestID: staleRequestID)
    #expect(store.pendingFocusRequest != nil)

    let currentRequestID = store.pendingFocusRequest?.requestID ?? -1
    store.markFocusRequestHandled(paneID: paneID, requestID: currentRequestID)
    #expect(store.pendingFocusRequest == nil)
  }

  @Test func closeIfEmptyOnlyRemovesEmptyDrafts() {
    let paneA = UUID()
    let paneB = UUID()
    var store = TerminalSideInputStore.empty
    store.open(paneID: paneA, sessionID: TerminalSessionID())
    store.open(paneID: paneB, sessionID: TerminalSessionID())
    store.updateText("keep me", for: paneB)

    store.closeIfEmpty(paneID: paneA)
    store.closeIfEmpty(paneID: paneB)

    #expect(store.draft(for: paneA) == nil)
    #expect(store.draft(for: paneB)?.text == "keep me")
  }

  @Test func submitReturnsExactTextAndClosesDraftWithoutAddingNewline() {
    let paneID = UUID()
    let sessionID = TerminalSessionID()
    var store = TerminalSideInputStore.empty
    store.open(paneID: paneID, sessionID: sessionID)
    store.updateText("hello\nworld", for: paneID)

    let submitted = store.submit(paneID: paneID)

    #expect(submitted?.sessionID == sessionID)
    #expect(submitted?.text == "hello\nworld")
    #expect(store.draft(for: paneID) == nil)
  }

  @Test func submitIgnoresWhitespaceOnlyTextAndClosesDraft() {
    let paneID = UUID()
    var store = TerminalSideInputStore.empty
    store.open(paneID: paneID, sessionID: TerminalSessionID())
    store.updateText("  \n\t", for: paneID)

    let submitted = store.submit(paneID: paneID)

    #expect(submitted == nil)
    #expect(store.draft(for: paneID) == nil)
  }

  @Test func removeMissingPanesDestroysDraftsForClosedPanes() {
    let surviving = UUID()
    let closed = UUID()
    var store = TerminalSideInputStore.empty
    store.open(paneID: surviving, sessionID: TerminalSessionID())
    store.open(paneID: closed, sessionID: TerminalSessionID())

    store.removeMissingPanes([surviving])

    #expect(store.draft(for: surviving) != nil)
    #expect(store.draft(for: closed) == nil)
  }
}

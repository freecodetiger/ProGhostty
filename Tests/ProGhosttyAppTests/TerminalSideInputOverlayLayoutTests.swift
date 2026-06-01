import AppKit
import Testing

@testable import ProGhosttyApp
@testable import ProGhosttyCore

@MainActor
@Suite("Terminal side input overlay layout")
struct TerminalSideInputOverlayLayoutTests {
  @Test func openingSideInputDoesNotChangePaneFittingWidth() {
    let paneID = UUID()
    let sessionID = TerminalSessionID()
    let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 500))
    let pane = TerminalPane(paneId: paneID, sessionId: sessionID)
    let controller = TerminalPaneViewController(pane: pane, contentView: contentView)
    controller.loadView()
    controller.view.frame = NSRect(x: 0, y: 0, width: 900, height: 500)

    controller.update(
      isSelected: true,
      onSelect: { _ in },
      onSplit: { _, _ in },
      onClose: { _ in },
      onPasteDroppedPaths: { _, _ in },
      menuText: AppText(language: "en"),
      palette: .dark,
      onResize: { _, _, _ in },
      isResizeSensitiveScreen: { _ in false },
      onSplitAvailabilityChanged: { _, _, _, _ in },
      onWorkspaceSwitcher: {},
      onSettings: {},
      sideInputStore: .empty,
      onSideInputTextChanged: { _, _ in },
      onSubmitSideInput: { _ in },
      onCloseEmptySideInput: { _ in },
      onCancelSideInput: { _ in },
      sideInputPlaceholder: "Type without moving the terminal view",
      onSideInputFocusRequestHandled: { _, _ in },
      keyboardShortcuts: .defaults
    )
    controller.view.layoutSubtreeIfNeeded()
    let fittingWithoutOverlay = controller.view.fittingSize.width

    var store = TerminalSideInputStore.empty
    store.open(paneID: paneID, sessionID: sessionID)
    controller.update(
      isSelected: true,
      onSelect: { _ in },
      onSplit: { _, _ in },
      onClose: { _ in },
      onPasteDroppedPaths: { _, _ in },
      menuText: AppText(language: "en"),
      palette: .dark,
      onResize: { _, _, _ in },
      isResizeSensitiveScreen: { _ in false },
      onSplitAvailabilityChanged: { _, _, _, _ in },
      onWorkspaceSwitcher: {},
      onSettings: {},
      sideInputStore: store,
      onSideInputTextChanged: { _, _ in },
      onSubmitSideInput: { _ in },
      onCloseEmptySideInput: { _ in },
      onCancelSideInput: { _ in },
      sideInputPlaceholder: "Type without moving the terminal view",
      onSideInputFocusRequestHandled: { _, _ in },
      keyboardShortcuts: .defaults
    )
    controller.view.layoutSubtreeIfNeeded()

    #expect(contentView.frame.width == 900)
    #expect(controller.view.fittingSize.width == fittingWithoutOverlay)
  }
}

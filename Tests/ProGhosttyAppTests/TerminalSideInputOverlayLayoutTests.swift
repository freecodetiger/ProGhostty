import AppKit
import Testing

@testable import ProGhosttyApp
@testable import ProGhosttyCore

@MainActor
@Suite("Terminal side input overlay layout")
struct TerminalSideInputOverlayLayoutTests {
  @Test func selectingLightPaneKeepsLightPalette() {
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
      onRename: {},
      onPasteDroppedPaths: { _, _ in },
      menuText: AppText(language: "en"),
      palette: .light,
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
      sideInputPlaceholder: "",
      onSideInputFocusRequestHandled: { _, _ in },
      keyboardShortcuts: .defaults
    )

    controller.setSelected(false)

    #expect(controller.view.layer?.backgroundColor?.sameRGB(as: TerminalSurfacePalette.light.background.cgColor) == true)
  }

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
      onRename: {},
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
      onRename: {},
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

private extension CGColor {
  func sameRGB(as other: CGColor) -> Bool {
    guard
      let lhs = NSColor(cgColor: self)?.usingColorSpace(.deviceRGB),
      let rhs = NSColor(cgColor: other)?.usingColorSpace(.deviceRGB)
    else {
      return false
    }
    return abs(lhs.redComponent - rhs.redComponent) < 0.001
      && abs(lhs.greenComponent - rhs.greenComponent) < 0.001
      && abs(lhs.blueComponent - rhs.blueComponent) < 0.001
  }
}

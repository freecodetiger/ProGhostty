import AppKit
import ProGhosttyCore
import QuartzCore
import SwiftUI

struct TerminalCanvasView: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    TerminalView()
      .background(Color(nsColor: model.terminalBackgroundColor))
  }
}

struct TerminalView: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    if let workspace = model.activeWorkspace {
      TerminalTreeLayoutView(root: workspace.layout.root)
    } else {
      Text("No active workspace")
        .font(.system(size: model.settings.fontSize, design: .monospaced))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(12)
        .background(Color(nsColor: model.terminalBackgroundColor))
    }
  }
}

private struct TerminalTreeLayoutView: NSViewControllerRepresentable {
  @EnvironmentObject private var model: AppModel
  let root: PaneNode

  func makeNSViewController(context: Context) -> SplitContainerViewController {
    SplitContainerViewController()
  }

  func updateNSViewController(_ controller: SplitContainerViewController, context: Context) {
    DebugLog.write("TerminalTreeLayoutView update leaves=\(PaneTreeReducer.listLeaves(in: root).count)")
    let paneIDs = Set(PaneTreeReducer.listLeaves(in: root).map(\.paneId))
    if !model.sideInputStore.paneIDs.isSubset(of: paneIDs) {
      DispatchQueue.main.async {
        model.pruneSideInputs(to: paneIDs)
      }
    }
    controller.update(
      root: root,
      selectedPaneID: model.selectedPaneID,
      onSelect: { model.selectPane($0) },
      onSplit: { paneID, axis in model.splitPane(paneID, axis: axis) },
      onClose: { paneID in model.closePane(paneID) },
      onPasteDroppedPaths: { paneID, text in model.pasteDroppedPaths(text, intoPane: paneID) },
      menuText: model.appText,
      keyboardShortcuts: model.settings.keyboardShortcuts,
      palette: model.terminalPalette,
      onResize: { paneID, rows, cols in model.resizePane(paneID, rows: rows, cols: cols) },
      isResizeSensitiveScreen: { paneID in model.paneIsResizeSensitiveScreen(paneID) },
      onSplitAvailabilityChanged: { paneID, size, canSplitRight, canSplitDown in
        model.updatePaneSplitAvailability(
          paneID,
          size: size,
          canSplitRight: canSplitRight,
          canSplitDown: canSplitDown
        )
      },
      onRatioChanged: { splitID, ratio in model.updateSplitRatio(splitID, ratio: ratio) },
      onWorkspaceSwitcher: { model.openWorkspaceSwitcher() },
      onSettings: { model.openSettingsWindow() },
      sideInputStore: model.sideInputStore,
      onSideInputTextChanged: { paneID, text in model.updateSideInputText(text, for: paneID) },
      onSubmitSideInput: { paneID in model.submitSideInput(for: paneID) },
      onCloseEmptySideInput: { paneID in model.closeEmptySideInput(for: paneID) },
      onCancelSideInput: { paneID in model.closeSideInputAfterEscape(for: paneID) },
      sideInputPlaceholder: model.appText.sideInputPlaceholder,
      onSideInputFocusRequestHandled: { paneID, requestID in
        model.markSideInputFocusRequestHandled(paneID: paneID, requestID: requestID)
      },
      viewForSession: { model.surfaceView(for: $0) }
    )
  }
}

final class SplitContainerViewController: NSViewController, NSSplitViewDelegate {
  private var currentRoot: PaneNode?
  private var selectedPaneID: UUID?
  private var splitId: UUID?
  private var targetRatio: Double = 0.5
  private var isApplyingProgrammaticRatio = false
  private var hasAppliedInitialRatio = false
  private var onSelect: ((UUID) -> Void)?
  private var onSplit: ((UUID, SplitAxis) -> Void)?
  private var onClose: ((UUID) -> Void)?
  private var onPasteDroppedPaths: ((UUID, String) -> Void)?
  private var menuText = AppText(language: "system")
  private var keyboardShortcuts = KeyboardShortcutSettings.defaults
  private var palette = TerminalSurfacePalette.dark
  private var onResize: ((UUID, Int, Int) -> Void)?
  private var isResizeSensitiveScreen: ((UUID) -> Bool)?
  private var onSplitAvailabilityChanged: ((UUID, NSSize, Bool, Bool) -> Void)?
  private var onRatioChanged: ((UUID, Double) -> Void)?
  private var onWorkspaceSwitcher: (() -> Void)?
  private var onSettings: (() -> Void)?
  private var sideInputStore = TerminalSideInputStore.empty
  private var onSideInputTextChanged: ((UUID, String) -> Void)?
  private var onSubmitSideInput: ((UUID) -> Void)?
  private var onCloseEmptySideInput: ((UUID) -> Void)?
  private var onCancelSideInput: ((UUID) -> Void)?
  private var sideInputPlaceholder = ""
  private var onSideInputFocusRequestHandled: ((UUID, Int) -> Void)?
  private var viewForSession: ((TerminalSessionID) -> NSView?)?
  private let minimumPaneLength = CGFloat(SplitRatioLayout.minimumPaneLength)
  private var hasMultiplePanes = false

  override func loadView() {
    view = NSView()
    view.wantsLayer = true
  }

  func update(
    root: PaneNode,
    selectedPaneID: UUID?,
    onSelect: @escaping (UUID) -> Void,
    onSplit: @escaping (UUID, SplitAxis) -> Void,
    onClose: @escaping (UUID) -> Void,
    onPasteDroppedPaths: @escaping (UUID, String) -> Void,
    menuText: AppText,
    keyboardShortcuts: KeyboardShortcutSettings,
    palette: TerminalSurfacePalette,
    onResize: @escaping (UUID, Int, Int) -> Void,
    isResizeSensitiveScreen: @escaping (UUID) -> Bool,
    onSplitAvailabilityChanged: @escaping (UUID, NSSize, Bool, Bool) -> Void,
    onRatioChanged: @escaping (UUID, Double) -> Void,
    onWorkspaceSwitcher: @escaping () -> Void,
    onSettings: @escaping () -> Void,
    sideInputStore: TerminalSideInputStore,
    onSideInputTextChanged: @escaping (UUID, String) -> Void,
    onSubmitSideInput: @escaping (UUID) -> Void,
    onCloseEmptySideInput: @escaping (UUID) -> Void,
    onCancelSideInput: @escaping (UUID) -> Void,
    sideInputPlaceholder: String,
    onSideInputFocusRequestHandled: @escaping (UUID, Int) -> Void,
    viewForSession: @escaping (TerminalSessionID) -> NSView?
  ) {
    let leafCount = PaneTreeReducer.listLeaves(in: root).count
    DebugLog.write("SplitContainer update rootLeaves=\(leafCount)")
    hasMultiplePanes = leafCount > 1
    self.selectedPaneID = selectedPaneID
    self.onSelect = onSelect
    self.onSplit = onSplit
    self.onClose = onClose
    self.onPasteDroppedPaths = onPasteDroppedPaths
    self.menuText = menuText
    self.keyboardShortcuts = keyboardShortcuts
    self.palette = palette
    view.layer?.backgroundColor = palette.background.cgColor
    self.onResize = onResize
    self.isResizeSensitiveScreen = isResizeSensitiveScreen
    self.onSplitAvailabilityChanged = onSplitAvailabilityChanged
    self.onRatioChanged = onRatioChanged
    self.onWorkspaceSwitcher = onWorkspaceSwitcher
    self.onSettings = onSettings
    self.sideInputStore = sideInputStore
    self.onSideInputTextChanged = onSideInputTextChanged
    self.onSubmitSideInput = onSubmitSideInput
    self.onCloseEmptySideInput = onCloseEmptySideInput
    self.onCancelSideInput = onCancelSideInput
    self.sideInputPlaceholder = sideInputPlaceholder
    self.onSideInputFocusRequestHandled = onSideInputFocusRequestHandled
    self.viewForSession = viewForSession

    guard let currentRoot else {
      self.currentRoot = root
      DebugLog.write("SplitContainer initial rebuild")
      rebuild(for: root)
      return
    }

    guard currentRoot != root else {
      updatePaneAppearance(in: self, selectedPaneID: selectedPaneID)
      return
    }

    if Self.hasSameStructure(currentRoot, root), let child = children.first,
      sync(node: root, with: child, selectedPaneID: selectedPaneID)
    {
      self.currentRoot = root
      return
    }

    self.currentRoot = root
    DebugLog.write("SplitContainer structural rebuild")
    rebuild(for: root)
  }

  override func viewDidLayout() {
    super.viewDidLayout()
    applyRatioIfNeeded()
  }

  func splitViewDidResizeSubviews(_ notification: Notification) {
    guard
      let splitView = notification.object as? NSSplitView,
      let splitId,
      SplitRatioLayout.shouldPersistRatioChange(
        isUserInitiated: (splitView as? TerminalSplitView)?.isUserResizingDivider == true,
        hasAppliedInitialRatio: hasAppliedInitialRatio,
        isApplyingProgrammaticRatio: isApplyingProgrammaticRatio
      ),
      splitView.arrangedSubviews.count == 2
    else {
      return
    }
    let first = splitView.arrangedSubviews[0]
    let total = splitView.isVertical ? splitView.bounds.width : splitView.bounds.height
    guard total > 1 else { return }
    let firstLength = splitView.isVertical ? first.frame.width : first.frame.height
    let value = SplitRatioLayout.ratio(
      firstLength: Double(firstLength),
      totalLength: Double(total),
      dividerThickness: Double(splitView.dividerThickness)
    )
    onRatioChanged?(splitId, value)
  }

  private func rebuild(for node: PaneNode) {
    DebugLog.write("SplitContainer rebuild nodeLeaves=\(PaneTreeReducer.listLeaves(in: node).count)")
    for child in children {
      child.view.removeFromSuperview()
      child.removeFromParent()
    }
    view.subviews.forEach { $0.removeFromSuperview() }

    let child = makeController(for: node)
    addChild(child)
    child.view.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(child.view)
    NSLayoutConstraint.activate([
      child.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      child.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      child.view.topAnchor.constraint(equalTo: view.topAnchor),
      child.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
  }

  private func makeController(for node: PaneNode) -> NSViewController {
    switch node {
    case .leaf(let pane):
      let controller = TerminalPaneViewController(pane: pane, contentView: viewForSession?(pane.sessionId))
      controller.update(
        isSelected: pane.paneId == selectedPaneID,
        onSelect: { [weak self] paneID in self?.onSelect?(paneID) },
        onSplit: { [weak self] paneID, axis in self?.onSplit?(paneID, axis) },
        onClose: { [weak self] paneID in self?.onClose?(paneID) },
        onPasteDroppedPaths: { [weak self] paneID, text in self?.onPasteDroppedPaths?(paneID, text) },
        menuText: menuText,
        palette: palette,
        onResize: { [weak self] paneID, rows, cols in self?.onResize?(paneID, rows, cols) },
        isResizeSensitiveScreen: { [weak self] paneID in self?.isResizeSensitiveScreen?(paneID) ?? false },
        onSplitAvailabilityChanged: { [weak self] paneID, size, canSplitRight, canSplitDown in
          self?.onSplitAvailabilityChanged?(paneID, size, canSplitRight, canSplitDown)
        },
        onWorkspaceSwitcher: { [weak self] in self?.onWorkspaceSwitcher?() },
        onSettings: { [weak self] in self?.onSettings?() },
        sideInputStore: sideInputStore,
        onSideInputTextChanged: { [weak self] paneID, text in self?.onSideInputTextChanged?(paneID, text) },
        onSubmitSideInput: { [weak self] paneID in self?.onSubmitSideInput?(paneID) },
        onCloseEmptySideInput: { [weak self] paneID in self?.onCloseEmptySideInput?(paneID) },
        onCancelSideInput: { [weak self] paneID in self?.onCancelSideInput?(paneID) },
        sideInputPlaceholder: sideInputPlaceholder,
        onSideInputFocusRequestHandled: { [weak self] paneID, requestID in
          self?.onSideInputFocusRequestHandled?(paneID, requestID)
        },
        keyboardShortcuts: keyboardShortcuts
      )
      return controller
    case .split(let split):
      let controller = SplitContainerViewController()
      controller.splitId = split.id
      controller.targetRatio = split.ratio
      controller.selectedPaneID = selectedPaneID
      controller.onSelect = onSelect
      controller.onSplit = onSplit
      controller.onClose = onClose
      controller.onPasteDroppedPaths = onPasteDroppedPaths
      controller.menuText = menuText
      controller.palette = palette
      controller.hasMultiplePanes = hasMultiplePanes
      controller.onResize = onResize
      controller.isResizeSensitiveScreen = isResizeSensitiveScreen
      controller.onSplitAvailabilityChanged = onSplitAvailabilityChanged
      controller.onRatioChanged = onRatioChanged
      controller.onWorkspaceSwitcher = onWorkspaceSwitcher
      controller.onSettings = onSettings
      controller.sideInputStore = sideInputStore
      controller.onSideInputTextChanged = onSideInputTextChanged
      controller.onSubmitSideInput = onSubmitSideInput
      controller.onCloseEmptySideInput = onCloseEmptySideInput
      controller.onCancelSideInput = onCancelSideInput
      controller.sideInputPlaceholder = sideInputPlaceholder
      controller.onSideInputFocusRequestHandled = onSideInputFocusRequestHandled
      controller.viewForSession = viewForSession
      let splitView = TerminalSplitView()
      splitView.customDividerColor = palette.splitDivider
      controller.configureMinimumLengths(on: splitView, for: split)
      splitView.wantsLayer = true
      splitView.layer?.backgroundColor = palette.background.cgColor
      splitView.isVertical = split.axis == .horizontal
      splitView.dividerStyle = .thin
      splitView.delegate = controller
      splitView.autosaveName = nil
      splitView.onUserResizeFinished = { [weak controller, weak splitView] in
        guard let controller, let splitView else { return }
        controller.persistUserRatio(from: splitView)
      }
      controller.view = splitView

      let first = controller.makeController(for: split.first)
      let second = controller.makeController(for: split.second)
      controller.addChild(first)
      controller.addChild(second)
      splitView.addArrangedSubview(first.view)
      splitView.addArrangedSubview(second.view)
      controller.configureSplitChildView(first.view)
      controller.configureSplitChildView(second.view)
      splitView.setHoldingPriority(.defaultLow, forSubviewAt: 0)
      splitView.setHoldingPriority(.defaultLow, forSubviewAt: 1)
      DispatchQueue.main.async { [weak controller] in
        controller?.applyRatioRecursively()
      }
      return controller
    }
  }

  private func applyRatioIfNeeded() {
    guard let splitView = view as? NSSplitView, splitView.arrangedSubviews.count == 2 else { return }
    let total = splitView.isVertical ? splitView.bounds.width : splitView.bounds.height
    guard total > 1 else { return }
    let first = splitView.arrangedSubviews[0]
    let firstLength = splitView.isVertical ? first.frame.width : first.frame.height
    let current = SplitRatioLayout.ratio(
      firstLength: Double(firstLength),
      totalLength: Double(total),
      dividerThickness: Double(splitView.dividerThickness)
    )
    guard abs(current - targetRatio) > 0.002 else {
      hasAppliedInitialRatio = true
      return
    }
    guard let position = SplitRatioLayout.safeFirstLength(
      totalLength: Double(total),
      dividerThickness: Double(splitView.dividerThickness),
      ratio: targetRatio,
      minimumFirstLength: Double((splitView as? TerminalSplitView)?.minimumFirstLength ?? minimumPaneLength),
      minimumSecondLength: Double((splitView as? TerminalSplitView)?.minimumSecondLength ?? minimumPaneLength)
    ) else {
      DebugLog.write("SplitContainer skip applyRatio split=\(splitId?.uuidString ?? "-") total=\(total) divider=\(splitView.dividerThickness) target=\(targetRatio): insufficient space")
      return
    }
    isApplyingProgrammaticRatio = true
    DebugLog.write("SplitContainer applyRatio split=\(splitId?.uuidString ?? "-") total=\(total) divider=\(splitView.dividerThickness) target=\(targetRatio) position=\(position)")
    splitView.setPosition(CGFloat(position), ofDividerAt: 0)
    splitView.adjustSubviews()
    isApplyingProgrammaticRatio = false
    hasAppliedInitialRatio = true
  }

  private func configureSplitChildView(_ childView: NSView) {
    childView.setContentHuggingPriority(.defaultLow, for: .horizontal)
    childView.setContentHuggingPriority(.defaultLow, for: .vertical)
    childView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    childView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
  }

  private func configureMinimumLengths(on splitView: TerminalSplitView, for split: SplitPane) {
    let first = SplitRatioLayout.minimumContentSize(for: split.first)
    let second = SplitRatioLayout.minimumContentSize(for: split.second)
    switch split.axis {
    case .horizontal:
      splitView.minimumFirstLength = CGFloat(first.width)
      splitView.minimumSecondLength = CGFloat(second.width)
    case .vertical:
      splitView.minimumFirstLength = CGFloat(first.height)
      splitView.minimumSecondLength = CGFloat(second.height)
    }
  }

  private func applyRatioRecursively() {
    applyRatioIfNeeded()
    for child in children {
      (child as? SplitContainerViewController)?.applyRatioRecursively()
    }
  }

  private func persistUserRatio(from splitView: NSSplitView) {
    guard
      let splitId,
      SplitRatioLayout.shouldPersistRatioChange(
        isUserInitiated: true,
        hasAppliedInitialRatio: hasAppliedInitialRatio,
        isApplyingProgrammaticRatio: isApplyingProgrammaticRatio
      ),
      splitView.arrangedSubviews.count == 2
    else {
      return
    }

    let first = splitView.arrangedSubviews[0]
    let total = splitView.isVertical ? splitView.bounds.width : splitView.bounds.height
    guard total > 1 else { return }
    let firstLength = splitView.isVertical ? first.frame.width : first.frame.height
    let value = SplitRatioLayout.ratio(
      firstLength: Double(firstLength),
      totalLength: Double(total),
      dividerThickness: Double(splitView.dividerThickness)
    )
    DebugLog.write("SplitContainer persistUserRatio split=\(splitId) value=\(value)")
    onRatioChanged?(splitId, value)
  }

  private func updatePaneAppearance(in controller: NSViewController, selectedPaneID: UUID?) {
    controller.view.layer?.backgroundColor = palette.background.cgColor
    if let split = controller.view as? TerminalSplitView {
      split.customDividerColor = palette.splitDivider
    }
    if let pane = controller as? TerminalPaneViewController {
      updateLeaf(
        pane,
        isSelected: pane.pane.paneId == selectedPaneID,
        selectedPaneID: selectedPaneID
      )
    }
    for child in controller.children {
      updatePaneAppearance(in: child, selectedPaneID: selectedPaneID)
    }
  }

  private func sync(node: PaneNode, with controller: NSViewController, selectedPaneID: UUID?) -> Bool {
    switch node {
    case .leaf(let pane):
      guard let leaf = controller as? TerminalPaneViewController else { return false }
      updateLeaf(
        leaf,
        isSelected: pane.paneId == selectedPaneID,
        selectedPaneID: selectedPaneID
      )
      return true
    case .split(let split):
      guard let splitController = controller as? SplitContainerViewController else { return false }
      guard splitController.children.count == 2 else { return false }
      splitController.splitId = split.id
      splitController.targetRatio = split.ratio
      splitController.selectedPaneID = selectedPaneID
      splitController.palette = palette
      splitController.hasMultiplePanes = hasMultiplePanes
      splitController.sideInputStore = sideInputStore
      splitController.onSideInputTextChanged = onSideInputTextChanged
      splitController.onSubmitSideInput = onSubmitSideInput
      splitController.onCloseEmptySideInput = onCloseEmptySideInput
      splitController.onCancelSideInput = onCancelSideInput
      splitController.sideInputPlaceholder = sideInputPlaceholder
      splitController.onSideInputFocusRequestHandled = onSideInputFocusRequestHandled
      splitController.view.layer?.backgroundColor = palette.background.cgColor
      if let splitView = splitController.view as? TerminalSplitView {
        splitView.customDividerColor = palette.splitDivider
        splitController.configureMinimumLengths(on: splitView, for: split)
      }
      guard
        sync(node: split.first, with: splitController.children[0], selectedPaneID: selectedPaneID),
        sync(node: split.second, with: splitController.children[1], selectedPaneID: selectedPaneID)
      else {
        return false
      }
      splitController.applyRatioIfNeeded()
      return true
    }
  }

  private static func hasSameStructure(_ lhs: PaneNode, _ rhs: PaneNode) -> Bool {
    switch (lhs, rhs) {
    case (.leaf(let left), .leaf(let right)):
      return left.paneId == right.paneId
    case (.split(let left), .split(let right)):
      return left.axis == right.axis
        && hasSameStructure(left.first, right.first)
        && hasSameStructure(left.second, right.second)
    default:
      return false
    }
  }

  private func updateLeaf(
    _ leaf: TerminalPaneViewController,
    isSelected: Bool,
    selectedPaneID: UUID?
  ) {
    leaf.update(
      isSelected: isSelected,
      onSelect: { [weak self] paneID in self?.onSelect?(paneID) },
      onSplit: { [weak self] paneID, axis in self?.onSplit?(paneID, axis) },
      onClose: { [weak self] paneID in self?.onClose?(paneID) },
      onPasteDroppedPaths: { [weak self] paneID, text in self?.onPasteDroppedPaths?(paneID, text) },
      menuText: menuText,
      palette: palette,
      dimsWhenInactive: hasMultiplePanes,
      onResize: { [weak self] paneID, rows, cols in self?.onResize?(paneID, rows, cols) },
      isResizeSensitiveScreen: { [weak self] paneID in self?.isResizeSensitiveScreen?(paneID) ?? false },
      onSplitAvailabilityChanged: { [weak self] paneID, size, canSplitRight, canSplitDown in
        self?.onSplitAvailabilityChanged?(paneID, size, canSplitRight, canSplitDown)
      },
      onWorkspaceSwitcher: { [weak self] in self?.onWorkspaceSwitcher?() },
      onSettings: { [weak self] in self?.onSettings?() },
      sideInputStore: sideInputStore,
      onSideInputTextChanged: { [weak self] paneID, text in self?.onSideInputTextChanged?(paneID, text) },
      onSubmitSideInput: { [weak self] paneID in self?.onSubmitSideInput?(paneID) },
      onCloseEmptySideInput: { [weak self] paneID in self?.onCloseEmptySideInput?(paneID) },
      onCancelSideInput: { [weak self] paneID in self?.onCancelSideInput?(paneID) },
      sideInputPlaceholder: sideInputPlaceholder,
      onSideInputFocusRequestHandled: { [weak self] paneID, requestID in
        self?.onSideInputFocusRequestHandled?(paneID, requestID)
      },
      keyboardShortcuts: keyboardShortcuts
    )
  }

  func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
    false
  }

  func splitView(
    _ splitView: NSSplitView,
    constrainMinCoordinate proposedMinimumPosition: CGFloat,
    ofSubviewAt dividerIndex: Int
  ) -> CGFloat {
    let total = splitView.isVertical ? splitView.bounds.width : splitView.bounds.height
    guard SplitRatioLayout.canSplit(
      totalLength: Double(total),
      dividerThickness: Double(splitView.dividerThickness),
      minimumFirstLength: Double((splitView as? TerminalSplitView)?.minimumFirstLength ?? minimumPaneLength),
      minimumSecondLength: Double((splitView as? TerminalSplitView)?.minimumSecondLength ?? minimumPaneLength)
    ) else {
      return proposedMinimumPosition
    }
    let minimum = (splitView as? TerminalSplitView)?.minimumFirstLength ?? minimumPaneLength
    return max(proposedMinimumPosition, minimum)
  }

  func splitView(
    _ splitView: NSSplitView,
    constrainMaxCoordinate proposedMaximumPosition: CGFloat,
    ofSubviewAt dividerIndex: Int
  ) -> CGFloat {
    let total = splitView.isVertical ? splitView.bounds.width : splitView.bounds.height
    guard SplitRatioLayout.canSplit(
      totalLength: Double(total),
      dividerThickness: Double(splitView.dividerThickness),
      minimumFirstLength: Double((splitView as? TerminalSplitView)?.minimumFirstLength ?? minimumPaneLength),
      minimumSecondLength: Double((splitView as? TerminalSplitView)?.minimumSecondLength ?? minimumPaneLength)
    ) else {
      return proposedMaximumPosition
    }
    let minimum = (splitView as? TerminalSplitView)?.minimumSecondLength ?? minimumPaneLength
    return min(proposedMaximumPosition, total - splitView.dividerThickness - minimum)
  }
}

private final class TerminalSplitView: NSSplitView {
  var isUserResizingDivider = false
  var onUserResizeFinished: (() -> Void)?
  var minimumFirstLength = CGFloat(SplitRatioLayout.minimumPaneLength)
  var minimumSecondLength = CGFloat(SplitRatioLayout.minimumPaneLength)
  private let dividerInteractionOutset: CGFloat = 4
  private var isEnforcingMinimumDividerPosition = false
  private var previewDividerPosition: CGFloat?
  private let previewDividerLayer = CALayer()
  var customDividerColor = TerminalSurfacePalette.dark.splitDivider {
    didSet {
      needsDisplay = true
      updatePreviewDividerLayer()
    }
  }

  override var dividerColor: NSColor {
    customDividerColor
  }

  override func drawDivider(in rect: NSRect) {
    customDividerColor.setFill()
    rect.fill()
  }

  override func resetCursorRects() {
    for index in 0..<(max(0, arrangedSubviews.count - 1)) {
      addCursorRect(dividerCursorRect(afterSubviewAt: index), cursor: dividerCursor)
    }
  }

  override func layout() {
    super.layout()
    enforceMinimumDividerPosition()
    updatePreviewDividerLayer()
  }

  override func mouseDown(with event: NSEvent) {
    guard let dividerIndex = dividerIndex(at: event) else {
      super.mouseDown(with: event)
      return
    }

    trackDividerPreview(afterSubviewAt: dividerIndex, initialEvent: event)
  }

  private func trackDividerPreview(afterSubviewAt dividerIndex: Int, initialEvent: NSEvent) {
    guard let initialPosition = currentDividerPosition(afterSubviewAt: dividerIndex) else { return }
    showPreviewDivider(at: initialPosition)

    var finalPosition = initialPosition
    var didDrag = false
    while let event = window?.nextEvent(
      matching: [.leftMouseDragged, .leftMouseUp],
      until: .distantFuture,
      inMode: .eventTracking,
      dequeue: true
    ) {
      switch event.type {
      case .leftMouseDragged:
        guard let position = clampedDividerPosition(for: event) else { continue }
        didDrag = true
        finalPosition = position
        showPreviewDivider(at: position)
      case .leftMouseUp:
        hidePreviewDivider()
        if didDrag {
          isUserResizingDivider = true
          setPosition(finalPosition, ofDividerAt: dividerIndex)
          adjustSubviews()
          isUserResizingDivider = false
          onUserResizeFinished?()
        }
        return
      default:
        continue
      }
    }

    hidePreviewDivider()
  }

  private func clampedDividerPosition(for event: NSEvent) -> CGFloat? {
    let location = convert(event.locationInWindow, from: nil)
    let proposed = isVertical ? location.x : location.y
    let total = isVertical ? bounds.width : bounds.height
    guard let position = SplitRatioLayout.clampedDividerPosition(
      proposedPosition: Double(proposed),
      totalLength: Double(total),
      dividerThickness: Double(dividerThickness),
      minimumFirstLength: Double(minimumFirstLength),
      minimumSecondLength: Double(minimumSecondLength)
    ) else {
      return nil
    }
    return CGFloat(position)
  }

  private func enforceMinimumDividerPosition() {
    guard
      !isEnforcingMinimumDividerPosition,
      arrangedSubviews.count == 2,
      let currentPosition = currentDividerPosition(afterSubviewAt: 0)
    else {
      return
    }
    let total = isVertical ? bounds.width : bounds.height
    guard let position = SplitRatioLayout.clampedDividerPosition(
      proposedPosition: Double(currentPosition),
      totalLength: Double(total),
      dividerThickness: Double(dividerThickness),
      minimumFirstLength: Double(minimumFirstLength),
      minimumSecondLength: Double(minimumSecondLength)
    ) else {
      return
    }
    let nextPosition = CGFloat(position)
    guard abs(nextPosition - currentPosition) > 0.5 else { return }

    isEnforcingMinimumDividerPosition = true
    setPosition(nextPosition, ofDividerAt: 0)
    adjustSubviews()
    isEnforcingMinimumDividerPosition = false
  }

  private func currentDividerPosition(afterSubviewAt index: Int) -> CGFloat? {
    guard index >= 0, index < arrangedSubviews.count - 1 else { return nil }
    let subviewFrame = arrangedSubviews[index].frame
    return isVertical ? subviewFrame.maxX : subviewFrame.maxY
  }

  private func showPreviewDivider(at position: CGFloat) {
    previewDividerPosition = position
    updatePreviewDividerLayer()
  }

  private func hidePreviewDivider() {
    previewDividerPosition = nil
    previewDividerLayer.removeFromSuperlayer()
  }

  private func updatePreviewDividerLayer() {
    guard let previewDividerPosition else {
      previewDividerLayer.removeFromSuperlayer()
      return
    }
    wantsLayer = true
    guard let layer else { return }
    if previewDividerLayer.superlayer !== layer {
      layer.addSublayer(previewDividerLayer)
    }

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    previewDividerLayer.zPosition = 1_000
    previewDividerLayer.backgroundColor = customDividerColor.withAlphaComponent(0.58).cgColor
    previewDividerLayer.frame = previewDividerLayerFrame(position: previewDividerPosition)
    previewDividerLayer.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    CATransaction.commit()
  }

  private func dividerIndex(at event: NSEvent) -> Int? {
    let location = convert(event.locationInWindow, from: nil)
    guard arrangedSubviews.count > 1 else { return nil }
    for index in 0..<(arrangedSubviews.count - 1) {
      if dividerHitRect(afterSubviewAt: index).contains(location) {
        return index
      }
    }
    return nil
  }

  private func dividerHitRect(afterSubviewAt index: Int) -> NSRect {
    dividerInteractionRect(afterSubviewAt: index)
  }

  private func dividerCursorRect(afterSubviewAt index: Int) -> NSRect {
    dividerInteractionRect(afterSubviewAt: index)
  }

  private var dividerCursor: NSCursor {
    isVertical ? .resizeLeftRight : .resizeUpDown
  }

  private func dividerRect(afterSubviewAt index: Int) -> NSRect {
    let subviewFrame = arrangedSubviews[index].frame
    let thickness = max(1, dividerThickness)
    if isVertical {
      return NSRect(
        x: subviewFrame.maxX,
        y: bounds.minY,
        width: thickness,
        height: bounds.height
      )
    } else {
      return NSRect(
        x: bounds.minX,
        y: subviewFrame.maxY,
        width: bounds.width,
        height: thickness
      )
    }
  }

  private func previewDividerLayerFrame(position: CGFloat) -> CGRect {
    let thickness = max(3, dividerThickness + 2)
    if isVertical {
      return CGRect(
        x: position,
        y: bounds.minY,
        width: thickness,
        height: bounds.height
      )
    } else {
      return CGRect(
        x: bounds.minX,
        y: position,
        width: bounds.width,
        height: thickness
      )
    }
  }

  private func dividerInteractionRect(afterSubviewAt index: Int) -> NSRect {
    dividerRect(afterSubviewAt: index)
      .insetBy(
        dx: isVertical ? -dividerInteractionOutset : 0,
        dy: isVertical ? 0 : -dividerInteractionOutset
      )
  }
}

final class TerminalPaneViewController: NSViewController {
  let pane: TerminalPane
  private weak var contentView: NSView?
  private var onSelect: ((UUID) -> Void)?
  private var onPasteDroppedPaths: ((UUID, String) -> Void)?
  private var onResize: ((UUID, Int, Int) -> Void)?
  private var isResizeSensitiveScreen: ((UUID) -> Bool)?
  private var onSplitAvailabilityChanged: ((UUID, NSSize, Bool, Bool) -> Void)?
  private var currentPalette = TerminalSurfacePalette.dark
  private var isDropTargeted = false
  private var lastAppliedGridSize: TerminalGridSize?
  private var lastSplitAvailability: (canSplitRight: Bool, canSplitDown: Bool)?
  private var pendingResizeGridSize: TerminalGridSize?
  private var pendingResizeWorkItem: DispatchWorkItem?
  private var resizeCoordinator = TerminalResizeCommitCoordinator()
  private var sideInputOverlay: TerminalSideInputOverlayView?

  init(pane: TerminalPane, contentView: NSView?) {
    self.pane = pane
    super.init(nibName: nil, bundle: nil)
    self.contentView = contentView
  }

  required init?(coder: NSCoder) {
    nil
  }

  override func loadView() {
    view = TerminalPaneHostView()
    if let hostView = view as? TerminalPaneHostView {
      hostView.onLiveResizeEnded = { [weak self] in
        self?.commitPendingLiveResize()
      }
    }
    view.wantsLayer = true
    if let contentView {
      setContentView(contentView)
    }
  }

  func update(
    isSelected: Bool,
    onSelect: @escaping (UUID) -> Void,
    onSplit: @escaping (UUID, SplitAxis) -> Void,
    onClose: @escaping (UUID) -> Void,
    onPasteDroppedPaths: @escaping (UUID, String) -> Void,
    menuText: AppText,
    palette: TerminalSurfacePalette,
    dimsWhenInactive: Bool = true,
    onResize: @escaping (UUID, Int, Int) -> Void,
    isResizeSensitiveScreen: @escaping (UUID) -> Bool,
    onSplitAvailabilityChanged: @escaping (UUID, NSSize, Bool, Bool) -> Void,
    onWorkspaceSwitcher: @escaping () -> Void,
    onSettings: @escaping () -> Void,
    sideInputStore: TerminalSideInputStore,
    onSideInputTextChanged: @escaping (UUID, String) -> Void,
    onSubmitSideInput: @escaping (UUID) -> Void,
    onCloseEmptySideInput: @escaping (UUID) -> Void,
    onCancelSideInput: @escaping (UUID) -> Void,
    sideInputPlaceholder: String,
    onSideInputFocusRequestHandled: @escaping (UUID, Int) -> Void,
    keyboardShortcuts: KeyboardShortcutSettings
  ) {
    self.onSelect = onSelect
    self.onResize = onResize
    self.isResizeSensitiveScreen = isResizeSensitiveScreen
    self.onSplitAvailabilityChanged = onSplitAvailabilityChanged
    self.onPasteDroppedPaths = onPasteDroppedPaths
    currentPalette = palette
    configureDropHandling()
    applyAppearance(isSelected: isSelected, palette: palette, dimsWhenInactive: dimsWhenInactive)
    updateSideInputOverlay(
      draft: sideInputStore.draft(for: pane.paneId),
      pendingFocusRequest: sideInputStore.pendingFocusRequest,
      palette: palette,
      onTextChanged: onSideInputTextChanged,
      onSubmit: onSubmitSideInput,
      onCloseIfEmpty: onCloseEmptySideInput,
      onCancel: onCancelSideInput,
      placeholder: sideInputPlaceholder,
      onFocusRequestHandled: onSideInputFocusRequestHandled
    )
    install(menu: menu(
      onSelect: onSelect,
      onSplit: onSplit,
      onClose: onClose,
      text: menuText,
      keyboardShortcuts: keyboardShortcuts,
      onWorkspaceSwitcher: onWorkspaceSwitcher,
      onSettings: onSettings
    ), in: view)
  }

  func setSelected(_ isSelected: Bool) {
    applyAppearance(isSelected: isSelected, palette: .dark, dimsWhenInactive: false)
  }

  func applyAppearance(
    isSelected: Bool,
    palette: TerminalSurfacePalette,
    dimsWhenInactive: Bool
  ) {
    view.layer?.backgroundColor = palette.background.cgColor
    view.layer?.borderWidth = 0
    view.layer?.borderColor = nil
    currentPalette = palette
    updateDropTargetAppearance()
  }

  override func viewWillDisappear() {
    super.viewWillDisappear()
    setDropTargeted(false)
  }

  override func viewDidLayout() {
    super.viewDidLayout()
    let size = view.bounds.size
    guard view.window != nil, size.width > 0, size.height > 0 else {
      pendingResizeWorkItem?.cancel()
      pendingResizeWorkItem = nil
      return
    }
    reportSplitAvailability()

    let gridSize = terminalGridSize(for: size)
    let liveResizeActive = isLiveResizeActive
    let resizeSensitive = isResizeSensitiveScreen?(pane.paneId) ?? false
    if gridSize == pendingResizeGridSize, liveResizeActive, resizeSensitive {
      return
    }
    let decision = resizeCoordinator.update(
      gridSize: gridSize,
      isLiveResize: liveResizeActive,
      isResizeSensitiveScreen: resizeSensitive
    )

    guard decision != .ignore else {
      pendingResizeWorkItem?.cancel()
      pendingResizeWorkItem = nil
      pendingResizeGridSize = nil
      return
    }
    guard decision != .deferUntilLiveResizeEnds else {
      pendingResizeWorkItem?.cancel()
      pendingResizeWorkItem = nil
      return
    }

    pendingResizeWorkItem?.cancel()
    pendingResizeGridSize = gridSize

    let workItem = DispatchWorkItem { [weak self] in
      guard let self else { return }
      let currentGridSize = self.terminalGridSize(for: self.view.bounds.size)
      guard
        self.pendingResizeGridSize == gridSize,
        currentGridSize == gridSize,
        self.lastAppliedGridSize != gridSize
      else {
        return
      }
      self.pendingResizeWorkItem = nil
      self.pendingResizeGridSize = nil
      self.lastAppliedGridSize = gridSize
      self.resizeCoordinator.markCommitted(gridSize)
      self.onResize?(self.pane.paneId, gridSize.rows, gridSize.cols)
    }

    pendingResizeWorkItem = workItem
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(40), execute: workItem)
  }

  private func commitPendingLiveResize() {
    pendingResizeWorkItem?.cancel()
    pendingResizeWorkItem = nil
    pendingResizeGridSize = nil
    guard case .commit(let gridSize) = resizeCoordinator.finishLiveResize() else { return }
    lastAppliedGridSize = gridSize
    resizeCoordinator.markCommitted(gridSize)
    onResize?(pane.paneId, gridSize.rows, gridSize.cols)
  }

  private var isLiveResizeActive: Bool {
    view.inLiveResize
      || view.window?.inLiveResize == true
      || (view as? TerminalPaneHostView)?.isLiveResizeActive == true
  }

  private func terminalGridSize(for size: CGSize) -> TerminalGridSize {
    let scale = view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
    if let surface = contentView as? PTYTerminalSurfaceView {
      let cellSize = surface.liveGridView.terminalCellSize
      let inset = surface.liveGridView.terminalContentInset
      return TerminalGridSizer.gridSize(
        for: size,
        cellSize: cellSize,
        inset: inset,
        scale: scale
      )
    }
    let textView = terminalTextView(in: contentView)
    let font = textView?.font ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    let sampleWidth = max(1, ceil(("W" as NSString).size(withAttributes: [.font: font]).width * scale))
    let lineHeight = max(1, ceil((font.ascender - font.descender + font.leading) * scale))
    let inset = textView?.textContainerInset ?? .zero
    let contentWidth = max(1, (size.width - inset.width * 2) * scale)
    let contentHeight = max(1, (size.height - inset.height * 2) * scale)
    return TerminalGridSize(
      rows: max(1, Int(contentHeight / lineHeight)),
      cols: max(2, Int(contentWidth / sampleWidth))
    )
  }

  private func terminalTextView(in surface: NSView?) -> NSTextView? {
    guard let surface else { return nil }
    if let textView = surface as? NSTextView {
      return textView
    }
    if let scrollView = surface as? NSScrollView, let textView = scrollView.documentView as? NSTextView {
      return textView
    }
    for subview in surface.subviews {
      if let textView = terminalTextView(in: subview) {
        return textView
      }
    }
    return nil
  }

  private func setContentView(_ contentView: NSView) {
    contentView.removeFromSuperview()
    contentView.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(contentView)
    NSLayoutConstraint.activate([
      contentView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      contentView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      contentView.topAnchor.constraint(equalTo: view.topAnchor),
      contentView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
  }

  private func updateSideInputOverlay(
    draft: TerminalSideInputDraft?,
    pendingFocusRequest: TerminalSideInputFocusRequest?,
    palette: TerminalSurfacePalette,
    onTextChanged: @escaping (UUID, String) -> Void,
    onSubmit: @escaping (UUID) -> Void,
    onCloseIfEmpty: @escaping (UUID) -> Void,
    onCancel: @escaping (UUID) -> Void,
    placeholder: String,
    onFocusRequestHandled: @escaping (UUID, Int) -> Void
  ) {
    guard let draft else {
      sideInputOverlay?.removeFromSuperview()
      sideInputOverlay = nil
      return
    }

    let overlay: TerminalSideInputOverlayView
    if let existing = sideInputOverlay {
      overlay = existing
    } else {
      overlay = TerminalSideInputOverlayView()
      overlay.translatesAutoresizingMaskIntoConstraints = false
      view.addSubview(overlay)
      let preferredWidth = overlay.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.72)
      preferredWidth.priority = .defaultHigh
      NSLayoutConstraint.activate([
        overlay.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
        overlay.centerXAnchor.constraint(equalTo: view.centerXAnchor),
        preferredWidth,
        overlay.widthAnchor.constraint(lessThanOrEqualToConstant: 560),
        overlay.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 12),
        overlay.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -12),
      ])
      sideInputOverlay = overlay
    }

    overlay.configure(
      paneID: pane.paneId,
      text: draft.text,
      palette: palette,
      onTextChanged: onTextChanged,
      onSubmit: onSubmit,
      onCloseIfEmpty: onCloseIfEmpty,
      onCancel: onCancel,
      placeholder: placeholder
    )
    guard pendingFocusRequest == TerminalSideInputFocusRequest(
      paneID: pane.paneId,
      requestID: draft.focusRequestID
    ) else {
      return
    }
    DispatchQueue.main.async { [weak overlay, weak self] in
      guard let overlay, overlay.superview === self?.view else { return }
      overlay.focus()
      onFocusRequestHandled(draft.paneID, draft.focusRequestID)
    }
  }

  private func configureDropHandling() {
    guard let hostView = view as? TerminalPaneHostView else { return }
    hostView.onDraggingFilesChanged = { [weak self] isTargeted in
      self?.setDropTargeted(isTargeted)
    }
    hostView.onFileURLsDropped = { [weak self] urls in
      self?.handleDroppedFileURLs(urls) ?? false
    }
  }

  private func handleDroppedFileURLs(_ urls: [URL]) -> Bool {
    guard let text = TerminalDraggedPathFormatter.formattedText(for: urls) else {
      DebugLog.write("dropped paths ignored pane=\(pane.paneId): no local file URLs")
      setDropTargeted(false)
      return false
    }

    onSelect?(pane.paneId)
    onPasteDroppedPaths?(pane.paneId, text)
    setDropTargeted(false)
    return true
  }

  private func setDropTargeted(_ isTargeted: Bool) {
    isDropTargeted = isTargeted
    updateDropTargetAppearance()
  }

  private func updateDropTargetAppearance() {
    guard isDropTargeted else {
      view.layer?.borderWidth = 0
      view.layer?.borderColor = nil
      return
    }

    view.layer?.borderWidth = 1
    view.layer?.borderColor = currentPalette.cursorBackground.withAlphaComponent(0.55).cgColor
  }

  @MainActor private func menu(
    onSelect: @escaping (UUID) -> Void,
    onSplit: @escaping (UUID, SplitAxis) -> Void,
    onClose: @escaping (UUID) -> Void,
    text: AppText,
    keyboardShortcuts: KeyboardShortcutSettings,
    onWorkspaceSwitcher: @escaping () -> Void,
    onSettings: @escaping () -> Void
  ) -> NSMenu {
    let menu = NSMenu()
    menu.allowsContextMenuPlugIns = false
    menu.autoenablesItems = false
    let paneId = pane.paneId
    menu.addItem(ClosureMenuItem(
      title: text.copy,
      handler: { [weak self] in
        self?.copyFromTerminalSurface()
      },
      isEnabled: { [weak self] in
        self?.hasTerminalSelection() == true
      }
    ))
    menu.addItem(ClosureMenuItem(
      title: text.paste,
      handler: { [weak self] in
        self?.pasteIntoTerminalSurface()
      },
      isEnabled: {
        NSPasteboard.general.string(forType: .string)?.isEmpty == false
      }
    ))
    menu.addItem(.separator())
    menu.addItem(SplitControlMenuItem(
      title: text.splitPane,
      splitRightTitle: text.splitRight,
      splitDownTitle: text.splitDown,
      splitRight: { [weak self] in
        DebugLog.write("context menu Split Right pane=\(paneId)")
        self?.performSplitIfPossible(axis: .horizontal, onSelect: onSelect, onSplit: onSplit)
      },
      splitDown: { [weak self] in
        DebugLog.write("context menu Split Down pane=\(paneId)")
        self?.performSplitIfPossible(axis: .vertical, onSelect: onSelect, onSplit: onSplit)
      },
      canSplitRight: { [weak self] in
        self?.canSplit(axis: .horizontal) == true
      },
      canSplitDown: { [weak self] in
        self?.canSplit(axis: .vertical) == true
      }
    ))
    menu.addItem(.separator())
    menu.addItem(ClosureMenuItem(
      title: text.closePane,
      handler: {
        onClose(paneId)
      }
    ))
    menu.addItem(.separator())
    menu.addItem(ClosureMenuItem(title: text.workspaces) {
      onWorkspaceSwitcher()
    })
    menu.addItem(.separator())
    menu.addItem(ClosureMenuItem(title: text.settings + "...") {
      onSettings()
    })
    return menu
  }

  private func copyFromTerminalSurface() {
    if let surface = contentView as? PTYTerminalSurfaceView, surface.isShowingLiveGrid {
      surface.liveGridView.copy(nil)
      return
    }
    terminalTextView(in: contentView)?.copy(nil)
  }

  private func pasteIntoTerminalSurface() {
    if let surface = contentView as? PTYTerminalSurfaceView, surface.isShowingLiveGrid {
      surface.liveGridView.paste(nil)
      return
    }
    terminalTextView(in: contentView)?.paste(nil)
  }

  private func hasTerminalSelection() -> Bool {
    if let surface = contentView as? PTYTerminalSurfaceView, surface.isShowingLiveGrid {
      return surface.liveGridView.selectedText?.isEmpty == false
    }
    guard let textView = terminalTextView(in: contentView) else { return false }
    return textView.selectedRange().length > 0
  }

  private func performSplitIfPossible(
    axis: SplitAxis,
    onSelect: (UUID) -> Void,
    onSplit: (UUID, SplitAxis) -> Void
  ) {
    let paneId = pane.paneId
    guard canSplit(axis: axis) else {
      DebugLog.write("split rejected pane=\(paneId) axis=\(axis) size=\(view.bounds.size): insufficient space")
      NSSound.beep()
      return
    }

    onSelect(paneId)
    onSplit(paneId, axis)
  }

  private func canSplit(axis: SplitAxis) -> Bool {
    let length = axis == .horizontal ? view.bounds.width : view.bounds.height
    return SplitRatioLayout.canSplit(totalLength: Double(length), dividerThickness: 1)
  }

  private func reportSplitAvailability() {
    let availability = (
      canSplitRight: canSplit(axis: .horizontal),
      canSplitDown: canSplit(axis: .vertical)
    )
    guard lastSplitAvailability?.canSplitRight != availability.canSplitRight
      || lastSplitAvailability?.canSplitDown != availability.canSplitDown
    else {
      return
    }
    lastSplitAvailability = availability
    onSplitAvailabilityChanged?(pane.paneId, view.bounds.size, availability.canSplitRight, availability.canSplitDown)
  }
}

private final class TerminalPaneHostView: NSView {
  var onLiveResizeEnded: (() -> Void)?
  var onDraggingFilesChanged: ((Bool) -> Void)?
  var onFileURLsDropped: (([URL]) -> Bool)?
  private(set) var isLiveResizeActive = false

  override var acceptsFirstResponder: Bool { true }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    registerForDraggedTypes([.fileURL])
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    registerForDraggedTypes([.fileURL])
  }

  override func mouseDown(with event: NSEvent) {
    nextResponder?.mouseDown(with: event)
  }

  override func viewWillStartLiveResize() {
    super.viewWillStartLiveResize()
    isLiveResizeActive = true
  }

  override func viewDidEndLiveResize() {
    super.viewDidEndLiveResize()
    isLiveResizeActive = false
    onLiveResizeEnded?()
  }

  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    guard hasFileURLs(sender.draggingPasteboard) else {
      onDraggingFilesChanged?(false)
      return []
    }
    onDraggingFilesChanged?(true)
    return .copy
  }

  override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
    guard hasFileURLs(sender.draggingPasteboard) else {
      onDraggingFilesChanged?(false)
      return []
    }
    onDraggingFilesChanged?(true)
    return .copy
  }

  override func draggingExited(_ sender: NSDraggingInfo?) {
    onDraggingFilesChanged?(false)
  }

  override func draggingEnded(_ sender: NSDraggingInfo) {
    onDraggingFilesChanged?(false)
  }

  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    let urls = fileURLs(from: sender.draggingPasteboard)
    let handled = onFileURLsDropped?(urls) ?? false
    onDraggingFilesChanged?(false)
    return handled
  }

  private func hasFileURLs(_ pasteboard: NSPasteboard) -> Bool {
    !fileURLs(from: pasteboard).isEmpty
  }

  private func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
    guard
      let items = pasteboard.readObjects(
        forClasses: [NSURL.self],
        options: [.urlReadingFileURLsOnly: true]
      ) as? [URL]
    else {
      return []
    }
    return items
  }
}

@MainActor private final class TerminalSideInputOverlayView: NSView {
  private let scrollView = NSScrollView()
  private let textView = TerminalSideInputTextView()
  private let placeholderField = NSTextField(labelWithString: "")
  private var heightConstraint: NSLayoutConstraint?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    setup()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    setup()
  }

  func configure(
    paneID: UUID,
    text: String,
    palette: TerminalSurfacePalette,
    onTextChanged: @escaping (UUID, String) -> Void,
    onSubmit: @escaping (UUID) -> Void,
    onCloseIfEmpty: @escaping (UUID) -> Void,
    onCancel: @escaping (UUID) -> Void,
    placeholder: String
  ) {
    layer?.backgroundColor = palette.background.withAlphaComponent(0.92).cgColor
    layer?.borderColor = palette.cursorBackground.withAlphaComponent(0.42).cgColor
    textView.textColor = palette.foreground
    textView.insertionPointColor = palette.cursorBackground
    placeholderField.stringValue = placeholder
    placeholderField.textColor = palette.foreground.withAlphaComponent(0.38)
    textView.onTextChanged = { [weak self] value in
      self?.updateHeight()
      self?.updatePlaceholderVisibility()
      onTextChanged(paneID, value)
    }
    textView.onSubmit = { onSubmit(paneID) }
    textView.onCloseIfEmpty = { onCloseIfEmpty(paneID) }
    textView.onCancel = { onCancel(paneID) }
    if textView.string != text {
      textView.string = text
      updateHeight()
    }
    updatePlaceholderVisibility()
  }

  func focus() {
    window?.makeFirstResponder(textView)
  }

  private func setup() {
    wantsLayer = true
    layer?.cornerRadius = 8
    layer?.borderWidth = 1
    layer?.masksToBounds = true
    shadow = NSShadow()
    shadow?.shadowBlurRadius = 12
    shadow?.shadowOffset = NSSize(width: 0, height: -2)
    shadow?.shadowColor = NSColor.black.withAlphaComponent(0.22)

    scrollView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.drawsBackground = false
    scrollView.hasVerticalScroller = false
    scrollView.hasHorizontalScroller = false
    scrollView.borderType = .noBorder

    textView.drawsBackground = false
    textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    textView.textContainerInset = NSSize(width: 10, height: 9)
    textView.isRichText = false
    textView.allowsUndo = true
    textView.isAutomaticQuoteSubstitutionEnabled = false
    textView.isAutomaticDashSubstitutionEnabled = false
    textView.isAutomaticTextReplacementEnabled = false
    textView.textContainer?.containerSize = NSSize(width: bounds.width, height: .greatestFiniteMagnitude)
    textView.textContainer?.widthTracksTextView = true
    textView.minSize = NSSize(width: 0, height: 0)
    textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.autoresizingMask = [.width]

    placeholderField.translatesAutoresizingMaskIntoConstraints = false
    placeholderField.font = textView.font
    placeholderField.lineBreakMode = .byTruncatingTail
    placeholderField.isEditable = false
    placeholderField.isSelectable = false
    placeholderField.drawsBackground = false

    scrollView.documentView = textView
    addSubview(scrollView)
    addSubview(placeholderField)
    let heightConstraint = heightAnchor.constraint(equalToConstant: 40)
    self.heightConstraint = heightConstraint
    NSLayoutConstraint.activate([
      widthAnchor.constraint(greaterThanOrEqualToConstant: 220),
      heightConstraint,
      scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
      scrollView.topAnchor.constraint(equalTo: topAnchor),
      scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

      placeholderField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 15),
      placeholderField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -15),
      placeholderField.topAnchor.constraint(equalTo: topAnchor, constant: 10),
    ])
    updatePlaceholderVisibility()
  }

  private func updateHeight() {
    let lineCount = max(1, textView.string.split(separator: "\n", omittingEmptySubsequences: false).count)
    heightConstraint?.constant = min(116, max(40, CGFloat(lineCount) * 18 + 22))
  }

  private func updatePlaceholderVisibility() {
    placeholderField.isHidden = !textView.string.isEmpty
  }
}

@MainActor private final class TerminalSideInputTextView: NSTextView {
  var onTextChanged: ((String) -> Void)?
  var onSubmit: (() -> Void)?
  var onCloseIfEmpty: (() -> Void)?
  var onCancel: (() -> Void)?

  override func keyDown(with event: NSEvent) {
    switch event.keyCode {
    case 36 where !event.modifierFlags.contains(.shift),
      76 where !event.modifierFlags.contains(.shift):
      onSubmit?()
    case 53:
      onCancel?()
    default:
      super.keyDown(with: event)
    }
  }

  override func resignFirstResponder() -> Bool {
    if string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      onCloseIfEmpty?()
    }
    return super.resignFirstResponder()
  }

  override func didChangeText() {
    super.didChangeText()
    onTextChanged?(string)
  }
}

private final class ClosureMenuItem: NSMenuItem, NSMenuItemValidation {
  private let handler: () -> Void
  private let isEnabledProvider: () -> Bool

  init(
    title: String,
    handler: @escaping () -> Void,
    keyEquivalent: String = "",
    modifierMask: NSEvent.ModifierFlags = [],
    isEnabled: @escaping () -> Bool = { true }
  ) {
    self.handler = handler
    isEnabledProvider = isEnabled
    super.init(title: title, action: #selector(run), keyEquivalent: keyEquivalent)
    keyEquivalentModifierMask = modifierMask
    target = self
  }

  required init(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  @MainActor @objc private func run() {
    DebugLog.write("ClosureMenuItem run title=\(title)")
    guard isEnabledProvider() else {
      DebugLog.write("ClosureMenuItem rejected disabled action title=\(title)")
      return
    }
    handler()
  }

  @MainActor func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    isEnabledProvider()
  }
}

@MainActor private final class SplitControlMenuItem: NSMenuItem, NSMenuItemValidation {
  private let controlView: SplitControlMenuView

  init(
    title: String,
    splitRightTitle: String,
    splitDownTitle: String,
    splitRight: @escaping () -> Void,
    splitDown: @escaping () -> Void,
    canSplitRight: @escaping () -> Bool,
    canSplitDown: @escaping () -> Bool
  ) {
    controlView = SplitControlMenuView(
      title: title,
      splitRightTitle: splitRightTitle,
      splitDownTitle: splitDownTitle,
      splitRight: splitRight,
      splitDown: splitDown,
      canSplitRight: canSplitRight,
      canSplitDown: canSplitDown
    )
    super.init(title: title, action: nil, keyEquivalent: "")
    view = controlView
  }

  required init(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  @MainActor func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    controlView.refreshEnabledState()
    return true
  }
}

@MainActor private final class SplitControlMenuView: NSView {
  private let titleField = NSTextField(labelWithString: "")
  private let rightButton: SplitGlyphButton
  private let downButton: SplitGlyphButton
  private let splitRight: () -> Void
  private let splitDown: () -> Void
  private let canSplitRight: () -> Bool
  private let canSplitDown: () -> Bool

  init(
    title: String,
    splitRightTitle: String,
    splitDownTitle: String,
    splitRight: @escaping () -> Void,
    splitDown: @escaping () -> Void,
    canSplitRight: @escaping () -> Bool,
    canSplitDown: @escaping () -> Bool
  ) {
    self.splitRight = splitRight
    self.splitDown = splitDown
    self.canSplitRight = canSplitRight
    self.canSplitDown = canSplitDown
    rightButton = SplitGlyphButton(axis: .horizontal)
    downButton = SplitGlyphButton(axis: .vertical)
    super.init(frame: NSRect(
      x: 0,
      y: 0,
      width: ProGhosttyContextMenuSizing.splitControlWidth,
      height: ProGhosttyContextMenuSizing.splitControlHeight
    ))

    titleField.stringValue = title
    titleField.font = .systemFont(ofSize: 11, weight: .medium)
    titleField.textColor = .secondaryLabelColor
    titleField.lineBreakMode = .byTruncatingTail
    titleField.translatesAutoresizingMaskIntoConstraints = false

    configure(button: rightButton, title: splitRightTitle, action: #selector(runSplitRight))
    configure(button: downButton, title: splitDownTitle, action: #selector(runSplitDown))

    addSubview(titleField)
    addSubview(rightButton)
    addSubview(downButton)

    let buttonLength = CGFloat(ProGhosttyContextMenuSizing.splitButtonLength)
    let spacing = CGFloat(ProGhosttyContextMenuSizing.splitButtonSpacing)
    let horizontalPadding = CGFloat(ProGhosttyContextMenuSizing.splitControlHorizontalPadding)
    let verticalPadding = CGFloat(ProGhosttyContextMenuSizing.splitControlVerticalPadding)
    let titleHeight = CGFloat(ProGhosttyContextMenuSizing.splitControlTitleHeight)

    NSLayoutConstraint.activate([
      titleField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: horizontalPadding),
      titleField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -horizontalPadding),
      titleField.topAnchor.constraint(equalTo: topAnchor, constant: verticalPadding),
      titleField.heightAnchor.constraint(equalToConstant: titleHeight),

      rightButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: horizontalPadding),
      rightButton.topAnchor.constraint(
        equalTo: titleField.bottomAnchor,
        constant: CGFloat(ProGhosttyContextMenuSizing.splitControlTitleSpacing)
      ),
      rightButton.widthAnchor.constraint(equalToConstant: buttonLength),
      rightButton.heightAnchor.constraint(equalToConstant: buttonLength),

      downButton.leadingAnchor.constraint(equalTo: rightButton.trailingAnchor, constant: spacing),
      downButton.topAnchor.constraint(equalTo: rightButton.topAnchor),
      downButton.widthAnchor.constraint(equalToConstant: buttonLength),
      downButton.heightAnchor.constraint(equalToConstant: buttonLength),
    ])

    refreshEnabledState()
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    refreshEnabledState()
  }

  func refreshEnabledState() {
    rightButton.isEnabled = canSplitRight()
    downButton.isEnabled = canSplitDown()
  }

  private func configure(button: SplitGlyphButton, title: String, action: Selector) {
    button.translatesAutoresizingMaskIntoConstraints = false
    button.target = self
    button.action = action
    button.toolTip = title
    button.setAccessibilityLabel(title)
  }

  @objc private func runSplitRight() {
    guard canSplitRight() else {
      NSSound.beep()
      return
    }
    enclosingMenuItem?.menu?.cancelTracking()
    splitRight()
  }

  @objc private func runSplitDown() {
    guard canSplitDown() else {
      NSSound.beep()
      return
    }
    enclosingMenuItem?.menu?.cancelTracking()
    splitDown()
  }
}

@MainActor private final class SplitGlyphButton: NSButton {
  private let axis: SplitAxis
  private var trackingArea: NSTrackingArea?
  private var isHovered = false {
    didSet {
      needsDisplay = true
    }
  }

  init(axis: SplitAxis) {
    self.axis = axis
    super.init(frame: .zero)
    isBordered = false
    title = ""
    imagePosition = .imageOnly
    focusRingType = .none
    wantsLayer = true
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let trackingArea {
      removeTrackingArea(trackingArea)
    }
    let options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect]
    let next = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
    addTrackingArea(next)
    trackingArea = next
  }

  override func mouseEntered(with event: NSEvent) {
    isHovered = true
  }

  override func mouseExited(with event: NSEvent) {
    isHovered = false
  }

  override var isEnabled: Bool {
    didSet {
      needsDisplay = true
    }
  }

  override var isHighlighted: Bool {
    didSet {
      needsDisplay = true
    }
  }

  override func draw(_ dirtyRect: NSRect) {
    let activeAlpha: CGFloat = isEnabled ? 1 : 0.36
    let backgroundAlpha: CGFloat = {
      if !isEnabled { return 0.035 }
      if isHighlighted { return 0.16 }
      if isHovered { return 0.11 }
      return 0.055
    }()
    let rect = bounds.insetBy(dx: 1, dy: 1)
    let background = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
    NSColor.labelColor.withAlphaComponent(backgroundAlpha).setFill()
    background.fill()
    NSColor.separatorColor.withAlphaComponent(isHovered && isEnabled ? 0.52 : 0.32).setStroke()
    background.lineWidth = 1
    background.stroke()

    drawSplitGlyph(in: bounds.insetBy(dx: 10, dy: 12), alpha: activeAlpha)
  }

  private func drawSplitGlyph(in rect: NSRect, alpha: CGFloat) {
    let outer = NSBezierPath(roundedRect: rect, xRadius: 2.5, yRadius: 2.5)
    NSColor.labelColor.withAlphaComponent(0.34 * alpha).setStroke()
    outer.lineWidth = 1.15
    outer.stroke()

    let highlightRect: NSRect
    switch axis {
    case .horizontal:
      highlightRect = NSRect(
        x: rect.midX,
        y: rect.minY,
        width: rect.width / 2,
        height: rect.height
      ).insetBy(dx: 2, dy: 2)
    case .vertical:
      highlightRect = NSRect(
        x: rect.minX,
        y: rect.midY,
        width: rect.width,
        height: rect.height / 2
      ).insetBy(dx: 2, dy: 2)
    }
    NSColor.labelColor.withAlphaComponent(0.13 * alpha).setFill()
    NSBezierPath(roundedRect: highlightRect, xRadius: 1.5, yRadius: 1.5).fill()

    let divider = NSBezierPath()
    switch axis {
    case .horizontal:
      divider.move(to: NSPoint(x: rect.midX, y: rect.minY + 1.5))
      divider.line(to: NSPoint(x: rect.midX, y: rect.maxY - 1.5))
    case .vertical:
      divider.move(to: NSPoint(x: rect.minX + 1.5, y: rect.midY))
      divider.line(to: NSPoint(x: rect.maxX - 1.5, y: rect.midY))
    }
    NSColor.labelColor.withAlphaComponent(0.48 * alpha).setStroke()
    divider.lineWidth = 1.3
    divider.stroke()
  }
}

@MainActor private func install(menu: NSMenu, in view: NSView) {
  menu.allowsContextMenuPlugIns = false
  menu.autoenablesItems = false
  view.menu = menu
  if let textView = view as? NSTextView {
    textView.menu = menu
  }
  if let scrollView = view as? NSScrollView {
    scrollView.menu = menu
    scrollView.documentView?.menu = menu
  }
  for subview in view.subviews {
    install(menu: menu, in: subview)
  }
}

private extension KeyboardShortcutBinding {
  var nsMenuKeyEquivalent: String {
    switch key {
    case "leftArrow":
      return String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!))
    case "rightArrow":
      return String(Character(UnicodeScalar(NSRightArrowFunctionKey)!))
    case "upArrow":
      return String(Character(UnicodeScalar(NSUpArrowFunctionKey)!))
    case "downArrow":
      return String(Character(UnicodeScalar(NSDownArrowFunctionKey)!))
    case "escape":
      return String(Character(UnicodeScalar(0x1B)!))
    case "delete":
      return String(Character(UnicodeScalar(NSDeleteCharacter)!))
    case "return":
      return "\r"
    case "tab":
      return "\t"
    case "space":
      return " "
    default:
      return key.count == 1 ? key.lowercased() : ""
    }
  }

  var nsMenuModifierMask: NSEvent.ModifierFlags {
    var mask: NSEvent.ModifierFlags = []
    if modifiers.contains(.command) {
      mask.insert(.command)
    }
    if modifiers.contains(.control) {
      mask.insert(.control)
    }
    if modifiers.contains(.option) {
      mask.insert(.option)
    }
    if modifiers.contains(.shift) {
      mask.insert(.shift)
    }
    return mask
  }
}

struct InspectorView: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Session")
        .font(.headline)
      Text("cwd: \(model.selectedCwd ?? "-")")
        .font(.caption)
        .textSelection(.enabled)
      Text("integration: \(model.shellIntegrationState)")
        .font(.caption)

      Spacer()
    }
    .padding(12)
  }

  private var activeWorkspace: AppModel.WorkspaceRuntime? {
    model.activeWorkspace
  }
}

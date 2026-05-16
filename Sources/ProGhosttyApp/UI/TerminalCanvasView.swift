import AppKit
import ProGhosttyCore
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
      ScrollView {
        Text(selectedOutput)
          .font(.system(size: model.settings.fontSize, design: .monospaced))
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(12)
          .textSelection(.enabled)
      }
      .background(Color(nsColor: model.terminalBackgroundColor))
    }
  }

  private var selectedOutput: String {
    guard model.activeWorkspace != nil else {
      return "No active workspace"
    }
    let output = model.selectedOutput
    return output.isEmpty ? "Terminal ready." : output
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
    controller.update(
      root: root,
      selectedPaneID: model.selectedPaneID,
      onSelect: { model.selectPane($0) },
      onSplit: { paneID, axis in model.splitPane(paneID, axis: axis) },
      onClose: { paneID in model.closePane(paneID) },
      menuText: model.appText,
      palette: model.terminalPalette,
      onResize: { paneID, rows, cols in model.resizePane(paneID, rows: rows, cols: cols) },
      onRatioChanged: { splitID, ratio in model.updateSplitRatio(splitID, ratio: ratio) },
      onWorkspaceSwitcher: { model.openWorkspaceSwitcher() },
      onSettings: { model.openSettingsWindow() },
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
  private var menuText = AppText(language: "system")
  private var palette = TerminalSurfacePalette.dark
  private var onResize: ((UUID, Int, Int) -> Void)?
  private var onRatioChanged: ((UUID, Double) -> Void)?
  private var onWorkspaceSwitcher: (() -> Void)?
  private var onSettings: (() -> Void)?
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
    menuText: AppText,
    palette: TerminalSurfacePalette,
    onResize: @escaping (UUID, Int, Int) -> Void,
    onRatioChanged: @escaping (UUID, Double) -> Void,
    onWorkspaceSwitcher: @escaping () -> Void,
    onSettings: @escaping () -> Void,
    viewForSession: @escaping (TerminalSessionID) -> NSView?
  ) {
    let leafCount = PaneTreeReducer.listLeaves(in: root).count
    DebugLog.write("SplitContainer update rootLeaves=\(leafCount)")
    hasMultiplePanes = leafCount > 1
    self.selectedPaneID = selectedPaneID
    self.onSelect = onSelect
    self.onSplit = onSplit
    self.onClose = onClose
    self.menuText = menuText
    self.palette = palette
    view.layer?.backgroundColor = palette.background.cgColor
    self.onResize = onResize
    self.onRatioChanged = onRatioChanged
    self.onWorkspaceSwitcher = onWorkspaceSwitcher
    self.onSettings = onSettings
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
        menuText: menuText,
        palette: palette,
        onResize: { [weak self] paneID, rows, cols in self?.onResize?(paneID, rows, cols) },
        onWorkspaceSwitcher: { [weak self] in self?.onWorkspaceSwitcher?() },
        onSettings: { [weak self] in self?.onSettings?() }
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
      controller.menuText = menuText
      controller.palette = palette
      controller.hasMultiplePanes = hasMultiplePanes
      controller.onResize = onResize
      controller.onRatioChanged = onRatioChanged
      controller.onWorkspaceSwitcher = onWorkspaceSwitcher
      controller.onSettings = onSettings
      controller.viewForSession = viewForSession
      let splitView = TerminalSplitView()
      splitView.customDividerColor = palette.splitDivider
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
      ratio: targetRatio
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
      splitController.view.layer?.backgroundColor = palette.background.cgColor
      (splitController.view as? TerminalSplitView)?.customDividerColor = palette.splitDivider
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
      menuText: menuText,
      palette: palette,
      dimsWhenInactive: hasMultiplePanes,
      onResize: { [weak self] paneID, rows, cols in self?.onResize?(paneID, rows, cols) },
      onWorkspaceSwitcher: { [weak self] in self?.onWorkspaceSwitcher?() },
      onSettings: { [weak self] in self?.onSettings?() }
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
      dividerThickness: Double(splitView.dividerThickness)
    ) else {
      return proposedMinimumPosition
    }
    return max(proposedMinimumPosition, minimumPaneLength)
  }

  func splitView(
    _ splitView: NSSplitView,
    constrainMaxCoordinate proposedMaximumPosition: CGFloat,
    ofSubviewAt dividerIndex: Int
  ) -> CGFloat {
    let total = splitView.isVertical ? splitView.bounds.width : splitView.bounds.height
    guard SplitRatioLayout.canSplit(
      totalLength: Double(total),
      dividerThickness: Double(splitView.dividerThickness)
    ) else {
      return proposedMaximumPosition
    }
    return min(proposedMaximumPosition, total - splitView.dividerThickness - minimumPaneLength)
  }
}

private final class TerminalSplitView: NSSplitView {
  var isUserResizingDivider = false
  var onUserResizeFinished: (() -> Void)?
  private let dividerInteractionOutset: CGFloat = 4
  var customDividerColor = TerminalSurfacePalette.dark.splitDivider {
    didSet {
      needsDisplay = true
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

  override func mouseDown(with event: NSEvent) {
    guard dividerIndex(at: event) != nil else {
      super.mouseDown(with: event)
      return
    }

    isUserResizingDivider = true
    super.mouseDown(with: event)
    isUserResizingDivider = false
    onUserResizeFinished?()
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
  private var onResize: ((UUID, Int, Int) -> Void)?
  private var lastAppliedSize: CGSize = .zero
  private var pendingResizeSize: CGSize = .zero
  private var pendingResizeWorkItem: DispatchWorkItem?

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
    menuText: AppText,
    palette: TerminalSurfacePalette,
    dimsWhenInactive: Bool = true,
    onResize: @escaping (UUID, Int, Int) -> Void,
    onWorkspaceSwitcher: @escaping () -> Void,
    onSettings: @escaping () -> Void
  ) {
    self.onSelect = onSelect
    self.onResize = onResize
    applyAppearance(isSelected: isSelected, palette: palette, dimsWhenInactive: dimsWhenInactive)
    install(menu: menu(
      onSelect: onSelect,
      onSplit: onSplit,
      onClose: onClose,
      text: menuText,
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
  }

  override func viewDidLayout() {
    super.viewDidLayout()
    let size = view.bounds.size
    guard view.window != nil, size.width > 0, size.height > 0 else {
      pendingResizeWorkItem?.cancel()
      pendingResizeWorkItem = nil
      return
    }

    guard size != lastAppliedSize else {
      pendingResizeWorkItem?.cancel()
      pendingResizeWorkItem = nil
      return
    }

    pendingResizeWorkItem?.cancel()
    pendingResizeSize = size

    let workItem = DispatchWorkItem { [weak self] in
      guard let self, self.pendingResizeSize == size, self.view.bounds.size == size else { return }
      self.pendingResizeWorkItem = nil
      self.lastAppliedSize = size
      let gridSize = self.terminalGridSize(for: size)
      self.onResize?(self.pane.paneId, gridSize.rows, gridSize.cols)
    }

    pendingResizeWorkItem = workItem
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(40), execute: workItem)
  }

  private func terminalGridSize(for size: CGSize) -> (rows: Int, cols: Int) {
    let scale = view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
    let textView = terminalTextView(in: contentView)
    let font = textView?.font ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    let sampleWidth = max(1, ceil(("W" as NSString).size(withAttributes: [.font: font]).width * scale))
    let lineHeight = max(1, ceil((font.ascender - font.descender + font.leading) * scale))
    let inset = textView?.textContainerInset ?? .zero
    let contentWidth = max(1, (size.width - inset.width * 2) * scale)
    let contentHeight = max(1, (size.height - inset.height * 2) * scale)
    return (
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

  private func menu(
    onSelect: @escaping (UUID) -> Void,
    onSplit: @escaping (UUID, SplitAxis) -> Void,
    onClose: @escaping (UUID) -> Void,
    text: AppText,
    onWorkspaceSwitcher: @escaping () -> Void,
    onSettings: @escaping () -> Void
  ) -> NSMenu {
    let menu = NSMenu()
    let paneId = pane.paneId
    menu.addItem(ClosureMenuItem(title: text.splitRight) { [weak self] in
      DebugLog.write("context menu Split Right pane=\(paneId)")
      self?.performSplitIfPossible(axis: .horizontal, onSelect: onSelect, onSplit: onSplit)
    } isEnabled: { [weak self] in
      self?.canSplit(axis: .horizontal) == true
    })
    menu.addItem(ClosureMenuItem(title: text.splitDown) { [weak self] in
      DebugLog.write("context menu Split Down pane=\(paneId)")
      self?.performSplitIfPossible(axis: .vertical, onSelect: onSelect, onSplit: onSplit)
    } isEnabled: { [weak self] in
      self?.canSplit(axis: .vertical) == true
    })
    menu.addItem(.separator())
    menu.addItem(ClosureMenuItem(title: text.closePane) {
      onClose(paneId)
    })
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
}

private final class TerminalPaneHostView: NSView {
  override var acceptsFirstResponder: Bool { true }

  override func mouseDown(with event: NSEvent) {
    nextResponder?.mouseDown(with: event)
  }
}

private final class ClosureMenuItem: NSMenuItem, NSMenuItemValidation {
  private let handler: () -> Void
  private let isEnabledProvider: () -> Bool

  init(
    title: String,
    handler: @escaping () -> Void,
    isEnabled: @escaping () -> Bool = { true }
  ) {
    self.handler = handler
    isEnabledProvider = isEnabled
    super.init(title: title, action: #selector(run), keyEquivalent: "")
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

@MainActor private func install(menu: NSMenu, in view: NSView) {
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

      Divider()

      Text("Recent Block")
        .font(.headline)
      if let block = model.selectedLastBlock {
        CommandBlockMarkerView(block: block)
        Text(block.command ?? "(command unavailable)")
          .font(.system(.caption, design: .monospaced))
          .textSelection(.enabled)
      } else {
        Text("No command block yet")
          .foregroundStyle(.secondary)
      }
      Spacer()
    }
    .padding(12)
  }

  private var activeWorkspace: AppModel.WorkspaceRuntime? {
    model.activeWorkspace
  }
}

struct CommandBlockMarkerView: View {
  let block: CommandBlock

  var body: some View {
    HStack {
      Text(symbol)
      Text(block.status.rawValue)
      if let duration = block.durationMs {
        Text("\(duration) ms")
      }
      if let exitCode = block.exitCode {
        Text("exit \(exitCode)")
      }
    }
    .font(.caption)
    .padding(6)
    .background(.quaternary)
    .clipShape(RoundedRectangle(cornerRadius: 6))
  }

  private var symbol: String {
    switch block.status {
    case .running: "..."
    case .success: "✓"
    case .failed: "✗"
    case .cancelled: "!"
    case .unknown, .partial: "?"
    }
  }
}

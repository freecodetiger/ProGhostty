import AppKit
import ProGhosttyCore
import QuartzCore
import SwiftUI

// Pane-hosting chrome extracted from TerminalCanvasView.swift (debt spec D3):
// drop-target host view, side-input overlay, and context-menu controls.

final class TerminalPaneHostView: NSView {
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

@MainActor final class TerminalSideInputOverlayView: NSView {
  private let scrollView = NSScrollView()
  private let textView = TerminalSideInputTextView()
  private let placeholderField = NSTextField(labelWithString: "")
  private(set) var preferredOverlayHeight: CGFloat = 40

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
    NSLayoutConstraint.activate([
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
    preferredOverlayHeight = min(116, max(40, CGFloat(lineCount) * 18 + 22))
    superview?.needsLayout = true
  }

  private func updatePlaceholderVisibility() {
    placeholderField.isHidden = !textView.string.isEmpty
  }
}

@MainActor final class TerminalSideInputTextView: NSTextView {
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

final class ClosureMenuItem: NSMenuItem, NSMenuItemValidation {
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

@MainActor final class SplitControlMenuItem: NSMenuItem, NSMenuItemValidation {
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

@MainActor final class SplitControlMenuView: NSView {
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

@MainActor final class SplitGlyphButton: NSButton {
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

@MainActor func install(menu: NSMenu, in view: NSView) {
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


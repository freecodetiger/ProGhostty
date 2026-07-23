import AppKit

/// Pointer-anchored actions Popover for a semantic object — a URL or a file path
/// (spec §6). Quiet by default; only appears on a deliberate primary click on a
/// target already lit by proximity. Anchored at the pointer, not the token start.
/// ⌘-click bypasses this and acts immediately (handled in the view).
@MainActor
final class SemanticLinkPopover {
  private var popover: NSPopover?

  struct Item {
    var title: String
    var symbol: String
    var handler: () -> Void
  }

  /// Present the popover titled `title` with `items`, anchored at `point`.
  /// `palette` sources the hover colors from the active terminal theme so the menu
  /// matches the terminal (consistent across light/dark, no system accent blue).
  func present(title: String, headerIcon: NSImage? = nil, detailRows: [FileDetailFormatter.Row] = [], items: [Item], at point: NSPoint, in view: NSView, palette: TerminalSurfacePalette) {
    // A popover requires an on-screen host window; skip if detached (e.g. tests).
    guard view.window != nil, !items.isEmpty else { return }
    dismiss()
    let controller = SemanticLinkPopoverController(title: title, headerIcon: headerIcon, detailRows: detailRows, items: items, palette: palette)
    let popover = NSPopover()
    popover.behavior = .transient
    popover.animates = true
    // Match the popover chrome to the terminal theme so it doesn't flip to the
    // system light/dark independently of the active theme.
    popover.appearance = NSAppearance(named: palette.background.isDarkColor ? .darkAqua : .aqua)
    popover.contentViewController = controller
    controller.onClose = { [weak popover] in popover?.performClose(nil) }
    // 1x1 anchor rect at the pointer so the popover points at the cursor, not the
    // token's start cell (spec §6).
    let anchorRect = NSRect(x: point.x, y: point.y, width: 1, height: 1)
    popover.show(relativeTo: anchorRect, of: view, preferredEdge: .maxY)
    self.popover = popover
  }

  func dismiss() {
    popover?.performClose(nil)
    popover = nil
  }
}

@MainActor
private final class SemanticLinkPopoverController: NSViewController {
  private let titleText: String
  private let headerIcon: NSImage?
  private let detailRows: [FileDetailFormatter.Row]
  private let items: [SemanticLinkPopover.Item]
  private let palette: TerminalSurfacePalette
  var onClose: (() -> Void)?

  init(title: String, headerIcon: NSImage?, detailRows: [FileDetailFormatter.Row], items: [SemanticLinkPopover.Item], palette: TerminalSurfacePalette) {
    self.titleText = title
    self.headerIcon = headerIcon
    self.detailRows = detailRows
    self.items = items
    self.palette = palette
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

  override func loadView() {
    let container = NSView()
    container.wantsLayer = true

    let buttons = items.map { item in
      makeActionButton(title: item.title, symbol: item.symbol) { [weak self] in
        // Close the popover first, then run the action on the next runloop so the
        // transient popover's dismissal + key-window change don't race the action
        // (e.g. a titlebar toast getting swallowed mid-transition).
        self?.onClose?()
        DispatchQueue.main.async { item.handler() }
      }
    }
    let buttonStack = NSStackView(views: buttons)
    buttonStack.orientation = .vertical
    buttonStack.alignment = .leading
    buttonStack.spacing = 2
    buttonStack.translatesAutoresizingMaskIntoConstraints = false
    for button in buttons {
      button.widthAnchor.constraint(equalTo: buttonStack.widthAnchor).isActive = true
    }

    // Header: file-type / site icon + prominent name. Info rows: icon + value.
    let header = makeHeader()
    var rowViews: [NSView] = detailRows.map { makeDetailRow(symbol: $0.symbol, text: $0.text) }
    if !rowViews.isEmpty {
      rowViews.insert(makeSeparator(), at: 0)
    }

    let stack = NSStackView(views: [header] + rowViews + [makeSeparator(), buttonStack])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 6
    stack.setCustomSpacing(rowViews.isEmpty ? 10 : 8, after: header)
    stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
    stack.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(stack)

    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      stack.topAnchor.constraint(equalTo: container.topAnchor),
      stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
      header.widthAnchor.constraint(lessThanOrEqualToConstant: 320),
      buttonStack.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 12),
      buttonStack.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -12),
    ])
    view = container
  }

  private func makeHeader() -> NSView {
    let titleLabel = NSTextField(labelWithString: titleText)
    titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
    titleLabel.textColor = palette.foreground.withAlphaComponent(0.9)
    titleLabel.lineBreakMode = .byTruncatingMiddle
    titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    guard let headerIcon else { return titleLabel }
    let iconView = NSImageView()
    iconView.image = headerIcon
    iconView.imageScaling = .scaleProportionallyUpOrDown
    iconView.symbolConfiguration = .init(pointSize: 18, weight: .regular)
    iconView.contentTintColor = palette.foreground.withAlphaComponent(0.85)
    iconView.translatesAutoresizingMaskIntoConstraints = false
    iconView.widthAnchor.constraint(equalToConstant: 22).isActive = true
    iconView.heightAnchor.constraint(equalToConstant: 22).isActive = true

    let row = NSStackView(views: [iconView, titleLabel])
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 8
    return row
  }

  private func makeDetailRow(symbol: String, text: String) -> NSView {
    let iconView = NSImageView()
    iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    iconView.symbolConfiguration = .init(pointSize: 10, weight: .regular)
    iconView.contentTintColor = palette.foreground.withAlphaComponent(0.45)
    iconView.translatesAutoresizingMaskIntoConstraints = false
    iconView.widthAnchor.constraint(equalToConstant: 13).isActive = true

    let label = NSTextField(labelWithString: text)
    label.font = .systemFont(ofSize: 11, weight: .regular)
    label.textColor = palette.foreground.withAlphaComponent(0.5)
    label.lineBreakMode = .byTruncatingMiddle
    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    label.widthAnchor.constraint(lessThanOrEqualToConstant: 300).isActive = true

    let row = NSStackView(views: [iconView, label])
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 6
    return row
  }

  private func makeSeparator() -> NSView {
    let line = NSView()
    line.wantsLayer = true
    line.layer?.backgroundColor = palette.foreground.withAlphaComponent(0.12).cgColor
    line.translatesAutoresizingMaskIntoConstraints = false
    line.heightAnchor.constraint(equalToConstant: 1).isActive = true
    line.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
    return line
  }

  private func makeActionButton(title: String, symbol: String, action: @escaping () -> Void) -> NSButton {
    let button = ClosureButton(title: title, symbol: symbol, foreground: palette.foreground, onClick: action)
    button.translatesAutoresizingMaskIntoConstraints = false
    return button
  }
}

/// A borderless, left-aligned action row button with a hover highlight.
@MainActor
private final class ClosureButton: NSButton {
  private let onClick: () -> Void
  private let foreground: NSColor
  private var trackingArea: NSTrackingArea?
  private var isHovered = false {
    didSet { updateHoverAppearance() }
  }

  init(title: String, symbol: String, foreground: NSColor, onClick: @escaping () -> Void) {
    self.onClick = onClick
    self.foreground = foreground
    super.init(frame: .zero)
    self.title = "  \(title)"
    self.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
    self.imagePosition = .imageLeading
    self.bezelStyle = .inline
    self.isBordered = false
    self.contentTintColor = foreground
    self.font = .systemFont(ofSize: 13, weight: .regular)
    self.target = self
    self.action = #selector(handleClick)
    self.alignment = .left
    self.wantsLayer = true
    self.layer?.cornerRadius = 6
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let trackingArea { removeTrackingArea(trackingArea) }
    let area = NSTrackingArea(
      rect: bounds,
      options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
      owner: self,
      userInfo: nil
    )
    addTrackingArea(area)
    trackingArea = area
  }

  override func mouseEntered(with event: NSEvent) { isHovered = true }
  override func mouseExited(with event: NSEvent) { isHovered = false }

  private func updateHoverAppearance() {
    // Hover uses the terminal theme's foreground at low alpha — consistent across
    // light/dark, matches the terminal, and avoids the system accent (blue).
    layer?.backgroundColor = isHovered
      ? foreground.withAlphaComponent(0.12).cgColor
      : NSColor.clear.cgColor
    contentTintColor = foreground
  }

  @objc private func handleClick() { onClick() }
}

private extension NSColor {
  /// Whether this color is dark enough to warrant a dark-appearance popover.
  var isDarkColor: Bool {
    let rgb = usingColorSpace(.deviceRGB) ?? self
    let luminance = 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
    return luminance < 0.5
  }
}

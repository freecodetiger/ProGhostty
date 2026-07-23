import AppKit
import ProGhosttyCore

/// View controller for `ProjectInfoPopover`. Rebuilds its stack on `update` so
/// the async git result replaces the "loading" placeholder in place.
@MainActor
final class ProjectInfoPopoverController: NSViewController {
  private var info: ProjectInfo
  private var isLoading: Bool
  private let palette: TerminalSurfacePalette
  private let text: AppText
  private let callbacks: ProjectInfoPopover.Callbacks

  private let stack = NSStackView()

  init(
    info: ProjectInfo,
    isLoading: Bool,
    palette: TerminalSurfacePalette,
    text: AppText,
    callbacks: ProjectInfoPopover.Callbacks
  ) {
    self.info = info
    self.isLoading = isLoading
    self.palette = palette
    self.text = text
    self.callbacks = callbacks
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

  func update(info: ProjectInfo, isLoading: Bool) {
    self.info = info
    self.isLoading = isLoading
    guard isViewLoaded else { return }
    rebuild()
    // The .git guess on open may be refined by the fetch (e.g. bare repo); keep
    // the panel width in sync with the confirmed kind.
    widthConstraint?.constant = panelWidth
    // Grow the popover to the new content height smoothly instead of snapping —
    // the git result arrives ~100ms after open, and an instant resize reads as a
    // jarring jump. Animate preferredContentSize; NSPopover follows it.
    view.layoutSubtreeIfNeeded()
    let target = NSSize(width: panelWidth, height: view.fittingSize.height)
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.16
      context.timingFunction = CAMediaTimingFunction(name: .easeOut)
      context.allowsImplicitAnimation = true
      preferredContentSize = target
    }
  }

  override func loadView() {
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 6
    stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
    stack.translatesAutoresizingMaskIntoConstraints = false
    let container = NSView()
    container.wantsLayer = true
    container.addSubview(stack)
    let width = stack.widthAnchor.constraint(equalToConstant: panelWidth)
    widthConstraint = width
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      stack.topAnchor.constraint(equalTo: container.topAnchor),
      stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
      // Fixed content width so every row shares one left + right edge (and so the
      // wrapping commit subject has a definite width to wrap against). Git repos
      // get a wider panel (commit subjects); plain dirs stay narrow.
      width,
    ])
    view = container
    rebuild()
    view.layoutSubtreeIfNeeded()
    preferredContentSize = NSSize(width: panelWidth, height: view.fittingSize.height)
  }

  private var widthConstraint: NSLayoutConstraint?

  /// Git repos need room for commit subjects; a plain directory only shows the
  /// path + "not a repo", so it stays narrow (two fixed widths, chosen by kind).
  private static let gitPanelWidth: CGFloat = 300
  private static let plainPanelWidth: CGFloat = 250
  private var panelWidth: CGFloat { info.isGitRepository ? Self.gitPanelWidth : Self.plainPanelWidth }
  private var contentWidth: CGFloat { panelWidth - 24 }

  private var fg: NSColor { palette.foreground }

  private func rebuild() {
    for sub in stack.arrangedSubviews {
      stack.removeArrangedSubview(sub)
      sub.removeFromSuperview()
    }

    let header = makeHeader()
    stack.addArrangedSubview(header)
    stack.setCustomSpacing(8, after: header)

    let pathLabel = makeLabel(info.absolutePath, size: 11, alpha: 0.5, monospaced: true, maxWidth: 360)
    stack.addArrangedSubview(pathLabel)
    stack.setCustomSpacing(10, after: pathLabel)

    stack.addArrangedSubview(makeSeparator())
    for row in statusRows() { stack.addArrangedSubview(makeDetailRow(symbol: row.symbol, text: row.text)) }

    // Recent commit history (git repo only): a small section title + one two-line
    // block per commit (meta line + subject), so subjects read in full. Aligned
    // to the panel's left edge — same start as the detail-row icons above.
    if info.isGitRepository, !info.recentCommits.isEmpty {
      let lastStatus = stack.arrangedSubviews.last
      if let lastStatus { stack.setCustomSpacing(10, after: lastStatus) }
      stack.addArrangedSubview(makeSeparator())
      let sectionTitle = makeLabel(text.projectRecentCommits, size: 10, alpha: 0.4, maxWidth: contentWidth)
      stack.addArrangedSubview(sectionTitle)
      stack.setCustomSpacing(6, after: sectionTitle)
      for (index, commit) in info.recentCommits.enumerated() {
        let block = makeCommitBlock(commit)
        stack.addArrangedSubview(block)
        if index < info.recentCommits.count - 1 { stack.setCustomSpacing(8, after: block) }
      }
    }

    let lastRow = stack.arrangedSubviews.last
    stack.addArrangedSubview(makeSeparator())
    if let lastRow { stack.setCustomSpacing(10, after: lastRow) }

    let actions = makeActions()
    stack.addArrangedSubview(actions)
    actions.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
  }

  private func makeHeader() -> NSView {
    let icon = NSImageView()
    icon.image = NSImage(systemSymbolName: info.isGitRepository ? "shippingbox" : "folder", accessibilityDescription: nil)
    icon.symbolConfiguration = .init(pointSize: 16, weight: .regular)
    icon.contentTintColor = fg.withAlphaComponent(0.85)
    icon.translatesAutoresizingMaskIntoConstraints = false
    icon.widthAnchor.constraint(equalToConstant: 20).isActive = true

    let title = makeLabel(info.displayName, size: 13, alpha: 0.9, weight: .medium, maxWidth: 320)
    let row = NSStackView(views: [icon, title])
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 8
    return row
  }

  private func statusRows() -> [(symbol: String, text: String)] {
    // A plain directory is known synchronously on open (via the .git check), so
    // show its final "not a repo" state immediately rather than a "loading" that
    // flips a moment later.
    guard info.isGitRepository else { return [("info.circle", text.projectNotGitRepo)] }
    if isLoading { return [("clock", text.projectLoading)] }

    var rows: [(String, String)] = []
    if let branch = info.branch {
      rows.append(("arrow.triangle.branch", branch))
    }
    if info.modifiedCount == 0, info.addedCount == 0 {
      rows.append(("checkmark.circle", text.projectClean))
    } else {
      var parts: [String] = []
      if info.modifiedCount > 0 { parts.append("\(info.modifiedCount) \(text.projectModified)") }
      if info.addedCount > 0 { parts.append("\(info.addedCount) \(text.projectAdded)") }
      rows.append(("circle.fill", parts.joined(separator: " · ")))
    }
    return rows
  }

  /// Two-line block for one commit: a small meta line (hash · relative time ·
  /// author) and the subject on its own line so it reads in full.
  private func makeCommitBlock(_ commit: GitCommit) -> NSView {
    var metaParts = [commit.shortHash]
    if let date = commit.date {
      let rel = RelativeDateTimeFormatter()
      rel.unitsStyle = .full
      rel.locale = text.semanticLinkText.locale
      metaParts.append(rel.localizedString(for: date, relativeTo: Date()))
    }
    if let author = commit.author { metaParts.append(author) }

    let meta = makeLabel(metaParts.joined(separator: " · "), size: 10, alpha: 0.4, monospaced: false, maxWidth: contentWidth)
    // Subject wraps across up to two lines (word wrap, then tail-truncate) so a
    // longer commit message reads more fully instead of cutting off on one line.
    let subjectWidth = contentWidth
    let subject = makeLabel(commit.subject, size: 12, alpha: 0.8, maxWidth: subjectWidth)
    subject.lineBreakMode = .byWordWrapping
    subject.usesSingleLineMode = false
    subject.cell?.wraps = true
    subject.cell?.isScrollable = false
    subject.maximumNumberOfLines = 2
    subject.preferredMaxLayoutWidth = subjectWidth
    subject.widthAnchor.constraint(equalToConstant: subjectWidth).isActive = true

    let block = NSStackView(views: [meta, subject])
    block.orientation = .vertical
    block.alignment = .leading
    block.spacing = 1
    return block
  }

  private func makeActions() -> NSView {
    var buttons: [NSButton] = []
    if let remote = info.remoteURL {
      buttons.append(makeButton(title: text.projectOpenRemote, symbol: "globe") { [callbacks] in
        callbacks.openRemote(remote)
      })
    }
    buttons.append(makeButton(title: text.projectCopyPath, symbol: "doc.on.clipboard") { [callbacks, path = info.absolutePath] in
      callbacks.copyPath(path)
    })
    buttons.append(makeButton(title: text.projectRevealInFinder, symbol: "folder") { [callbacks, path = info.absolutePath] in
      callbacks.revealInFinder(path)
    })
    let vstack = NSStackView(views: buttons)
    vstack.orientation = .vertical
    vstack.alignment = .leading
    vstack.spacing = 2
    for b in buttons { b.widthAnchor.constraint(equalTo: vstack.widthAnchor).isActive = true }
    return vstack
  }

  // MARK: - Builders

  private func makeLabel(_ string: String, size: CGFloat, alpha: CGFloat, weight: NSFont.Weight = .regular, monospaced: Bool = false, maxWidth: CGFloat) -> NSTextField {
    let label = NSTextField(labelWithString: string)
    label.font = monospaced ? .monospacedSystemFont(ofSize: size, weight: weight) : .systemFont(ofSize: size, weight: weight)
    label.textColor = fg.withAlphaComponent(alpha)
    label.lineBreakMode = .byTruncatingMiddle
    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    label.widthAnchor.constraint(lessThanOrEqualToConstant: maxWidth).isActive = true
    return label
  }

  private func makeDetailRow(symbol: String, text: String) -> NSView {
    let icon = NSImageView()
    icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    icon.symbolConfiguration = .init(pointSize: 10, weight: .regular)
    icon.contentTintColor = fg.withAlphaComponent(0.45)
    icon.translatesAutoresizingMaskIntoConstraints = false
    icon.widthAnchor.constraint(equalToConstant: 14).isActive = true

    let label = makeLabel(text, size: 11, alpha: 0.55, maxWidth: 320)
    let row = NSStackView(views: [icon, label])
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 6
    return row
  }

  private func makeSeparator() -> NSView {
    let line = NSView()
    line.wantsLayer = true
    line.layer?.backgroundColor = fg.withAlphaComponent(0.12).cgColor
    line.translatesAutoresizingMaskIntoConstraints = false
    line.heightAnchor.constraint(equalToConstant: 1).isActive = true
    line.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
    return line
  }

  private func makeButton(title: String, symbol: String, action: @escaping () -> Void) -> NSButton {
    let button = ProjectInfoButton(title: title, symbol: symbol, foreground: fg) { [weak self] in
      self?.dismissAndRun(action)
    }
    button.translatesAutoresizingMaskIntoConstraints = false
    return button
  }

  private func dismissAndRun(_ action: @escaping () -> Void) {
    view.window?.performClose(nil)
    DispatchQueue.main.async(execute: action)
  }
}

/// Borderless left-aligned action row with a hover highlight (mirrors the file
/// popover's button).
@MainActor
private final class ProjectInfoButton: NSButton {
  private let onClick: () -> Void
  private let foreground: NSColor
  private var trackingArea: NSTrackingArea?
  private var isHovered = false { didSet { updateHover() } }

  init(title: String, symbol: String, foreground: NSColor, onClick: @escaping () -> Void) {
    self.onClick = onClick
    self.foreground = foreground
    super.init(frame: .zero)
    self.title = "  \(title)"
    image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
    imagePosition = .imageLeading
    isBordered = false
    contentTintColor = foreground
    font = .systemFont(ofSize: 13, weight: .regular)
    alignment = .left
    wantsLayer = true
    layer?.cornerRadius = 6
    target = self
    action = #selector(handleClick)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let trackingArea { removeTrackingArea(trackingArea) }
    let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
    addTrackingArea(area)
    trackingArea = area
  }

  override func mouseEntered(with event: NSEvent) { isHovered = true }
  override func mouseExited(with event: NSEvent) { isHovered = false }

  private func updateHover() {
    layer?.backgroundColor = isHovered ? foreground.withAlphaComponent(0.12).cgColor : NSColor.clear.cgColor
  }

  @objc private func handleClick() { onClick() }
}

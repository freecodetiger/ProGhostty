import AppKit
import ProGhosttyCore
import SwiftUI

struct WorkspaceTitlebarView: NSViewRepresentable {
  let title: String
  let tooltip: String?
  let subtitle: String?
  let subtitleTooltip: String?
  let backgroundColor: NSColor
  let usesDarkAppearance: Bool
  let toast: AppModel.TitlebarToast?
  let paneLabel: String?
  let paneAutoTitle: String?
  let onWorkspaceSwitcher: () -> Void
  let onToastClick: () -> Void
  let onSubtitleClick: (NSView, NSRect) -> Void
  let onPaneLabelClick: () -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(onWorkspaceSwitcher: onWorkspaceSwitcher, onToastClick: onToastClick, onSubtitleClick: onSubtitleClick, onPaneLabelClick: onPaneLabelClick)
  }

  func makeNSView(context: Context) -> NSView {
    NSView(frame: .zero)
  }

  func updateNSView(_ view: NSView, context: Context) {
    context.coordinator.title = title
    context.coordinator.tooltip = tooltip
    context.coordinator.subtitle = subtitle
    context.coordinator.subtitleTooltip = subtitleTooltip
    context.coordinator.backgroundColor = backgroundColor
    context.coordinator.usesDarkAppearance = usesDarkAppearance
    context.coordinator.toast = toast
    context.coordinator.paneLabel = paneLabel
    context.coordinator.paneAutoTitle = paneAutoTitle
    context.coordinator.onWorkspaceSwitcher = onWorkspaceSwitcher
    context.coordinator.onToastClick = onToastClick
    context.coordinator.onSubtitleClick = onSubtitleClick
    context.coordinator.onPaneLabelClick = onPaneLabelClick

    if let window = view.window {
      apply(to: window, context: context)
    } else {
      DispatchQueue.main.async {
        guard let window = view.window else { return }
        apply(to: window, context: context)
      }
    }
  }

  private func apply(to window: NSWindow, context: Context) {
    context.coordinator.installIfNeeded(in: window)
    context.coordinator.updateTitle(in: window)
    context.coordinator.updateWindowAppearance(window)
  }

  @MainActor final class Coordinator: NSObject {
    var title: String = "ProGhostty"
    var tooltip: String?
    var subtitle: String?
    var subtitleTooltip: String?
    var backgroundColor: NSColor = .black
    var usesDarkAppearance = true
    var toast: AppModel.TitlebarToast?
    var paneLabel: String?
    var paneAutoTitle: String?
    var onWorkspaceSwitcher: () -> Void
    var onToastClick: () -> Void
    var onSubtitleClick: (NSView, NSRect) -> Void
    var onPaneLabelClick: () -> Void
    private var isSubtitleHovered = false

    private weak var installedWindow: NSWindow?
    private let titlebarControlsStack = NSStackView()
    private let subtitleLabel = TitlebarHoverLabel(labelWithString: "")
    private let paneLabelLabel: NSTextField = {
      let label = NSTextField(labelWithString: "")
      label.font = .systemFont(ofSize: 12, weight: .medium)
      label.alignment = .left
      label.lineBreakMode = .byTruncatingMiddle
      label.maximumNumberOfLines = 1
      label.drawsBackground = false
      label.isBordered = false
      label.isEditable = false
      label.isSelectable = false
      label.translatesAutoresizingMaskIntoConstraints = false
      label.setContentHuggingPriority(.defaultLow, for: .horizontal)
      label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
      return label
    }()
    private let toastView = TitlebarToastCapsuleView()
    private let button = NSButton(title: "ProGhostty", target: nil, action: nil)
    private let titlebarBackgroundView = TitlebarBackgroundView()
    private let subtitleWidthConstraint: NSLayoutConstraint
    private var titlebarBackgroundConstraints: [NSLayoutConstraint] = []
    private var subtitleConstraints: [NSLayoutConstraint] = []
    private var paneLabelConstraints: [NSLayoutConstraint] = []
    private var titlebarControlsConstraints: [NSLayoutConstraint] = []
    private let notificationObservers = NotificationObserverBag()
    private var appearanceGeneration = 0

    init(onWorkspaceSwitcher: @escaping () -> Void, onToastClick: @escaping () -> Void, onSubtitleClick: @escaping (NSView, NSRect) -> Void, onPaneLabelClick: @escaping () -> Void) {
      self.onWorkspaceSwitcher = onWorkspaceSwitcher
      self.onToastClick = onToastClick
      self.onSubtitleClick = onSubtitleClick
      self.onPaneLabelClick = onPaneLabelClick
      subtitleWidthConstraint = subtitleLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 360)
      super.init()
      titlebarBackgroundView.identifier = ProGhosttyWindowAppearance.titlebarBackgroundIdentifier
      button.target = self
      button.action = #selector(openWorkspaceSwitcher)
      button.bezelStyle = .inline
      button.isBordered = false
      button.wantsLayer = true
      button.layer?.backgroundColor = NSColor.clear.cgColor
      button.font = .systemFont(ofSize: 12, weight: .medium)
      button.contentTintColor = .secondaryLabelColor
      button.lineBreakMode = .byTruncatingMiddle
      button.cell?.lineBreakMode = .byTruncatingMiddle
      button.cell?.wraps = false
      button.setContentHuggingPriority(.required, for: .horizontal)
      button.widthAnchor.constraint(lessThanOrEqualToConstant: 360).isActive = true
      subtitleLabel.font = .systemFont(ofSize: 12, weight: .medium)
      subtitleLabel.alignment = .center
      subtitleLabel.lineBreakMode = .byTruncatingMiddle
      subtitleLabel.maximumNumberOfLines = 1
      subtitleLabel.drawsBackground = false
      subtitleLabel.isBordered = false
      subtitleLabel.isEditable = false
      subtitleLabel.isSelectable = false
      subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
      subtitleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
      subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
      subtitleWidthConstraint.isActive = true
      subtitleLabel.onHoverChanged = { [weak self] isHovered in
        self?.isSubtitleHovered = isHovered
        self?.updateSubtitle()
      }
      subtitleLabel.onClick = { [weak self] label in
        guard let self, self.subtitle != nil else { return }
        // Anchor the panel at the label's frame in its own coordinates.
        self.onSubtitleClick(label, label.bounds)
      }
      let paneLabelClick = NSClickGestureRecognizer(target: self, action: #selector(paneLabelClicked))
      paneLabelLabel.addGestureRecognizer(paneLabelClick)
      titlebarControlsStack.orientation = .horizontal
      titlebarControlsStack.alignment = .centerY
      titlebarControlsStack.spacing = 8
      titlebarControlsStack.detachesHiddenViews = true
      titlebarControlsStack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 12)
      titlebarControlsStack.addArrangedSubview(toastView)
      titlebarControlsStack.addArrangedSubview(button)
      titlebarBackgroundView.wantsLayer = true
      toastView.target = self
      toastView.action = #selector(openToastAction)
    }

    func installIfNeeded(in window: NSWindow) {
      guard installedWindow !== window else { return }

      installedWindow = window
      updateWindowAppearance(window)
      installTitlebarBackground(in: window)
      installTitlebarControls(in: window)
      installWindowObservers(for: window)
    }

    func updateTitle(in window: NSWindow) {
      window.title = title
      button.title = title
      button.toolTip = tooltip
      updateSubtitle()
      updatePaneLabel()
      updateToast()
    }

    private func updatePaneLabel() {
      // Manual label wins; the program-reported title only fills the gap.
      let manual = (paneLabel?.isEmpty == false) ? paneLabel : nil
      let auto = (paneAutoTitle?.isEmpty == false) ? paneAutoTitle : nil
      guard let display = manual ?? auto else {
        paneLabelLabel.isHidden = true
        paneLabelLabel.toolTip = nil
        return
      }
      paneLabelLabel.isHidden = false
      paneLabelLabel.stringValue = display
      paneLabelLabel.textColor = manual != nil ? button.contentTintColor : autoTitleColor
      paneLabelLabel.toolTip = manual == nil ? display : nil
      refreshAccessoryLayout()
    }

    /// One step weaker than the manual-label tint so reported titles read as
    /// ambient state, not something the user named.
    private var autoTitleColor: NSColor {
      usesDarkAppearance
        ? NSColor(calibratedWhite: 0.6, alpha: 1)
        : .tertiaryLabelColor
    }

    func updateWindowAppearance(_ window: NSWindow) {
      appearanceGeneration += 1
      applyWindowAppearanceNow(window)
      scheduleTitlebarStabilization(for: window, generation: appearanceGeneration)
    }

    private func applyWindowAppearanceNow(_ window: NSWindow) {
      ProGhosttyWindowAppearance.applyTerminalChrome(
        to: window,
        backgroundColor: backgroundColor,
        usesDarkAppearance: usesDarkAppearance
      )
      titlebarBackgroundView.layer?.backgroundColor = backgroundColor.cgColor
      button.contentTintColor = usesDarkAppearance
        ? NSColor(calibratedWhite: 0.78, alpha: 1)
        : .secondaryLabelColor
      subtitleLabel.textColor = button.contentTintColor
      updateToast()
      window.isMovableByWindowBackground = false
      installTitlebarBackground(in: window)
      installTitlebarControls(in: window)
      harmonizeTitlebarMaterials(in: window)
      keepTitlebarViewsOrdered(in: window)
    }

    private func scheduleTitlebarStabilization(for window: NSWindow, generation: Int) {
      DispatchQueue.main.async { [weak self, weak window] in
        guard let self, let window else { return }
        self.applyDeferredWindowAppearance(window, generation: generation)
      }
      for delay in [0.05, 0.20] {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak window] in
          guard let self, let window else { return }
          self.applyDeferredWindowAppearance(window, generation: generation)
        }
      }
    }

    private func applyDeferredWindowAppearance(_ window: NSWindow, generation: Int) {
      guard generation == appearanceGeneration else { return }
      applyWindowAppearanceNow(window)
      updateSubtitle()
      updatePaneLabel()
      updateToast()
    }

    private func updateSubtitle() {
      guard let subtitle else {
        subtitleLabel.isHidden = true
        subtitleLabel.stringValue = ""
        subtitleLabel.toolTip = nil
        isSubtitleHovered = false
        subtitleWidthConstraint.constant = 360
        refreshAccessoryLayout()
        return
      }

      subtitleLabel.isHidden = false
      if isSubtitleHovered, let subtitleTooltip, !subtitleTooltip.isEmpty {
        subtitleLabel.stringValue = "📁 \(middleTruncated(subtitleTooltip, limit: 72))"
        subtitleWidthConstraint.constant = 760
      } else {
        subtitleLabel.stringValue = subtitle
        subtitleWidthConstraint.constant = 360
      }
      subtitleLabel.toolTip = nil
      refreshAccessoryLayout()
    }

    private func updateToast() {
      guard let toast else {
        toastView.update(message: nil, colors: nil, isActionable: false)
        refreshAccessoryLayout()
        return
      }

      let colors: ProGhosttyTitlebarToastColors
      switch toast.style {
      case .success:
        colors = ProGhosttyTitlebarToastPalette.success(usesDarkAppearance: usesDarkAppearance)
      case .info:
        colors = ProGhosttyTitlebarToastPalette.info(usesDarkAppearance: usesDarkAppearance)
      case .error:
        colors = ProGhosttyTitlebarToastPalette.error(usesDarkAppearance: usesDarkAppearance)
      case .update:
        colors = ProGhosttyTitlebarToastPalette.info(usesDarkAppearance: usesDarkAppearance)
      }
      toastView.update(message: toast.message, colors: colors, isActionable: toast.isActionable)
      refreshAccessoryLayout()
    }

    private func refreshAccessoryLayout() {
      titlebarControlsStack.invalidateIntrinsicContentSize()
      titlebarControlsStack.needsLayout = true
      titlebarControlsStack.layoutSubtreeIfNeeded()
      subtitleLabel.invalidateIntrinsicContentSize()
      subtitleLabel.needsLayout = true
      subtitleLabel.layoutSubtreeIfNeeded()
      guard let host = installedWindow?.contentView?.superview else { return }
      host.needsLayout = true
      // Defer the host re-layout: forcing layoutSubtreeIfNeeded here synchronously
      // re-enters the SwiftUI hosting view's layout and re-triggers updateNSView.
      DispatchQueue.main.async {
        host.layoutSubtreeIfNeeded()
      }
    }

    private func middleTruncated(_ text: String, limit: Int) -> String {
      let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard trimmed.count > limit, limit > 1 else { return trimmed }

      let ellipsis = "…"
      let visibleCount = max(1, limit - ellipsis.count)
      let prefixCount = max(1, visibleCount / 2)
      let suffixCount = max(1, visibleCount - prefixCount)
      let prefix = trimmed.prefix(prefixCount)
      let suffix = trimmed.suffix(suffixCount)
      return "\(prefix)\(ellipsis)\(suffix)"
    }

    private func forceReinstall(in window: NSWindow) {
      titlebarBackgroundView.removeFromSuperview()
      titlebarControlsStack.removeFromSuperview()
      subtitleLabel.removeFromSuperview()
      paneLabelLabel.removeFromSuperview()
      installTitlebarBackground(in: window)
      installTitlebarControls(in: window)
      keepTitlebarViewsOrdered(in: window)
    }

    private func installTitlebarBackground(in window: NSWindow) {
      guard let titlebarHost = titlebarHost(in: window) else { return }

      if titlebarBackgroundView.superview !== titlebarHost {
        NSLayoutConstraint.deactivate(titlebarBackgroundConstraints)
        titlebarBackgroundConstraints.removeAll()
        titlebarBackgroundView.removeFromSuperview()
        titlebarBackgroundView.translatesAutoresizingMaskIntoConstraints = false
        titlebarHost.addSubview(titlebarBackgroundView, positioned: .above, relativeTo: nil)
        titlebarBackgroundConstraints = [
          titlebarBackgroundView.leadingAnchor.constraint(equalTo: titlebarHost.leadingAnchor),
          titlebarBackgroundView.trailingAnchor.constraint(equalTo: titlebarHost.trailingAnchor),
          titlebarBackgroundView.topAnchor.constraint(equalTo: titlebarHost.topAnchor),
          titlebarBackgroundView.bottomAnchor.constraint(equalTo: titlebarHost.bottomAnchor),
        ]
        NSLayoutConstraint.activate(titlebarBackgroundConstraints)
      }

      keepTitlebarViewsOrdered(in: window)
    }

    private func installTitlebarControls(in window: NSWindow) {
      guard let host = titlebarOverlayHost(in: window) else { return }

      if titlebarControlsStack.superview !== host {
        NSLayoutConstraint.deactivate(titlebarControlsConstraints)
        titlebarControlsConstraints.removeAll()
        titlebarControlsStack.removeFromSuperview()
        titlebarControlsStack.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(titlebarControlsStack, positioned: .above, relativeTo: nil)
        titlebarControlsConstraints = [
          titlebarControlsStack.trailingAnchor.constraint(equalTo: host.trailingAnchor),
          titlebarModuleCenterY(for: titlebarControlsStack, in: window, host: host),
          titlebarControlsStack.heightAnchor.constraint(greaterThanOrEqualToConstant: 24),
        ]
        NSLayoutConstraint.activate(titlebarControlsConstraints)
      }

      if subtitleLabel.superview !== host {
        NSLayoutConstraint.deactivate(subtitleConstraints)
        subtitleConstraints.removeAll()
        subtitleLabel.removeFromSuperview()
        host.addSubview(subtitleLabel, positioned: .above, relativeTo: nil)
        subtitleConstraints = [
          subtitleLabel.centerXAnchor.constraint(equalTo: host.centerXAnchor),
          titlebarModuleCenterY(for: subtitleLabel, in: window, host: host),
          subtitleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: host.leadingAnchor, constant: 120),
          subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: titlebarControlsStack.leadingAnchor, constant: -12),
        ]
        NSLayoutConstraint.activate(subtitleConstraints)
      }

      // Pane label: left side, right of traffic lights.
      if paneLabelLabel.superview !== host {
        NSLayoutConstraint.deactivate(paneLabelConstraints)
        paneLabelConstraints.removeAll()
        paneLabelLabel.removeFromSuperview()
        host.addSubview(paneLabelLabel, positioned: .above, relativeTo: nil)
        paneLabelConstraints = [
          paneLabelLabel.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 80),
          titlebarModuleCenterY(for: paneLabelLabel, in: window, host: host),
          paneLabelLabel.trailingAnchor.constraint(lessThanOrEqualTo: subtitleLabel.leadingAnchor, constant: -12),
        ]
        NSLayoutConstraint.activate(paneLabelConstraints)
      }

      keepTitlebarViewsOrdered(in: window)
    }

    private func installWindowObservers(for window: NSWindow) {
      notificationObservers.removeAll()

      let notifications: [Notification.Name] = [
        NSWindow.didBecomeKeyNotification,
        NSWindow.didResignKeyNotification,
        NSWindow.didBecomeMainNotification,
        NSWindow.didResignMainNotification,
        // Fullscreen enter/exit rebuilds the titlebar host hierarchy, detaching
        // our custom titlebar views. Re-run the appearance path so they re-attach
        // (installTitlebarBackground/Controls re-add when superview !== host).
        NSWindow.willEnterFullScreenNotification,
        NSWindow.didEnterFullScreenNotification,
        NSWindow.willExitFullScreenNotification,
        NSWindow.didExitFullScreenNotification,
      ]
      for name in notifications {
        let observer = NotificationCenter.default.addObserver(
          forName: name,
          object: window,
          queue: .main
        ) { [weak self, weak window] _ in
          DispatchQueue.main.async {
            guard let self, let window else { return }
            self.updateWindowAppearance(window)
            // Fullscreen exit leaves the titlebar container in a transient
            // position, so the content's centerY constraint (anchored to the
            // close button) resolves off-screen (frame.minY < 0). Force a
            // remove + re-add to rebuild the constraints against the restored
            // close-button position — immediately, then once more a beat later
            // in case the titlebar was still mid-restore.
            if name == NSWindow.didExitFullScreenNotification {
              self.forceReinstall(in: window)
              DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self, weak window] in
                guard let self, let window else { return }
                self.forceReinstall(in: window)
              }
            }
          }
        }
        notificationObservers.append(observer)
      }
    }

    private func harmonizeTitlebarMaterials(in window: NSWindow) {
      guard let titlebarHost = titlebarHost(in: window) else { return }
      for visualEffectView in titlebarHost.descendants(of: NSVisualEffectView.self) {
        visualEffectView.blendingMode = .withinWindow
        visualEffectView.material = .windowBackground
        visualEffectView.state = .active
        visualEffectView.wantsLayer = true
        visualEffectView.layer?.backgroundColor = backgroundColor.cgColor
      }
    }

    private func keepTitlebarViewsOrdered(in window: NSWindow) {
      guard
        let titlebarHost = titlebarHost(in: window),
        titlebarBackgroundView.superview === titlebarHost
      else {
        return
      }

      titlebarHost.addSubview(titlebarBackgroundView, positioned: .above, relativeTo: nil)

      let controlsToPreserve = [
        window.standardWindowButton(.closeButton),
        window.standardWindowButton(.miniaturizeButton),
        window.standardWindowButton(.zoomButton),
        subtitleLabel,
        paneLabelLabel,
        titlebarControlsStack,
      ].compactMap { $0 }

      for control in controlsToPreserve {
        if let directChild = titlebarHost.directChild(containing: control),
          directChild !== titlebarBackgroundView {
          titlebarHost.addSubview(directChild, positioned: .above, relativeTo: titlebarBackgroundView)
        } else if let overlayHost = titlebarOverlayHost(in: window),
          let directChild = overlayHost.directChild(containing: control) {
          overlayHost.addSubview(directChild, positioned: .above, relativeTo: nil)
        }
      }
    }

    /// Vertically centers a titlebar module on the traffic-light buttons so
    /// text and buttons share one optical line regardless of titlebar height.
    /// Falls back to the old fixed top inset when no close button exists.
    private func titlebarModuleCenterY(for view: NSView, in window: NSWindow, host: NSView) -> NSLayoutConstraint {
      if let closeButton = window.standardWindowButton(.closeButton) {
        return view.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor)
      }
      return view.topAnchor.constraint(equalTo: host.topAnchor, constant: 5)
    }

    private func titlebarHost(in window: NSWindow) -> NSView? {
      window.standardWindowButton(.closeButton)?.superview
        ?? window.contentView?.superview
    }

    private func titlebarOverlayHost(in window: NSWindow) -> NSView? {
      window.contentView?.superview ?? titlebarHost(in: window)
    }

    @objc private func openWorkspaceSwitcher() {
      onWorkspaceSwitcher()
    }

    @objc private func paneLabelClicked() {
      onPaneLabelClick()
    }

    @objc private func openToastAction() {
      onToastClick()
    }
  }
}

private extension AppModel.TitlebarToast {
  var isActionable: Bool {
    switch style {
    case .update:
      return true
    case .success, .info, .error:
      return false
    }
  }
}

private final class TitlebarBackgroundView: NSView {
  override func hitTest(_ point: NSPoint) -> NSView? {
    nil
  }
}

private final class TitlebarHoverLabel: NSTextField {
  var onHoverChanged: ((Bool) -> Void)?
  var onClick: ((NSView) -> Void)?
  private var hoverTrackingArea: NSTrackingArea?

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let hoverTrackingArea {
      removeTrackingArea(hoverTrackingArea)
    }
    let area = NSTrackingArea(
      rect: bounds,
      options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
      owner: self,
      userInfo: nil
    )
    hoverTrackingArea = area
    addTrackingArea(area)
  }

  override func mouseEntered(with event: NSEvent) {
    super.mouseEntered(with: event)
    onHoverChanged?(true)
  }

  override func mouseExited(with event: NSEvent) {
    super.mouseExited(with: event)
    onHoverChanged?(false)
  }

  override func mouseDown(with event: NSEvent) {
    guard onClick != nil, !isHidden else {
      super.mouseDown(with: event)
      return
    }
    onClick?(self)
  }
}

private final class TitlebarToastCapsuleView: NSView {
  private let label = NSTextField(labelWithString: "")
  private var colors: ProGhosttyTitlebarToastColors?
  weak var target: AnyObject?
  var action: Selector?
  private var isActionable = false

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.masksToBounds = false
    isHidden = true

    label.font = .systemFont(ofSize: 11, weight: .medium)
    label.lineBreakMode = .byTruncatingTail
    label.maximumNumberOfLines = 1
    label.drawsBackground = false
    label.isBordered = false
    label.translatesAutoresizingMaskIntoConstraints = false
    addSubview(label)

    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: ProGhosttyTitlebarToastMetrics.horizontalPadding),
      label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -ProGhosttyTitlebarToastMetrics.horizontalPadding),
      label.topAnchor.constraint(equalTo: topAnchor, constant: ProGhosttyTitlebarToastMetrics.verticalPadding),
      label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -ProGhosttyTitlebarToastMetrics.verticalPadding),
      widthAnchor.constraint(lessThanOrEqualToConstant: ProGhosttyTitlebarToastMetrics.maximumWidth),
    ])

    setContentHuggingPriority(.required, for: .horizontal)
    setContentCompressionResistancePriority(.required, for: .horizontal)
    updateBackingScale()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    nil
  }

  func update(message: String?, colors: ProGhosttyTitlebarToastColors?, isActionable: Bool) {
    guard let message, let colors else {
      isHidden = true
      self.colors = nil
      self.isActionable = false
      label.stringValue = ""
      invalidateIntrinsicContentSize()
      needsDisplay = true
      return
    }

    isHidden = false
    self.colors = colors
    self.isActionable = isActionable
    label.stringValue = message
    label.textColor = colors.foreground
    label.toolTip = isActionable ? message : nil
    invalidateIntrinsicContentSize()
    superview?.invalidateIntrinsicContentSize()
    needsDisplay = true
  }

  override var intrinsicContentSize: NSSize {
    guard !isHidden, !label.stringValue.isEmpty else {
      return NSSize(width: 0, height: 0)
    }
    let fitting = label.intrinsicContentSize
    return NSSize(
      width: min(
        ProGhosttyTitlebarToastMetrics.maximumWidth,
        fitting.width + ProGhosttyTitlebarToastMetrics.horizontalPadding * 2
      ),
      height: fitting.height + ProGhosttyTitlebarToastMetrics.verticalPadding * 2
    )
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    updateBackingScale()
  }

  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    updateBackingScale()
    needsDisplay = true
  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    guard let colors, !isHidden, bounds.width > 0, bounds.height > 0 else { return }

    let scale = backingScaleFactor
    let borderWidth = ProGhosttyTitlebarToastMetrics.borderWidth(backingScaleFactor: scale)
    let rect = pixelAligned(bounds, scale: scale).insetBy(dx: borderWidth / 2, dy: borderWidth / 2)
    guard rect.width > 0, rect.height > 0 else { return }

    let radius = ProGhosttyTitlebarToastMetrics.capsuleRadius(for: rect.height)
    let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    path.lineWidth = borderWidth

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current?.cgContext.setShouldAntialias(true)
    colors.background.setFill()
    path.fill()
    colors.border.setStroke()
    path.stroke()
    NSGraphicsContext.restoreGraphicsState()
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    guard isActionable, !isHidden, bounds.contains(point) else { return nil }
    return self
  }

  override func resetCursorRects() {
    super.resetCursorRects()
    if isActionable {
      addCursorRect(bounds, cursor: .pointingHand)
    }
  }

  override func mouseUp(with event: NSEvent) {
    guard isActionable, bounds.contains(convert(event.locationInWindow, from: nil)), let action else {
      return
    }
    _ = NSApp.sendAction(action, to: target, from: self)
  }

  private var backingScaleFactor: CGFloat {
    window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
  }

  private func updateBackingScale() {
    layer?.contentsScale = backingScaleFactor
  }

  private func pixelAligned(_ rect: NSRect, scale: CGFloat) -> NSRect {
    guard scale > 0 else { return rect.integral }
    let minX = round(rect.minX * scale) / scale
    let minY = round(rect.minY * scale) / scale
    let maxX = round(rect.maxX * scale) / scale
    let maxY = round(rect.maxY * scale) / scale
    return NSRect(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))
  }
}

private final class NotificationObserverBag {
  private var observers: [NSObjectProtocol] = []

  func append(_ observer: NSObjectProtocol) {
    observers.append(observer)
  }

  func removeAll() {
    for observer in observers {
      NotificationCenter.default.removeObserver(observer)
    }
    observers.removeAll()
  }

  deinit {
    removeAll()
  }
}

private extension NSView {
  func directChild(containing descendant: NSView) -> NSView? {
    for subview in subviews {
      if subview === descendant || descendant.isDescendant(of: subview) {
        return subview
      }
    }
    return nil
  }

  func descendants<T: NSView>(of type: T.Type) -> [T] {
    var result: [T] = []
    for subview in subviews {
      if let match = subview as? T {
        result.append(match)
      }
      result.append(contentsOf: subview.descendants(of: type))
    }
    return result
  }

}

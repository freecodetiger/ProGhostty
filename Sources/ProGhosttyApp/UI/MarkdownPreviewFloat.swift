import AppKit
import ProGhosttyCore
import SwiftUI
import WebKit

/// SwiftUI bridge for the markdown preview float. Fills the container (the
/// terminal canvas overlay); the inner `MarkdownPreviewFloatView` manages its
/// own frame (drag / resize / clamp) and reports changes up to AppModel.
struct MarkdownPreviewFloatRepresentable: NSViewRepresentable {
  var html: String?
  var baseURL: URL?
  var containerSize: CGSize
  var frame: CGRect?
  var paneAnchor: CGRect?
  var panelFramesProvider: () -> [CGRect]
  var onFrameChange: (CGRect) -> Void
  var onDismiss: () -> Void
  var onDock: (Int) -> Void
  var onDetach: () -> Void

  func makeNSView(context: Context) -> MarkdownPreviewFloatContainerView {
    let view = MarkdownPreviewFloatContainerView()
    view.onFrameChange = onFrameChange
    view.onDismiss = onDismiss
    return view
  }

  func updateNSView(_ view: MarkdownPreviewFloatContainerView, context: Context) {
    let resolved: CGRect
    if let frame {
      resolved = MarkdownPreviewLayout.clamped(frame, in: containerSize)
    } else {
      resolved = MarkdownPreviewLayout.initialFrame(in: containerSize, anchoredTo: paneAnchor)
      onFrameChange(resolved)
    }
    view.onFrameChange = onFrameChange
    view.onDismiss = onDismiss
    view.onDock = onDock
    view.onDetach = onDetach
    view.panelFramesProvider = panelFramesProvider
    view.configure(
      html: html,
      baseURL: baseURL,
      containerSize: containerSize,
      frame: resolved
    )
  }
}

/// Container that fills the GeometryReader and hosts the float. Not flipped:
/// all float frames are in AppKit y-up coordinates, matching the pane anchor
/// AppModel provides (window content view coordinates).
final class MarkdownPreviewFloatContainerView: NSView {
  var onFrameChange: ((CGRect) -> Void)?
  var onDismiss: (() -> Void)?
  var onDock: ((Int) -> Void)?
  var onDetach: (() -> Void)?
  var panelFramesProvider: (() -> [CGRect])?

  private let float = MarkdownPreviewFloatView()
  private var containerSize = CGSize.zero
  private var snapTargets: [CGRect] = []
  private var snapHoverRect: CGRect?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    addSubview(float)
    float.onFrameChange = { [weak self] frame in
      self?.onFrameChange?(frame)
    }
    float.onDismiss = { [weak self] in
      self?.onDismiss?()
    }
    float.onDock = { [weak self] index in
      self?.onDock?(index)
    }
    float.onDetach = { [weak self] in
      self?.onDetach?()
    }
    float.onSnapPreview = { [weak self] targets, hover in
      self?.setSnapPreview(targets: targets, hover: hover)
    }
  }

  required init?(coder: NSCoder) {
    nil
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard window != nil, !didDumpHierarchy else { return }
    didDumpHierarchy = true
    if let contentView = window?.contentView {
      let subs = contentView.subviews.map {
        "\($0.className) z=\($0.layer?.zPosition ?? 0) frame=\(NSStringFromRect($0.frame))"
      }
      DebugLog.write("markdown-preview contentView.subviews=\(subs.joined(separator: " | "))")
    }
    DebugLog.write(
      "markdown-preview container isFlipped=\(isFlipped) frame=\(NSStringFromRect(frame)) "
        + "window=\(window?.contentView.map { NSStringFromSize($0.frame.size) } ?? "-")"
    )
    let chain = sequence(first: self) { $0.superview }.prefix(8).map(\.className).joined(separator: " → ")
    DebugLog.write("markdown-preview container-chain=\(chain)")
  }
  private var didDumpHierarchy = false

  /// Dock-mode feedback: faint dashed outlines around every dockable panel,
  /// plus a strong outline on the one the float's center is over (or none).
  func setSnapPreview(targets: [CGRect], hover: CGRect?) {
    guard targets != snapTargets || hover != snapHoverRect else { return }
    snapTargets = targets
    snapHoverRect = hover
    needsDisplay = true
  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    for target in snapTargets {
      drawSnapOutline(target, strong: false)
    }
    if let hover = snapHoverRect {
      drawSnapOutline(hover, strong: true)
    }
  }

  private func drawSnapOutline(_ rect: CGRect, strong: Bool) {
    let inset = rect.insetBy(dx: 2, dy: 2)
    let path = NSBezierPath(roundedRect: inset, xRadius: 8, yRadius: 8)
    path.lineWidth = strong ? 2 : 1
    path.setLineDash([6, 4], count: 2, phase: 0)
    let color = strong
      ? NSColor.controlAccentColor.withAlphaComponent(0.9)
      : NSColor.controlAccentColor.withAlphaComponent(0.35)
    color.setStroke()
    path.stroke()
  }

  func configure(
    html: String?,
    baseURL: URL?,
    containerSize: CGSize,
    frame: CGRect
  ) {
    self.containerSize = containerSize
    let clamped = MarkdownPreviewLayout.clamped(frame, in: containerSize)
    // The workspace re-renders constantly (per-frame model updates), so this
    // runs mid-drag too. During a drag the incoming frame is STALE (the model
    // only learns the new frame at drag-end) — writing it would yank the float
    // back to its pre-drag position/size. Skip the write while a drag or frame
    // animation is running; the float itself is the source of truth then.
    if !float.isDragging, !float.isAnimatingFrame, clamped != float.frame {
      float.frame = clamped
      if clamped != frame {
        onFrameChange?(clamped)
      }
    }
    float.setContainerSize(containerSize)
    float.panelFramesProvider = panelFramesProvider
    if let html {
      float.setHTML(html, baseURL: baseURL)
    }
  }
}

/// The floating preview panel: a white GitHub-README-style document card with
/// minimal chrome. The body is a no-focus WKWebView filling the whole card (no
/// reserved titlebar — the document gets 100% of the height). A small three-dot
/// grab handle at the top (like Ghostty's window grip) plain-drags the float
/// freely. A transparent surface over the card forwards plain mouse / scroll
/// events to WebKit (selection, scrolling, links) and, only while the user
/// holds ⌥ (Option), turns a drag into a dock-directed move: all panels outline
/// as targets and dropping over one docks it. Every edge and corner stays an
/// invisible resize zone (the cursor turns into the resize arrow); a faint "×"
/// appears at the top-right on hover; Esc / right-click dismiss. Never accepts
/// first responder — focus stays in the terminal; text selection + ⌘C copy work
/// through WebKit + our own hover-routed copy.
final class MarkdownPreviewFloatView: NSView, WKNavigationDelegate {
  /// Invisible resize hit zones along the card's edges / corners (macOS-window
  /// style: no visible grip, cursor feedback only).
  static let edgeResizeThickness: CGFloat = 6
  static let cornerResizeSize: CGFloat = 24
  static let cornerRadius: CGFloat = 14

  var onFrameChange: ((CGRect) -> Void)?
  var onDismiss: (() -> Void)?
  /// Current panel frames (container coordinates) queried during a move-drag to
  /// find a snap target. Provided by AppModel.
  var panelFramesProvider: (() -> [CGRect])?
  /// Committed a dock into panel at `index`.
  var onDock: ((Int) -> Void)?
  /// Detached from a docked panel (the user grabbed it).
  var onDetach: (() -> Void)?
  /// Dock-mode feedback: every dockable panel's frame to outline (faint), plus
  /// the hovered target to highlight (strong), or nil to clear.
  var onSnapPreview: (([CGRect], CGRect?) -> Void)?

  private static let webViewConfiguration: WKWebViewConfiguration = {
    let configuration = WKWebViewConfiguration()
    // Relative images are inlined as base64 data URLs by MarkdownPreviewRenderer
    // (WebKit refuses file:// subresources from a loadHTMLString page, and the
    // private allowFileAccessFromFileURLs preference does not fix that), so the
    // page needs no file access at all.
    return configuration
  }()

  private let backgroundView = MarkdownPreviewBackgroundView()
  private let webView = NoFocusWebView(frame: .zero, configuration: MarkdownPreviewFloatView.webViewConfiguration)
  private let dragSurface = PreviewDragSurface()
  private let dragHandle = DragHandleView()
  private let closeButton = CloseButton()
  private var containerSize = CGSize.zero
  private var keyMonitor: Any?
  private var hoverTrackingArea: NSTrackingArea?

  private enum DragMode: Equatable {
    case none
    case move
    case moveDock
    case resize(MarkdownPreviewLayout.ResizeZone)
  }

  private var dragMode: DragMode = .none
  private var dragStartLocation = NSPoint.zero
  private var dragStartFrame = CGRect.zero
  private var isDocked = false

  /// Pre-grab state, restored when a grab-and-release never moves (an accidental
  /// click on the handle must leave the float exactly where it was — a free
  /// float stays put, a docked one stays docked).
  private var preGrabFrame = CGRect.zero
  private var preGrabDocked = false
  private var preGrabDockedIndex: Int?
  private var grabOriginalPoint = NSPoint.zero

  /// Bumped on every `beginDrag`. Frame-animation completions capture the
  /// generation they started with and bail if a newer drag has begun, so a
  /// settle/dock/expand completion can't clobber a drag that started mid-animation.
  private var dragGeneration = 0

  /// True while a drag (move / ⌥-move / resize) is in progress. The workspace
  /// SwiftUI re-renders constantly and would otherwise feed a STALE model frame
  /// into `configure`, fighting the live drag frame. During a drag the float
  /// owns its own frame; `configure` must not touch it.
  var isDragging: Bool { dragMode != .none }

  /// True while a frame animation (lift / dock spring / expand) owns the frame.
  /// `configure` must also stay away during these windows, or the animation is
  /// cut short by a stale model frame write.
  var isAnimatingFrame = false

  /// The dock-directed drag model (drop-to-dock, iOS-springboard style): a grab
  /// of a docked float, or any ⌥-drag, lifts the float onto a small "carry"
  /// card; the pane under its center lights up live; releasing over it springs
  /// the card into that pane. A plain handle-drag of a free float stays a free
  /// move (the tiled layout has no "empty" release point, so a free drag that
  /// docked would make the free float unreachable).
  private var isDockDirectedDrag = false
  /// Live dock target during a dock-directed drag (nil = over no pane).
  private var dockTargetIndex: Int?
  /// How the mini carry card is anchored to the cursor: `.top` for a handle grab
  /// (the mouse sits on the handle), `.center` for an ⌥-drag.
  private var miniCardAnchor: MarkdownPreviewLayout.MiniCardAnchor = .center
  /// Target frame of an in-flight lift; nil once the lift settles (used to stop
  /// the completion handler from clobbering a later dock/expand animation).
  private var liftTargetFrame: CGRect?

  /// Pane the float is docked into; a ~30Hz timer re-pins the float to its
  /// current frame (in this float's coordinate space).
  private var dockedPanelIndex: Int?
  private var dockFollowTimer: Timer?

  override var acceptsFirstResponder: Bool { false }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    // Shadow lives on the float (masksToBounds is false) so the rounded,
    // clipped white background can drop a soft shadow onto the terminal.
    layer?.masksToBounds = false
    layer?.shadowColor = NSColor.black.cgColor
    layer?.shadowOpacity = 0.22
    layer?.shadowRadius = 16
    layer?.shadowOffset = CGSize(width: 0, height: -3)

    backgroundView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(backgroundView)

    // The GitHub-README web view. No-focus: it never becomes first responder,
    // so keyboard focus stays in the terminal; scrolling and mouse-drag text
    // selection work natively in WebKit, and ⌘C copy is hover-routed by us.
    webView.translatesAutoresizingMaskIntoConstraints = false
    webView.allowsMagnification = false
    if #available(macOS 13.3, *) {
      // Lets Safari's Web Inspector attach (Develop ▸ Web Inspector) to debug
      // image / link issues in the preview page.
      webView.isInspectable = true
    }
    // White background comes from the github-markdown-css page itself. Fills the
    // whole card — no reserved titlebar, the document owns every pixel.
    // The web view's own surface is white (underPageBackgroundColor) so the
    // async-reflow gap during a resize is white-on-white. And it starts HIDDEN:
    // WKWebView paints BLACK until its first committed frame, which would bury
    // the white card under a black rectangle on every load — `didFinish` fades
    // the rendered page in over the white card instead.
    webView.underPageBackgroundColor = .white
    webView.alphaValue = 0
    webView.layer?.backgroundColor = NSColor.white.cgColor
    backgroundView.addSubview(webView)

    // Transparent surface over the whole card. Plain clicks / scrolls / drags
    // are forwarded to WebKit (selection, scrolling, links); holding ⌥ turns the
    // next drag into a move of the float. This is how the preview moves without
    // any visible titlebar. Has no cursor rects, so WebKit's own cursor (I-beam
    // over text) shows through.
    dragSurface.translatesAutoresizingMaskIntoConstraints = false
    addSubview(dragSurface)
    dragSurface.onMoveMouseDown = { [weak self] event in self?.beginDrag(.moveDock, with: event) }
    dragSurface.onMoveMouseDragged = { [weak self] event in self?.continueDrag(with: event) }
    dragSurface.onMoveMouseUp = { [weak self] event in self?.endDrag(with: event) }
    dragSurface.forward = { [weak self] event in self?.forwardToWebView(event) }

    // Invisible resize zones on every edge and corner (macOS-window style): the
    // cursor turns into the resize arrow on hover, no visible grip. Each zone
    // forwards wheel events to the web view so the card's borders still scroll.
    // They sit above the drag surface, so resizing wins over ⌥-move at the
    // borders.
    var resizeZones: [MarkdownPreviewLayout.ResizeZone: ResizeZoneView] = [:]
    for zone in MarkdownPreviewLayout.ResizeZone.allCases {
      let view = ResizeZoneView(zone: zone)
      view.translatesAutoresizingMaskIntoConstraints = false
      view.onMouseDown = { [weak self] event in self?.beginDrag(.resize(zone), with: event) }
      view.onMouseDragged = { [weak self] event in self?.continueDrag(with: event) }
      view.onMouseUp = { [weak self] event in self?.endDrag(with: event) }
      view.onScrollWheel = { [weak self] event in self?.webView.scrollWheel(with: event) }
      addSubview(view)
      resizeZones[zone] = view
    }

    // Three-dot grab handle at the top (like Ghostty's window grip): a plain
    // drag moves the float freely — no modifier, no snap. Sits above the drag
    // surface and the top resize zone, so it wins the grab there.
    dragHandle.translatesAutoresizingMaskIntoConstraints = false
    addSubview(dragHandle)
    dragHandle.onMouseDown = { [weak self] event in self?.beginDrag(.move, with: event) }
    dragHandle.onMouseDragged = { [weak self] event in self?.continueDrag(with: event) }
    dragHandle.onMouseUp = { [weak self] event in self?.endDrag(with: event) }
    dragHandle.onScrollWheel = { [weak self] event in self?.webView.scrollWheel(with: event) }

    // Hover-revealed close button (top-right): a faint circle that fills on
    // hover. Hidden until the pointer enters the card; never takes focus.
    closeButton.target = self
    closeButton.action = #selector(closeClicked)
    closeButton.isHidden = true
    closeButton.translatesAutoresizingMaskIntoConstraints = false
    addSubview(closeButton)

    // Link clicks: open in the default browser instead of navigating the
    // preview page in place (which would destroy the rendered document).
    webView.navigationDelegate = self

    // Our own context menu (Copy / Close) instead of WebKit's.
    webView.onContextMenu = { [weak self] event in
      self?.showContextMenu(with: event)
    }

    NSLayoutConstraint.activate([
      backgroundView.leadingAnchor.constraint(equalTo: leadingAnchor),
      backgroundView.trailingAnchor.constraint(equalTo: trailingAnchor),
      backgroundView.topAnchor.constraint(equalTo: topAnchor),
      backgroundView.bottomAnchor.constraint(equalTo: bottomAnchor),

      // The web view owns the whole card; the drag surface / resize zones are
      // transparent overlays on top of it.
      webView.leadingAnchor.constraint(equalTo: backgroundView.leadingAnchor),
      webView.trailingAnchor.constraint(equalTo: backgroundView.trailingAnchor),
      webView.topAnchor.constraint(equalTo: backgroundView.topAnchor),
      webView.bottomAnchor.constraint(equalTo: backgroundView.bottomAnchor),

      dragSurface.leadingAnchor.constraint(equalTo: leadingAnchor),
      dragSurface.trailingAnchor.constraint(equalTo: trailingAnchor),
      dragSurface.topAnchor.constraint(equalTo: topAnchor),
      dragSurface.bottomAnchor.constraint(equalTo: bottomAnchor),

      dragHandle.centerXAnchor.constraint(equalTo: centerXAnchor),
      dragHandle.topAnchor.constraint(equalTo: topAnchor, constant: 2),
      dragHandle.widthAnchor.constraint(equalToConstant: 60),
      dragHandle.heightAnchor.constraint(equalToConstant: 16),

      // Resize zones: thin edge strips + corner squares. Edges come first in
      // declaration order, corners after, so the corners win hit-testing (and
      // the cursor) where they overlap.
      resizeZones[.top]!.leadingAnchor.constraint(equalTo: leadingAnchor),
      resizeZones[.top]!.trailingAnchor.constraint(equalTo: trailingAnchor),
      resizeZones[.top]!.topAnchor.constraint(equalTo: topAnchor),
      resizeZones[.top]!.heightAnchor.constraint(equalToConstant: Self.edgeResizeThickness),
      resizeZones[.bottom]!.leadingAnchor.constraint(equalTo: leadingAnchor),
      resizeZones[.bottom]!.trailingAnchor.constraint(equalTo: trailingAnchor),
      resizeZones[.bottom]!.bottomAnchor.constraint(equalTo: bottomAnchor),
      resizeZones[.bottom]!.heightAnchor.constraint(equalToConstant: Self.edgeResizeThickness),
      resizeZones[.left]!.topAnchor.constraint(equalTo: topAnchor),
      resizeZones[.left]!.bottomAnchor.constraint(equalTo: bottomAnchor),
      resizeZones[.left]!.leadingAnchor.constraint(equalTo: leadingAnchor),
      resizeZones[.left]!.widthAnchor.constraint(equalToConstant: Self.edgeResizeThickness),
      resizeZones[.right]!.topAnchor.constraint(equalTo: topAnchor),
      resizeZones[.right]!.bottomAnchor.constraint(equalTo: bottomAnchor),
      resizeZones[.right]!.trailingAnchor.constraint(equalTo: trailingAnchor),
      resizeZones[.right]!.widthAnchor.constraint(equalToConstant: Self.edgeResizeThickness),
      resizeZones[.topLeft]!.topAnchor.constraint(equalTo: topAnchor),
      resizeZones[.topLeft]!.leadingAnchor.constraint(equalTo: leadingAnchor),
      resizeZones[.topLeft]!.widthAnchor.constraint(equalToConstant: Self.cornerResizeSize),
      resizeZones[.topLeft]!.heightAnchor.constraint(equalToConstant: Self.cornerResizeSize),
      resizeZones[.topRight]!.topAnchor.constraint(equalTo: topAnchor),
      resizeZones[.topRight]!.trailingAnchor.constraint(equalTo: trailingAnchor),
      resizeZones[.topRight]!.widthAnchor.constraint(equalToConstant: Self.cornerResizeSize),
      resizeZones[.topRight]!.heightAnchor.constraint(equalToConstant: Self.cornerResizeSize),
      resizeZones[.bottomLeft]!.bottomAnchor.constraint(equalTo: bottomAnchor),
      resizeZones[.bottomLeft]!.leadingAnchor.constraint(equalTo: leadingAnchor),
      resizeZones[.bottomLeft]!.widthAnchor.constraint(equalToConstant: Self.cornerResizeSize),
      resizeZones[.bottomLeft]!.heightAnchor.constraint(equalToConstant: Self.cornerResizeSize),
      resizeZones[.bottomRight]!.bottomAnchor.constraint(equalTo: bottomAnchor),
      resizeZones[.bottomRight]!.trailingAnchor.constraint(equalTo: trailingAnchor),
      resizeZones[.bottomRight]!.widthAnchor.constraint(equalToConstant: Self.cornerResizeSize),
      resizeZones[.bottomRight]!.heightAnchor.constraint(equalToConstant: Self.cornerResizeSize),

      closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
      closeButton.topAnchor.constraint(equalTo: topAnchor, constant: 4),
      closeButton.widthAnchor.constraint(equalToConstant: 20),
      closeButton.heightAnchor.constraint(equalToConstant: 20),
    ])
  }

  required init?(coder: NSCoder) {
    nil
  }

  // The white card + web view are Auto Layout–pinned to this view's edges, but
  // AppKit resolves those constraints on the NEXT layout pass — a full frame
  // behind a fast drag. The float's own layer resizes instantly (its shadow
  // follows the edge), so a fast resize/move would briefly show the terminal
  // through the gap between the leading edge and the lagging card. Resolve the
  // layout synchronously so the card tracks the frame exactly.
  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    layoutSubtreeIfNeeded()
  }

  override func setFrameOrigin(_ newOrigin: NSPoint) {
    super.setFrameOrigin(newOrigin)
    layoutSubtreeIfNeeded()
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let hoverTrackingArea {
      removeTrackingArea(hoverTrackingArea)
    }
    let area = NSTrackingArea(
      rect: bounds,
      options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
      owner: self,
      userInfo: nil
    )
    addTrackingArea(area)
    hoverTrackingArea = area
  }

  override func mouseEntered(with event: NSEvent) {
    closeButton.isHidden = false
  }

  override func mouseExited(with event: NSEvent) {
    closeButton.isHidden = true
  }

  func setContainerSize(_ size: CGSize) {
    containerSize = size
  }

  func setHTML(_ html: String, baseURL: URL?) {
    if html != lastLoadedHTML || baseURL != lastLoadedBaseURL {
      lastLoadedHTML = html
      lastLoadedBaseURL = baseURL
      // New document: hide until its first paint (didFinish fades it in).
      webView.alphaValue = 0
      webView.loadHTMLString(html, baseURL: baseURL)
      if Date().timeIntervalSince(lastLayoutLog) > 1 {
        lastLayoutLog = Date()
        DebugLog.write("markdown-preview frames float=\(NSStringFromRect(frame)) web=\(NSStringFromRect(webView.frame))")
      }
    }
  }
  private var lastLoadedHTML: String?
  private var lastLoadedBaseURL: URL?
  private var lastLayoutLog = Date.distantPast

  @objc private func closeClicked() {
    DebugLog.write("markdown-preview close button")
    onDismiss?()
  }

  // MARK: - Hover-routed keys

  /// Hover-routed ⌘C (copy selection) and Esc (dismiss) — both only while the
  /// pointer is over the card, so the terminal keeps its ⌘C / Esc keys.
  private func installKeyMonitor() {
    guard keyMonitor == nil else { return }
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard
        let self,
        let window = self.window,
        event.window === window
      else {
        return event
      }
      let mousePoint = self.convert(window.mouseLocationOutsideOfEventStream, from: nil)
      guard self.bounds.contains(mousePoint) else { return event }

      // Esc closes the preview (pointer is over the card).
      if event.keyCode == 53 {
        DebugLog.write("markdown-preview Esc dismiss")
        self.onDismiss?()
        return nil
      }
      // ⌘C copies the WebKit selection when the pointer is over the card.
      if event.modifierFlags.contains(.command),
        event.charactersIgnoringModifiers?.lowercased() == "c"
      {
        self.copySelectionToPasteboard()
        return nil
      }
      return event
    }
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    installKeyMonitor()
  }

  // MARK: - Copy / context menu

  private func copySelectionToPasteboard() {
    webView.evaluateJavaScript("window.getSelection().toString()") { result, error in
      guard error == nil, let text = result as? String, !text.isEmpty else { return }
      DebugLog.write("markdown-preview copy chars=\(text.count)")
      let pasteboard = NSPasteboard.general
      pasteboard.clearContents()
      pasteboard.setString(text, forType: .string)
    }
  }

  private func showContextMenu(with event: NSEvent) {
    let menu = NSMenu()
    let copyItem = NSMenuItem(title: "Copy", action: #selector(copyFromContextMenu), keyEquivalent: "")
    copyItem.target = self
    menu.addItem(copyItem)
    menu.addItem(.separator())
    let closeItem = NSMenuItem(title: "Close Preview", action: #selector(closeFromContextMenu), keyEquivalent: "")
    closeItem.target = self
    menu.addItem(closeItem)
    NSMenu.popUpContextMenu(menu, with: event, for: self)
  }

  @objc private func copyFromContextMenu() {
    copySelectionToPasteboard()
  }

  @objc private func closeFromContextMenu() {
    onDismiss?()
  }

  // MARK: - Link navigation

  func webView(
    _ webView: WKWebView,
    decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
  ) {
    // A user click on a link (or image link) opens in the default browser; the
    // preview page never navigates away from the markdown document. The initial
    // loadHTMLString navigation is `.other` and passes through.
    DebugLog.write(
      "markdown-preview nav-policy type=\(navigationAction.navigationType.rawValue) "
        + "url=\(navigationAction.request.url?.absoluteString ?? "nil")"
    )
    if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
      // In-page anchor links (`[docs](#install)`) resolve to the current
      // document URL plus a fragment; let WebKit scroll to the section instead
      // of treating the URL as an external link (which would open the file
      // location in Finder).
      if let current = webView.url,
        var target = URLComponents(url: url, resolvingAgainstBaseURL: false),
        var source = URLComponents(url: current, resolvingAgainstBaseURL: false)
      {
        target.fragment = nil
        source.fragment = nil
        if target.url == source.url {
          DebugLog.write("markdown-preview fragment-jump \(url.absoluteString)")
          decisionHandler(.allow)
          return
        }
      }
      DebugLog.write("markdown-preview open link \(url.absoluteString)")
      NSWorkspace.shared.open(url)
      decisionHandler(.cancel)
    } else {
      decisionHandler(.allow)
    }
  }

  func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
    DebugLog.write("markdown-preview nav start url=\(webView.url?.absoluteString ?? "nil")")
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    DebugLog.write("markdown-preview nav finish url=\(webView.url?.absoluteString ?? "nil")")
    // First paint: fade the rendered page in over the white card. It started at
    // alpha 0 so WKWebView's pre-commit black rectangle never shows.
    if webView.alphaValue < 1 {
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.15
        context.timingFunction = CAMediaTimingFunction(name: .easeOut)
        webView.animator().alphaValue = 1
      }
    }
    // Report every <img> in the page: resolved src, load state, natural width.
    // A naturalWidth of 0 means the image failed to load.
    let js = "JSON.stringify(Array.from(document.images).map(i => "
      + "({src: i.getAttribute('src'), base: i.src, complete: i.complete, w: i.naturalWidth})))"
    webView.evaluateJavaScript(js) { result, _ in
      DebugLog.write("markdown-preview images=\(result ?? "none")")
    }
  }

  func webView(
    _ webView: WKWebView,
    didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: Error
  ) {
    DebugLog.write("markdown-preview nav fail-provisional \(error)")
  }

  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    DebugLog.write("markdown-preview nav fail \(error)")
  }

  func webView(_ webView: WKWebView, webContentProcessDidTerminate: WKWebView) {
    DebugLog.write("markdown-preview web-content-process terminated")
  }

  // MARK: - Drag / resize

  /// The drag point in the CONTAINER's coordinate space (stable during a drag).
  /// Converting in the float's own space is wrong: the float moves under the
  /// cursor, so the delta would degrade to the per-event increment and the
  /// float would jitter in place.
  private func dragPoint(for event: NSEvent) -> NSPoint {
    superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
  }

  /// The pane frames converted from window contentView (y-up) coordinates into
  /// this float's container space. The container is flipped (y-down, origin
  /// top-left) and inset from the contentView, so `convert(_:from:)` — which
  /// handles both the flip and the offset — is the only correct conversion.
  private func panelsInContainer() -> [CGRect] {
    let panels = panelFramesProvider?() ?? []
    guard let container = superview, let window, let contentView = window.contentView else {
      return panels
    }
    return panels.map { container.convert($0, from: contentView) }
  }

  private func beginDrag(_ mode: DragMode, with event: NSEvent) {
    DebugLog.write("markdown-preview beginDrag mode=\(mode)")
    // Capture pre-grab state before the detach below clears it.
    preGrabDocked = isDocked
    preGrabDockedIndex = dockedPanelIndex
    if isDocked {
      isDocked = false
      stopDockFollowTimer()
      dockedPanelIndex = nil
      onDetach?()
    }
    // Every move drag (handle or ⌥) is dock-directed drop-to-dock: the float
    // lifts onto a mini carry card and, released over a pane, springs into it
    // (iOS-springboard style). A pane-sized float physically can't dock into a
    // small pane — `moved` clamps it inside the container, so a full-height
    // float never moves down and a wide float's center can't reach a narrow
    // pane — hence the tear-off to a maneuverable card. Resize drags keep the
    // current (pane) size.
    isDockDirectedDrag = mode == .move || mode == .moveDock
    dragMode = mode
    dragGeneration += 1
    // A previous drag's animation may still be in flight; its completion is
    // now stale (generation mismatch) and won't clear these, so take the frame
    // over ourselves.
    liftTimer?.invalidate()
    liftTimer = nil
    fillTimer?.invalidate()
    fillTimer = nil
    isAnimatingFrame = false
    liftTargetFrame = nil
    dockTargetIndex = nil
    dragStartLocation = dragPoint(for: event)
    dragStartFrame = frame
    grabOriginalPoint = dragStartLocation
    preGrabFrame = frame
    if isDockDirectedDrag {
      miniCardAnchor = mode == .move ? .top : .center
      liftToMiniCard(grabbedAt: dragStartLocation, anchor: miniCardAnchor)
    }
    DebugLog.write(
      "markdown-preview beginDrag start=\(NSStringFromRect(dragStartFrame)) "
        + "loc=\(NSStringFromPoint(dragStartLocation)) container=\(Int(containerSize.width))x\(Int(containerSize.height))"
    )
  }

  /// Pass a mouse event through to the web view unchanged (coordinates are
  /// resolved by the receiver against the window).
  private func forwardToWebView(_ event: NSEvent) {
    switch event.type {
    case .leftMouseDown: webView.mouseDown(with: event)
    case .leftMouseDragged: webView.mouseDragged(with: event)
    case .leftMouseUp: webView.mouseUp(with: event)
    case .scrollWheel: webView.scrollWheel(with: event)
    case .rightMouseDown: webView.rightMouseDown(with: event)
    default: break
    }
  }

  /// Lift a dock-directed grab onto the mini carry card: the SIZE eases from the
  /// pane to the mini card over ~0.22s while the POSITION tracks the cursor on
  /// every tick, so the drag is responsive from the very first mouse movement
  /// and the pane→mini shrink reads as a soft tear-off rather than a snap.
  /// (A frame animation would either gate the drag for its duration — the card
  /// then "catches up" abruptly — or fight the cursor-following.)
  private func liftToMiniCard(grabbedAt point: NSPoint, anchor: MarkdownPreviewLayout.MiniCardAnchor) {
    liftFromFrame = frame
    liftStartTime = CACurrentMediaTime()
    liftTargetFrame = MarkdownPreviewLayout.miniCardFrame(grabbedAt: point, container: containerSize, anchor: anchor)
    isAnimatingFrame = true
    let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.tickLift() }
    }
    RunLoop.main.add(timer, forMode: .common)
    liftTimer = timer
  }

  private static let liftDuration: CFTimeInterval = 0.22

  private var liftTimer: Timer?
  private var liftStartTime: CFTimeInterval = 0
  private var liftFromFrame = CGRect.zero

  private func tickLift() {
    let t = min(1, (CACurrentMediaTime() - liftStartTime) / Self.liftDuration)
    // easeInOut
    let eased = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
    let point = currentMousePointInContainer()
    let miniSize = MarkdownPreviewLayout.miniCardFrame(grabbedAt: point, container: containerSize, anchor: miniCardAnchor).size
    let width = liftFromFrame.width + (miniSize.width - liftFromFrame.width) * eased
    let height = liftFromFrame.height + (miniSize.height - liftFromFrame.height) * eased
    let y: CGFloat
    switch miniCardAnchor {
    case .top: y = point.y - height + MarkdownPreviewLayout.handleGrabOffset
    case .center: y = point.y - height / 2
    }
    frame = MarkdownPreviewLayout.clamped(
      CGRect(x: point.x - width / 2, y: y, width: width, height: height),
      in: containerSize
    )
    if t >= 1 {
      liftTimer?.invalidate()
      liftTimer = nil
      liftTargetFrame = nil
      isAnimatingFrame = false
    }
  }

  /// The cursor's current position in the container's coordinate space (used to
  /// tell a grab-and-release without moving from a real drag).
  private func currentMousePointInContainer() -> NSPoint {
    guard let window, let container = superview else { return .zero }
    return container.convert(window.mouseLocationOutsideOfEventStream, from: nil)
  }

  private func continueDrag(with event: NSEvent) {
    guard dragMode != .none else { return }
    // The lift animation owns the frame briefly; drop events until it settles.
    guard !isAnimatingFrame else { return }
    let point = dragPoint(for: event)
    let newFrame: CGRect
    switch dragMode {
    case .move, .moveDock:
      // The carry card is re-anchored to the cursor on every event (no delta
      // accumulation, so it never drifts): the cursor stays on the handle /
      // card center and the card tracks 1:1.
      newFrame = MarkdownPreviewLayout.miniCardFrame(grabbedAt: point, container: containerSize, anchor: miniCardAnchor)
    case .resize(let zone):
      let delta = CGSize(width: point.x - dragStartLocation.x, height: point.y - dragStartLocation.y)
      newFrame = MarkdownPreviewLayout.resized(dragStartFrame, by: delta, from: zone, in: containerSize)
    case .none:
      return
    }
    if isDockDirectedDrag {
      // Drop-to-dock: the pane under the carry card's center (the cursor) is the
      // live target, highlighted on every event.
      NSCursor.closedHand.set()
      let panels = panelsInContainer()
      let target = panels.count >= 2 ? MarkdownPreviewLayout.snapTarget(for: newFrame, panels: panels) : nil
      dockTargetIndex = target
      onSnapPreview?(panels.count >= 2 ? panels : [], target.map { panels[$0] })
    }
    guard newFrame != frame else { return }
    frame = newFrame
    needsDisplay = true
    DebugLog.write("markdown-preview drag frame=\(NSStringFromRect(newFrame))")
  }

  private func endDrag(with event: NSEvent) {
    // Release during the lift animation: settle the mini card, then decide.
    if isAnimatingFrame, let target = liftTargetFrame {
      liftTimer?.invalidate()
      liftTimer = nil
      isAnimatingFrame = false
      liftTargetFrame = nil
      frame = target
    }
    let panels = panelsInContainer()
    dragMode = .none
    onSnapPreview?([], nil)
    NSCursor.arrow.set()
    if isDockDirectedDrag {
      isDockDirectedDrag = false
      if let index = dockTargetIndex, panels.indices.contains(index) {
        dockToPanel(index, panels: panels)
      } else {
        let point = currentMousePointInContainer()
        let moved = hypot(point.x - grabOriginalPoint.x, point.y - grabOriginalPoint.y)
        if moved < 4 {
          // Grab-and-release without moving (an accidental click): as if the grab
          // never happened — a free float stays put, a docked one stays docked.
          frame = preGrabFrame
          if preGrabDocked, let index = preGrabDockedIndex {
            isDocked = true
            dockedPanelIndex = index
            onFrameChange?(preGrabFrame)
            onDock?(index)
            startDockFollowTimer()
          } else {
            onFrameChange?(preGrabFrame)
          }
        } else {
          // Released off any pane after a real move: park it as a free
          // reading-size card at the drop point (the mini card was only the carry
          // state).
          expandToReadingSize(centeredOn: frame)
        }
      }
      dockTargetIndex = nil
      return
    }
    DebugLog.write(
      "markdown-preview endDrag start=\(NSStringFromRect(dragStartFrame)) "
        + "end=\(NSStringFromRect(frame)) report=\(frame != dragStartFrame)"
    )
    if frame != dragStartFrame {
      onFrameChange?(frame)
    }
  }

  /// Spring the float into the pane, then start the follow timer that keeps it
  /// pinned there. The model frame is reported once the fill settles, so a stale
  /// write can't cut it short.
  private func dockToPanel(_ index: Int, panels: [CGRect]) {
    DebugLog.write("markdown-preview dockToPanel index=\(index)")
    let docked = MarkdownPreviewLayout.dockedFrame(for: panels[index])
    isDocked = true
    dockedPanelIndex = index
    onDock?(index)
    animateToFrame(docked) { [weak self] in
      self?.startDockFollowTimer()
    }
  }

  /// A dock-directed drag released off any pane: expand the mini carry card back
  /// to the reading size at the drop point, so the preview never ends up stuck
  /// in the tiny carry state.
  private func expandToReadingSize(centeredOn card: CGRect) {
    let size = MarkdownPreviewLayout.initialFrame(in: containerSize).size
    let target = MarkdownPreviewLayout.clamped(
      CGRect(x: card.midX - size.width / 2, y: card.midY - size.height / 2, width: size.width, height: size.height),
      in: containerSize
    )
    DebugLog.write("markdown-preview expandFree target=\(NSStringFromRect(target))")
    animateToFrame(target)
  }

  /// Fill `target` (a pane on dock, or the reading size on a free drop) by
  /// tweening the frame from exactly where the drag left it, driven by a timer
  /// so the MODEL frame — and therefore the web view's layout — advances with
  /// the motion. `animator().frame` would set the model frame to `target`
  /// instantly: the WKWebView (sized by Auto Layout against the model bounds)
  /// would reflow to the pane layout at the first frame, and the card would
  /// appear to "jump" before the layer grew into it.
  private func animateToFrame(_ target: CGRect, completion: (() -> Void)? = nil) {
    fillGeneration = dragGeneration
    fillFromFrame = frame
    fillToFrame = target
    fillCompletion = completion
    fillStartTime = CACurrentMediaTime()
    isAnimatingFrame = true
    let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.tickFill() }
    }
    RunLoop.main.add(timer, forMode: .common)
    fillTimer = timer
  }

  private static let fillDuration: CFTimeInterval = 0.3

  private var fillTimer: Timer?
  private var fillStartTime: CFTimeInterval = 0
  private var fillFromFrame = CGRect.zero
  private var fillToFrame = CGRect.zero
  private var fillCompletion: (() -> Void)?
  private var fillGeneration = 0

  private func tickFill() {
    // A newer drag owns the frame now.
    guard fillGeneration == dragGeneration else { return }
    let t = min(1, (CACurrentMediaTime() - fillStartTime) / Self.fillDuration)
    // easeInOut
    let eased = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
    frame = CGRect(
      x: fillFromFrame.minX + (fillToFrame.minX - fillFromFrame.minX) * eased,
      y: fillFromFrame.minY + (fillToFrame.minY - fillFromFrame.minY) * eased,
      width: fillFromFrame.width + (fillToFrame.width - fillFromFrame.width) * eased,
      height: fillFromFrame.height + (fillToFrame.height - fillFromFrame.height) * eased
    )
    guard t >= 1 else { return }
    fillTimer?.invalidate()
    fillTimer = nil
    isAnimatingFrame = false
    frame = fillToFrame
    let completion = fillCompletion
    fillCompletion = nil
    onFrameChange?(fillToFrame)
    completion?()
  }

  /// While docked, re-pin the float to the pane's current frame on a ~30Hz timer
  /// so split resizes / layout changes keep it snug. Lives in the float because
  /// only it knows the container↔contentView conversion.
  private func startDockFollowTimer() {
    stopDockFollowTimer()
    let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, let index = self.dockedPanelIndex else { return }
        let panels = self.panelsInContainer()
        guard panels.indices.contains(index) else { return }
        let target = MarkdownPreviewLayout.dockedFrame(for: panels[index])
        if target != self.frame {
          self.frame = target
          self.needsDisplay = true
          self.onFrameChange?(target)
        }
      }
    }
    RunLoop.main.add(timer, forMode: .common)
    dockFollowTimer = timer
  }

  private func stopDockFollowTimer() {
    dockFollowTimer?.invalidate()
    dockFollowTimer = nil
  }

  deinit {
    MainActor.assumeIsolated {
      dockFollowTimer?.invalidate()
      liftTimer?.invalidate()
      fillTimer?.invalidate()
    }
  }
}

/// A WKWebView that never becomes first responder — keyboard focus stays in the
/// terminal. WebKit still handles scrolling and mouse-drag text selection; copy
/// is done by us via JS, and the right-click menu is our own.
private final class NoFocusWebView: WKWebView {
  var onContextMenu: ((NSEvent) -> Void)?

  override var acceptsFirstResponder: Bool { false }
  override func becomeFirstResponder() -> Bool { false }

  override func mouseDown(with event: NSEvent) {
    DebugLog.write("markdown-preview webview mouseDown")
    super.mouseDown(with: event)
  }

  override func rightMouseDown(with event: NSEvent) {
    DebugLog.write("markdown-preview webview rightMouseDown")
    onContextMenu?(event)
  }
}

/// The rounded white card behind the preview content. Fixed white regardless of
/// system appearance (matches the GitHub-README page).
private final class MarkdownPreviewBackgroundView: NSView {
  private static let borderColor = NSColor(srgbRed: 0xD0 / 255, green: 0xD7 / 255, blue: 0xDE / 255, alpha: 1)

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.backgroundColor = NSColor.white.cgColor
    layer?.cornerRadius = MarkdownPreviewFloatView.cornerRadius
    layer?.masksToBounds = true
    layer?.borderColor = Self.borderColor.cgColor
    layer?.borderWidth = 1
  }

  required init?(coder: NSCoder) {
    nil
  }
}

/// Three dots at the very top-center of the card, hidden until the pointer
/// comes near (the view's padded tracking area is the proximity zone). A plain
/// drag anywhere in the zone moves the float freely — no ⌥, no snap.
private final class DragHandleView: NSView {
  var onMouseDown: ((NSEvent) -> Void)?
  var onMouseDragged: ((NSEvent) -> Void)?
  var onMouseUp: ((NSEvent) -> Void)?
  var onScrollWheel: ((NSEvent) -> Void)?

  private var hovered = false

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.opacity = 0 // hidden until the pointer approaches
  }

  required init?(coder: NSCoder) { nil }

  override func mouseDown(with event: NSEvent) { onMouseDown?(event) }
  override func mouseDragged(with event: NSEvent) { onMouseDragged?(event) }
  override func mouseUp(with event: NSEvent) { onMouseUp?(event) }
  override func scrollWheel(with event: NSEvent) { onScrollWheel?(event) }

  override func resetCursorRects() {
    addCursorRect(bounds, cursor: .openHand)
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    for area in trackingAreas {
      removeTrackingArea(area)
    }
    // Generous zone so the dots fade in as the pointer approaches the top edge.
    let area = NSTrackingArea(
      rect: bounds.insetBy(dx: -20, dy: -8),
      options: [.mouseEnteredAndExited, .activeInKeyWindow],
      owner: self,
      userInfo: nil
    )
    addTrackingArea(area)
  }

  override func mouseEntered(with event: NSEvent) {
    hovered = true
    fade(to: 1)
  }

  override func mouseExited(with event: NSEvent) {
    hovered = false
    fade(to: 0)
  }

  private func fade(to opacity: Float) {
    CATransaction.begin()
    CATransaction.setAnimationDuration(0.12)
    layer?.opacity = opacity
    CATransaction.commit()
  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    let dotColor = NSColor(
      srgbRed: 0x55 / 255,
      green: 0x5D / 255,
      blue: 0x66 / 255,
      alpha: hovered ? 0.9 : 0.6
    )
    dotColor.setFill()
    // Three bare dots hugging the very top edge (no capsule).
    let radius: CGFloat = 1.6
    let spacing: CGFloat = 6
    let centerY: CGFloat = 5
    let leftX = bounds.midX - spacing
    for x in [leftX, bounds.midX, leftX + spacing * 2] {
      NSBezierPath(ovalIn: NSRect(x: x - radius, y: centerY - radius, width: radius * 2, height: radius * 2)).fill()
    }
  }
}

/// Transparent surface covering the whole card, in front of the web view. It
/// passes every mouse event through to WebKit below (via hitTest returning nil)
/// so links, images, text selection and scrolling work natively — it only
/// captures a drag while the user holds ⌥ (Option), turning it into a move of
/// the float. Has no cursor rects so WebKit's own cursor shows through.
private final class PreviewDragSurface: NSView {
  var onMoveMouseDown: ((NSEvent) -> Void)?
  var onMoveMouseDragged: ((NSEvent) -> Void)?
  var onMoveMouseUp: ((NSEvent) -> Void)?
  /// Pass-through: send the event on to the web view.
  var forward: ((NSEvent) -> Void)?

  private var moveDragging = false

  /// Transparent unless ⌥ is held: returns nil so WebKit below handles the
  /// event natively, and returns self only while the user holds Option — that's
  /// when a drag should move the float.
  override func hitTest(_ point: NSPoint) -> NSView? {
    guard NSApp.currentEvent?.modifierFlags.contains(.option) == true else { return nil }
    return super.hitTest(point)
  }

  override func mouseDown(with event: NSEvent) {
    moveDragging = true
    onMoveMouseDown?(event)
  }

  override func mouseDragged(with event: NSEvent) {
    onMoveMouseDragged?(event)
  }

  override func mouseUp(with event: NSEvent) {
    moveDragging = false
    onMoveMouseUp?(event)
  }

  // Only reachable while ⌥ is held (hitTest above); still pass wheel / right
  // click through to WebKit.
  override func scrollWheel(with event: NSEvent) { forward?(event) }
  override func rightMouseDown(with event: NSEvent) { forward?(event) }
}

/// An invisible resize hit zone on an edge or corner of the card. Shows the
/// resize cursor on hover (macOS-window style, no visible grip); forwards wheel
/// events to the web view so the card's borders still scroll.
private final class ResizeZoneView: NSView {
  let zone: MarkdownPreviewLayout.ResizeZone
  var onMouseDown: ((NSEvent) -> Void)?
  var onMouseDragged: ((NSEvent) -> Void)?
  var onMouseUp: ((NSEvent) -> Void)?
  var onScrollWheel: ((NSEvent) -> Void)?

  init(zone: MarkdownPreviewLayout.ResizeZone) {
    self.zone = zone
    super.init(frame: .zero)
  }

  required init?(coder: NSCoder) { nil }

  override func mouseDown(with event: NSEvent) { onMouseDown?(event) }
  override func mouseDragged(with event: NSEvent) { onMouseDragged?(event) }
  override func mouseUp(with event: NSEvent) { onMouseUp?(event) }
  override func scrollWheel(with event: NSEvent) { onScrollWheel?(event) }

  override func resetCursorRects() {
    let cursor: NSCursor
    switch zone {
    case .left, .right:
      cursor = .resizeLeftRight
    case .top, .bottom:
      cursor = .resizeUpDown
    case .topLeft, .topRight, .bottomLeft, .bottomRight:
      // Diagonal cursors are macOS 15+ (`frameResize`); fall back to the
      // horizontal arrow on older systems.
      if #available(macOS 15.0, *) {
        let position: NSCursor.FrameResizePosition
        switch zone {
        case .topLeft: position = .topLeading(relativeTo: .leftToRight)
        case .topRight: position = .topTrailing(relativeTo: .leftToRight)
        case .bottomLeft: position = .bottomLeading(relativeTo: .leftToRight)
        default: position = .bottomTrailing(relativeTo: .leftToRight)
        }
        cursor = .frameResize(position: position, directions: .all)
      } else {
        cursor = .resizeLeftRight
      }
    }
    addCursorRect(bounds, cursor: cursor)
  }
}

/// The hover-revealed close button: a faint circle that fills on hover. Never
/// takes focus.
private final class CloseButton: NSButton {
  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    title = "×"
    isBordered = false
    bezelStyle = .regularSquare
    font = NSFont.systemFont(ofSize: 12, weight: .medium)
    contentTintColor = NSColor(srgbRed: 0x6B / 255, green: 0x74 / 255, blue: 0x7D / 255, alpha: 1)
    refusesFirstResponder = true
    wantsLayer = true
  }

  required init?(coder: NSCoder) { nil }

  private var hovered = false

  override func resetCursorRects() {
    addCursorRect(bounds, cursor: .pointingHand)
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    for area in trackingAreas {
      removeTrackingArea(area)
    }
    let area = NSTrackingArea(
      rect: bounds,
      options: [.mouseEnteredAndExited, .activeInKeyWindow],
      owner: self,
      userInfo: nil
    )
    addTrackingArea(area)
  }

  override func mouseEntered(with event: NSEvent) {
    hovered = true
    needsDisplay = true
  }

  override func mouseExited(with event: NSEvent) {
    hovered = false
    needsDisplay = true
  }

  override func draw(_ dirtyRect: NSRect) {
    if hovered {
      NSColor.black.withAlphaComponent(0.07).setFill()
      NSBezierPath(ovalIn: bounds.insetBy(dx: 0.5, dy: 0.5)).fill()
    }
    super.draw(dirtyRect)
  }
}


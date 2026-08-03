import AppKit
import Foundation

@MainActor
public final class PTYTerminalSurfaceRegistry: TerminalSurfaceRegistry {
  private struct SurfaceState {
    var containerView: PTYTerminalSurfaceView
    var scrollView: NSScrollView
    var textView: PTYTextView
    var gridView: PTYGridView
    var liveRenderer: any TerminalLiveRendererBackend
    var textBackend: GhosttyVTTextRendererBackend
    var bridge: GhosttyVTBridge? = nil
    var scrollbar: GhosttyTerminalScrollbar? = nil
    var lastFrame: GhosttyTerminalFrame? = nil
    var lastRenderFrame: TerminalRenderFrame? = nil
    var lastHTMLSnapshot: String? = nil
    var lastCursorFrame: GhosttyTerminalFrame? = nil
    var liveRendererFallbackReason: String? = nil
    var bridgeDiagnostics = BridgeRenderDiagnostics()
  }

  private struct BridgeRenderDiagnostics {
    var scrollViewportDuration: TimeInterval = 0
    var scrollbarSnapshotDuration: TimeInterval = 0
    var frameSnapshotDuration: TimeInterval = 0
    var scrollFrameSnapshotDuration: TimeInterval = 0
    var snapshotCellCount: Int = 0

    func apply(to diagnostics: inout TerminalRendererDiagnostics) {
      diagnostics.bridgeScrollViewportDuration = scrollViewportDuration
      diagnostics.bridgeScrollbarSnapshotDuration = scrollbarSnapshotDuration
      diagnostics.bridgeFrameSnapshotDuration = frameSnapshotDuration
      diagnostics.bridgeScrollFrameSnapshotDuration = scrollFrameSnapshotDuration
      diagnostics.bridgeSnapshotCellCount = snapshotCellCount
    }
  }

  private struct CursorTextPlacement {
    var index: Int
    var filler: String
  }

  private var surfaces: [TerminalSessionID: SurfaceState] = [:]
  private lazy var outputCoordinator: TerminalOutputCoordinator = TerminalOutputCoordinator(
    coalescingDelayNanoseconds: TerminalOutputCoordinator.pipelineStageDelayNanoseconds
  ) { [weak self] snapshot, bridge, session, wasPinnedToBottom in
    self?.renderOutputImmediately(
      snapshot,
      bridge: bridge,
      session: session,
      wasPinnedToBottom: wasPinnedToBottom
    )
  }
  private var palette = TerminalSurfacePalette.dark
  private var fontFamily = FontCatalog.defaultMonospacedFontName()
  private var cjkFallbackFamily: String?
  private var fontSize: CGFloat = 14
  private var focusedSessionID: TerminalSessionID?
  private var pendingFocusSessionID: TerminalSessionID?
  private var inputHandler: (@MainActor (TerminalSessionID, Data) -> Void)?
  private var pasteHandler: (@MainActor (TerminalSessionID, String) -> Void)?
  private var activationHandler: (@MainActor (TerminalSessionID) -> Void)?
  private var linkHoverHandler: (@MainActor (TerminalSessionID, Bool) -> Void)?
  private var linkTargetHandler: (@MainActor (TerminalSessionID, TerminalLinkTarget) -> Void)?
  /// Per-session predicate: does a bare token resolve to an existing file/dir under
  /// that session's cwd? Enables bare-word path detection (e.g. `src`, `dist`).
  private var pathExistenceProvider: (@MainActor (TerminalSessionID, String) -> Bool)?
  /// Per-session resolver: a clicked file target → its absolute path + popover
  /// detail lines. Owns cwd resolution + filesystem access (App layer).
  private var fileInfoProvider: (@MainActor (TerminalSessionID, TerminalFilePathTarget) -> TerminalFileFacts?)?
  private var viewportScrollHandler: (@MainActor (TerminalSessionID, Int) -> Bool)?
  private var semanticLinkText = SemanticLinkText()
  private var rendererOptions = TerminalRendererOptions()
  private let isMetalDirectAvailable: Bool
  private let makeDirectRenderer: (TerminalRendererOptions) -> any TerminalLiveRendererBackend

  public init(
    isMetalDirectAvailable: Bool = MetalDirectRendererBackend.isRuntimeAvailable,
    makeDirectRenderer: @escaping (TerminalRendererOptions) -> any TerminalLiveRendererBackend = { options in
      MetalDirectRendererBackend(options: options)
    }
  ) {
    self.isMetalDirectAvailable = isMetalDirectAvailable
    self.makeDirectRenderer = makeDirectRenderer
  }

  public func createSurface(session id: TerminalSessionID) {
    let textBackend = GhosttyVTTextRendererBackend(
      palette: palette,
      fontFamily: fontFamily,
      cjkFallbackFamily: cjkFallbackFamily,
      fontSize: fontSize
    )
    textBackend.setInputHandler { [weak self] data in
      guard let self else { return }
      inputHandler?(id, data)
    }
    textBackend.setPasteHandler { [weak self] text in
      guard let self else { return }
      pasteHandler?(id, text)
    }
    textBackend.setActivationHandler { [weak self] in
      self?.activationHandler?(id)
    }
    let textView = textBackend.textView
    let scrollView = textBackend.scrollView

    let liveRenderer = makeLiveRenderer()
    liveRenderer.applyPalette(palette)
    liveRenderer.applyFont(family: fontFamily, size: fontSize, cjkFallbackFamily: cjkFallbackFamily)
    let gridView = liveRenderer.gridView
    configureLiveGridView(gridView, session: id)

    let containerView = PTYTerminalSurfaceView(scrollView: scrollView, liveGridView: gridView)
    containerView.onWindowAvailable = { [weak self] in
      self?.focusPendingSessionIfNeeded()
    }
    containerView.applyPalette(palette)
    surfaces[id] = SurfaceState(
      containerView: containerView,
      scrollView: scrollView,
      textView: textView,
      gridView: gridView,
      liveRenderer: liveRenderer,
      textBackend: textBackend
    )
  }

  private func makeLiveRenderer() -> any TerminalLiveRendererBackend {
    // Resolved with hasFrame: true because this only builds the *live* renderer;
    // the text-fallback presentation is driven separately by the textBackend
    // when there is no live frame. So .ghosttyVTTextFallback here means "no live
    // GPU/text choice applies" and we use the CPU cell grid as the live surface.
    let selection = TerminalRendererPolicy.resolve(
      mode: rendererOptions.mode,
      hasFrame: true,
      isMetalDirectAvailable: isMetalDirectAvailable
    )
    switch selection.activeBackend {
    case .metalDirect:
      let directRenderer = makeDirectRenderer(rendererOptions)
      if directRenderer.diagnostics.metalDirect.pipelineReady {
        return directRenderer
      }
      return GhosttyVTCellGridRendererBackend(options: rendererOptions)
    case .ghosttyVTCellGrid, .ghosttyVTTextFallback:
      return GhosttyVTCellGridRendererBackend(options: rendererOptions)
    }
  }

  private func configureLiveGridView(_ gridView: PTYGridView, session id: TerminalSessionID) {
    gridView.inputHandler = { [weak self] data in
      guard let self else { return }
      inputHandler?(id, data)
    }
    gridView.pasteHandler = { [weak self] text in
      guard let self else { return }
      pasteHandler?(id, text)
    }
    gridView.viewportScrollHandler = { [weak self] rowDelta in
      guard let self, rowDelta != 0 else { return false }
      return self.scrollViewport(session: id, rowDelta: rowDelta, backend: self.surfaces[id]?.liveRenderer)
    }
    gridView.viewportCanScrollHandler = { [weak self] rowDelta in
      guard let self, rowDelta != 0 else { return false }
      return self.canScrollViewport(session: id, rowDelta: rowDelta)
    }
    gridView.browseScrollMetricsHandler = { [weak self] in
      guard let self, let bridge = self.surfaces[id]?.bridge,
        let scrollbar = try? bridge.scrollbar()
      else {
        return nil
      }
      return (total: scrollbar.total, topAbsoluteRow: scrollbar.offset)
    }
    gridView.browsePresentHandler = { [weak self] topAbsoluteRow, visibleRows in
      self?.presentBrowseWindow(session: id, topAbsoluteRow: topAbsoluteRow, visibleRows: visibleRows)
    }
    gridView.browseFollowResumeHandler = { [weak self] in
      // Scrolled back to the live tail: render the live frame (cursor + latest
      // output) from the VT, replacing the history window.
      guard let self, let bridge = self.surfaces[id]?.bridge else { return }
      self.render(bridge, session: id)
    }
    gridView.rowFetchHandler = { [weak self] startRow, count in
      guard let self, let bridge = self.surfaces[id]?.bridge else { return nil }
      return try? bridge.rows(at: startRow, count: count)
    }
    gridView.activationHandler = { [weak self] in
      self?.activationHandler?(id)
    }
    gridView.linkHoverHandler = { [weak self] isHovering in
      self?.linkHoverHandler?(id, isHovering)
    }
    gridView.openLinkTargetHandler = { [weak self] target in
      PTYRenderDebugLog.write("surface link-target session=\(id) target=\(target)")
      self?.linkTargetHandler?(id, target)
    }
    gridView.pathExistenceValidator = pathExistenceProvider.map { provider in
      { token in provider(id, token) }
    }
    gridView.fileInfoProvider = fileInfoProvider.map { provider in
      { target in provider(id, target) }
    }
    gridView.mouseReportingActiveHandler = { [weak self] in
      guard let self, let bridge = self.surfaces[id]?.bridge else { return false }
      return bridge.isMouseReportingActive()
    }
    gridView.semanticLinkText = semanticLinkText
    gridView.pasteboard = .general
    gridView.applyPalette(palette)
    gridView.applyFont(family: fontFamily, size: fontSize, cjkFallbackFamily: cjkFallbackFamily)
    gridView.applyRendererOptions(rendererOptions)
  }

  private func replaceLiveRenderer(
    _ newRenderer: any TerminalLiveRendererBackend,
    session id: TerminalSessionID,
    surface: inout SurfaceState,
    fallbackReason: String? = nil,
    preserveVisibleFrame: Bool = true
  ) {
    let oldGridView = surface.gridView
    surface.liveRenderer = newRenderer
    surface.gridView = newRenderer.gridView
    surface.liveRendererFallbackReason = fallbackReason
    if oldGridView !== surface.gridView {
      surface.containerView.replaceLiveGridView(with: surface.gridView)
    }
    configureLiveGridView(surface.gridView, session: id)
    if preserveVisibleFrame, let renderFrame = surface.lastRenderFrame {
      render(renderFrame, in: surface.liveRenderer)
      surface.liveRenderer.flushPendingFrame()
    }
  }

  public func removeSurface(session id: TerminalSessionID) {
    outputCoordinator.cancel(session: id)
    surfaces[id] = nil
  }

  public func viewForSession(_ id: TerminalSessionID) -> NSView? {
    surfaces[id]?.containerView
  }

  public func selectedText(for id: TerminalSessionID) -> String? {
    guard let surface = surfaces[id] else { return nil }
    if surface.containerView.isShowingLiveGrid {
      return surface.gridView.selectedText
    }
    let textView = surface.textView
    let range = textView.selectedRange()
    guard range.length > 0 else { return nil }
    return (textView.string as NSString).substring(with: range)
  }

  public func rendererDiagnostics(for id: TerminalSessionID) -> TerminalRendererDiagnostics? {
    guard let surface = surfaces[id] else { return nil }
    return composedRendererDiagnostics(for: surface)
  }

  private func composedRendererDiagnostics(for surface: SurfaceState) -> TerminalRendererDiagnostics {
    var diagnostics: TerminalRendererDiagnostics
    if surface.containerView.isShowingLiveGrid {
      diagnostics = surface.liveRenderer.diagnostics
      if let liveRendererFallbackReason = surface.liveRendererFallbackReason {
        diagnostics.backendFallbackReason = liveRendererFallbackReason
      }
    } else {
      diagnostics = surface.textBackend.diagnostics
    }
    surface.bridgeDiagnostics.apply(to: &diagnostics)
    return diagnostics
  }

  public func applyPalette(_ palette: TerminalSurfacePalette) {
    self.palette = palette
    for (sessionID, surface) in surfaces {
      surface.containerView.applyPalette(palette)
      surface.gridView.applyPalette(palette)
      surface.liveRenderer.applyPalette(palette)
      surface.textBackend.applyPalette(palette)
      refreshPresentation(for: sessionID)
    }
  }

  public func applyFont(family: String, size: CGFloat, cjkFallbackFamily: String? = nil) {
    fontFamily = family
    self.cjkFallbackFamily = normalizedFontFamily(cjkFallbackFamily)
    fontSize = size
    for (sessionID, surface) in surfaces {
      surface.textView.font = terminalFont(weight: .regular)
      surface.gridView.applyFont(family: family, size: size, cjkFallbackFamily: self.cjkFallbackFamily)
      surface.liveRenderer.applyFont(family: family, size: size, cjkFallbackFamily: self.cjkFallbackFamily)
      surface.textBackend.applyFont(family: family, size: size, cjkFallbackFamily: self.cjkFallbackFamily)
      refreshPresentation(for: sessionID)
      surface.textView.window?.invalidateCursorRects(for: surface.textView)
      surface.gridView.window?.invalidateCursorRects(for: surface.gridView)
    }
  }

  public func applyRendererOptions(_ options: TerminalRendererOptions) {
    rendererOptions = options
    for surface in surfaces.values {
      surface.gridView.applyRendererOptions(options)
      surface.liveRenderer.applyOptions(options)
    }
  }

  public func flushPendingRenderers() {
    outputCoordinator.flushAll()
    for sessionID in Array(surfaces.keys) {
      surfaces[sessionID]?.liveRenderer.flushPendingFrame()
      guard var surface = surfaces[sessionID] else { continue }
      handleLiveRendererFailureIfNeeded(session: sessionID, surface: &surface)
      surfaces[sessionID] = surface
    }
  }

  public func setFocusedSession(_ id: TerminalSessionID?) {
    guard focusedSessionID != id else { return }
    focusedSessionID = id
    for sessionID in surfaces.keys {
      refreshPresentation(for: sessionID)
    }
  }

  public func focusSessionView(_ id: TerminalSessionID?) {
    guard let id, let surface = surfaces[id] else { return }
    pendingFocusSessionID = id
    if focus(surface: surface) {
      pendingFocusSessionID = nil
    }
  }

  private func focusPendingSessionIfNeeded() {
    guard let pendingFocusSessionID, let surface = surfaces[pendingFocusSessionID] else { return }
    if focus(surface: surface) {
      self.pendingFocusSessionID = nil
    }
  }

  private func focus(surface: SurfaceState) -> Bool {
    let responder: NSView = surface.containerView.isShowingLiveGrid ? surface.gridView : surface.textView
    guard let window = responder.window else { return false }
    return window.makeFirstResponder(responder)
  }

  public func setInputHandler(_ handler: (@MainActor (TerminalSessionID, Data) -> Void)?) {
    inputHandler = handler
  }

  public func setPasteHandler(_ handler: (@MainActor (TerminalSessionID, String) -> Void)?) {
    pasteHandler = handler
  }

  public func setActivationHandler(_ handler: (@MainActor (TerminalSessionID) -> Void)?) {
    activationHandler = handler
  }

  public func setLinkHoverHandler(_ handler: (@MainActor (TerminalSessionID, Bool) -> Void)?) {
    linkHoverHandler = handler
    for (id, surface) in surfaces {
      surface.gridView.linkHoverHandler = { [weak self] isHovering in
        self?.linkHoverHandler?(id, isHovering)
      }
    }
  }

  public func setLinkTargetHandler(_ handler: (@MainActor (TerminalSessionID, TerminalLinkTarget) -> Void)?) {
    linkTargetHandler = handler
    for (id, surface) in surfaces {
      surface.gridView.openLinkTargetHandler = { [weak self] target in
        PTYRenderDebugLog.write("surface link-target session=\(id) target=\(target)")
        self?.linkTargetHandler?(id, target)
      }
    }
  }

  public func setPathExistenceProvider(_ provider: (@MainActor (TerminalSessionID, String) -> Bool)?) {
    pathExistenceProvider = provider
    for (id, surface) in surfaces {
      surface.gridView.pathExistenceValidator = provider.map { provider in
        { token in provider(id, token) }
      }
    }
  }

  public func setFileInfoProvider(_ provider: (@MainActor (TerminalSessionID, TerminalFilePathTarget) -> TerminalFileFacts?)?) {
    fileInfoProvider = provider
    for (id, surface) in surfaces {
      surface.gridView.fileInfoProvider = provider.map { provider in
        { target in provider(id, target) }
      }
    }
  }

  public func applySemanticLinkText(_ text: SemanticLinkText) {
    semanticLinkText = text
    for surface in surfaces.values {
      surface.gridView.semanticLinkText = text
    }
  }

  public func setViewportScrollHandler(_ handler: (@MainActor (TerminalSessionID, Int) -> Bool)?) {
    viewportScrollHandler = handler
  }

  public func render(_ bridge: GhosttyVTBridge, session id: TerminalSessionID) {
    guard var surface = surfaces[id] else { return }
    outputCoordinator.cancel(session: id)
    let scrollbarStart = Self.now()
    surface.scrollbar = try? bridge.scrollbar()
    surface.bridgeDiagnostics.scrollbarSnapshotDuration = Self.now() - scrollbarStart
    render(bridge, surface: &surface, session: id)
    surfaces[id] = surface
  }

  public func render(_ snapshot: ResizeRenderSnapshot, bridge: GhosttyVTBridge, session id: TerminalSessionID) {
    guard var surface = surfaces[id] else { return }
    outputCoordinator.cancel(session: id)
    surface.bridge = bridge
    surface.scrollbar = snapshot.scrollbar
    render(snapshot, surface: &surface, session: id)
    surfaces[id] = surface
  }

  public func renderOutput(
    _ snapshot: ResizeRenderSnapshot,
    bridge: GhosttyVTBridge,
    session id: TerminalSessionID,
    wasPinnedToBottom: Bool,
    delivery: TerminalOutputCoordinator.Delivery = .coalesced
  ) {
    guard surfaces[id] != nil else { return }
    outputCoordinator.scheduleRender(
      snapshot: snapshot,
      bridge: bridge,
      session: id,
      wasPinnedToBottom: wasPinnedToBottom,
      delivery: delivery
    )
  }

  private func renderOutputImmediately(
    _ snapshot: ResizeRenderSnapshot,
    bridge: GhosttyVTBridge,
    session id: TerminalSessionID,
    wasPinnedToBottom: Bool
  ) {
    guard var surface = surfaces[id] else { return }
    surface.bridge = bridge
    surface.scrollbar = snapshot.scrollbar
    if surface.containerView.isShowingLiveGrid {
      // Dragging a selection: changing content mid-drag would corrupt the
      // selection anchor, so keep freezing (matches pattern-1).
      if surface.gridView.isDraggingSelection {
        surfaces[id] = surface
        return
      }
      // Active gesture/inertia: the display link is running and will re-present
      // with the latest total on its next tick — don't present concurrently.
      // (Checked before browseTopAbsoluteRow, which is also set mid-gesture.)
      if surface.gridView.isSmoothScrollBrowsingActive {
        surfaces[id] = surface
        return
      }
      // Pattern-2 settled in history: instead of freezing the display, re-present
      // the SAME browse window against the now-larger scrollback. The anchored
      // rows are unchanged (new output only appends at the bottom), so the
      // visible history stays put while the tail keeps flowing below.
      if let browseTop = surface.gridView.browseTopAbsoluteRow {
        let visibleRows = snapshot.frame?.rows ?? surface.lastFrame?.rows ?? 0
        // Persist the refreshed bridge/scrollbar before handing off to
        // presentBrowseWindow (which reads surfaces[id] fresh and writes it back).
        surfaces[id] = surface
        if visibleRows > 0 {
          presentBrowseWindow(session: id, topAbsoluteRow: browseTop, visibleRows: visibleRows)
        }
        return
      }
      // Event-driven row-based history view (non-pattern-2 fallback): keep the
      // legacy freeze so output doesn't fight the row-commit path.
      if surface.gridView.isViewingHistory {
        surfaces[id] = surface
        return
      }
    }
    if !wasPinnedToBottom, surface.containerView.isShowingLiveGrid {
      surfaces[id] = surface
      return
    }
    if wasPinnedToBottom {
      surface.liveRenderer.resetPixelScroll(suppressMomentum: false)
    }
    render(snapshot, surface: &surface, session: id)
    surfaces[id] = surface
  }

  public func finishQueuedViewportScroll(
    _ snapshot: ResizeRenderSnapshot,
    bridge: GhosttyVTBridge,
    session id: TerminalSessionID
  ) {
    guard var surface = surfaces[id] else { return }
    surface.bridge = bridge
    surface.scrollbar = snapshot.scrollbar
    render(snapshot, surface: &surface, session: id)
    surface.liveRenderer.flushPendingFrame()
    surface.liveRenderer.resetViewportStartRowKeepingVisualOffset()
    surfaces[id] = surface
  }

  public func cancelQueuedViewportScroll(session id: TerminalSessionID) {
    guard let surface = surfaces[id] else { return }
    surface.liveRenderer.resetPixelScroll(suppressMomentum: false)
  }

  public func markResizePending(session id: TerminalSessionID) {
    guard let surface = surfaces[id] else { return }
    surface.liveRenderer.markResizePending()
    surface.textBackend.markResizePending()
  }

  public func applyResizeDiagnostics(_ diagnostics: TerminalResizeDiagnostics, session id: TerminalSessionID) {
    guard let surface = surfaces[id] else { return }
    surface.liveRenderer.applyResizeDiagnostics(diagnostics)
    surface.textBackend.applyResizeDiagnostics(diagnostics)
  }

  private func scrollViewport(
    session id: TerminalSessionID,
    rowDelta: Int,
    backend: (any TerminalLiveRendererBackend)?
  ) -> Bool {
    guard var surface = surfaces[id], backend != nil, let bridge = surface.bridge else { return false }
    // The grid controller uses positive deltas for visual downward movement
    // through history; libghostty's viewport API defines upward history
    // movement as negative.
    let terminalDelta = -rowDelta
    guard let scrollbar = surface.scrollbar else { return false }
    if isAtViewportEdge(deltaRows: terminalDelta, scrollbar: scrollbar) {
      return false
    }
    if let viewportScrollHandler {
      return viewportScrollHandler(id, rowDelta)
    }
    let scrollViewportStart = Self.now()
    bridge.scrollViewport(deltaRows: terminalDelta)
    surface.bridgeDiagnostics.scrollViewportDuration = Self.now() - scrollViewportStart
    let scrollbarStart = Self.now()
    surface.scrollbar = try? bridge.scrollbar()
    surface.bridgeDiagnostics.scrollbarSnapshotDuration = Self.now() - scrollbarStart
    renderScrollCommit(bridge, surface: &surface, session: id)
    surface.liveRenderer.resetViewportStartRowKeepingVisualOffset()
    surfaces[id] = surface
    return true
  }

  func viewportIsPinnedToBottom(_ id: TerminalSessionID) -> Bool? {
    guard let scrollbar = surfaces[id]?.scrollbar else { return nil }
    return scrollbar.offset + scrollbar.length >= scrollbar.total
  }

  func prepareForPinnedOutput(
    session id: TerminalSessionID,
    wasPinnedToBottom: Bool
  ) {
    guard wasPinnedToBottom, let surface = surfaces[id] else { return }
    surface.liveRenderer.resetPixelScroll(suppressMomentum: false)
  }

  @discardableResult
  func prepareForUserInput(session id: TerminalSessionID) -> Bool {
    guard let surface = surfaces[id] else { return false }
    let isPinnedToBottom = surface.scrollbar.map { scrollbar in
      scrollbar.offset + scrollbar.length >= scrollbar.total
    } ?? true
    let shouldRenderInputSnapshot = surface.gridView.isViewingHistory
      || surface.gridView.viewport != TerminalViewport()
      || !isPinnedToBottom
    guard shouldRenderInputSnapshot else { return false }
    surface.liveRenderer.resetPixelScroll(suppressMomentum: true)
    return true
  }

  private func canScrollViewport(session id: TerminalSessionID, rowDelta: Int) -> Bool {
    guard let scrollbar = surfaces[id]?.scrollbar else { return false }
    return !isAtViewportEdge(deltaRows: -rowDelta, scrollbar: scrollbar)
  }

  private func isAtViewportEdge(deltaRows: Int, bridge: GhosttyVTBridge) -> Bool {
    guard let scrollbar = try? bridge.scrollbar(), scrollbar.total > scrollbar.length else {
      return true
    }
    return isAtViewportEdge(deltaRows: deltaRows, scrollbar: scrollbar)
  }

  private func isAtViewportEdge(deltaRows: Int, scrollbar: GhosttyTerminalScrollbar) -> Bool {
    guard scrollbar.total > scrollbar.length else {
      return true
    }
    if deltaRows < 0 {
      return scrollbar.offset == 0
    }
    if deltaRows > 0 {
      return scrollbar.offset + scrollbar.length >= scrollbar.total
    }
    return true
  }

  private func scrollToBottom(_ bridge: GhosttyVTBridge) {
    GhosttyVTQueueWork.scrollToBottom(bridge)
  }

  private func handleLiveRendererFailureIfNeeded(
    session id: TerminalSessionID,
    surface: inout SurfaceState
  ) {
    guard surface.liveRenderer.diagnostics.backend == .metalDirect,
      surface.liveRenderer.diagnostics.backendFallbackReason == TerminalRendererDiagnostics.metalDirectRenderFailedFallbackReason
    else {
      return
    }
    let fallbackRenderer = GhosttyVTCellGridRendererBackend(options: rendererOptions)
    replaceLiveRenderer(
      fallbackRenderer,
      session: id,
      surface: &surface,
      fallbackReason: TerminalRendererDiagnostics.metalDirectRenderFailedFallbackReason
    )
  }

  private func render(_ renderFrame: TerminalRenderFrame, in backend: any TerminalLiveRendererBackend) {
    backend.render(renderFrame)
  }

  private func render(_ bridge: GhosttyVTBridge, surface: inout SurfaceState, session id: TerminalSessionID) {
    surface.bridge = bridge
    let shouldFollowOutput = surface.textBackend.isScrolledToBottom
    let frameStart = Self.now()
    let frame = try? bridge.frame()
    surface.bridgeDiagnostics.frameSnapshotDuration = Self.now() - frameStart
    surface.bridgeDiagnostics.scrollFrameSnapshotDuration = 0
    surface.bridgeDiagnostics.snapshotCellCount = frame?.cells.count ?? 0
    let rendererSelection = rendererSelection(for: frame)
    if let frame, rendererSelection.presentation == .liveCellGrid {
      let scrollFrameStart = Self.now()
      let scrollFrame = try? bridge.scrollFrame(overscanTop: GhosttyTerminalScrollFrame.pixelScrollOverscanRows, overscanBottom: GhosttyTerminalScrollFrame.pixelScrollOverscanRows)
      surface.bridgeDiagnostics.scrollFrameSnapshotDuration = Self.now() - scrollFrameStart
      surface.bridgeDiagnostics.snapshotCellCount = Self.snapshotCellCount(
        frame: frame,
        scrollFrame: scrollFrame
      )
      let renderFrame: TerminalRenderFrame
      if let scrollFrame {
        renderFrame = TerminalRenderFrame(scrollFrame: scrollFrame, isFocused: isFocused(id))
      } else {
        renderFrame = TerminalRenderFrame(frame: frame, isFocused: isFocused(id))
      }
      surface.lastHTMLSnapshot = nil
      surface.lastFrame = frame
      surface.lastCursorFrame = nil
      surface.lastRenderFrame = renderFrame
      let shouldTransferFocus = surface.textView.window?.firstResponder === surface.textView
      surface.containerView.showLiveGrid()
      PTYRenderDebugLog.write(
        "render session=\(id) mode=live-grid rows=\(frame.rows) cols=\(frame.cols) alt=\(frame.isAlternateScreen) cursor=(\(frame.cursorX),\(frame.cursorY)) shape=\(frame.cursorShape) belowCursor=\(hasRenderedContentBelowCursor(in: frame))"
      )
      if shouldTransferFocus {
        surface.gridView.window?.makeFirstResponder(surface.gridView)
      }
      render(renderFrame, in: surface.liveRenderer)
      if let scrollbar = surface.scrollbar, let scrollFrame {
        PTYRenderDebugLog.write(
          "snapshot session=\(id) scrollbar=(offset:\(scrollbar.offset), length:\(scrollbar.length), total:\(scrollbar.total)) viewportStart=\(String(describing: scrollFrame.viewportStartRow)) tail=\"\(Self.tailText(from: scrollFrame.viewport))\""
        )
      }
      PTYRenderDebugLog.write("diagnostics session=\(id) \(composedRendererDiagnostics(for: surface).debugSummary)")
    } else if let html = try? bridge.htmlText(),
      let attributed = try? attributedTerminalSnapshot(fromHTML: html, cursorFrame: frame, isFocused: isFocused(id))
    {
      surface.containerView.showScrollback()
      PTYRenderDebugLog.write(
        "render session=\(id) mode=scrollback-html rows=\(frame?.rows ?? 0) cols=\(frame?.cols ?? 0) alt=\(frame?.isAlternateScreen ?? false) cursor=(\(frame?.cursorX ?? 0),\(frame?.cursorY ?? 0)) shape=\(String(describing: frame?.cursorShape)) belowCursor=\(frame.map { hasRenderedContentBelowCursor(in: $0) } ?? false)"
      )
      surface.lastHTMLSnapshot = html
      surface.lastFrame = nil
      surface.lastCursorFrame = frame
      surface.textBackend.setFocused(isFocused(id))
      surface.textBackend.render(attributed: attributed, scrollToEnd: shouldFollowOutput)
      PTYRenderDebugLog.write("diagnostics session=\(id) \(composedRendererDiagnostics(for: surface).debugSummary)")
    } else if let text = try? bridge.plainText() {
      surface.containerView.showScrollback()
      PTYRenderDebugLog.write("render session=\(id) mode=plain-text")
      surface.lastHTMLSnapshot = nil
      surface.lastFrame = nil
      surface.lastCursorFrame = nil
      surface.textBackend.render(plainText: text)
      PTYRenderDebugLog.write("diagnostics session=\(id) \(composedRendererDiagnostics(for: surface).debugSummary)")
    }
  }

  private func renderScrollCommit(_ bridge: GhosttyVTBridge, surface: inout SurfaceState, session id: TerminalSessionID) {
    surface.bridge = bridge
    surface.bridgeDiagnostics.frameSnapshotDuration = 0
    let scrollFrameStart = Self.now()
    let scrollFrame = try? bridge.scrollFrame(overscanTop: GhosttyTerminalScrollFrame.pixelScrollOverscanRows, overscanBottom: GhosttyTerminalScrollFrame.pixelScrollOverscanRows)
    surface.bridgeDiagnostics.scrollFrameSnapshotDuration = Self.now() - scrollFrameStart
    guard let scrollFrame else {
      surface.bridgeDiagnostics.snapshotCellCount = 0
      return
    }
    surface.bridgeDiagnostics.snapshotCellCount = Self.snapshotCellCount(
      frame: scrollFrame.viewport,
      scrollFrame: scrollFrame
    )
    let renderFrame = TerminalRenderFrame(scrollFrame: scrollFrame, isFocused: isFocused(id))
    surface.lastHTMLSnapshot = nil
    surface.lastFrame = scrollFrame.viewport
    surface.lastCursorFrame = nil
    surface.lastRenderFrame = renderFrame
    let shouldTransferFocus = surface.textView.window?.firstResponder === surface.textView
    surface.containerView.showLiveGrid()
    if shouldTransferFocus {
      surface.gridView.window?.makeFirstResponder(surface.gridView)
    }
    render(renderFrame, in: surface.liveRenderer)
    if let scrollbar = surface.scrollbar {
      PTYRenderDebugLog.write(
        "scroll-render session=\(id) scrollbar=(offset:\(scrollbar.offset), length:\(scrollbar.length), total:\(scrollbar.total)) viewportStart=\(String(describing: scrollFrame.viewportStartRow)) tail=\"\(Self.tailText(from: scrollFrame.viewport))\""
      )
    }
    PTYRenderDebugLog.write("diagnostics session=\(id) \(composedRendererDiagnostics(for: surface).debugSummary)")
  }

  /// Re-render a surface's current visible content with up-to-date presentation
  /// attributes (focused cursor style, palette, font) WITHOUT changing the scroll
  /// position. In browse mode this re-presents the history window; in live mode it
  /// renders the latest bottom frame.
  private func refreshPresentation(for sessionID: TerminalSessionID) {
    guard let surface = surfaces[sessionID] else { return }

    // Path 1: text backend (HTML snapshot fallback)
    if let html = surface.lastHTMLSnapshot,
      let attributed = try? attributedTerminalSnapshot(
        fromHTML: html,
        cursorFrame: surface.lastCursorFrame,
        isFocused: isFocused(sessionID)
      )
    {
      surface.textBackend.render(attributed: attributed, scrollToEnd: false)
      return
    }

    // Path 2: pattern-2 browse mode — re-present the history window
    if surface.containerView.isShowingLiveGrid,
      let browseTop = surface.gridView.browseTopAbsoluteRow
    {
      let visibleRows = surface.lastFrame?.rows ?? 0
      if visibleRows > 0 {
        presentBrowseWindow(session: sessionID, topAbsoluteRow: browseTop, visibleRows: visibleRows)
        return
      }
    }

    // Path 3: live bottom — normal render
    if let frame = surface.lastFrame {
      render(frame, in: surface.liveRenderer, isFocused: isFocused(sessionID))
    }
  }

  /// Pattern-2 browse present: fetch the window `[topAbsoluteRow, +visibleRows)`
  /// (plus one row above and below for the sub-row peek) DIRECTLY from
  /// scrollback via `rows(at:)`, WITHOUT moving the VT viewport, and present it
  /// as a scroll frame with one overscan row on each side. The grid view's
  /// display-link tick already set `viewport.visualOffsetY` to the sub-row
  /// pixel offset; the renderer draws `topAbsoluteRow` shifted down by it.
  private func presentBrowseWindow(
    session id: TerminalSessionID,
    topAbsoluteRow: UInt64,
    visibleRows: Int
  ) {
    guard var surface = surfaces[id], let bridge = surface.bridge, visibleRows > 0 else { return }

    // One row above (overscan top, revealed by a positive pixel offset), the
    // visible rows, and one row below (overscan bottom).
    let hasTop = topAbsoluteRow > 0
    let start = hasTop ? topAbsoluteRow - 1 : topAbsoluteRow
    let count = visibleRows + (hasTop ? 1 : 0) + 1
    guard let window = try? bridge.rows(at: start, count: count), window.cols > 0 else { return }

    let cols = window.cols
    let rows = window.rows
    let topOverscanCount = hasTop && !rows.isEmpty ? 1 : 0

    let overscanTop = topOverscanCount > 0 ? Array(rows.prefix(1)) : []
    let remainder = Array(rows.dropFirst(topOverscanCount))
    let viewportRowSlice = Array(remainder.prefix(visibleRows))
    let overscanBottom = Array(remainder.dropFirst(viewportRowSlice.count).prefix(1))

    // Synthesize the viewport frame from the fetched rows. Cursor is off-screen
    // while browsing history, so it is hidden.
    var viewportCells: [GhosttyTerminalFrame.Cell] = []
    viewportCells.reserveCapacity(viewportRowSlice.count * cols)
    for row in viewportRowSlice {
      viewportCells.append(contentsOf: row.cells)
    }
    let viewportFrame = GhosttyTerminalFrame(
      cols: cols,
      rows: viewportRowSlice.count,
      cursorVisible: false,
      cursorX: 0,
      cursorY: 0,
      cells: viewportCells
    )

    let scrollFrame = GhosttyTerminalScrollFrame(
      viewport: viewportFrame,
      overscanTop: overscanTop,
      overscanBottom: overscanBottom,
      requestedOverscanTop: topOverscanCount,
      requestedOverscanBottom: overscanBottom.count,
      viewportStartRow: start &+ UInt64(topOverscanCount)
    )
    let renderFrame = TerminalRenderFrame(scrollFrame: scrollFrame, isFocused: isFocused(id))
    surface.lastRenderFrame = renderFrame
    surfaces[id] = surface
    render(renderFrame, in: surface.liveRenderer)
    surface.liveRenderer.flushPendingFrame()
  }

  private func render(_ snapshot: ResizeRenderSnapshot, surface: inout SurfaceState, session id: TerminalSessionID) {
    let shouldFollowOutput = surface.textBackend.isScrolledToBottom
    let rendererSelection = rendererSelection(for: snapshot.frame)
    if let frame = snapshot.frame, rendererSelection.presentation == .liveCellGrid {
      let renderFrame = snapshot.scrollFrame.map { TerminalRenderFrame(scrollFrame: $0, isFocused: isFocused(id)) }
        ?? TerminalRenderFrame(frame: frame, isFocused: isFocused(id))
      surface.lastHTMLSnapshot = nil
      surface.lastFrame = frame
      surface.lastCursorFrame = nil
      surface.lastRenderFrame = renderFrame
      let shouldTransferFocus = surface.textView.window?.firstResponder === surface.textView
      surface.containerView.showLiveGrid()
      if shouldTransferFocus {
        surface.gridView.window?.makeFirstResponder(surface.gridView)
      }
      render(renderFrame, in: surface.liveRenderer)
      surface.liveRenderer.flushPendingFrame()
      handleLiveRendererFailureIfNeeded(session: id, surface: &surface)
      PTYRenderDebugLog.write(
        "resize-render session=\(id) mode=live-grid rows=\(frame.rows) cols=\(frame.cols) scrollbar=(offset:\(snapshot.scrollbar?.offset ?? 0), length:\(snapshot.scrollbar?.length ?? 0), total:\(snapshot.scrollbar?.total ?? 0)) diagnostics=\(surface.liveRenderer.diagnostics.debugSummary)"
      )
    } else if let html = snapshot.html,
      let attributed = try? attributedTerminalSnapshot(
        fromHTML: html,
        cursorFrame: snapshot.frame,
        isFocused: isFocused(id)
      )
    {
      surface.containerView.showScrollback()
      surface.lastHTMLSnapshot = html
      surface.lastFrame = nil
      surface.lastCursorFrame = snapshot.frame
      surface.textBackend.setFocused(isFocused(id))
      surface.textBackend.render(attributed: attributed, scrollToEnd: shouldFollowOutput)
      PTYRenderDebugLog.write("resize-render session=\(id) mode=scrollback-html diagnostics=\(surface.textBackend.diagnostics.debugSummary)")
    } else if let text = snapshot.plainText {
      surface.containerView.showScrollback()
      surface.lastHTMLSnapshot = nil
      surface.lastFrame = nil
      surface.lastCursorFrame = nil
      surface.textBackend.render(plainText: text)
      PTYRenderDebugLog.write("resize-render session=\(id) mode=plain-text diagnostics=\(surface.textBackend.diagnostics.debugSummary)")
    }
  }

  private func shouldRenderLiveCellGrid(_ frame: GhosttyTerminalFrame) -> Bool {
    frame.isAlternateScreen || frame.cursorShape != .block || hasRenderedContentBelowCursor(in: frame)
  }

  private func rendererSelection(for frame: GhosttyTerminalFrame?) -> TerminalRendererBackendSelection {
    TerminalRendererPolicy.resolve(
      mode: rendererOptions.mode,
      hasFrame: frame != nil,
      isMetalDirectAvailable: isMetalDirectAvailable
    )
  }

  private func hasRenderedContentBelowCursor(in frame: GhosttyTerminalFrame) -> Bool {
    let firstRowBelowCursor = max(0, frame.cursorY + 1)
    guard firstRowBelowCursor < frame.rows else { return false }
    for row in firstRowBelowCursor..<frame.rows {
      let rowStart = row * frame.cols
      let rowEnd = min(rowStart + frame.cols, frame.cells.count)
      guard rowStart < rowEnd else { continue }
      if frame.cells[rowStart..<rowEnd].contains(where: isRenderedCell) {
        return true
      }
    }
    return false
  }

  private static func tailText(from frame: GhosttyTerminalFrame, maxRows: Int = 6) -> String {
    guard frame.rows > 0, frame.cols > 0 else { return "" }
    let firstRow = max(0, frame.rows - maxRows)
    return (firstRow..<frame.rows)
      .map { row in
        let start = row * frame.cols
        let end = min(start + frame.cols, frame.cells.count)
        guard start < end else { return "" }
        return frame.cells[start..<end]
          .map { String($0.scalar) }
          .joined()
          .trimmingCharacters(in: .whitespaces)
      }
      .joined(separator: " | ")
  }

  private static func snapshotCellCount(
    frame: GhosttyTerminalFrame,
    scrollFrame: GhosttyTerminalScrollFrame?
  ) -> Int {
    guard let scrollFrame else { return frame.cells.count }
    return scrollFrame.viewport.cells.count
      + scrollFrame.overscanTop.reduce(0) { $0 + $1.cells.count }
      + scrollFrame.overscanBottom.reduce(0) { $0 + $1.cells.count }
  }

  private static func now() -> TimeInterval {
    ProcessInfo.processInfo.systemUptime
  }

  private func render(
    _ frame: GhosttyTerminalFrame,
    in backend: any TerminalLiveRendererBackend,
    isFocused: Bool
  ) {
    backend.render(TerminalRenderFrame(frame: frame, isFocused: isFocused))
  }

  private func render(
    bridge: GhosttyVTBridge,
    fallbackFrame frame: GhosttyTerminalFrame,
    in backend: any TerminalLiveRendererBackend,
    isFocused: Bool
  ) {
    guard let scrollFrame = try? bridge.scrollFrame(overscanTop: GhosttyTerminalScrollFrame.pixelScrollOverscanRows, overscanBottom: GhosttyTerminalScrollFrame.pixelScrollOverscanRows) else {
      backend.render(TerminalRenderFrame(frame: frame, isFocused: isFocused))
      backend.updateOverscanDiagnostics(topRows: 0, bottomRows: 0)
      return
    }
    backend.render(TerminalRenderFrame(scrollFrame: scrollFrame, isFocused: isFocused))
  }

  private func render(
    _ frame: GhosttyTerminalFrame,
    in view: NSTextView,
    scrollView: NSScrollView,
    isFocused: Bool,
    scrollToEnd: Bool
  ) {
    let attributed = TerminalAttributedRenderer(
      fontFamily: fontFamily,
      cjkFallbackFamily: cjkFallbackFamily,
      fontSize: fontSize,
      palette: palette,
      isFocused: isFocused
    )
    .attributedString(for: frame)
    replaceText(in: view, with: attributed, scrollView: scrollView, scrollToEnd: scrollToEnd)
  }

  private func replaceText(
    in textView: NSTextView,
    with attributed: NSAttributedString,
    scrollView: NSScrollView,
    scrollToEnd: Bool
  ) {
    let previousOrigin = scrollView.contentView.bounds.origin
    let previousCursorMinY = scrollToEnd ? cursorDocumentMinY(in: textView) : nil
    if let textStorage = textView.textStorage {
      TerminalAttributedDiff.apply(attributed, to: textStorage)
    } else {
      textView.textStorage?.setAttributedString(attributed)
    }
    textView.window?.invalidateCursorRects(for: textView)
    if scrollToEnd {
      if
        let previousCursorMinY,
        let nextCursorMinY = cursorDocumentMinY(in: textView),
        let documentView = scrollView.documentView
      {
        let maxOriginY = max(0, documentView.bounds.maxY - scrollView.contentView.bounds.height)
        let originY = TerminalScrollAnchor.replacementOrigin(
          previousOriginY: previousOrigin.y,
          previousCursorDocumentMinY: previousCursorMinY,
          nextCursorDocumentMinY: nextCursorMinY,
          maxOriginY: maxOriginY
        )
        scrollView.contentView.scroll(to: NSPoint(x: previousOrigin.x, y: originY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
      } else {
        textView.scrollToEndOfDocument(nil)
      }
    } else {
      scrollView.contentView.scroll(to: previousOrigin)
      scrollView.reflectScrolledClipView(scrollView.contentView)
    }
  }

  private func cursorDocumentMinY(in textView: NSTextView) -> CGFloat? {
    guard
      let textStorage = textView.textStorage,
      let layoutManager = textView.layoutManager,
      let textContainer = textView.textContainer,
      textStorage.length > 0
    else {
      return nil
    }
    var cursorRange: NSRange?
    textStorage.enumerateAttribute(
      .proGhosttyCursorShape,
      in: NSRange(location: 0, length: textStorage.length)
    ) { value, range, stop in
      guard value is TerminalCursorShape else { return }
      cursorRange = range
      stop.pointee = true
    }
    guard let cursorRange else { return nil }
    layoutManager.ensureLayout(for: textContainer)
    let glyphRange = layoutManager.glyphRange(
      forCharacterRange: NSRange(location: cursorRange.location, length: 1),
      actualCharacterRange: nil
    )
    guard glyphRange.length > 0 else { return nil }
    let rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
    return textView.textContainerOrigin.y + rect.minY
  }

  private func isScrolledToBottom(_ scrollView: NSScrollView) -> Bool {
    guard let documentView = scrollView.documentView else { return true }
    let visibleMaxY = scrollView.contentView.bounds.maxY
    let documentMaxY = documentView.bounds.maxY
    return documentMaxY - visibleMaxY < 2
  }

  private func isFocused(_ id: TerminalSessionID) -> Bool {
    focusedSessionID.map { $0 == id } ?? true
  }

  private func attributedTerminalSnapshot(from bridge: GhosttyVTBridge) throws -> NSAttributedString {
    try attributedTerminalSnapshot(fromHTML: bridge.htmlText(), cursorFrame: try? bridge.frame(), isFocused: true)
  }

  private func attributedTerminalSnapshot(
    fromHTML html: String,
    cursorFrame: GhosttyTerminalFrame?,
    isFocused: Bool
  ) throws -> NSAttributedString {
    let attributed = try GhosttyHTMLAttributedAdapter(
      palette: palette,
      fontFamily: fontFamily,
      fontSize: fontSize
    ).attributedString(fromHTML: html, isFocused: isFocused)
    return attributedWithCursor(attributed, cursorFrame: cursorFrame, isFocused: isFocused)
  }

  private func attributedWithCursor(
    _ attributed: NSAttributedString,
    cursorFrame: GhosttyTerminalFrame?,
    isFocused: Bool
  ) -> NSAttributedString {
    guard isFocused, let cursorFrame, cursorFrame.cursorVisible else {
      return attributed
    }
    let mutable = NSMutableAttributedString(attributedString: attributed)
    let placement = textPlacementForCursor(frame: cursorFrame, text: mutable.string as NSString)
    ensureCursorPlacement(placement, in: mutable)
    guard mutable.length > 0 else { return mutable }
    let safeIndex = min(placement.index, mutable.length - 1)
    mutable.addAttributes(
      [
        .font: terminalFont(weight: .regular),
        .proGhosttyCursorShape: cursorFrame.cursorShape,
        .proGhosttyCursorColor: palette.cursorBackground,
      ],
      range: NSRange(location: safeIndex, length: 1)
    )
    return mutable
  }

  private func ensureCursorPlacement(_ placement: CursorTextPlacement, in attributed: NSMutableAttributedString) {
    guard placement.index >= attributed.length else { return }
    let missing = placement.index - attributed.length + 1
    let filler = placement.filler.isEmpty
      ? String(repeating: " ", count: missing)
      : placement.filler + String(repeating: " ", count: max(0, missing - (placement.filler as NSString).length))
    attributed.append(NSAttributedString(string: filler, attributes: [
      .font: terminalFont(weight: .regular),
      .foregroundColor: palette.foreground,
      .backgroundColor: palette.background,
    ]))
  }

  private func textPlacementForCursor(frame: GhosttyTerminalFrame, text: NSString) -> CursorTextPlacement {
    let lineStarts = lineStartOffsets(in: text)
    guard !lineStarts.isEmpty else {
      let cursorX = max(0, frame.cursorX)
      return CursorTextPlacement(index: cursorX, filler: String(repeating: " ", count: cursorX + 1))
    }
    let cursorRow = max(0, frame.cursorY)
    let renderedTailRow = lastRenderedViewportRow(in: frame, fallback: cursorRow)
    let rowDeltaFromTail = renderedTailRow - cursorRow
    if rowDeltaFromTail < 0 {
      let missingRows = -rowDeltaFromTail
      let cursorX = max(0, frame.cursorX)
      let filler = String(repeating: "\n", count: missingRows) + String(repeating: " ", count: cursorX + 1)
      return CursorTextPlacement(index: text.length + missingRows + cursorX, filler: filler)
    }

    let targetLine = max(0, lineStarts.count - 1 - rowDeltaFromTail)
    let lineStart = lineStarts[targetLine]
    let lineEndRange = NSRange(location: lineStart, length: max(0, text.length - lineStart))
    let newline = text.range(of: "\n", options: [], range: lineEndRange)
    let lineEnd = newline.location == NSNotFound ? text.length : newline.location
    let desiredIndex = lineStart + max(0, frame.cursorX)
    let canExtendLineAtDocumentEnd = lineEnd == text.length
    let index = canExtendLineAtDocumentEnd ? desiredIndex : min(desiredIndex, lineEnd)
    return CursorTextPlacement(index: index, filler: "")
  }

  private func lastRenderedViewportRow(in frame: GhosttyTerminalFrame, fallback: Int) -> Int {
    var lastRenderedRow: Int?
    for row in 0..<max(0, frame.rows) {
      let rowStart = row * frame.cols
      let rowEnd = min(rowStart + frame.cols, frame.cells.count)
      guard rowStart < rowEnd else { continue }
      if frame.cells[rowStart..<rowEnd].contains(where: isRenderedCell) {
        lastRenderedRow = row
      }
    }
    return lastRenderedRow ?? fallback
  }

  private func isRenderedCell(_ cell: GhosttyTerminalFrame.Cell) -> Bool {
    cell.scalar != " " || !cell.usesDefaultBackground
  }

  private func lineStartOffsets(in text: NSString) -> [Int] {
    var starts = [0]
    var searchLocation = 0
    while searchLocation < text.length {
      let searchRange = NSRange(location: searchLocation, length: text.length - searchLocation)
      let newline = text.range(of: "\n", options: [], range: searchRange)
      guard newline.location != NSNotFound else { break }
      let nextStart = newline.location + 1
      if nextStart <= text.length {
        starts.append(nextStart)
      }
      searchLocation = nextStart
    }
    return starts
  }

  private func terminalFont(weight: NSFont.Weight) -> NSFont {
    if let named = NSFont(name: fontFamily, size: fontSize) {
      if weight == .semibold {
        return NSFontManager.shared.convert(named, toHaveTrait: .boldFontMask)
      }
      return named
    }
    return NSFont.monospacedSystemFont(ofSize: fontSize, weight: weight)
  }

  private func normalizedFontFamily(_ family: String?) -> String? {
    guard let trimmed = family?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
      return nil
    }
    return trimmed
  }

  private static func hexString(for color: NSColor) -> String {
    let rgb = color.usingColorSpace(.deviceRGB) ?? color
    return String(
      format: "#%02X%02X%02X",
      Int(round(rgb.redComponent * 255)),
      Int(round(rgb.greenComponent * 255)),
      Int(round(rgb.blueComponent * 255))
    )
  }
}

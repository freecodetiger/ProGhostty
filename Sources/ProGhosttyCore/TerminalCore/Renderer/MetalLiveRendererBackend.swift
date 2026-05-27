import AppKit
import Foundation
import ImageIO
import Metal
import MetalKit

public struct MetalLiveRenderPlan: Equatable, Sendable {
  public let renderFrame: TerminalRenderFrame
  public let presentation: TerminalRenderFramePresentation
  public let rows: Int
  public let cols: Int
  public let overscanTopRows: Int
  public let overscanBottomRows: Int
  public let isFocused: Bool

  public init(
    renderFrame: TerminalRenderFrame,
    presentation: TerminalRenderFramePresentation,
    rows: Int,
    cols: Int,
    overscanTopRows: Int,
    overscanBottomRows: Int,
    isFocused: Bool
  ) {
    self.renderFrame = renderFrame
    self.presentation = presentation
    self.rows = rows
    self.cols = cols
    self.overscanTopRows = overscanTopRows
    self.overscanBottomRows = overscanBottomRows
    self.isFocused = isFocused
  }
}

public enum MetalLiveFrameEncoder {
  public static func encode(_ renderFrame: TerminalRenderFrame) -> MetalLiveRenderPlan {
    let sourceFrame = renderFrame.frame
    let overscanTopRows = renderFrame.scrollFrame?.overscanTop.count ?? 0
    let overscanBottomRows = renderFrame.scrollFrame?.overscanBottom.count ?? 0
    return MetalLiveRenderPlan(
      renderFrame: renderFrame,
      presentation: renderFrame.presentation,
      rows: sourceFrame.rows + overscanTopRows + overscanBottomRows,
      cols: sourceFrame.cols,
      overscanTopRows: overscanTopRows,
      overscanBottomRows: overscanBottomRows,
      isFocused: renderFrame.isFocused
    )
  }
}

@MainActor
public final class MetalLiveRendererView: PTYGridView {
  private let captureRenderer: GhosttyVTCellGridRendererBackend
  private let device: MTLDevice?
  private let commandQueue: MTLCommandQueue?
  private let textureLoader: MTKTextureLoader?
  private var pendingBitmap: NSBitmapImageRep?

  public init(
    captureRenderer: GhosttyVTCellGridRendererBackend,
    options: TerminalRendererOptions = TerminalRendererOptions()
  ) {
    self.captureRenderer = captureRenderer
    device = MTLCreateSystemDefaultDevice()
    commandQueue = device?.makeCommandQueue()
    textureLoader = device.map(MTKTextureLoader.init(device:))
    super.init(frame: .zero)
    wantsLayer = true
    layer = makeBackingLayer()
    captureRenderer.gridView.frame = bounds
    applyRendererOptions(options)
  }

  @available(*, unavailable)
  public required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  public override func makeBackingLayer() -> CALayer {
    let layer = CAMetalLayer()
    layer.device = device
    layer.pixelFormat = .bgra8Unorm
    layer.framebufferOnly = false
    layer.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
    return layer
  }

  public override func layout() {
    super.layout()
    captureRenderer.gridView.frame = bounds
    captureRenderer.gridView.bounds = bounds
    if let metalLayer = layer as? CAMetalLayer {
      metalLayer.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
    }
    flushPendingFrame()
  }

  public override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if let metalLayer = layer as? CAMetalLayer {
      metalLayer.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
    }
    flushPendingFrame()
  }

  public override func draw(_ dirtyRect: NSRect) {}

  public override func applyPalette(_ palette: TerminalSurfacePalette) {
    super.applyPalette(palette)
    captureRenderer.applyPalette(palette)
  }

  public override func applyFont(family: String, size: CGFloat) {
    super.applyFont(family: family, size: size)
    captureRenderer.applyFont(family: family, size: size)
    captureRenderer.gridView.frame = bounds
  }

  public override func applyRendererOptions(_ options: TerminalRendererOptions) {
    super.applyRendererOptions(options)
    captureRenderer.applyOptions(options)
  }

  public override func setFocused(_ isFocused: Bool) {
    super.setFocused(isFocused)
    captureRenderer.setFocused(isFocused)
  }

  public override func resetViewportStartRowKeepingVisualOffset() {
    super.resetViewportStartRowKeepingVisualOffset()
    captureRenderer.resetViewportStartRowKeepingVisualOffset()
  }

  public override func resetPixelScroll(suppressMomentum: Bool = false) {
    super.resetPixelScroll(suppressMomentum: suppressMomentum)
    captureRenderer.resetPixelScroll(suppressMomentum: suppressMomentum)
  }

  public func enqueue(_ renderFrame: TerminalRenderFrame) {
    if let scrollFrame = renderFrame.scrollFrame {
      super.render(
        scrollFrame,
        isFocused: renderFrame.isFocused,
        dirty: CellGridDirtyResult(
          mode: .full,
          rows: Set(0..<max(0, scrollFrame.viewport.rows))
        )
      )
    } else {
      super.render(renderFrame.frame, isFocused: renderFrame.isFocused)
    }
    captureRenderer.render(renderFrame)
    captureRenderer.flushPendingFrame()
    pendingBitmap = snapshotBitmap()
  }

  public func flushPendingFrame() {
    guard let bitmap = pendingBitmap else { return }
    pendingBitmap = nil
    present(bitmap: bitmap)
  }

  private func snapshotBitmap() -> NSBitmapImageRep? {
    let rendererView = captureRenderer.gridView
    guard bounds.width > 0, bounds.height > 0 else { return nil }
    rendererView.frame = bounds
    rendererView.bounds = bounds
    guard let bitmap = rendererView.bitmapImageRepForCachingDisplay(in: rendererView.bounds) else {
      return nil
    }
    rendererView.cacheDisplay(in: rendererView.bounds, to: bitmap)
    return bitmap
  }

  private func present(bitmap: NSBitmapImageRep) {
    guard
      let _ = device,
      let commandQueue,
      let textureLoader,
      let metalLayer = layer as? CAMetalLayer,
      let data = bitmap.representation(using: .png, properties: [:]) as Data?,
      let source = CGImageSourceCreateWithData(data as CFData, nil),
      let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else {
      pendingBitmap = bitmap
      return
    }

    let options: [MTKTextureLoader.Option: Any] = [.SRGB: false]
    guard let sourceTexture = try? textureLoader.newTexture(cgImage: cgImage, options: options) else {
      pendingBitmap = bitmap
      return
    }

    metalLayer.drawableSize = CGSize(width: sourceTexture.width, height: sourceTexture.height)
    guard let drawable = metalLayer.nextDrawable() else {
      pendingBitmap = bitmap
      return
    }

    guard let commandBuffer = commandQueue.makeCommandBuffer() else {
      pendingBitmap = bitmap
      return
    }
    guard let blitEncoder = commandBuffer.makeBlitCommandEncoder() else {
      pendingBitmap = bitmap
      return
    }

    let size = MTLSize(width: sourceTexture.width, height: sourceTexture.height, depth: 1)
    blitEncoder.copy(
      from: sourceTexture,
      sourceSlice: 0,
      sourceLevel: 0,
      sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
      sourceSize: size,
      to: drawable.texture,
      destinationSlice: 0,
      destinationLevel: 0,
      destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
    )
    blitEncoder.endEncoding()
    commandBuffer.present(drawable)
    commandBuffer.commit()
  }
}

@MainActor
public final class MetalLiveRendererBackend: TerminalLiveRendererBackend {
  public static var isRuntimeAvailable: Bool {
    MTLCreateSystemDefaultDevice() != nil
  }

  public let metalView: MetalLiveRendererView
  private let captureRenderer: GhosttyVTCellGridRendererBackend
  private var options: TerminalRendererOptions
  private var diagnosticsState = TerminalRendererDiagnostics(backend: .metalLive)
  private var pendingFrame = false
  private var flushScheduled = false

  public init(options: TerminalRendererOptions = TerminalRendererOptions()) {
    self.options = options
    captureRenderer = GhosttyVTCellGridRendererBackend(options: options)
    metalView = MetalLiveRendererView(captureRenderer: captureRenderer, options: options)
    Self.applyBackendSelectionDiagnostics(options: options, to: &diagnosticsState)
  }

  public var gridView: PTYGridView { metalView }
  public var view: NSView { metalView }
  public var selectedText: String? { metalView.selectedText }

  public var diagnostics: TerminalRendererDiagnostics {
    var state = captureRenderer.diagnostics
    state.backend = .metalLive
    state.requestedBackend = diagnosticsState.requestedBackend
    state.backendFallbackReason = diagnosticsState.backendFallbackReason
    state.usesBitmapCapture = true
    state.coalescedFrames = diagnosticsState.coalescedFrames
    state.droppedFrames = diagnosticsState.droppedFrames
    metalView.applyScrollDiagnostics(to: &state)
    return state
  }

  public func setInputHandler(_ handler: ((Data) -> Void)?) {
    metalView.inputHandler = handler
  }

  public func setActivationHandler(_ handler: (() -> Void)?) {
    metalView.activationHandler = handler
  }

  public func applyPalette(_ palette: TerminalSurfacePalette) {
    metalView.applyPalette(palette)
  }

  public func applyFont(family: String, size: CGFloat) {
    metalView.applyFont(family: family, size: size)
  }

  public func applyOptions(_ options: TerminalRendererOptions) {
    self.options = options
    Self.applyBackendSelectionDiagnostics(options: options, to: &diagnosticsState)
    metalView.applyRendererOptions(options)
  }

  public func setFocused(_ isFocused: Bool) {
    metalView.setFocused(isFocused)
  }

  public func render(frame: GhosttyTerminalFrame) {
    render(TerminalRenderFrame(frame: frame, isFocused: gridView.isFocusedTerminal))
  }

  public func render(scrollFrame: GhosttyTerminalScrollFrame) {
    render(TerminalRenderFrame(scrollFrame: scrollFrame, isFocused: gridView.isFocusedTerminal))
  }

  public func render(_ renderFrame: TerminalRenderFrame) {
    if pendingFrame {
      diagnosticsState.coalescedFrames += 1
      diagnosticsState.droppedFrames += 1
    }
    pendingFrame = true
    metalView.enqueue(renderFrame)
    scheduleFlush()
  }

  public func flushPendingFrame() {
    flushScheduled = false
    guard pendingFrame else {
      metalView.flushPendingFrame()
      return
    }
    pendingFrame = false
    metalView.flushPendingFrame()
  }

  private func scheduleFlush() {
    guard !flushScheduled else { return }
    flushScheduled = true
    DispatchQueue.main.async { [weak self] in
      Task { @MainActor in
        self?.flushPendingFrame()
      }
    }
  }

  public func updateOverscanDiagnostics(topRows: Int, bottomRows: Int) {
    captureRenderer.updateOverscanDiagnostics(topRows: topRows, bottomRows: bottomRows)
  }

  public func markResizePending() {
    captureRenderer.markResizePending()
  }

  public func applyResizeDiagnostics(_ diagnostics: TerminalResizeDiagnostics) {
    captureRenderer.applyResizeDiagnostics(diagnostics)
  }

  public func resetViewportStartRowKeepingVisualOffset() {
    metalView.resetViewportStartRowKeepingVisualOffset()
    captureRenderer.resetViewportStartRowKeepingVisualOffset()
  }

  public func resetPixelScroll(suppressMomentum: Bool = false) {
    metalView.resetPixelScroll(suppressMomentum: suppressMomentum)
    captureRenderer.resetPixelScroll(suppressMomentum: suppressMomentum)
  }

  public func focus() {
    metalView.window?.makeFirstResponder(metalView)
  }

  private static func applyBackendSelectionDiagnostics(
    options: TerminalRendererOptions,
    to diagnostics: inout TerminalRendererDiagnostics
  ) {
    let selection = TerminalRendererBackendSelection.resolve(
      mode: options.mode,
      hasFrame: true,
      isMetalLiveAvailable: true
    )
    diagnostics.backend = .metalLive
    diagnostics.requestedBackend = selection.requestedBackend
    diagnostics.backendFallbackReason = selection.fallbackReason
  }
}

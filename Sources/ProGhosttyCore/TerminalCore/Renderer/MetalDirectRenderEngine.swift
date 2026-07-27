import AppKit
import Foundation
import Metal
import MetalKit

@MainActor
protocol MetalDirectRenderingEngine: AnyObject {
  var drawPassCount: Int { get }
  var presentedFrameCount: Int { get }
  var latestSubmittedGeneration: Int { get }
  var latestPresentedGeneration: Int { get }
  var pipelineReady: Bool { get }
  /// While true (active scrolling), the engine never blocks the main thread on
  /// commandBuffer.waitUntilCompleted — it uses the async completion handler so
  /// the display-link tick stays under its frame budget. Set false when idle so
  /// normal typing keeps its low-latency synchronous present.
  var prefersAsyncPresent: Bool { get set }
  var lastRenderedRowCount: Int { get }
  var lastRenderedCellCount: Int { get }
  var lastRenderedRunCount: Int { get }
  var lastRenderPassLoadPolicy: MetalDirectRenderPassLoadPolicy { get }
  var lastWaitedForCompletion: Bool { get }
  var lastGPUWaitReason: String { get }
  var lastGlyphTextureHitCount: Int { get }
  var lastGlyphTextureMissCount: Int { get }
  var staleCompletionCount: Int { get }

  func resetTextureCache()
  func render(
    renderFrame: TerminalRenderFrame,
    plan: MetalTerminalRenderPlan,
    view: MetalDirectRendererView,
    palette: TerminalSurfacePalette,
    glyphAtlas: MetalGlyphAtlas
  ) -> Bool
  /// Clear the drawable to terminal background at the view's current bounds.
  /// Used when pane height changes so a stale topLeft-letterboxed frame cannot
  /// look like content jumped before the reflow present lands.
  func clearToBackground(
    view: MetalDirectRendererView,
    palette: TerminalSurfacePalette
  ) -> Bool
}

enum MetalDirectRenderPassLoadPolicy: Equatable {
  case clear
  case load
}

struct MetalDirectFrameCompletionTracker: Equatable {
  private(set) var latestSubmittedGeneration = 0
  private(set) var completedGeneration = 0
  private(set) var presentedFrameCount = 0
  private(set) var staleCompletionCount = 0

  mutating func submit(_ generation: Int) -> Int {
    latestSubmittedGeneration = generation
    return generation
  }

  mutating func complete(_ generation: Int) -> Bool {
    guard generation == latestSubmittedGeneration else {
      staleCompletionCount += 1
      return false
    }
    completedGeneration = generation
    presentedFrameCount += 1
    return true
  }
}

struct MetalMarkedTextGlyphLayout: Equatable, Sendable {
  let scalar: String
  let rect: CGRect
}

struct MetalCursorGlyphLayout: Equatable, Sendable {
  let scalar: String
  let rect: CGRect
}

final class MetalDirectFrameCompletionBox: @unchecked Sendable {
  private let lock = NSLock()
  private var tracker = MetalDirectFrameCompletionTracker()

  var presentedFrameCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return tracker.presentedFrameCount
  }

  var latestSubmittedGeneration: Int {
    lock.lock()
    defer { lock.unlock() }
    return tracker.latestSubmittedGeneration
  }

  var latestPresentedGeneration: Int {
    lock.lock()
    defer { lock.unlock() }
    return tracker.completedGeneration
  }

  var staleCompletionCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return tracker.staleCompletionCount
  }

  func submit(_ generation: Int) -> Int {
    lock.lock()
    defer { lock.unlock() }
    return tracker.submit(generation)
  }

  @discardableResult
  func complete(_ generation: Int) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return tracker.complete(generation)
  }
}

private enum MetalDirectCommandCompletion {
  static func addHandler(
    to commandBuffer: MTLCommandBuffer,
    completionBox: MetalDirectFrameCompletionBox,
    generation: Int,
    retainedResources: [Any],
    onPresented: (@Sendable () -> Void)? = nil
  ) {
    commandBuffer.addCompletedHandler { [completionBox, retainedResources] _ in
      _ = retainedResources.count
      completionBox.complete(generation)
      onPresented?()
    }
  }
}

@MainActor
final class MetalDirectRenderEngine: MetalDirectRenderingEngine {
  private struct Vertex {
    var position: SIMD2<Float>
    var color: SIMD4<Float>
    var texCoord: SIMD2<Float>
    var weightBoost: Float = 0
  }

  /// Vertex for the feathered Semantic Halo SDF pass. `localPos` is the fragment
  /// position relative to the halo's center (pixels); the fragment shader uses it
  /// against a rounded-rect signed distance field to produce a soft falloff.
  private struct HaloVertex {
    var position: SIMD2<Float>
    var color: SIMD4<Float>
    var localPos: SIMD2<Float>
    var halfSize: SIMD2<Float>
    var cornerRadius: Float
    var feather: Float
    var ringWidth: Float
  }

  private struct Uniforms {
    var drawableSize: SIMD2<Float>
  }

  private final class CachedTexture {
    let generation: Int
    let texture: MTLTexture

    init(generation: Int, texture: MTLTexture) {
      self.generation = generation
      self.texture = texture
    }
  }

  private let device: MTLDevice
  private let commandQueue: MTLCommandQueue
  var prefersAsyncPresent: Bool = false
  /// Back-pressure for the async present path. CAMetalLayer's drawable pool is
  /// finite (default 3); without a gate the display-link tick keeps calling
  /// nextDrawable() faster than the compositor drains it, presents pile up, and
  /// the visible frame lags far behind (freeze-then-catch-up). Limiting
  /// in-flight presented drawables paces producer to consumer. Exactly one
  /// signal per successful acquire, in the completion handler / after wait.
  private static let maxInFlightDrawables = 2
  private let inFlightSemaphore = DispatchSemaphore(value: maxInFlightDrawables)
  private let textureLoader: MTKTextureLoader
  private let backgroundPipeline: MTLRenderPipelineState
  private let glyphPipeline: MTLRenderPipelineState
  private let haloPipeline: MTLRenderPipelineState
  private var cachedTextures: [Int: CachedTexture] = [:]
  private let completionBox = MetalDirectFrameCompletionBox()
  private var previousTransientOverlayRevision = 0

  private(set) var drawPassCount = 0
  private(set) var pipelineReady = false
  private(set) var lastRenderedRowCount = 0
  private(set) var lastRenderedCellCount = 0
  private(set) var lastRenderedRunCount = 0
  private(set) var lastRenderPassLoadPolicy = MetalDirectRenderPassLoadPolicy.clear
  private(set) var lastWaitedForCompletion = false
  private(set) var lastGPUWaitReason = "none"
  private(set) var lastGlyphTextureHitCount = 0
  private(set) var lastGlyphTextureMissCount = 0
  var presentedFrameCount: Int { completionBox.presentedFrameCount }
  var latestSubmittedGeneration: Int { completionBox.latestSubmittedGeneration }
  var latestPresentedGeneration: Int { completionBox.latestPresentedGeneration }
  var staleCompletionCount: Int { completionBox.staleCompletionCount }

  init(device: MTLDevice) throws {
    self.device = device
    guard let commandQueue = device.makeCommandQueue() else {
      throw NSError(domain: "MetalDirectRenderEngine", code: 1, userInfo: [NSLocalizedDescriptionKey: "command queue unavailable"])
    }
    self.commandQueue = commandQueue
    textureLoader = MTKTextureLoader(device: device)

    let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
    let backgroundPipeline = try Self.makePipeline(
      device: device,
      library: library,
      vertexFunctionName: "metal_direct_vertex",
      fragmentFunctionName: "metal_direct_background_fragment"
    )
    let glyphPipeline = try Self.makePipeline(
      device: device,
      library: library,
      vertexFunctionName: "metal_direct_vertex",
      fragmentFunctionName: "metal_direct_glyph_fragment"
    )
    let haloPipeline = try Self.makePipeline(
      device: device,
      library: library,
      vertexFunctionName: "metal_direct_halo_vertex",
      fragmentFunctionName: "metal_direct_halo_fragment"
    )
    self.backgroundPipeline = backgroundPipeline
    self.glyphPipeline = glyphPipeline
    self.haloPipeline = haloPipeline
    pipelineReady = true
  }

  func resetTextureCache() {
    cachedTextures.removeAll(keepingCapacity: true)
  }

  func clearToBackground(
    view: MetalDirectRendererView,
    palette: TerminalSurfacePalette
  ) -> Bool {
    guard pipelineReady else { return false }
    let scale = view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
    let drawableSize = Self.drawableTargetSize(forViewBounds: view.bounds.size, backingScale: scale)
    guard let metalLayer = view.layer as? CAMetalLayer else { return false }

    metalLayer.contentsScale = scale
    metalLayer.drawableSize = drawableSize
    // Always synchronous: height-change clears are rare, and a Metal completion
    // handler must not hop onto @MainActor isolation (EXC_BREAKPOINT /
    // dispatch_assert_queue when the completion queue is not main — hit while
    // closing a split re-lays out the remaining pane height).
    inFlightSemaphore.wait()
    guard let drawable = metalLayer.nextDrawable(),
      let commandBuffer = commandQueue.makeCommandBuffer()
    else {
      inFlightSemaphore.signal()
      return false
    }

    let passDescriptor = MTLRenderPassDescriptor()
    passDescriptor.colorAttachments[0].texture = drawable.texture
    passDescriptor.colorAttachments[0].loadAction = .clear
    passDescriptor.colorAttachments[0].storeAction = .store
    passDescriptor.colorAttachments[0].clearColor = MTLClearColor(
      red: Double(palette.background.metalRed),
      green: Double(palette.background.metalGreen),
      blue: Double(palette.background.metalBlue),
      alpha: 1
    )
    if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) {
      encoder.endEncoding()
    }
    commandBuffer.present(drawable)
    commandBuffer.commit()
    commandBuffer.waitUntilCompleted()
    inFlightSemaphore.signal()
    lastRenderPassLoadPolicy = .clear
    lastWaitedForCompletion = true
    lastGPUWaitReason = "clear-background-sync"
    return true
  }

  func render(
    renderFrame: TerminalRenderFrame,
    plan: MetalTerminalRenderPlan,
    view: MetalDirectRendererView,
    palette: TerminalSurfacePalette,
    glyphAtlas: MetalGlyphAtlas
  ) -> Bool {
    guard pipelineReady else { return false }
    lastGlyphTextureHitCount = 0
    lastGlyphTextureMissCount = 0

    let drawFrame = renderFrame.expandedFrame
    let pixelScale = plan.backingScale
    let cellSize = CGSize(
      width: plan.cellSize.width * pixelScale,
      height: plan.cellSize.height * pixelScale
    )
    let inset = CGSize(
      width: view.terminalContentInset.width * pixelScale,
      height: view.terminalContentInset.height * pixelScale
    )
    let overscanTopRows = renderFrame.scrollFrame?.overscanTop.count ?? 0
    // Pattern 2: draw the expanded grid DIRECTLY to the drawable, shifted by a
    // single translation — no offscreen texture, no composite pass. This is
    // exactly equivalent to the old "render into offscreen at translation 0,
    // then composite the offscreen shifted by presentationTranslationY": row r
    // lands at y = inset + r*cellHeight + translationY either way. Because a
    // CAMetalLayer drawable does not retain content across frames, the whole
    // visible grid is redrawn every frame (cheap on the GPU; ~0.2ms), which also
    // makes scrolling — where every row shifts by a sub-row remainder — trivial.
    let translationY = (-CGFloat(overscanTopRows) * plan.cellSize.height + plan.pixelRemainderY) * pixelScale
    let drawableSize = Self.drawableTargetSize(
      forViewBounds: view.bounds.size,
      backingScale: pixelScale
    )
    let cursorOverlay = view.currentCursorOverlay
    let markedTextOverlay = view.currentMarkedTextOverlay
    let markedTextString = view.currentMarkedTextString
    if PTYRenderDebugLog.isEnabled {
      PTYRenderDebugLog.write(
        "metalDirectEngine gen=\(renderFrame.generation) presentation=\(renderFrame.presentation) frameCursor=(\(renderFrame.frame.cursorX),\(renderFrame.frame.cursorY)) overscanTop=\(renderFrame.scrollFrame?.overscanTop.count ?? 0) cursorOverlay=\(Self.debugDescription(for: cursorOverlay)) markedOverlay=\(Self.debugDescription(for: markedTextOverlay)) markedActive=\(view.isComposingMarkedText) markedString=\(markedTextString.map { "\"\(Self.debugLogText($0))\"" } ?? "nil")"
      )
    }

    // Pattern 2 redraws the ENTIRE visible grid every frame in a single pass:
    // the CAMetalLayer drawable does not retain content across frames, and a
    // sub-row scroll shifts every row, so partial/dirty redraw is neither
    // possible nor useful here. One coordinate space (the drawable), one
    // translation, all cells.
    let renderCellRanges = Self.fullCellRanges(rows: drawFrame.rows, cols: plan.cols)
    let shouldRenderScene = drawFrame.rows > 0 && plan.cols > 0

    let backgroundVertices = buildBackgroundVertices(
      frame: drawFrame,
      cellRanges: renderCellRanges,
      palette: palette,
      isFocused: renderFrame.isFocused,
      cellSize: cellSize,
      inset: inset,
      translationY: translationY
    )
    // A single overlay set drawn to the drawable at the viewport translation.
    // (Pattern 1 split these across an offscreen scene pass + a drawable pass;
    // with direct-draw there is only the drawable, so cursor + selection + link +
    // marked-text all share one translation, matching the old composited result.)
    // Selection/link ranges from PTYGridView are already in expanded-frame
    // row space (renderedGeometry). Do NOT add overscanTop again — that was
    // the pattern-1 viewport-row contract and double-shifted highlights by
    // overscanTop rows (1-row browse miss / ~24-row live miss). Marked-text /
    // cursor overlays stay viewport-relative and still need markedTextRowsOffset.
    let overlays = MetalOverlayBuffer.makeOverlays(
      renderFrame: renderFrame,
      plan: plan,
      palette: palette,
      markedTextActive: view.isComposingMarkedText,
      selectedRows: view.currentSelectionRowSet,
      selectedCellRanges: view.currentSelectionCellRanges,
      selectionRowsOffset: 0,
      linkHoverRows: [],
      linkHoverCellRanges: view.currentLinkHoverCellRanges,
      linkHoverIntensity: view.currentLinkHoverIntensity,
      cursorOverlay: cursorOverlay,
      markedTextOverlay: markedTextOverlay,
      imeCompositionCursorOverlay: view.currentIMECompositionCursorOverlay,
      markedTextRowsOffset: overscanTopRows,
      translationYOverride: translationY
    )
    // Semantic halo is drawn by its own SDF pipeline, beneath glyphs; keep it out
    // of the flat-rect overlay vertex builders.
    let haloOverlays = overlays.filter { $0.kind == .semanticHalo }
    let flatOverlays = overlays.filter { $0.kind != .semanticHalo }
    let haloVertices = buildHaloVertices(overlays: haloOverlays)
    // The ring cursor is no longer drawn in the Metal pass — it is an independent
    // CALayer composited by Core Animation above this content (see PTYGridView
    // `ringCursorLayer`), so it never enters this full-rebuild present path.
    let overlayBelowVertices = buildOverlayVertices(
      overlays: flatOverlays.filter { $0.phase == .beneathGlyphs }
    )
    // Dwell reveal (spec §4): the awoken semantic object's glyphs gain weight in
    // place (faux-weight alpha dilation in the shader). No float, no halo, no
    // color change. `currentLinkHoverIntensity` is the 0…1 tween of the boost.
    let linkWeightBoost = view.currentLinkHoverIntensity
    let linkLitColumnsByRow: [Int: Set<Int>] = linkWeightBoost > 0.001
      ? Dictionary(
          grouping: view.currentLinkHoverCellRanges.flatMap { range in
            range.cols.map { (range.row, $0) }
          },
          by: { $0.0 }
        ).mapValues { Set($0.map { $0.1 }) }
      : [:]
    let glyphVertices = buildGlyphVertices(
      frame: drawFrame,
      cellRanges: renderCellRanges,
      palette: palette,
      isFocused: renderFrame.isFocused,
      glyphAtlas: glyphAtlas,
      cellSize: cellSize,
      inset: inset,
      translationY: translationY,
      cursorRow: renderFrame.scrollFrame.map { $0.overscanTop.count + $0.viewport.cursorY } ?? renderFrame.frame.cursorY,
      cursorCol: renderFrame.frame.cursorX,
      cursorVisible: renderFrame.frame.cursorVisible,
      cursorShape: renderFrame.frame.cursorShape,
      linkLitColumnsByRow: linkLitColumnsByRow,
      linkWeightBoost: linkWeightBoost
    )
    let overlayAboveVertices = buildOverlayVertices(
      overlays: flatOverlays.filter { $0.phase == .aboveGlyphs }
    )
    let markedTextGlyphLayout = Self.markedTextGlyphLayout(
      text: markedTextString ?? "",
      overlay: markedTextOverlay,
      renderFrame: renderFrame,
      plan: plan,
      contentInset: view.terminalContentInset
    )
    let markedTextGlyphDraw = buildMarkedTextGlyphDraw(
      layout: markedTextGlyphLayout,
      palette: palette,
      isFocused: renderFrame.isFocused,
      glyphAtlas: glyphAtlas
    )
    let cursorGlyphDraw = buildCursorGlyphDraw(
      layout: Self.cursorGlyphLayout(
        renderFrame: renderFrame,
        plan: plan,
        contentInset: view.terminalContentInset,
        markedTextActive: view.isComposingMarkedText,
        cursorOverlay: cursorOverlay
      ),
      palette: palette,
      glyphAtlas: glyphAtlas
    )
    // Trailing ↗ Action Hint (spec §5): a small arrow one cell past the hovered
    // URL, faded by proximity. Reuses the single-glyph draw path.
    let actionHintDraw = buildActionHintGlyphDraw(
      hint: view.currentActionHint,
      palette: palette,
      glyphAtlas: glyphAtlas,
      cellSize: cellSize,
      inset: inset,
      translationY: translationY
    )
    // Typing / idle presents synchronously for lowest latency; active scrolling
    // (prefersAsyncPresent) presents async with semaphore back-pressure so the
    // display-link tick never blocks the main thread on GPU completion.
    let shouldWait = !prefersAsyncPresent
    let waitReason = prefersAsyncPresent ? "async-scroll" : "sync-present"
    let glyphSlices = glyphTextureSlices(for: drawFrame, cellRanges: renderCellRanges, glyphAtlas: glyphAtlas)

    guard
      let backgroundBuffer = makeBuffer(vertices: backgroundVertices),
      let overlayBelowBuffer = makeBuffer(vertices: overlayBelowVertices),
      let haloBuffer = makeBuffer(haloVertices: haloVertices),
      let glyphBuffer = makeBuffer(vertices: glyphVertices),
      let overlayAboveBuffer = makeBuffer(vertices: overlayAboveVertices),
      let markedTextGlyphBuffer = makeBuffer(vertices: markedTextGlyphDraw.vertices),
      let cursorGlyphBuffer = makeBuffer(vertices: cursorGlyphDraw.vertices),
      let actionHintGlyphBuffer = makeBuffer(vertices: actionHintDraw.vertices)
    else {
      return false
    }

    guard let commandBuffer = commandQueue.makeCommandBuffer() else {
      return false
    }

    var retainedResources: [Any] = [
      backgroundBuffer,
      overlayBelowBuffer,
      haloBuffer,
      glyphBuffer,
      overlayAboveBuffer,
      markedTextGlyphBuffer,
      cursorGlyphBuffer,
      actionHintGlyphBuffer,
      backgroundPipeline,
      glyphPipeline,
      haloPipeline,
    ]
    retainedResources.append(contentsOf: glyphSlices.map(\.texture))
    retainedResources.append(contentsOf: markedTextGlyphDraw.slices.map(\.texture))
    retainedResources.append(contentsOf: cursorGlyphDraw.slices.map(\.texture))
    retainedResources.append(contentsOf: actionHintDraw.slices.map(\.texture))

    var presentedDrawable = false
    if let metalLayer = view.layer as? CAMetalLayer {
      retainedResources.append(metalLayer)
      // Keep contentsScale in sync with the backing scale used to compute
      // drawableSize. After sleep/wake the layer's cached scale may be stale
      // while the drawable is sized for the live backing-scale factor, causing
      // the content to appear stretched or blurry.
      metalLayer.contentsScale = pixelScale
      metalLayer.drawableSize = drawableSize
      // Gate on the in-flight pool BEFORE acquiring a drawable so this tick can't
      // outrun the compositor. Released once per acquire below / in completion.
      // During scroll we must NOT block the main thread if the GPU is behind —
      // drop this frame instead of freezing input/cursor updates.
      if prefersAsyncPresent {
        if inFlightSemaphore.wait(timeout: .now()) == .timedOut {
          return false
        }
      } else {
        inFlightSemaphore.wait()
      }
      let drawable = metalLayer.nextDrawable()
      if let drawable {
        presentedDrawable = true
        retainedResources.append(drawable)
        // Pattern 2: one render pass, straight to the drawable. Clear to the
        // background color, then draw the whole shifted grid in z-order:
        // background quads → beneath-glyph overlays (block cursor) → glyphs →
        // above-glyph overlays (selection / link / bar+underline cursor) →
        // marked-text glyphs → block-cursor glyph.
        let passDescriptor = MTLRenderPassDescriptor()
        passDescriptor.colorAttachments[0].texture = drawable.texture
        passDescriptor.colorAttachments[0].loadAction = .clear
        passDescriptor.colorAttachments[0].storeAction = .store
        passDescriptor.colorAttachments[0].clearColor = MTLClearColor(
          red: Double(palette.background.metalRed),
          green: Double(palette.background.metalGreen),
          blue: Double(palette.background.metalBlue),
          alpha: 1
        )
        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) {
          var uniforms = Uniforms(drawableSize: SIMD2(Float(drawableSize.width), Float(drawableSize.height)))
          func setUniforms() {
            withUnsafeBytes(of: &uniforms) { bytes in
              encoder.setVertexBytes(bytes.baseAddress!, length: bytes.count, index: 1)
            }
          }

          encoder.setRenderPipelineState(backgroundPipeline)
          encoder.setVertexBuffer(backgroundBuffer, offset: 0, index: 0)
          setUniforms()
          encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: backgroundVertices.count)

          if !overlayBelowVertices.isEmpty {
            encoder.setVertexBuffer(overlayBelowBuffer, offset: 0, index: 0)
            setUniforms()
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: overlayBelowVertices.count)
          }

          // Feathered Semantic Halo: beneath glyphs so text stays crisp on top.
          if !haloVertices.isEmpty {
            encoder.setRenderPipelineState(haloPipeline)
            encoder.setVertexBuffer(haloBuffer, offset: 0, index: 0)
            setUniforms()
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: haloVertices.count)
          }

          if !glyphVertices.isEmpty {
            encoder.setRenderPipelineState(glyphPipeline)
            encoder.setVertexBuffer(glyphBuffer, offset: 0, index: 0)
            setUniforms()
            for textureSlice in glyphSlices {
              encoder.setFragmentTexture(textureSlice.texture, index: 0)
              encoder.drawPrimitives(type: .triangle, vertexStart: textureSlice.vertexStart, vertexCount: textureSlice.vertexCount)
            }
          }

          if !overlayAboveVertices.isEmpty {
            encoder.setRenderPipelineState(backgroundPipeline)
            encoder.setVertexBuffer(overlayAboveBuffer, offset: 0, index: 0)
            setUniforms()
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: overlayAboveVertices.count)
          }

          if !markedTextGlyphDraw.vertices.isEmpty {
            encoder.setRenderPipelineState(glyphPipeline)
            encoder.setVertexBuffer(markedTextGlyphBuffer, offset: 0, index: 0)
            setUniforms()
            for textureSlice in markedTextGlyphDraw.slices {
              encoder.setFragmentTexture(textureSlice.texture, index: 0)
              encoder.drawPrimitives(type: .triangle, vertexStart: textureSlice.vertexStart, vertexCount: textureSlice.vertexCount)
            }
          }

          if !cursorGlyphDraw.vertices.isEmpty {
            encoder.setRenderPipelineState(glyphPipeline)
            encoder.setVertexBuffer(cursorGlyphBuffer, offset: 0, index: 0)
            setUniforms()
            for textureSlice in cursorGlyphDraw.slices {
              encoder.setFragmentTexture(textureSlice.texture, index: 0)
              encoder.drawPrimitives(type: .triangle, vertexStart: textureSlice.vertexStart, vertexCount: textureSlice.vertexCount)
            }
          }

          if !actionHintDraw.vertices.isEmpty {
            encoder.setRenderPipelineState(glyphPipeline)
            encoder.setVertexBuffer(actionHintGlyphBuffer, offset: 0, index: 0)
            setUniforms()
            for textureSlice in actionHintDraw.slices {
              encoder.setFragmentTexture(textureSlice.texture, index: 0)
              encoder.drawPrimitives(type: .triangle, vertexStart: textureSlice.vertexStart, vertexCount: textureSlice.vertexCount)
            }
          }

          encoder.endEncoding()
        }
        commandBuffer.present(drawable)
      } else {
        // No drawable acquired: release the slot we reserved.
        inFlightSemaphore.signal()
      }
    }

    previousTransientOverlayRevision = plan.transientOverlayRevision

    let generation = completionBox.submit(renderFrame.generation)
    if shouldWait {
      commandBuffer.commit()
      commandBuffer.waitUntilCompleted()
      completionBox.complete(generation)
      if presentedDrawable { inFlightSemaphore.signal() }
    } else {
      let semaphore = inFlightSemaphore
      var onPresented: (@Sendable () -> Void)?
      if presentedDrawable {
        onPresented = { _ = semaphore.signal() }
      }
      MetalDirectCommandCompletion.addHandler(
        to: commandBuffer,
        completionBox: completionBox,
        generation: generation,
        retainedResources: retainedResources,
        onPresented: onPresented
      )
      commandBuffer.commit()
    }

    lastRenderedRowCount = shouldRenderScene ? Set(renderCellRanges.map(\.row)).count : 0
    lastRenderedCellCount = shouldRenderScene ? renderCellRanges.reduce(0) { $0 + $1.cols.count } : 0
    lastRenderedRunCount = shouldRenderScene ? 1 : 0
    lastRenderPassLoadPolicy = .clear
    lastWaitedForCompletion = shouldWait
    lastGPUWaitReason = waitReason
    if shouldRenderScene {
      drawPassCount += 1
    }
    return true
  }

  func texture(for entry: MetalGlyphAtlasEntry, glyphAtlas: MetalGlyphAtlas) -> MTLTexture? {
    if let cached = cachedTextures[entry.id], cached.generation == entry.generation {
      lastGlyphTextureHitCount += 1
      return cached.texture
    }
    lastGlyphTextureMissCount += 1
    guard let image = glyphAtlas.renderedImage(for: entry.scalar, style: entry.style) else {
      return nil
    }
    let options = Self.glyphTextureLoaderOptions()
    guard let texture = try? textureLoader.newTexture(cgImage: image, options: options) else {
      return nil
    }
    cachedTextures[entry.id] = CachedTexture(generation: entry.generation, texture: texture)
    return texture
  }

  static func glyphTextureLoaderOptions() -> [MTKTextureLoader.Option: Any] {
    [
      .SRGB: false,
      .origin: MTKTextureLoader.Origin.topLeft,
    ]
  }

  static func drawableTargetSize(
    forViewBounds bounds: CGSize,
    backingScale: CGFloat
  ) -> CGSize {
    let scale = max(1, backingScale)
    return CGSize(
      width: max(1, ceil(bounds.width * scale)),
      height: max(1, ceil(bounds.height * scale))
    )
  }

  static func cursorGlyphLayout(
    renderFrame: TerminalRenderFrame,
    plan: MetalTerminalRenderPlan,
    contentInset: CGSize,
    markedTextActive: Bool,
    cursorOverlay: MetalMarkedTextOverlay? = nil
  ) -> MetalCursorGlyphLayout? {
    guard !markedTextActive else { return nil }
    let frame = renderFrame.expandedFrame
    let cursorRowsOffset = renderFrame.scrollFrame?.overscanTop.count ?? 0
    let cursorRow = cursorOverlay.map { $0.row + cursorRowsOffset } ?? frame.cursorY
    let cursorCol = cursorOverlay?.col ?? frame.cursorX
    guard renderFrame.isFocused,
      frame.cursorVisible,
      frame.cursorShape == .block,
      cursorRow >= 0,
      cursorRow < frame.rows,
      cursorCol >= 0,
      cursorCol < frame.cols
    else {
      return nil
    }
    let index = cursorRow * frame.cols + cursorCol
    guard index >= 0, index < frame.cells.count else { return nil }
    let cell = frame.cells[index]
    guard cell.scalar != " " else { return nil }

    let pixelScale = plan.backingScale
    let cellSize = CGSize(
      width: plan.cellSize.width * pixelScale,
      height: plan.cellSize.height * pixelScale
    )
    let inset = CGSize(
      width: contentInset.width * pixelScale,
      height: contentInset.height * pixelScale
    )
    let translationY = -CGFloat(plan.overscanTopRows) * cellSize.height + plan.pixelRemainderY * pixelScale
    let rect = CGRect(
      x: inset.width + CGFloat(cursorCol) * cellSize.width,
      y: inset.height + CGFloat(cursorRow) * cellSize.height + translationY,
      width: cellSize.width,
      height: cellSize.height
    )
    return MetalCursorGlyphLayout(scalar: String(cell.scalar), rect: rect)
  }

  static func markedTextGlyphLayout(
    text: String,
    overlay: MetalMarkedTextOverlay?,
    renderFrame: TerminalRenderFrame,
    plan: MetalTerminalRenderPlan,
    contentInset: CGSize
  ) -> [MetalMarkedTextGlyphLayout] {
    guard !text.isEmpty, let overlay else { return [] }
    let pixelScale = plan.backingScale
    let cellSize = CGSize(
      width: plan.cellSize.width * pixelScale,
      height: plan.cellSize.height * pixelScale
    )
    guard cellSize.width > 0, cellSize.height > 0 else { return [] }
    let inset = CGSize(
      width: contentInset.width * pixelScale,
      height: contentInset.height * pixelScale
    )
    let rowOffset = renderFrame.scrollFrame?.overscanTop.count ?? 0
    let row = overlay.row + rowOffset
    let translationY = -CGFloat(plan.overscanTopRows) * cellSize.height + plan.pixelRemainderY * pixelScale
    let originX = inset.width + CGFloat(max(0, overlay.col)) * cellSize.width
    let originY = inset.height + CGFloat(max(0, row)) * cellSize.height + translationY
    let maxX = originX + max(0, overlay.width * pixelScale)
    PTYRenderDebugLog.write(
      "markedTextGlyphLayout overlay=(row:\(overlay.row), col:\(overlay.col), width:\(overlay.width)) rowOffset=\(rowOffset) origin=(\(originX),\(originY)) maxX=\(maxX) text=\"\(text)\""
    )

    var glyphs: [MetalMarkedTextGlyphLayout] = []
    glyphs.reserveCapacity(text.count)
    for (index, character) in text.map(String.init).enumerated() {
      let rect = CGRect(
        x: originX + CGFloat(index) * cellSize.width,
        y: originY,
        width: cellSize.width,
        height: cellSize.height
      )
      guard rect.maxX <= maxX + 0.5 else { break }
      glyphs.append(MetalMarkedTextGlyphLayout(scalar: character, rect: rect))
    }
    return glyphs
  }

  static func glyphDrawRect(for entry: MetalGlyphAtlasEntry, in cellRect: CGRect) -> CGRect {
    guard entry.drawSize.width > 0, entry.drawSize.height > 0 else {
      return cellRect
    }
    return CGRect(
      x: cellRect.minX + entry.drawOffset.x,
      y: cellRect.minY + entry.drawOffset.y,
      width: entry.drawSize.width,
      height: entry.drawSize.height
    )
  }

  static func glyphCellRect(
    row: Int,
    col: Int,
    cell: GhosttyTerminalFrame.Cell,
    cellSize: CGSize,
    inset: CGSize,
    translationY: CGFloat
  ) -> CGRect {
    CGRect(
      x: inset.width + CGFloat(col) * cellSize.width,
      y: inset.height + CGFloat(row) * cellSize.height + translationY,
      width: cell.width == .wide ? cellSize.width * 2 : cellSize.width,
      height: cellSize.height
    )
  }

  static func glyphTextureRect(for entry: MetalGlyphAtlasEntry) -> CGRect {
    guard entry.bitmapSize.width > 0, entry.bitmapSize.height > 0 else {
      return CGRect(x: 0, y: 0, width: 1, height: 1)
    }
    return CGRect(x: 0, y: 0, width: 1, height: 1)
  }

  static func renderRows(
    for plan: MetalTerminalRenderPlan,
    drawFrameRows: Int
  ) -> Range<Int> {
    let rowRuns = renderRowRuns(for: plan, drawFrameRows: drawFrameRows)
    guard let first = rowRuns.first, let last = rowRuns.last else {
      return 0..<0
    }
    return first.lowerBound..<last.upperBound
  }

  static func renderRowRuns(
    for plan: MetalTerminalRenderPlan,
    drawFrameRows: Int
  ) -> [Range<Int>] {
    guard drawFrameRows > 0 else { return [] }
    let fullRange = 0..<drawFrameRows
    guard !plan.dirtyRows.isEmpty else { return [] }
    let viewportRows = max(0, plan.viewportRows)
    if viewportRows > 0 && Set(0..<viewportRows).isSubset(of: plan.dirtyRows) {
      return [fullRange]
    }

    let rowOffset = plan.presentation == .scrollFrame ? plan.overscanTopRows : 0
    let mappedRows = plan.dirtyRows
      .map { $0 + rowOffset }
      .filter { fullRange.contains($0) }
      .sorted()
    guard let first = mappedRows.first, let last = mappedRows.last else {
      return [fullRange]
    }
    var runs: [Range<Int>] = []
    var runStart = first
    var previous = first
    for row in mappedRows.dropFirst() {
      if row == previous + 1 {
        previous = row
        continue
      }
      runs.append(runStart..<(previous + 1))
      runStart = row
      previous = row
    }
    runs.append(runStart..<(last + 1))
    return runs
  }

  static func renderCellRanges(
    for plan: MetalTerminalRenderPlan,
    drawFrameRows: Int
  ) -> [MetalCellDirtyRange] {
    guard drawFrameRows > 0, plan.cols > 0 else { return [] }
    let rowOffset = plan.presentation == .scrollFrame ? plan.overscanTopRows : 0
    let viewportRows = max(0, plan.viewportRows)
    let viewportIsFullyDirty = viewportRows > 0 && Set(0..<viewportRows).isSubset(of: plan.dirtyRows)
    if viewportIsFullyDirty {
      return (0..<drawFrameRows).map { MetalCellDirtyRange(row: $0, cols: 0..<max(0, plan.cols)) }
    }
    if !plan.dirtyCellRanges.isEmpty {
      return plan.dirtyCellRanges.compactMap { range in
        let row = range.row + rowOffset
        guard row >= 0, row < drawFrameRows else { return nil }
        let lower = min(max(0, range.cols.lowerBound), max(0, plan.cols))
        let upper = min(max(lower, range.cols.upperBound), max(0, plan.cols))
        guard lower < upper else { return nil }
        return MetalCellDirtyRange(row: row, cols: lower..<upper)
      }
    }
    return renderRowRuns(for: plan, drawFrameRows: drawFrameRows).flatMap { rowRun in
      rowRun.map { MetalCellDirtyRange(row: $0, cols: 0..<max(0, plan.cols)) }
    }
  }

  private static func fullCellRanges(rows: Int, cols: Int) -> [MetalCellDirtyRange] {
    guard rows > 0, cols > 0 else { return [] }
    return (0..<rows).map { MetalCellDirtyRange(row: $0, cols: 0..<cols) }
  }

  static func renderPassLoadPolicy(
    isFirstFrame: Bool,
    didResizeTexture: Bool,
    redrawMode: TerminalRedrawMode,
    renderRows: Range<Int>,
    drawFrameRows: Int
  ) -> MetalDirectRenderPassLoadPolicy {
    renderPassLoadPolicy(
      isFirstFrame: isFirstFrame,
      didResizeTexture: didResizeTexture,
      redrawMode: redrawMode,
      renderRowRuns: [renderRows],
      drawFrameRows: drawFrameRows
    )
  }

  static func renderPassLoadPolicy(
    isFirstFrame: Bool,
    didResizeTexture: Bool,
    redrawMode: TerminalRedrawMode,
    renderRowRuns: [Range<Int>],
    drawFrameRows: Int
  ) -> MetalDirectRenderPassLoadPolicy {
    if isFirstFrame || didResizeTexture || redrawMode == .full {
      return .clear
    }
    guard drawFrameRows > 0 else { return .clear }
    if coversFullDrawFrame(renderRowRuns, drawFrameRows: drawFrameRows) {
      return .clear
    }
    return .load
  }

  private static func coversFullDrawFrame(_ runs: [Range<Int>], drawFrameRows: Int) -> Bool {
    guard !runs.isEmpty else { return false }
    var expectedLower = 0
    for run in runs {
      guard run.lowerBound == expectedLower else { return false }
      expectedLower = run.upperBound
    }
    return expectedLower == drawFrameRows
  }

  static func shouldWaitForCommandCompletion(
    isFirstFrame: Bool,
    didResizeTexture: Bool,
    redrawMode: TerminalRedrawMode,
    loadPolicy: MetalDirectRenderPassLoadPolicy,
    cursorRowDirty: Bool,
    rendersScene: Bool = true,
    hasDrawableTransientOverlays: Bool = false
  ) -> Bool {
    commandCompletionWaitReason(
      isFirstFrame: isFirstFrame,
      didResizeTexture: didResizeTexture,
      redrawMode: redrawMode,
      loadPolicy: loadPolicy,
      cursorRowDirty: cursorRowDirty,
      rendersScene: rendersScene,
      hasDrawableTransientOverlays: hasDrawableTransientOverlays
    ) != "none"
  }

  static func commandCompletionWaitReason(
    isFirstFrame: Bool,
    didResizeTexture: Bool,
    redrawMode: TerminalRedrawMode,
    loadPolicy: MetalDirectRenderPassLoadPolicy,
    cursorRowDirty: Bool,
    rendersScene: Bool = true,
    hasDrawableTransientOverlays: Bool = false
  ) -> String {
    if isFirstFrame {
      return "first-frame"
    }
    if didResizeTexture {
      return "texture-resize"
    }
    if redrawMode == .full {
      return "full-redraw"
    }
    if loadPolicy == .clear {
      return "clear-load-action"
    }
    if cursorRowDirty {
      return "cursor-row-dirty"
    }
    if rendersScene && loadPolicy == .load {
      return "load-scene-render"
    }
    if hasDrawableTransientOverlays {
      return "drawable-transient-overlays"
    }
    return "none"
  }

  private func makeBuffer(vertices: [Vertex]) -> MTLBuffer? {
    guard !vertices.isEmpty else {
      return device.makeBuffer(length: 1, options: [])
    }
    return vertices.withUnsafeBytes { rawBuffer in
      guard let baseAddress = rawBuffer.baseAddress else {
        return nil
      }
      return device.makeBuffer(
        bytes: baseAddress,
        length: MemoryLayout<Vertex>.stride * vertices.count,
        options: []
      )
    }
  }

  private func makeBuffer(haloVertices: [HaloVertex]) -> MTLBuffer? {
    guard !haloVertices.isEmpty else {
      return device.makeBuffer(length: 1, options: [])
    }
    return haloVertices.withUnsafeBytes { rawBuffer in
      guard let baseAddress = rawBuffer.baseAddress else {
        return nil
      }
      return device.makeBuffer(
        bytes: baseAddress,
        length: MemoryLayout<HaloVertex>.stride * haloVertices.count,
        options: []
      )
    }
  }

  private func buildBackgroundVertices(
    frame: GhosttyTerminalFrame,
    cellRanges: [MetalCellDirtyRange],
    palette: TerminalSurfacePalette,
    isFocused: Bool,
    cellSize: CGSize,
    inset: CGSize,
    translationY: CGFloat
  ) -> [Vertex] {
    var vertices: [Vertex] = []
    vertices.reserveCapacity(cellRanges.reduce(0) { $0 + $1.cols.count } * 6)
    for range in cellRanges {
      let row = range.row
      let rowStart = row * frame.cols
      let rowEnd = min(rowStart + frame.cols, frame.cells.count)
      guard row >= 0, row < frame.rows, rowStart < rowEnd else { continue }
      for col in range.cols {
        let index = rowStart + col
        guard col >= 0, col < frame.cols, index < rowEnd else { continue }
        let cell = frame.cells[index]
        // The drawable is already cleared to the palette background every frame,
        // so a default-background, non-inverse cell needs no quad. Skipping these
        // is the difference between emitting a quad + a per-cell NSColor→deviceRGB
        // conversion for every one of ~1900 screen cells vs only the few with an
        // explicit background — the dominant per-frame cost under pattern-2's
        // full redraw.
        guard cell.inverse || !cell.usesDefaultBackground else { continue }
        let colors = TerminalColorResolver.resolvedColors(for: cell, palette: palette, isFocused: isFocused)
        let rect = CGRect(
          x: inset.width + CGFloat(col) * cellSize.width,
          y: inset.height + CGFloat(row) * cellSize.height + translationY,
          width: cellSize.width,
          height: cellSize.height
        )
        vertices.append(contentsOf: quadVertices(rect: rect, color: colors.background.metalRGBA, texture: false))
      }
    }
    return vertices
  }

  private func buildGlyphVertices(
    frame: GhosttyTerminalFrame,
    cellRanges: [MetalCellDirtyRange],
    palette: TerminalSurfacePalette,
    isFocused: Bool,
    glyphAtlas: MetalGlyphAtlas,
    cellSize: CGSize,
    inset: CGSize,
    translationY: CGFloat,
    cursorRow: Int,
    cursorCol: Int,
    cursorVisible: Bool,
    cursorShape: TerminalCursorShape,
    linkLitColumnsByRow: [Int: Set<Int>] = [:],
    linkWeightBoost: CGFloat = 0
  ) -> [Vertex] {
    var vertices: [Vertex] = []
    vertices.reserveCapacity(cellRanges.reduce(0) { $0 + $1.cols.count } * 6)
    for range in cellRanges {
      let row = range.row
      let rowStart = row * frame.cols
      let rowEnd = min(rowStart + frame.cols, frame.cells.count)
      guard row >= 0, row < frame.rows, rowStart < rowEnd else { continue }
      let litColumns = linkLitColumnsByRow[row]
      for col in range.cols {
        let index = rowStart + col
        guard col >= 0, col < frame.cols, index < rowEnd else { continue }
        let cell = frame.cells[index]
        guard cell.scalar != " ", cell.width != .spacerTail, cell.width != .spacerHead else { continue }
        let colors = TerminalColorResolver.resolvedColors(for: cell, palette: palette, isFocused: isFocused)
        let rect = Self.glyphCellRect(
          row: row,
          col: col,
          cell: cell,
          cellSize: cellSize,
          inset: inset,
          translationY: translationY
        )
        let entry = glyphAtlas.entry(for: String(cell.scalar), style: MetalGlyphStyle(cell))
        guard texture(for: entry, glyphAtlas: glyphAtlas) != nil else {
          continue
        }
        // Dwell reveal (spec §4): the awoken object's glyphs gain weight in place.
        // No float, no color change — only the fragment-shader alpha dilation.
        let boost: Float = (linkWeightBoost > 0.001 && litColumns?.contains(col) == true)
          ? Float(linkWeightBoost)
          : 0
        let foreground = colors.foreground.metalRGBA
        vertices.append(contentsOf: quadVertices(
          rect: Self.glyphDrawRect(for: entry, in: rect),
          color: foreground,
          textureRect: Self.glyphTextureRect(for: entry),
          weightBoost: boost
        ))
      }
    }
    return vertices
  }

  private func glyphTextureSlices(
    for frame: GhosttyTerminalFrame,
    cellRanges: [MetalCellDirtyRange],
    glyphAtlas: MetalGlyphAtlas
  ) -> [GlyphTextureSlice] {
    var slices: [GlyphTextureSlice] = []
    var vertexStart = 0
    for range in cellRanges {
      let row = range.row
      let rowStart = row * frame.cols
      let rowEnd = min(rowStart + frame.cols, frame.cells.count)
      guard row >= 0, row < frame.rows, rowStart < rowEnd else { continue }
      for col in range.cols {
        let index = rowStart + col
        guard col >= 0, col < frame.cols, index < rowEnd else { continue }
        let cell = frame.cells[index]
        guard cell.scalar != " ", cell.width != .spacerTail, cell.width != .spacerHead else { continue }
        let entry = glyphAtlas.entry(for: String(cell.scalar), style: MetalGlyphStyle(cell))
        guard let texture = texture(for: entry, glyphAtlas: glyphAtlas) else { continue }
        slices.append(GlyphTextureSlice(texture: texture, vertexStart: vertexStart, vertexCount: 6))
        vertexStart += 6
      }
    }
    return slices
  }

  private func buildMarkedTextGlyphDraw(
    layout: [MetalMarkedTextGlyphLayout],
    palette: TerminalSurfacePalette,
    isFocused: Bool,
    glyphAtlas: MetalGlyphAtlas
  ) -> (vertices: [Vertex], slices: [GlyphTextureSlice]) {
    var vertices: [Vertex] = []
    var slices: [GlyphTextureSlice] = []
    vertices.reserveCapacity(layout.count * 6)
    for glyph in layout {
      let entry = glyphAtlas.entry(for: glyph.scalar)
      guard let texture = texture(for: entry, glyphAtlas: glyphAtlas) else { continue }
      let color = palette.foreground.withAlphaComponent(isFocused ? 0.92 : 0.62).metalRGBA
      vertices.append(contentsOf: quadVertices(
        rect: Self.glyphDrawRect(for: entry, in: glyph.rect),
        color: color,
        textureRect: Self.glyphTextureRect(for: entry)
      ))
      slices.append(GlyphTextureSlice(texture: texture, vertexStart: vertices.count - 6, vertexCount: 6))
    }
    return (vertices, slices)
  }

  private func buildCursorGlyphDraw(
    layout: MetalCursorGlyphLayout?,
    palette: TerminalSurfacePalette,
    glyphAtlas: MetalGlyphAtlas
  ) -> (vertices: [Vertex], slices: [GlyphTextureSlice]) {
    guard let layout else { return ([], []) }
    let entry = glyphAtlas.entry(for: layout.scalar)
    guard let texture = texture(for: entry, glyphAtlas: glyphAtlas) else {
      return ([], [])
    }
    let vertices = quadVertices(
      rect: Self.glyphDrawRect(for: entry, in: layout.rect),
      color: palette.cursorForeground.metalRGBA,
      textureRect: Self.glyphTextureRect(for: entry)
    )
    return (
      vertices,
      [GlyphTextureSlice(texture: texture, vertexStart: 0, vertexCount: vertices.count)]
    )
  }

  private func buildOverlayVertices(overlays: [MetalOverlayPrimitive]) -> [Vertex] {
    overlays.flatMap { overlay in
      quadVertices(rect: overlay.rect, color: overlay.color, texture: false)
    }
  }

  /// Build the trailing ↗ Action Hint glyph (spec §5). It fades in place by
  /// opacity only — no float, no translation — once the object reaches ActionHint.
  private func buildActionHintGlyphDraw(
    hint: PTYGridView.ActionHint?,
    palette: TerminalSurfacePalette,
    glyphAtlas: MetalGlyphAtlas,
    cellSize: CGSize,
    inset: CGSize,
    translationY: CGFloat
  ) -> (vertices: [Vertex], slices: [GlyphTextureSlice]) {
    guard let hint, hint.intensity > 0.01 else { return ([], []) }
    let entry = glyphAtlas.entry(for: "↗")
    guard let texture = texture(for: entry, glyphAtlas: glyphAtlas) else { return ([], []) }
    let cellRect = CGRect(
      x: inset.width + CGFloat(hint.col) * cellSize.width,
      y: inset.height + CGFloat(hint.row) * cellSize.height + translationY,
      width: cellSize.width,
      height: cellSize.height
    )
    // Fade in place — opacity is the whole reveal (spec §5). Kept faint.
    let color = palette.foreground.withAlphaComponent(min(0.85, hint.intensity * 0.85)).metalRGBA
    let vertices = quadVertices(
      rect: Self.glyphDrawRect(for: entry, in: cellRect),
      color: color,
      textureRect: Self.glyphTextureRect(for: entry)
    )
    return (vertices, [GlyphTextureSlice(texture: texture, vertexStart: 0, vertexCount: vertices.count)])
  }

  /// Build SDF-halo vertices for `.semanticHalo` primitives. Each becomes a quad
  /// carrying, per vertex, its position relative to the halo center plus the
  /// rounded-rect half-size / corner / feather so the fragment shader can compute
  /// a smooth signed-distance falloff.
  private func buildHaloVertices(overlays: [MetalOverlayPrimitive]) -> [HaloVertex] {
    overlays.flatMap { overlay -> [HaloVertex] in
      guard let halo = overlay.halo else { return [] }
      let rect = overlay.rect
      let cx = Float(rect.midX)
      let cy = Float(rect.midY)
      let minX = Float(rect.minX)
      let maxX = Float(rect.maxX)
      let minY = Float(rect.minY)
      let maxY = Float(rect.maxY)
      func vertex(_ px: Float, _ py: Float) -> HaloVertex {
        HaloVertex(
          position: SIMD2<Float>(px, py),
          color: overlay.color,
          localPos: SIMD2<Float>(px - cx, py - cy),
          halfSize: halo.coreHalfSize,
          cornerRadius: halo.cornerRadius,
          feather: halo.feather,
          ringWidth: halo.ringWidth
        )
      }
      return [
        vertex(minX, minY), vertex(maxX, minY), vertex(minX, maxY),
        vertex(minX, maxY), vertex(maxX, minY), vertex(maxX, maxY),
      ]
    }
  }

  private func quadVertices(rect: CGRect, color: SIMD4<Float>, texture: Bool) -> [Vertex] {
    quadVertices(
      rect: rect,
      color: color,
      textureRect: texture ? CGRect(x: 0, y: 0, width: 1, height: 1) : nil
    )
  }

  private func quadVertices(rect: CGRect, color: SIMD4<Float>, textureRect: CGRect?, weightBoost: Float = 0) -> [Vertex] {
    let minX = Float(rect.minX)
    let maxX = Float(rect.maxX)
    let minY = Float(rect.minY)
    let maxY = Float(rect.maxY)
    let tl = SIMD2<Float>(minX, minY)
    let tr = SIMD2<Float>(maxX, minY)
    let bl = SIMD2<Float>(minX, maxY)
    let br = SIMD2<Float>(maxX, maxY)
    let zero = SIMD2<Float>(0, 0)
    let texRect = textureRect ?? .zero
    let uvtl = SIMD2<Float>(Float(texRect.minX), Float(texRect.minY))
    let uvtr = SIMD2<Float>(Float(texRect.maxX), Float(texRect.minY))
    let uvbl = SIMD2<Float>(Float(texRect.minX), Float(texRect.maxY))
    let uvbr = SIMD2<Float>(Float(texRect.maxX), Float(texRect.maxY))
    return [
      Vertex(position: tl, color: color, texCoord: textureRect == nil ? zero : uvtl, weightBoost: weightBoost),
      Vertex(position: tr, color: color, texCoord: textureRect == nil ? zero : uvtr, weightBoost: weightBoost),
      Vertex(position: bl, color: color, texCoord: textureRect == nil ? zero : uvbl, weightBoost: weightBoost),
      Vertex(position: bl, color: color, texCoord: textureRect == nil ? zero : uvbl, weightBoost: weightBoost),
      Vertex(position: tr, color: color, texCoord: textureRect == nil ? zero : uvtr, weightBoost: weightBoost),
      Vertex(position: br, color: color, texCoord: textureRect == nil ? zero : uvbr, weightBoost: weightBoost),
    ]
  }

  private static func makePipeline(
    device: MTLDevice,
    library: MTLLibrary,
    vertexFunctionName: String,
    fragmentFunctionName: String
  ) throws -> MTLRenderPipelineState {
    let descriptor = MTLRenderPipelineDescriptor()
    descriptor.vertexFunction = library.makeFunction(name: vertexFunctionName)
    descriptor.fragmentFunction = library.makeFunction(name: fragmentFunctionName)
    descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
    descriptor.colorAttachments[0].isBlendingEnabled = true
    descriptor.colorAttachments[0].rgbBlendOperation = .add
    descriptor.colorAttachments[0].alphaBlendOperation = .add
    descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
    descriptor.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
    descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
    descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
    return try device.makeRenderPipelineState(descriptor: descriptor)
  }

  private static func debugDescription(for overlay: GridMarkedTextOverlay?) -> String {
    guard let overlay else { return "nil" }
    return "(row:\(overlay.row),col:\(overlay.col),width:\(String(format: "%.1f", overlay.width)))"
  }

  private static func debugLogText(_ text: String) -> String {
    let sanitized = text
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
      .replacingOccurrences(of: "\n", with: "\\n")
      .replacingOccurrences(of: "\r", with: "\\r")
    let maxLength = 120
    guard sanitized.count > maxLength else { return sanitized }
    return String(sanitized.prefix(maxLength)) + "..."
  }

  static let shaderSource = #"""
  #include <metal_stdlib>
  using namespace metal;

  struct VertexIn {
    float2 position;
    float4 color;
    float2 texCoord;
    float weightBoost;
  };

  struct VertexOut {
    float4 position [[position]];
    float4 color;
    float2 texCoord;
    float weightBoost;
  };

  struct Uniforms {
    float2 drawableSize;
  };

  vertex VertexOut metal_direct_vertex(
    uint vertexID [[vertex_id]],
    const device VertexIn *vertices [[buffer(0)]],
    constant Uniforms &uniforms [[buffer(1)]]
  ) {
    VertexOut out;
    VertexIn in = vertices[vertexID];
    float2 clip = float2(
      (in.position.x / uniforms.drawableSize.x) * 2.0 - 1.0,
      1.0 - (in.position.y / uniforms.drawableSize.y) * 2.0
    );
    out.position = float4(clip, 0.0, 1.0);
    out.color = in.color;
    out.texCoord = in.texCoord;
    out.weightBoost = in.weightBoost;
    return out;
  }

  fragment float4 metal_direct_background_fragment(VertexOut in [[stage_in]]) {
    return in.color;
  }

  fragment float4 metal_direct_glyph_fragment(
    VertexOut in [[stage_in]],
    texture2d<float> texture0 [[texture(0)]]
  ) {
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::nearest);
    // Base coverage is ALWAYS the nearest-filtered tap — pixel-exact, identical to
    // plain text. Never resample the glyph core with linear, or the whole stroke
    // goes soft (the cause of the "blurry when weighted" artifact).
    float core = texture0.sample(s, in.texCoord).a;
    if (in.weightBoost < 0.001) {
      return float4(in.color.rgb, in.color.a * core);
    }
    // Faux-weight (spec §4.1): grow ONLY a thin outer rim by max-combining a few
    // linear-filtered neighbor taps, then union with the crisp core. The core
    // stays sharp; the boost just adds sub-texel coverage at the stroke edge.
    constexpr sampler ls(coord::normalized, address::clamp_to_edge, filter::linear);
    float w = float(texture0.get_width());
    float h = float(texture0.get_height());
    // Up to ~0.7 device texels of dilation at full boost — a gentle Regular→
    // Medium-ish thickening without closing glyph counters.
    float2 d = float2(1.0 / max(w, 1.0), 1.0 / max(h, 1.0)) * (in.weightBoost * 0.7);
    float rim = texture0.sample(ls, in.texCoord + float2( d.x, 0.0)).a;
    rim = max(rim, texture0.sample(ls, in.texCoord + float2(-d.x, 0.0)).a);
    rim = max(rim, texture0.sample(ls, in.texCoord + float2(0.0,  d.y)).a);
    rim = max(rim, texture0.sample(ls, in.texCoord + float2(0.0, -d.y)).a);
    rim = max(rim, texture0.sample(ls, in.texCoord + float2( d.x,  d.y)).a);
    rim = max(rim, texture0.sample(ls, in.texCoord + float2( d.x, -d.y)).a);
    rim = max(rim, texture0.sample(ls, in.texCoord + float2(-d.x,  d.y)).a);
    rim = max(rim, texture0.sample(ls, in.texCoord + float2(-d.x, -d.y)).a);
    float a = max(core, rim);
    return float4(in.color.rgb, in.color.a * a);
  }

  // ---- Feathered Semantic Halo (spec §4.2) ----

  struct HaloVertexIn {
    float2 position;
    float4 color;
    float2 localPos;
    float2 halfSize;
    float cornerRadius;
    float feather;
    float ringWidth;
  };

  struct HaloVertexOut {
    float4 position [[position]];
    float4 color;
    float2 localPos;
    float2 halfSize;
    float cornerRadius;
    float feather;
    float ringWidth;
  };

  vertex HaloVertexOut metal_direct_halo_vertex(
    uint vertexID [[vertex_id]],
    const device HaloVertexIn *vertices [[buffer(0)]],
    constant Uniforms &uniforms [[buffer(1)]]
  ) {
    HaloVertexOut out;
    HaloVertexIn in = vertices[vertexID];
    float2 clip = float2(
      (in.position.x / uniforms.drawableSize.x) * 2.0 - 1.0,
      1.0 - (in.position.y / uniforms.drawableSize.y) * 2.0
    );
    out.position = float4(clip, 0.0, 1.0);
    out.color = in.color;
    out.localPos = in.localPos;
    out.halfSize = in.halfSize;
    out.cornerRadius = in.cornerRadius;
    out.feather = in.feather;
    out.ringWidth = in.ringWidth;
    return out;
  }

  // Signed distance to a rounded rectangle centered at origin.
  static inline float rounded_box_sdf(float2 p, float2 halfSize, float radius) {
    float2 q = abs(p) - (halfSize - float2(radius));
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
  }

  // Cheap per-pixel hash noise in [-0.5, 0.5], used to dither the halo so its very
  // low-alpha gradient does not quantize into visible concentric bands on 8-bit
  // output. Standard fract-sin hash keyed on the fragment's screen coordinate.
  static inline float halo_dither(float2 p) {
    float n = fract(sin(dot(p, float2(12.9898, 78.233))) * 43758.5453);
    return n - 0.5;
  }

  fragment float4 metal_direct_halo_fragment(HaloVertexOut in [[stage_in]]) {
    float dist = rounded_box_sdf(in.localPos, in.halfSize, in.cornerRadius);

    // Ring mode (cursor puck): a crisp stroked outline with only ~1px AA, so it
    // reads as a clean small circle rather than a soft glow.
    if (in.ringWidth > 0.0) {
      float aa = 1.0;
      // Distance from the ring's centerline (half the stroke inside the edge).
      float ringDist = abs(dist + in.ringWidth * 0.5) - in.ringWidth * 0.5;
      float coverage = 1.0 - smoothstep(0.0, aa, ringDist);
      if (coverage <= 0.001) {
        discard_fragment();
      }
      return float4(in.color.rgb, in.color.a * coverage);
    }

    // Soft, borderless falloff: begin the fade slightly INSIDE the core so there
    // is no hard edge where the solid core meets the feather, then ease out across
    // the whole feather band. smootherstep (6t^5-15t^4+10t^3) is gentler than
    // smoothstep and reads as a true glow rather than a shape with a rim.
    float feather = max(in.feather, 1.0);
    float t = clamp((dist + feather * 0.25) / (feather * 1.25), 0.0, 1.0);
    float smoother = t * t * t * (t * (t * 6.0 - 15.0) + 10.0);
    float coverage = 1.0 - smoother;
    // Dither the final alpha by ~1/255 to break up 8-bit banding (the "rings").
    // Amplitude is one quantization step so it scatters the boundary between
    // adjacent alpha levels without introducing perceptible noise.
    float alpha = in.color.a * coverage;
    alpha += halo_dither(in.position.xy) * (1.0 / 255.0);
    if (alpha <= 0.001) {
      discard_fragment();
    }
    return float4(in.color.rgb, alpha);
  }
  """#
}

private struct GlyphTextureSlice {
  let texture: MTLTexture
  let vertexStart: Int
  let vertexCount: Int
}

private extension MetalGlyphStyle {
  init(_ cell: GhosttyTerminalFrame.Cell) {
    self.init(bold: cell.bold, italic: cell.italic, underline: cell.underline)
  }
}

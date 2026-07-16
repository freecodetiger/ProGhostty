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
    retainedResources: [Any]
  ) {
    commandBuffer.addCompletedHandler { [completionBox, retainedResources] _ in
      _ = retainedResources.count
      completionBox.complete(generation)
    }
  }
}

@MainActor
final class MetalDirectRenderEngine: MetalDirectRenderingEngine {
  private struct Vertex {
    var position: SIMD2<Float>
    var color: SIMD4<Float>
    var texCoord: SIMD2<Float>
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

  private struct OffscreenTexture {
    let texture: MTLTexture
    let didResize: Bool
  }

  private let device: MTLDevice
  private let commandQueue: MTLCommandQueue
  private let textureLoader: MTKTextureLoader
  private let backgroundPipeline: MTLRenderPipelineState
  private let glyphPipeline: MTLRenderPipelineState
  private let compositePipeline: MTLRenderPipelineState
  private var cachedTextures: [Int: CachedTexture] = [:]
  private var offscreenTexture: MTLTexture?
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
    let compositePipeline = try Self.makePipeline(
      device: device,
      library: library,
      vertexFunctionName: "metal_direct_vertex",
      fragmentFunctionName: "metal_direct_composite_fragment"
    )
    self.backgroundPipeline = backgroundPipeline
    self.glyphPipeline = glyphPipeline
    self.compositePipeline = compositePipeline
    pipelineReady = true
  }

  func resetTextureCache() {
    cachedTextures.removeAll(keepingCapacity: true)
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
    let sceneTranslationY = drawTranslationY(
      topOverscanRows: renderFrame.scrollFrame?.overscanTop.count ?? 0,
      pixelRemainderY: 0,
      cellHeight: cellSize.height
    )
    let presentationTranslationY = plan.pixelRemainderY * pixelScale
    let renderSize = Self.renderTargetSize(
      for: plan,
      contentInset: view.terminalContentInset
    )
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

    let plannedRenderRowRuns = Self.renderRowRuns(for: plan, drawFrameRows: drawFrame.rows)
    let plannedRenderCellRanges = Self.renderCellRanges(for: plan, drawFrameRows: drawFrame.rows)

    guard let offscreen = ensureOffscreenTexture(size: renderSize) else {
      return false
    }
    let texture = offscreen.texture
    let transientOverlayChanged = plan.transientOverlayRevision != 0
      && plan.transientOverlayRevision != previousTransientOverlayRevision
    let mustRebuildScene = drawPassCount == 0 || offscreen.didResize || transientOverlayChanged
    let renderRowRuns = mustRebuildScene && drawFrame.rows > 0
      ? [0..<drawFrame.rows]
      : plannedRenderRowRuns
    let renderCellRanges = mustRebuildScene
      ? Self.fullCellRanges(rows: drawFrame.rows, cols: plan.cols)
      : plannedRenderCellRanges
    let shouldRenderScene = mustRebuildScene || !renderCellRanges.isEmpty
    let redrawMode: TerminalRedrawMode = renderCellRanges.isEmpty
      ? .clean
      : (Self.coversFullDrawFrame(renderRowRuns, drawFrameRows: drawFrame.rows) ? .full : .dirty)
    let loadPolicy = Self.renderPassLoadPolicy(
      isFirstFrame: drawPassCount == 0,
      didResizeTexture: offscreen.didResize,
      redrawMode: redrawMode,
      renderRowRuns: renderRowRuns,
      drawFrameRows: drawFrame.rows
    )
    let backgroundVertices = buildBackgroundVertices(
      frame: drawFrame,
      cellRanges: renderCellRanges,
      palette: palette,
      isFocused: renderFrame.isFocused,
      cellSize: cellSize,
      inset: inset,
      translationY: sceneTranslationY
    )
    let sceneOverlays = MetalOverlayBuffer.makeOverlays(
      renderFrame: renderFrame,
      plan: plan,
      palette: palette,
      markedTextActive: view.isComposingMarkedText,
      selectedRows: view.currentSelectionRowSet,
      selectedCellRanges: view.currentSelectionCellRanges,
      selectionRowsOffset: 0,
      linkHoverRows: [],
      linkHoverCellRanges: view.currentLinkHoverCellRanges,
      cursorOverlay: cursorOverlay,
      markedTextOverlay: markedTextOverlay,
      imeCompositionCursorOverlay: view.currentIMECompositionCursorOverlay,
      markedTextRowsOffset: renderFrame.scrollFrame?.overscanTop.count ?? 0,
      pixelRemainderY: 0
    )
    let drawableOverlays = MetalOverlayBuffer.makeOverlays(
      renderFrame: renderFrame,
      plan: plan,
      palette: palette,
      markedTextActive: view.isComposingMarkedText,
      selectedRows: view.currentSelectionRowSet,
      selectedCellRanges: view.currentSelectionCellRanges,
      selectionRowsOffset: 0,
      linkHoverRows: [],
      linkHoverCellRanges: view.currentLinkHoverCellRanges,
      cursorOverlay: cursorOverlay,
      markedTextOverlay: markedTextOverlay,
      imeCompositionCursorOverlay: view.currentIMECompositionCursorOverlay,
      markedTextRowsOffset: renderFrame.scrollFrame?.overscanTop.count ?? 0,
      pixelRemainderY: plan.pixelRemainderY
    )
    let drawCursorOnDrawable = Self.cursorShouldDrawOnDrawable(shape: renderFrame.frame.cursorShape)
    let offscreenOverlays = !shouldRenderScene || renderRowRuns.isEmpty
      ? []
      : Self.offscreenOverlays(from: sceneOverlays, drawCursorOnDrawable: drawCursorOnDrawable)
    let drawableTransientOverlays = Self.drawableOverlays(
      from: drawableOverlays,
      drawCursorOnDrawable: drawCursorOnDrawable
    )
    let overlayBelowVertices = buildOverlayVertices(
      overlays: offscreenOverlays.filter { $0.phase == .beneathGlyphs }
    )
    let glyphVertices = buildGlyphVertices(
      frame: drawFrame,
      cellRanges: renderCellRanges,
      palette: palette,
      isFocused: renderFrame.isFocused,
      glyphAtlas: glyphAtlas,
      cellSize: cellSize,
      inset: inset,
      translationY: sceneTranslationY,
      cursorRow: renderFrame.scrollFrame.map { $0.overscanTop.count + $0.viewport.cursorY } ?? renderFrame.frame.cursorY,
      cursorCol: renderFrame.frame.cursorX,
      cursorVisible: renderFrame.frame.cursorVisible,
      cursorShape: renderFrame.frame.cursorShape
    )
    let overlayAboveVertices = buildOverlayVertices(
      overlays: offscreenOverlays.filter { $0.phase == .aboveGlyphs }
    )
    let drawableOverlayVertices = buildOverlayVertices(overlays: drawableTransientOverlays)
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
    let hasDrawableTransientOverlays = !drawableOverlayVertices.isEmpty
      || !markedTextGlyphDraw.vertices.isEmpty
      || !cursorGlyphDraw.vertices.isEmpty
    let waitReason = Self.commandCompletionWaitReason(
      isFirstFrame: drawPassCount == 0,
      didResizeTexture: offscreen.didResize,
      redrawMode: redrawMode,
      loadPolicy: loadPolicy,
      cursorRowDirty: plan.dirtyRows.contains(renderFrame.frame.cursorY),
      rendersScene: shouldRenderScene,
      hasDrawableTransientOverlays: hasDrawableTransientOverlays
    )
    let shouldWait = waitReason != "none"
    let glyphSlices = glyphTextureSlices(for: drawFrame, cellRanges: renderCellRanges, glyphAtlas: glyphAtlas)
    let compositeVertices = quadVertices(
      rect: CGRect(
        x: 0,
        y: presentationTranslationY,
        width: renderSize.width,
        height: renderSize.height
      ),
      color: SIMD4<Float>(1, 1, 1, 1),
      texture: true
    )

    guard
      let backgroundBuffer = makeBuffer(vertices: backgroundVertices),
      let overlayBelowBuffer = makeBuffer(vertices: overlayBelowVertices),
      let glyphBuffer = makeBuffer(vertices: glyphVertices),
      let overlayAboveBuffer = makeBuffer(vertices: overlayAboveVertices),
      let drawableOverlayBuffer = makeBuffer(vertices: drawableOverlayVertices),
      let markedTextGlyphBuffer = makeBuffer(vertices: markedTextGlyphDraw.vertices),
      let cursorGlyphBuffer = makeBuffer(vertices: cursorGlyphDraw.vertices),
      let compositeBuffer = makeBuffer(vertices: compositeVertices)
    else {
      return false
    }

    guard let commandBuffer = commandQueue.makeCommandBuffer() else {
      return false
    }

    if shouldRenderScene {
      let passDescriptor = MTLRenderPassDescriptor()
      passDescriptor.colorAttachments[0].texture = texture
      passDescriptor.colorAttachments[0].loadAction = loadPolicy == .clear ? .clear : .load
      passDescriptor.colorAttachments[0].storeAction = .store
      passDescriptor.colorAttachments[0].clearColor = MTLClearColor(
        red: Double(palette.background.metalRed),
        green: Double(palette.background.metalGreen),
        blue: Double(palette.background.metalBlue),
        alpha: 1
      )

      if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) {
      var uniforms = Uniforms(drawableSize: SIMD2(Float(renderSize.width), Float(renderSize.height)))
      encoder.setRenderPipelineState(backgroundPipeline)
      encoder.setVertexBuffer(backgroundBuffer, offset: 0, index: 0)
      withUnsafeBytes(of: &uniforms) { bytes in
        encoder.setVertexBytes(bytes.baseAddress!, length: bytes.count, index: 1)
      }
      encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: backgroundVertices.count)

      if !overlayBelowVertices.isEmpty {
        encoder.setVertexBuffer(overlayBelowBuffer, offset: 0, index: 0)
        withUnsafeBytes(of: &uniforms) { bytes in
          encoder.setVertexBytes(bytes.baseAddress!, length: bytes.count, index: 1)
        }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: overlayBelowVertices.count)
      }

      if !glyphVertices.isEmpty {
        encoder.setRenderPipelineState(glyphPipeline)
        encoder.setVertexBuffer(glyphBuffer, offset: 0, index: 0)
        withUnsafeBytes(of: &uniforms) { bytes in
          encoder.setVertexBytes(bytes.baseAddress!, length: bytes.count, index: 1)
        }
        for textureSlice in glyphSlices {
          encoder.setFragmentTexture(textureSlice.texture, index: 0)
          encoder.drawPrimitives(type: .triangle, vertexStart: textureSlice.vertexStart, vertexCount: textureSlice.vertexCount)
        }
      }

      if !overlayAboveVertices.isEmpty {
        encoder.setRenderPipelineState(backgroundPipeline)
        encoder.setVertexBuffer(overlayAboveBuffer, offset: 0, index: 0)
        withUnsafeBytes(of: &uniforms) { bytes in
          encoder.setVertexBytes(bytes.baseAddress!, length: bytes.count, index: 1)
        }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: overlayAboveVertices.count)
      }

      encoder.endEncoding()
      }
    }

    var retainedResources: [Any] = [
      texture,
      backgroundBuffer,
      overlayBelowBuffer,
      glyphBuffer,
      overlayAboveBuffer,
      drawableOverlayBuffer,
      markedTextGlyphBuffer,
      cursorGlyphBuffer,
      compositeBuffer,
      backgroundPipeline,
      glyphPipeline,
      compositePipeline,
    ]
    retainedResources.append(contentsOf: glyphSlices.map(\.texture))
    retainedResources.append(contentsOf: markedTextGlyphDraw.slices.map(\.texture))
    retainedResources.append(contentsOf: cursorGlyphDraw.slices.map(\.texture))

    if let metalLayer = view.layer as? CAMetalLayer {
      retainedResources.append(metalLayer)
      metalLayer.drawableSize = drawableSize
      if let drawable = metalLayer.nextDrawable() {
        retainedResources.append(drawable)
        let compositePassDescriptor = MTLRenderPassDescriptor()
        compositePassDescriptor.colorAttachments[0].texture = drawable.texture
        compositePassDescriptor.colorAttachments[0].loadAction = .clear
        compositePassDescriptor.colorAttachments[0].storeAction = .store
        compositePassDescriptor.colorAttachments[0].clearColor = MTLClearColor(
          red: Double(palette.background.metalRed),
          green: Double(palette.background.metalGreen),
          blue: Double(palette.background.metalBlue),
          alpha: 1
        )
        if let compositeEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: compositePassDescriptor) {
          var compositeUniforms = Uniforms(drawableSize: SIMD2(Float(drawableSize.width), Float(drawableSize.height)))
          compositeEncoder.setRenderPipelineState(compositePipeline)
          compositeEncoder.setVertexBuffer(compositeBuffer, offset: 0, index: 0)
          withUnsafeBytes(of: &compositeUniforms) { bytes in
            compositeEncoder.setVertexBytes(bytes.baseAddress!, length: bytes.count, index: 1)
          }
          compositeEncoder.setFragmentTexture(texture, index: 0)
          compositeEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: compositeVertices.count)
          compositeEncoder.endEncoding()
        }
        if !drawableOverlayVertices.isEmpty {
          let overlayPassDescriptor = MTLRenderPassDescriptor()
          overlayPassDescriptor.colorAttachments[0].texture = drawable.texture
          overlayPassDescriptor.colorAttachments[0].loadAction = .load
          overlayPassDescriptor.colorAttachments[0].storeAction = .store
          if let overlayEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: overlayPassDescriptor) {
            var overlayUniforms = Uniforms(drawableSize: SIMD2(Float(drawableSize.width), Float(drawableSize.height)))
            overlayEncoder.setRenderPipelineState(backgroundPipeline)
            overlayEncoder.setVertexBuffer(drawableOverlayBuffer, offset: 0, index: 0)
            withUnsafeBytes(of: &overlayUniforms) { bytes in
              overlayEncoder.setVertexBytes(bytes.baseAddress!, length: bytes.count, index: 1)
            }
            overlayEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: drawableOverlayVertices.count)
            overlayEncoder.endEncoding()
          }
        }
        if !markedTextGlyphDraw.vertices.isEmpty {
          let markedTextPassDescriptor = MTLRenderPassDescriptor()
          markedTextPassDescriptor.colorAttachments[0].texture = drawable.texture
          markedTextPassDescriptor.colorAttachments[0].loadAction = .load
          markedTextPassDescriptor.colorAttachments[0].storeAction = .store
          if let markedTextEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: markedTextPassDescriptor) {
            var markedTextUniforms = Uniforms(drawableSize: SIMD2(Float(drawableSize.width), Float(drawableSize.height)))
            markedTextEncoder.setRenderPipelineState(glyphPipeline)
            markedTextEncoder.setVertexBuffer(markedTextGlyphBuffer, offset: 0, index: 0)
            withUnsafeBytes(of: &markedTextUniforms) { bytes in
              markedTextEncoder.setVertexBytes(bytes.baseAddress!, length: bytes.count, index: 1)
            }
            for textureSlice in markedTextGlyphDraw.slices {
              markedTextEncoder.setFragmentTexture(textureSlice.texture, index: 0)
              markedTextEncoder.drawPrimitives(type: .triangle, vertexStart: textureSlice.vertexStart, vertexCount: textureSlice.vertexCount)
            }
            markedTextEncoder.endEncoding()
          }
        }
        if !cursorGlyphDraw.vertices.isEmpty {
          let cursorGlyphPassDescriptor = MTLRenderPassDescriptor()
          cursorGlyphPassDescriptor.colorAttachments[0].texture = drawable.texture
          cursorGlyphPassDescriptor.colorAttachments[0].loadAction = .load
          cursorGlyphPassDescriptor.colorAttachments[0].storeAction = .store
          if let cursorGlyphEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: cursorGlyphPassDescriptor) {
            var cursorGlyphUniforms = Uniforms(drawableSize: SIMD2(Float(drawableSize.width), Float(drawableSize.height)))
            cursorGlyphEncoder.setRenderPipelineState(glyphPipeline)
            cursorGlyphEncoder.setVertexBuffer(cursorGlyphBuffer, offset: 0, index: 0)
            withUnsafeBytes(of: &cursorGlyphUniforms) { bytes in
              cursorGlyphEncoder.setVertexBytes(bytes.baseAddress!, length: bytes.count, index: 1)
            }
            for textureSlice in cursorGlyphDraw.slices {
              cursorGlyphEncoder.setFragmentTexture(textureSlice.texture, index: 0)
              cursorGlyphEncoder.drawPrimitives(type: .triangle, vertexStart: textureSlice.vertexStart, vertexCount: textureSlice.vertexCount)
            }
            cursorGlyphEncoder.endEncoding()
          }
        }
        commandBuffer.present(drawable)
      }
    }

    previousTransientOverlayRevision = plan.transientOverlayRevision

    let generation = completionBox.submit(renderFrame.generation)
    if shouldWait {
      commandBuffer.commit()
      commandBuffer.waitUntilCompleted()
      completionBox.complete(generation)
    } else {
      MetalDirectCommandCompletion.addHandler(
        to: commandBuffer,
        completionBox: completionBox,
        generation: generation,
        retainedResources: retainedResources
      )
      commandBuffer.commit()
    }

    lastRenderedRowCount = shouldRenderScene ? Set(renderCellRanges.map(\.row)).count : 0
    lastRenderedCellCount = shouldRenderScene ? renderCellRanges.reduce(0) { $0 + $1.cols.count } : 0
    lastRenderedRunCount = shouldRenderScene ? renderRowRuns.count : 0
    lastRenderPassLoadPolicy = loadPolicy
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

  private func ensureOffscreenTexture(size: CGSize) -> OffscreenTexture? {
    let width = max(1, Int(size.width.rounded(.up)))
    let height = max(1, Int(size.height.rounded(.up)))
    if let offscreenTexture, offscreenTexture.width == width, offscreenTexture.height == height {
      return OffscreenTexture(texture: offscreenTexture, didResize: false)
    }
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
    descriptor.usage = [.renderTarget, .shaderRead]
    descriptor.storageMode = .private
    guard let texture = device.makeTexture(descriptor: descriptor) else {
      return nil
    }
    offscreenTexture = texture
    return OffscreenTexture(texture: texture, didResize: true)
  }

  static func renderTargetSize(
    for plan: MetalTerminalRenderPlan,
    contentInset: CGSize
  ) -> CGSize {
    let pixelScale = plan.backingScale
    let cellSize = CGSize(
      width: plan.cellSize.width * pixelScale,
      height: plan.cellSize.height * pixelScale
    )
    let inset = CGSize(
      width: contentInset.width * pixelScale,
      height: contentInset.height * pixelScale
    )
    return CGSize(
      width: max(1, ceil(inset.width * 2 + CGFloat(plan.cols) * cellSize.width)),
      height: max(1, ceil(inset.height * 2 + CGFloat(plan.viewportRows) * cellSize.height))
    )
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

  static func offscreenOverlays(
    from overlays: [MetalOverlayPrimitive],
    drawCursorOnDrawable: Bool
  ) -> [MetalOverlayPrimitive] {
    overlays.filter { overlay in
      switch overlay.kind {
      case .selection, .linkHover, .markedText:
        return false
      case .cursor:
        return !drawCursorOnDrawable
      }
    }
  }

  static func drawableOverlays(
    from overlays: [MetalOverlayPrimitive],
    drawCursorOnDrawable: Bool
  ) -> [MetalOverlayPrimitive] {
    overlays.filter { overlay in
      switch overlay.kind {
      case .selection, .linkHover, .markedText:
        return true
      case .cursor:
        return drawCursorOnDrawable
      }
    }
  }

  static func cursorShouldDrawOnDrawable(shape: TerminalCursorShape) -> Bool {
    true
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
        let colors = TerminalColorResolver.resolvedColors(for: cell, palette: palette, isFocused: isFocused)
        let rect = CGRect(
          x: inset.width + CGFloat(col) * cellSize.width,
          y: inset.height + CGFloat(row) * cellSize.height + translationY,
          width: cellSize.width,
          height: cellSize.height
        )
        let background = (cell.inverse || !cell.usesDefaultBackground)
          ? colors.background
          : palette.background
        vertices.append(contentsOf: quadVertices(rect: rect, color: background.metalRGBA, texture: false))
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
    cursorShape: TerminalCursorShape
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
        let foreground = colors.foreground.metalRGBA
        vertices.append(contentsOf: quadVertices(
          rect: Self.glyphDrawRect(for: entry, in: rect),
          color: foreground,
          textureRect: Self.glyphTextureRect(for: entry)
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

  private func quadVertices(rect: CGRect, color: SIMD4<Float>, texture: Bool) -> [Vertex] {
    quadVertices(
      rect: rect,
      color: color,
      textureRect: texture ? CGRect(x: 0, y: 0, width: 1, height: 1) : nil
    )
  }

  private func quadVertices(rect: CGRect, color: SIMD4<Float>, textureRect: CGRect?) -> [Vertex] {
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
      Vertex(position: tl, color: color, texCoord: textureRect == nil ? zero : uvtl),
      Vertex(position: tr, color: color, texCoord: textureRect == nil ? zero : uvtr),
      Vertex(position: bl, color: color, texCoord: textureRect == nil ? zero : uvbl),
      Vertex(position: bl, color: color, texCoord: textureRect == nil ? zero : uvbl),
      Vertex(position: tr, color: color, texCoord: textureRect == nil ? zero : uvtr),
      Vertex(position: br, color: color, texCoord: textureRect == nil ? zero : uvbr),
    ]
  }

  private func drawTranslationY(topOverscanRows: Int, pixelRemainderY: CGFloat, cellHeight: CGFloat) -> CGFloat {
    -CGFloat(topOverscanRows) * cellHeight + pixelRemainderY
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
  };

  struct VertexOut {
    float4 position [[position]];
    float4 color;
    float2 texCoord;
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
    float alpha = texture0.sample(s, in.texCoord).a;
    return float4(in.color.rgb, in.color.a * alpha);
  }

  fragment float4 metal_direct_composite_fragment(
    VertexOut in [[stage_in]],
    texture2d<float> texture0 [[texture(0)]]
  ) {
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::nearest);
    return texture0.sample(s, in.texCoord);
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

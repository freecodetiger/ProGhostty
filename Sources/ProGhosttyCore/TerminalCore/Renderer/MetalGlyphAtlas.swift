import AppKit
import CoreText
import Foundation
import MetalKit

public struct MetalGlyphStyle: Equatable, Hashable, Sendable {
  public var bold: Bool
  public var italic: Bool
  public var underline: Bool

  public init(bold: Bool = false, italic: Bool = false, underline: Bool = false) {
    self.bold = bold
    self.italic = italic
    self.underline = underline
  }

  public static let regular = MetalGlyphStyle()
}

public struct MetalGlyphAtlasEntry: Equatable, Sendable {
  public let id: Int
  public let generation: Int
  public let scalar: String
  public let style: MetalGlyphStyle
  public let bitmapSize: CGSize
  public let inkBounds: CGRect
  public let drawOffset: CGPoint
  public let drawSize: CGSize

  public init(
    id: Int,
    generation: Int,
    scalar: String,
    style: MetalGlyphStyle,
    bitmapSize: CGSize,
    inkBounds: CGRect,
    drawOffset: CGPoint? = nil,
    drawSize: CGSize? = nil
  ) {
    self.id = id
    self.generation = generation
    self.scalar = scalar
    self.style = style
    self.bitmapSize = bitmapSize
    self.inkBounds = inkBounds
    self.drawOffset = drawOffset ?? inkBounds.origin
    self.drawSize = drawSize ?? inkBounds.size
  }
}

@MainActor
public final class MetalGlyphAtlas {
  private struct GlyphKey: Hashable {
    var scalar: String
    var fontFamily: String
    var cjkFallbackFamily: String?
    var fontSize: CGFloat
    var backingScale: CGFloat
    var style: MetalGlyphStyle
  }

  private struct RenderedGlyph {
    var image: CGImage
    var bitmapSize: CGSize
    var inkBounds: CGRect
    var drawOffset: CGPoint
    var drawSize: CGSize
  }

  private var fontFamily: String
  private var cjkFallbackFamily: String?
  private var fontSize: CGFloat
  private var backingScale: CGFloat
  private var entries: [GlyphKey: MetalGlyphAtlasEntry] = [:]
  private var renderedGlyphs: [GlyphKey: RenderedGlyph] = [:]
  private var nextID = 0
  private var generation = 0

  public init(fontFamily: String, fontSize: CGFloat, backingScale: CGFloat, cjkFallbackFamily: String? = nil) {
    self.fontFamily = fontFamily
    self.cjkFallbackFamily = Self.normalizedFontFamily(cjkFallbackFamily)
    self.fontSize = fontSize
    self.backingScale = backingScale
  }

  public var entryCount: Int {
    entries.count
  }

  public func applyFont(family: String, size: CGFloat, cjkFallbackFamily: String? = nil) {
    let normalizedCJKFallback = Self.normalizedFontFamily(cjkFallbackFamily)
    guard fontFamily != family || fontSize != size || self.cjkFallbackFamily != normalizedCJKFallback else { return }
    fontFamily = family
    self.cjkFallbackFamily = normalizedCJKFallback
    fontSize = size
    invalidate()
  }

  public func applyBackingScale(_ scale: CGFloat) {
    guard backingScale != scale else { return }
    backingScale = scale
    invalidate()
  }

  public func entry(for scalar: String, style: MetalGlyphStyle = .regular) -> MetalGlyphAtlasEntry {
    let key = GlyphKey(
      scalar: scalar,
      fontFamily: fontFamily,
      cjkFallbackFamily: cjkFallbackFamily,
      fontSize: fontSize,
      backingScale: backingScale,
      style: style
    )
    if let entry = entries[key] {
      return entry
    }

    let glyph = renderedGlyph(for: scalar, style: style)
    let entry = MetalGlyphAtlasEntry(
      id: nextID,
      generation: generation,
      scalar: scalar,
      style: style,
      bitmapSize: glyph?.bitmapSize ?? .zero,
      inkBounds: glyph?.inkBounds ?? .zero,
      drawOffset: glyph?.drawOffset ?? .zero,
      drawSize: glyph?.drawSize ?? .zero
    )
    nextID += 1
    entries[key] = entry
    return entry
  }

  public func renderedImage(for scalar: String, style: MetalGlyphStyle = .regular) -> CGImage? {
    let key = GlyphKey(
      scalar: scalar,
      fontFamily: fontFamily,
      cjkFallbackFamily: cjkFallbackFamily,
      fontSize: fontSize,
      backingScale: backingScale,
      style: style
    )
    return renderedGlyph(for: key)?.image
  }

  private func renderedGlyph(for scalar: String, style: MetalGlyphStyle = .regular) -> RenderedGlyph? {
    let key = GlyphKey(
      scalar: scalar,
      fontFamily: fontFamily,
      cjkFallbackFamily: cjkFallbackFamily,
      fontSize: fontSize,
      backingScale: backingScale,
      style: style
    )
    return renderedGlyph(for: key)
  }

  private func renderedGlyph(for key: GlyphKey) -> RenderedGlyph? {
    if let glyph = renderedGlyphs[key] {
      return glyph
    }
    let glyph = Self.renderedGlyph(
      for: key.scalar,
      fontFamily: key.fontFamily,
      cjkFallbackFamily: key.cjkFallbackFamily,
      fontSize: key.fontSize,
      backingScale: key.backingScale,
      style: key.style
    )
    renderedGlyphs[key] = glyph
    return glyph
  }

  public var renderCellSize: CGSize {
    Self.renderCellSize(fontFamily: fontFamily, fontSize: fontSize, backingScale: backingScale)
  }

  private func invalidate() {
    entries.removeAll(keepingCapacity: true)
    renderedGlyphs.removeAll(keepingCapacity: true)
    generation += 1
  }

  private static func renderCellSize(
    fontFamily: String,
    fontSize: CGFloat,
    backingScale: CGFloat
  ) -> CGSize {
    pixelSize(
      for: logicalCellSize(fontFamily: fontFamily, fontSize: fontSize),
      backingScale: backingScale
    )
  }

  private static func logicalCellSize(
    fontFamily: String,
    fontSize: CGFloat
  ) -> CGSize {
    let font = NSFont(name: fontFamily, size: fontSize)
      ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
    let width = max(1, ceil(("W" as NSString).size(withAttributes: [.font: font]).width))
    let height = max(1, ceil(font.ascender - font.descender + font.leading))
    return CGSize(width: width, height: height)
  }

  private static func pixelSize(for logicalSize: CGSize, backingScale: CGFloat) -> CGSize {
    CGSize(
      width: max(1, ceil(logicalSize.width * backingScale)),
      height: max(1, ceil(logicalSize.height * backingScale))
    )
  }

  private static func renderedGlyph(
    for scalar: String,
    fontFamily: String,
    cjkFallbackFamily: String?,
    fontSize: CGFloat,
    backingScale: CGFloat,
    style: MetalGlyphStyle
  ) -> RenderedGlyph? {
    let renderFontFamily = glyphFontFamily(
      for: scalar,
      primaryFamily: fontFamily,
      cjkFallbackFamily: cjkFallbackFamily,
      fontSize: fontSize
    )
    if let glyph = coreTextRenderedGlyph(
      for: scalar,
      fontFamily: fontFamily,
      renderFontFamily: renderFontFamily,
      fontSize: fontSize,
      backingScale: backingScale,
      style: style
    ) {
      return glyph
    }
    return fallbackRenderedGlyph(
      for: scalar,
      fontFamily: fontFamily,
      renderFontFamily: renderFontFamily,
      fontSize: fontSize,
      backingScale: backingScale,
      style: style
    )
  }

  private static func coreTextRenderedGlyph(
    for scalar: String,
    fontFamily: String,
    renderFontFamily: String,
    fontSize: CGFloat,
    backingScale: CGFloat,
    style: MetalGlyphStyle
  ) -> RenderedGlyph? {
    let nsString = scalar as NSString
    guard nsString.length == 1 || nsString.length == 2 else { return nil }

    let scale = max(1, backingScale)
    let pointFont = font(family: renderFontFamily, size: fontSize, bold: style.bold)
    let pixelFont = font(family: renderFontFamily, size: fontSize * scale, bold: style.bold)
    let baseCTFont = CTFontCreateWithName(pixelFont.fontName as CFString, fontSize * scale, nil)
    let ctFont = CTFontCreateForString(
      baseCTFont,
      scalar as CFString,
      CFRange(location: 0, length: nsString.length)
    )
    var characters = (0..<nsString.length).map { UniChar(nsString.character(at: $0)) }
    var glyphs = [CGGlyph](repeating: 0, count: nsString.length)
    guard CTFontGetGlyphsForCharacters(ctFont, &characters, &glyphs, nsString.length) else {
      return nil
    }
    guard let glyph = glyphs.first, glyph != 0, glyphs.dropFirst().allSatisfy({ $0 == 0 }) else {
      return nil
    }

    var measuredGlyph = glyph
    var bounds = CTFontGetBoundingRectsForGlyphs(ctFont, .horizontal, &measuredGlyph, nil, 1)
    if style.italic {
      let skewPadding = ceil(bounds.height * 0.18)
      bounds.origin.x -= skewPadding * 0.5
      bounds.size.width += skewPadding
    }
    guard bounds.width >= 0.25, bounds.height >= 0.25 else {
      return nil
    }

    let logicalSize = logicalCellSize(fontFamily: fontFamily, fontSize: fontSize)
    let cellSize = pixelSize(for: logicalSize, backingScale: scale)
    let topPadding = max(0, pointFont.leading) * 0.5
    let baselineFromTop = (topPadding + pointFont.ascender) * scale
    let baselineFromBottom = max(0, cellSize.height - baselineFromTop)

    var cellBounds = CGRect(
      x: bounds.origin.x,
      y: bounds.origin.y + baselineFromBottom,
      width: bounds.width,
      height: bounds.height
    )
    if style.underline {
      let underlineThickness = max(1, ceil(CTFontGetUnderlineThickness(ctFont)))
      let underlineY = baselineFromBottom + CTFontGetUnderlinePosition(ctFont) - underlineThickness * 0.5
      let underlineBounds = CGRect(
        x: 0,
        y: floor(underlineY),
        width: cellSize.width,
        height: underlineThickness
      )
      cellBounds = cellBounds.union(underlineBounds)
    }

    let padding: CGFloat = 0
    let pixelX = floor(cellBounds.minX) - padding
    let pixelY = floor(cellBounds.minY) - padding
    let fractionX = cellBounds.minX - floor(cellBounds.minX)
    let fractionY = cellBounds.minY - floor(cellBounds.minY)
    let width = max(1, Int(ceil(cellBounds.width + fractionX + padding * 2)))
    let height = max(1, Int(ceil(cellBounds.height + fractionY + padding * 2)))
    let bitmapSize = CGSize(width: width, height: height)

    guard let context = CGContext(
      data: nil,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: width * 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
      return nil
    }

    context.clear(CGRect(x: 0, y: 0, width: width, height: height))
    context.setAllowsFontSmoothing(true)
    context.setShouldSmoothFonts(false)
    context.setAllowsFontSubpixelPositioning(true)
    context.setShouldSubpixelPositionFonts(true)
    context.setAllowsFontSubpixelQuantization(false)
    context.setShouldSubpixelQuantizeFonts(false)
    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)
    context.setFillColor(NSColor.white.cgColor)
    context.setStrokeColor(NSColor.white.cgColor)
    context.textMatrix = .identity
    context.translateBy(x: -pixelX, y: -pixelY)
    if style.italic {
      context.concatenate(CGAffineTransform(a: 1, b: 0, c: -0.18, d: 1, tx: 0, ty: 0))
    }
    var drawGlyph = glyph
    var position = CGPoint(x: 0, y: baselineFromBottom)
    CTFontDrawGlyphs(ctFont, &drawGlyph, &position, 1, context)
    if style.underline {
      let underlineThickness = max(1, ceil(CTFontGetUnderlineThickness(ctFont)))
      let underlineY = floor(baselineFromBottom + CTFontGetUnderlinePosition(ctFont) - underlineThickness * 0.5)
      context.fill(CGRect(x: 0, y: underlineY, width: cellSize.width, height: underlineThickness))
    }
    guard let image = context.makeImage() else { return nil }

    let drawOffset = CGPoint(
      x: pixelX,
      y: cellSize.height - (pixelY + CGFloat(height))
    )
    return RenderedGlyph(
      image: image,
      bitmapSize: bitmapSize,
      inkBounds: alphaBounds(in: image) ?? CGRect(origin: .zero, size: bitmapSize),
      drawOffset: drawOffset,
      drawSize: bitmapSize
    )
  }

  private static func fallbackRenderedGlyph(
    for scalar: String,
    fontFamily: String,
    renderFontFamily: String,
    fontSize: CGFloat,
    backingScale: CGFloat,
    style: MetalGlyphStyle
  ) -> RenderedGlyph? {
    let font = font(family: renderFontFamily, size: fontSize, bold: style.bold)
    let logicalSize = logicalCellSize(fontFamily: fontFamily, fontSize: fontSize)
    let pixelSize = pixelSize(for: logicalSize, backingScale: backingScale)
    let width = max(1, Int(pixelSize.width))
    let height = max(1, Int(pixelSize.height))
    guard
      let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: width,
        pixelsHigh: height,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
      )
    else {
      return nil
    }
    rep.size = logicalSize

    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }

    guard let context = NSGraphicsContext(bitmapImageRep: rep) else {
      return nil
    }
    NSGraphicsContext.current = context
    NSColor.clear.setFill()
    NSBezierPath(rect: NSRect(origin: .zero, size: logicalSize)).fill()

    var attributes: [NSAttributedString.Key: Any] = [
      .font: font,
      .foregroundColor: NSColor.white,
    ]
    if style.italic {
      attributes[.obliqueness] = 0.18
    }
    if style.underline {
      attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
    }
    let baseline = max(0, (logicalSize.height - font.ascender + font.descender) * 0.5)
    (scalar as NSString).draw(
      at: NSPoint(x: 0, y: baseline),
      withAttributes: attributes
    )
    guard let image = rep.cgImage else { return nil }
    return RenderedGlyph(
      image: image,
      bitmapSize: pixelSize,
      inkBounds: alphaBounds(in: image) ?? CGRect(origin: .zero, size: pixelSize),
      drawOffset: .zero,
      drawSize: pixelSize
    )
  }

  private static func alphaBounds(in image: CGImage) -> CGRect? {
    let width = image.width
    let height = image.height
    guard width > 0, height > 0 else { return nil }
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    guard let context = CGContext(
      data: &bytes,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: width * 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
      return nil
    }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

    var minX = width
    var minY = height
    var maxX = -1
    var maxY = -1
    for y in 0..<height {
      for x in 0..<width {
        let alpha = bytes[(y * width + x) * 4 + 3]
        guard alpha > 0 else { continue }
        minX = min(minX, x)
        minY = min(minY, y)
        maxX = max(maxX, x)
        maxY = max(maxY, y)
      }
    }
    guard maxX >= minX, maxY >= minY else { return nil }
    return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
  }

  private static func font(family: String, size: CGFloat, bold: Bool) -> NSFont {
    if let named = NSFont(name: family, size: size) {
      if bold {
        return NSFontManager.shared.convert(named, toHaveTrait: .boldFontMask)
      }
      return named
    }
    return NSFont.monospacedSystemFont(ofSize: size, weight: bold ? .semibold : .regular)
  }

  private static func glyphFontFamily(
    for scalar: String,
    primaryFamily: String,
    cjkFallbackFamily: String?,
    fontSize: CGFloat
  ) -> String {
    guard
      FontManager.containsCJK(scalar),
      let cjkFallbackFamily,
      NSFont(name: cjkFallbackFamily, size: fontSize) != nil
    else {
      return primaryFamily
    }
    return cjkFallbackFamily
  }

  private static func normalizedFontFamily(_ family: String?) -> String? {
    guard let trimmed = family?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
      return nil
    }
    return trimmed
  }
}

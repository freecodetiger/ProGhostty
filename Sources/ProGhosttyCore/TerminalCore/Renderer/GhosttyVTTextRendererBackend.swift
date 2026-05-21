import AppKit
import Foundation

@MainActor
public final class GhosttyVTTextRendererBackend: TerminalRendererBackend {
  let scrollView: NSScrollView
  let textView: PTYTextView
  private var palette: TerminalSurfacePalette
  private var fontFamily: String
  private var fontSize: CGFloat
  private var isFocused = true
  private var diagnosticsState = TerminalRendererDiagnostics(backend: .ghosttyVTTextFallback)

  public init(
    palette: TerminalSurfacePalette = .dark,
    fontFamily: String = FontManager.defaultMonospacedFontName(),
    fontSize: CGFloat = 14
  ) {
    self.palette = palette
    self.fontFamily = fontFamily
    self.fontSize = fontSize
    textView = PTYTextView()
    textView.isEditable = false
    textView.isSelectable = true
    textView.font = NSFont(name: fontFamily, size: fontSize) ?? .monospacedSystemFont(ofSize: fontSize, weight: .regular)
    textView.autoresizingMask = [.width, .height]
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.minSize = NSSize(width: 0, height: 0)
    textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    textView.textContainer?.widthTracksTextView = true
    textView.textContainer?.heightTracksTextView = false
    textView.textContainerInset = NSSize(width: 14, height: 12)
    TerminalSurfaceStyle.configureTextView(textView, palette: palette)

    scrollView = NSScrollView()
    TerminalSurfaceStyle.configureScrollView(scrollView, backgroundColor: palette.background)
    scrollView.documentView = textView
    textView.scrollToBottomHandler = { [weak textView] in
      textView?.scrollToEndOfDocument(nil)
    }
  }

  public var view: NSView { scrollView }
  public var diagnostics: TerminalRendererDiagnostics { diagnosticsState }

  public var selectedText: String? {
    let range = textView.selectedRange()
    guard range.length > 0 else { return nil }
    return (textView.string as NSString).substring(with: range)
  }

  public var isScrolledToBottom: Bool {
    guard let documentView = scrollView.documentView else { return true }
    let visibleMaxY = scrollView.contentView.bounds.maxY
    let documentMaxY = documentView.bounds.maxY
    return documentMaxY - visibleMaxY < 2
  }

  public func setInputHandler(_ handler: ((Data) -> Void)?) {
    textView.inputHandler = handler
  }

  public func setActivationHandler(_ handler: (() -> Void)?) {
    textView.activationHandler = handler
  }

  public func applyPalette(_ palette: TerminalSurfacePalette) {
    self.palette = palette
    TerminalSurfaceStyle.configureTextView(textView, palette: palette)
    TerminalSurfaceStyle.configureScrollView(scrollView, backgroundColor: palette.background)
    diagnosticsState.redrawMode = .full
  }

  public func applyFont(family: String, size: CGFloat) {
    fontFamily = family
    fontSize = size
    textView.font = terminalFont(weight: .regular)
    textView.window?.invalidateCursorRects(for: textView)
    diagnosticsState.redrawMode = .full
  }

  public func setFocused(_ isFocused: Bool) {
    self.isFocused = isFocused
    diagnosticsState.redrawMode = .full
  }

  public func render(frame: GhosttyTerminalFrame) {
    let attributed = TerminalAttributedRenderer(
      fontFamily: fontFamily,
      fontSize: fontSize,
      palette: palette,
      isFocused: isFocused
    )
    .attributedString(for: frame)
    replaceText(with: attributed, scrollToEnd: isScrolledToBottom)
    diagnosticsState.backend = .ghosttyVTTextFallback
    diagnosticsState.dirtyRowCount = frame.rows
    diagnosticsState.visibleRowCount = frame.rows
    diagnosticsState.redrawMode = .full
    diagnosticsState.alternateScreenActive = frame.isAlternateScreen
  }

  public func focus() {
    textView.window?.makeFirstResponder(textView)
  }

  public func render(attributed: NSAttributedString, scrollToEnd: Bool) {
    replaceText(with: attributed, scrollToEnd: scrollToEnd)
    diagnosticsState.backend = .ghosttyVTTextFallback
    diagnosticsState.dirtyRowCount = 1
    diagnosticsState.visibleRowCount = max(1, Int(ceil(scrollView.contentView.bounds.height / max(1, textView.font?.lineHeight ?? 1))))
    diagnosticsState.redrawMode = .full
  }

  public func render(plainText text: String) {
    let attributed = NSAttributedString(string: text, attributes: [
      .font: terminalFont(weight: .regular),
      .foregroundColor: palette.foreground,
      .backgroundColor: palette.background,
    ])
    replaceText(with: attributed, scrollToEnd: isScrolledToBottom)
    diagnosticsState.backend = .ghosttyVTTextFallback
    diagnosticsState.redrawMode = .full
  }

  public func markResizePending() {
    diagnosticsState.pendingResize = true
  }

  public func applyResizeDiagnostics(_ diagnostics: TerminalResizeDiagnostics) {
    diagnosticsState.pendingResize = false
    diagnosticsState.lastResizeTotalDuration = diagnostics.totalDuration
    diagnosticsState.lastResizeVTDuration = diagnostics.vtDuration
    diagnosticsState.lastResizeSnapshotDuration = diagnostics.snapshotDuration
  }

  private func replaceText(with attributed: NSAttributedString, scrollToEnd: Bool) {
    let previousOrigin = scrollView.contentView.bounds.origin
    let previousCursorMinY = scrollToEnd ? cursorDocumentMinY() : nil
    if let textStorage = textView.textStorage {
      TerminalAttributedDiff.apply(attributed, to: textStorage)
    } else {
      textView.textStorage?.setAttributedString(attributed)
    }
    textView.window?.invalidateCursorRects(for: textView)
    if scrollToEnd {
      if
        let previousCursorMinY,
        let nextCursorMinY = cursorDocumentMinY(),
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

  private func cursorDocumentMinY() -> CGFloat? {
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

  private func terminalFont(weight: NSFont.Weight) -> NSFont {
    if let named = NSFont(name: fontFamily, size: fontSize) {
      if weight == .semibold {
        return NSFontManager.shared.convert(named, toHaveTrait: .boldFontMask)
      }
      return named
    }
    return NSFont.monospacedSystemFont(ofSize: fontSize, weight: weight)
  }
}

private extension NSFont {
  var lineHeight: CGFloat {
    max(1, ceil(ascender - descender + leading))
  }
}

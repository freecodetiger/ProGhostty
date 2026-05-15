import AppKit

public enum TerminalSurfaceStyle {
  @MainActor
  public static func configureScrollView(_ scrollView: NSScrollView, backgroundColor: NSColor) {
    scrollView.hasVerticalScroller = false
    scrollView.hasHorizontalScroller = false
    scrollView.verticalScroller = nil
    scrollView.horizontalScroller = nil
    scrollView.autohidesScrollers = true
    scrollView.drawsBackground = true
    scrollView.borderType = .noBorder
    scrollView.scrollerStyle = .overlay
    scrollView.backgroundColor = backgroundColor
    scrollView.contentView.drawsBackground = false
  }
}

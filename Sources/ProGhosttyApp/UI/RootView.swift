import AppKit
import ProGhosttyCore
import SwiftUI

struct RootView: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    ZStack(alignment: .topTrailing) {
      TerminalCanvasView()
        .blur(radius: model.isWorkspaceSwitcherPresented
          ? ProGhosttyOverlayStyle.workspaceSwitcherTerminalBlurRadius
          : 0)

      if model.isWorkspaceSwitcherPresented {
        WorkspaceSwitcherView()
          .environmentObject(model)
          .transition(.opacity.combined(with: .scale(scale: 0.98)))
      }

      TerminalNotificationOverlay(
        notification: model.inAppNotification,
        usesDarkAppearance: model.usesDarkAppearance,
        action: { model.openInAppNotificationAction() }
      )

    }
    .animation(.easeOut(duration: 0.12), value: model.isWorkspaceSwitcherPresented)
    .animation(.easeOut(duration: 0.14), value: model.titlebarToast)
    .animation(.easeOut(duration: 0.16), value: model.inAppNotification)
    .preferredColorScheme(model.appColorScheme)
    .background(Color(nsColor: model.terminalBackgroundColor).ignoresSafeArea())
    .background(
      WorkspaceTitlebarView(
        title: model.activeTitlebarLabel,
        tooltip: model.activeTitlebarTooltip,
        subtitle: model.activePaneTitlebarLabel,
        subtitleTooltip: model.activePaneTitlebarTooltip,
        backgroundColor: model.terminalBackgroundColor,
        usesDarkAppearance: model.usesDarkAppearance,
        toast: model.titlebarToast,
        onWorkspaceSwitcher: { model.openWorkspaceSwitcher() },
        onToastClick: { model.openTitlebarToastAction() }
      )
      .frame(width: 0, height: 0)
    )
    .background(
      TerminalChromeSyncView(
        backgroundColor: model.terminalBackgroundColor,
        usesDarkAppearance: model.usesDarkAppearance,
        syncToken: terminalChromeSyncToken
      )
      .frame(width: 0, height: 0)
    )
    .background(
      TerminalShortcutHost(
        closePaneBinding: model.settings.keyboardShortcuts.shortcut(for: .closePane),
        sideInputBinding: model.settings.keyboardShortcuts.shortcut(for: .sideInput),
        onClosePane: { model.closeSelectedPane() },
        onOpenSideInput: { model.openSideInput() }
      )
      .frame(width: 0, height: 0)
    )
    .background(
      TerminalWindowResizeGuard(
        minimumContentSize: {
          guard let runtime = model.activeWorkspace else {
            return NSSize(
              width: ProGhosttyWindowSizing.minimumContentWidth,
              height: ProGhosttyWindowSizing.minimumContentHeight
            )
          }
          let minimum = SplitRatioLayout.windowMinimumContentSize(
            for: runtime.layout.root,
            baseWidth: ProGhosttyWindowSizing.minimumContentWidth,
            baseHeight: ProGhosttyWindowSizing.minimumContentHeight
          )
          return NSSize(width: minimum.width, height: minimum.height)
        }
      )
      .frame(width: 0, height: 0)
    )
    .onAppear {
      model.activateMainWindowAndFocusTerminal()
    }
  }

  private var terminalChromeSyncToken: Int {
    var hasher = Hasher()
    hasher.combine(model.isWorkspaceSwitcherPresented)
    hasher.combine(model.titlebarToast?.message)
    hasher.combine(String(describing: model.titlebarToast?.style))
    hasher.combine(String(describing: model.titlebarToast?.lifetime))
    hasher.combine(model.usesDarkAppearance)
    hasher.combine(model.terminalBackgroundColor.rgbSignature)
    return hasher.finalize()
  }
}

private struct TerminalNotificationOverlay: View {
  let notification: AppModel.InAppNotification?
  let usesDarkAppearance: Bool
  let action: () -> Void

  var body: some View {
    Group {
      if let notification {
        Button(action: action) {
          HStack(alignment: .top, spacing: 10) {
            Image(systemName: "bell.badge")
              .font(.system(size: 15, weight: .semibold))
              .foregroundStyle(accentColor)
              .frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: 4) {
              Text(notification.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(primaryTextColor)
                .lineLimit(1)
                .truncationMode(.tail)
              Text(notification.body)
                .font(.system(size: 12))
                .foregroundStyle(secondaryTextColor)
                .lineLimit(2)
                .truncationMode(.tail)
            }
          }
          .padding(.horizontal, 12)
          .padding(.vertical, 10)
          .frame(width: 300, alignment: .leading)
          .background(backgroundColor)
          .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
          .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
              .stroke(borderColor, lineWidth: 1)
          )
          .shadow(color: Color.black.opacity(usesDarkAppearance ? 0.32 : 0.14), radius: 12, x: 0, y: 8)
        }
        .buttonStyle(.plain)
        .padding(.top, 42)
        .padding(.trailing, 14)
        .transition(.move(edge: .top).combined(with: .opacity))
        .accessibilityLabel("\(notification.title): \(notification.body)")
      }
    }
    .allowsHitTesting(notification != nil)
  }

  private var backgroundColor: Color {
    usesDarkAppearance
      ? Color(nsColor: NSColor(calibratedWhite: 0.10, alpha: 0.96))
      : Color(nsColor: NSColor(calibratedWhite: 0.98, alpha: 0.98))
  }

  private var borderColor: Color {
    usesDarkAppearance
      ? Color.white.opacity(0.14)
      : Color.black.opacity(0.12)
  }

  private var primaryTextColor: Color {
    usesDarkAppearance ? Color.white.opacity(0.94) : Color.black.opacity(0.88)
  }

  private var secondaryTextColor: Color {
    usesDarkAppearance ? Color.white.opacity(0.68) : Color.black.opacity(0.62)
  }

  private var accentColor: Color {
    usesDarkAppearance
      ? Color(red: 0.64, green: 0.86, blue: 0.82)
      : Color(red: 0.05, green: 0.42, blue: 0.48)
  }
}

private struct TerminalWindowResizeGuard: NSViewRepresentable {
  var minimumContentSize: () -> NSSize

  func makeCoordinator() -> Coordinator {
    Coordinator(minimumContentSize: minimumContentSize)
  }

  func makeNSView(context: Context) -> WindowView {
    let view = WindowView()
    view.resizeDelegate = context.coordinator
    return view
  }

  func updateNSView(_ view: WindowView, context: Context) {
    context.coordinator.minimumContentSize = minimumContentSize
    view.resizeDelegate = context.coordinator
    view.installResizeDelegate()
  }

  static func dismantleNSView(_ view: WindowView, coordinator: Coordinator) {
    if view.window?.delegate === coordinator {
      view.window?.delegate = nil
    }
  }

  final class WindowView: NSView {
    weak var resizeDelegate: NSWindowDelegate?

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      installResizeDelegate()
    }

    func installResizeDelegate() {
      guard let window, let resizeDelegate else { return }
      window.delegate = resizeDelegate
    }
  }

  final class Coordinator: NSObject, NSWindowDelegate {
    var minimumContentSize: () -> NSSize

    init(minimumContentSize: @escaping () -> NSSize) {
      self.minimumContentSize = minimumContentSize
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
      let contentMinimum = minimumContentSize()
      sender.contentMinSize = contentMinimum
      let frameMinimum = sender.frameRect(forContentRect: NSRect(origin: .zero, size: contentMinimum)).size
      sender.minSize = frameMinimum
      return NSSize(
        width: max(frameSize.width, frameMinimum.width),
        height: max(frameSize.height, frameMinimum.height)
      )
    }
  }
}

private extension NSColor {
  var rgbSignature: String {
    let rgb = usingColorSpace(.deviceRGB) ?? self
    return String(
      format: "%.4f:%.4f:%.4f:%.4f",
      rgb.redComponent,
      rgb.greenComponent,
      rgb.blueComponent,
      rgb.alphaComponent
    )
  }
}

private struct TerminalShortcutHost: NSViewRepresentable {
  let closePaneBinding: KeyboardShortcutBinding
  let sideInputBinding: KeyboardShortcutBinding
  let onClosePane: () -> Void
  let onOpenSideInput: () -> Void

  func makeNSView(context: Context) -> KeyView {
    let view = KeyView()
    view.closePaneBinding = closePaneBinding
    view.sideInputBinding = sideInputBinding
    view.onClosePane = onClosePane
    view.onOpenSideInput = onOpenSideInput
    view.installMonitor()
    return view
  }

  func updateNSView(_ view: KeyView, context: Context) {
    view.closePaneBinding = closePaneBinding
    view.sideInputBinding = sideInputBinding
    view.onClosePane = onClosePane
    view.onOpenSideInput = onOpenSideInput
    view.installMonitor()
  }

  static func dismantleNSView(_ view: KeyView, coordinator: ()) {
    view.removeMonitor()
  }

  final class KeyView: NSView {
    var closePaneBinding: KeyboardShortcutBinding?
    var sideInputBinding: KeyboardShortcutBinding?
    var onClosePane: (() -> Void)?
    var onOpenSideInput: (() -> Void)?
    private var monitor: Any?

    func installMonitor() {
      guard monitor == nil else { return }
      monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
        guard let self else { return event }
        guard NSApp.modalWindow == nil else { return event }
        guard let window, event.window === window else { return event }
        if closePaneBinding?.matches(key: event.proGhosttyShortcutKey, modifiers: event.proGhosttyShortcutModifiers) == true {
          onClosePane?()
          return nil
        }
        if sideInputBinding?.matches(key: event.proGhosttyShortcutKey, modifiers: event.proGhosttyShortcutModifiers) == true {
          onOpenSideInput?()
          return nil
        }
        return event
      }
    }

    func removeMonitor() {
      if let monitor {
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
      }
    }

    deinit {
      MainActor.assumeIsolated {
        removeMonitor()
      }
    }
  }
}

private extension NSEvent {
  var proGhosttyShortcutModifiers: Set<KeyboardShortcutModifier> {
    var result: Set<KeyboardShortcutModifier> = []
    if modifierFlags.contains(.command) {
      result.insert(.command)
    }
    if modifierFlags.contains(.control) {
      result.insert(.control)
    }
    if modifierFlags.contains(.option) {
      result.insert(.option)
    }
    if modifierFlags.contains(.shift) {
      result.insert(.shift)
    }
    return result
  }

  var proGhosttyShortcutKey: String? {
    switch keyCode {
    case 36, 76:
      return "return"
    case 48:
      return "tab"
    case 49:
      return "space"
    case 51, 117:
      return "delete"
    case 53:
      return "escape"
    case 123:
      return "leftArrow"
    case 124:
      return "rightArrow"
    case 125:
      return "downArrow"
    case 126:
      return "upArrow"
    default:
      return charactersIgnoringModifiers?.lowercased()
    }
  }
}

private struct UtilityOverlay<Content: View>: View {
  @EnvironmentObject private var model: AppModel
  let width: CGFloat
  let height: CGFloat
  var showsCloseButton = true
  let onClose: () -> Void
  @ViewBuilder var content: Content

  var body: some View {
    ZStack {
      Color.black.opacity(model.appColorScheme == .light ? 0.08 : 0.16)
        .ignoresSafeArea()
        .onTapGesture(perform: onClose)

      ZStack(alignment: .topTrailing) {
        content
          .frame(width: width, height: height)
          .background(.regularMaterial)
          .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
          .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
              .stroke(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 1)
          )
          .shadow(color: .black.opacity(0.20), radius: 24, x: 0, y: 18)

        if showsCloseButton {
          Button(action: onClose) {
            Image(systemName: "xmark.circle.fill")
              .font(.system(size: 18, weight: .medium))
              .symbolRenderingMode(.hierarchical)
              .foregroundStyle(.secondary)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .padding(12)
        }
      }
    }
  }
}

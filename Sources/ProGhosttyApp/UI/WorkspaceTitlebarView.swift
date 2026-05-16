import AppKit
import ProGhosttyCore
import SwiftUI

struct WorkspaceTitlebarView: NSViewRepresentable {
  let title: String
  let tooltip: String?
  let backgroundColor: NSColor
  let usesDarkAppearance: Bool
  let onSettings: () -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(onSettings: onSettings)
  }

  func makeNSView(context: Context) -> NSView {
    NSView(frame: .zero)
  }

  func updateNSView(_ view: NSView, context: Context) {
    context.coordinator.title = title
    context.coordinator.tooltip = tooltip
    context.coordinator.backgroundColor = backgroundColor
    context.coordinator.usesDarkAppearance = usesDarkAppearance
    context.coordinator.onSettings = onSettings

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
    var backgroundColor: NSColor = .black
    var usesDarkAppearance = true
    var onSettings: () -> Void

    private weak var installedWindow: NSWindow?
    private var accessory: NSTitlebarAccessoryViewController?
    private let button = NSButton(title: "ProGhostty", target: nil, action: nil)
    private let titlebarBackgroundView = TitlebarBackgroundView()
    private var titlebarBackgroundConstraints: [NSLayoutConstraint] = []
    private let notificationObservers = NotificationObserverBag()

    init(onSettings: @escaping () -> Void) {
      self.onSettings = onSettings
      super.init()
      titlebarBackgroundView.identifier = ProGhosttyWindowAppearance.titlebarBackgroundIdentifier
      button.target = self
      button.action = #selector(openSettings)
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
      titlebarBackgroundView.wantsLayer = true
    }

    func installIfNeeded(in window: NSWindow) {
      guard installedWindow !== window else { return }
      if let accessory, let installedWindow {
        if let index = installedWindow.titlebarAccessoryViewControllers.firstIndex(where: { $0 === accessory }) {
          installedWindow.removeTitlebarAccessoryViewController(at: index)
        }
      }

      installedWindow = window
      updateWindowAppearance(window)
      let controller = NSTitlebarAccessoryViewController()
      controller.layoutAttribute = .right
      controller.view = button
      accessory = controller
      window.addTitlebarAccessoryViewController(controller)
      installTitlebarBackground(in: window)
      installWindowObservers(for: window)
    }

    func updateTitle(in window: NSWindow) {
      window.title = title
      button.title = title
      button.toolTip = tooltip
    }

    func updateWindowAppearance(_ window: NSWindow) {
      ProGhosttyWindowAppearance.applyTerminalChrome(
        to: window,
        backgroundColor: backgroundColor,
        usesDarkAppearance: usesDarkAppearance
      )
      titlebarBackgroundView.layer?.backgroundColor = backgroundColor.cgColor
      window.isMovableByWindowBackground = false
      installTitlebarBackground(in: window)
      harmonizeTitlebarMaterials(in: window)
      keepTitlebarBackgroundOrdered(in: window)
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

      keepTitlebarBackgroundOrdered(in: window)
    }

    private func installWindowObservers(for window: NSWindow) {
      notificationObservers.removeAll()

      let notifications: [Notification.Name] = [
        NSWindow.didBecomeKeyNotification,
        NSWindow.didResignKeyNotification,
        NSWindow.didBecomeMainNotification,
        NSWindow.didResignMainNotification,
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

    private func keepTitlebarBackgroundOrdered(in window: NSWindow) {
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
        button,
      ].compactMap { $0 }

      for control in controlsToPreserve {
        guard let directChild = titlebarHost.directChild(containing: control),
          directChild !== titlebarBackgroundView
        else {
          continue
        }
        titlebarHost.addSubview(directChild, positioned: .above, relativeTo: titlebarBackgroundView)
      }
    }

    private func titlebarHost(in window: NSWindow) -> NSView? {
      window.standardWindowButton(.closeButton)?.superview
        ?? window.contentView?.superview
    }

    @objc private func openSettings() {
      onSettings()
    }
  }
}

private final class TitlebarBackgroundView: NSView {
  override func hitTest(_ point: NSPoint) -> NSView? {
    nil
  }
}

@MainActor
enum ProGhosttyWindowAppearance {
  static let titlebarBackgroundIdentifier = NSUserInterfaceItemIdentifier("ProGhosttyTitlebarBackground")

  static func applyTerminalChrome(
    to window: NSWindow,
    backgroundColor: NSColor,
    usesDarkAppearance: Bool
  ) {
    window.appearance = NSAppearance(named: usesDarkAppearance ? .darkAqua : .aqua)
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.titlebarSeparatorStyle = .none
    window.styleMask.insert(.fullSizeContentView)
    window.isOpaque = true
    window.backgroundColor = backgroundColor

    let background = backgroundColor.cgColor
    window.contentView?.wantsLayer = true
    window.contentView?.layer?.backgroundColor = background
    window.contentView?.superview?.wantsLayer = true
    window.contentView?.superview?.layer?.backgroundColor = background

    for view in window.contentView?.superview?.descendants(matchingIdentifier: titlebarBackgroundIdentifier) ?? [] {
      view.wantsLayer = true
      view.layer?.backgroundColor = background
    }
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

  func descendants(matchingIdentifier identifier: NSUserInterfaceItemIdentifier) -> [NSView] {
    var result: [NSView] = []
    for subview in subviews {
      if subview.identifier == identifier {
        result.append(subview)
      }
      result.append(contentsOf: subview.descendants(matchingIdentifier: identifier))
    }
    return result
  }
}

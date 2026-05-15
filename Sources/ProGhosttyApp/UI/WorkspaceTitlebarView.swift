import AppKit
import ProGhosttyCore
import SwiftUI

struct WorkspaceTitlebarView: NSViewRepresentable {
  let title: String
  let workspaces: [Workspace]
  let activeWorkspaceID: UUID?
  let onActivate: (UUID) -> Void
  let onOpenSwitcher: () -> Void
  let onNewWorkspace: () -> Void
  let onManageWorkspaces: () -> Void
  let onSettings: () -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(
      onActivate: onActivate,
      onOpenSwitcher: onOpenSwitcher,
      onNewWorkspace: onNewWorkspace,
      onManageWorkspaces: onManageWorkspaces,
      onSettings: onSettings
    )
  }

  func makeNSView(context: Context) -> NSView {
    NSView(frame: .zero)
  }

  func updateNSView(_ view: NSView, context: Context) {
    context.coordinator.title = title
    context.coordinator.workspaces = workspaces
    context.coordinator.activeWorkspaceID = activeWorkspaceID
    context.coordinator.onActivate = onActivate
    context.coordinator.onOpenSwitcher = onOpenSwitcher
    context.coordinator.onNewWorkspace = onNewWorkspace
    context.coordinator.onManageWorkspaces = onManageWorkspaces
    context.coordinator.onSettings = onSettings

    DispatchQueue.main.async {
      guard let window = view.window else { return }
      context.coordinator.installIfNeeded(in: window)
      context.coordinator.updateTitle(in: window)
    }
  }

  @MainActor final class Coordinator: NSObject {
    var title: String = "ProGhostty"
    var workspaces: [Workspace] = []
    var activeWorkspaceID: UUID?
    var onActivate: (UUID) -> Void
    var onOpenSwitcher: () -> Void
    var onNewWorkspace: () -> Void
    var onManageWorkspaces: () -> Void
    var onSettings: () -> Void

    private weak var installedWindow: NSWindow?
    private var accessory: NSTitlebarAccessoryViewController?
    private let button = NSButton(title: "ProGhostty", target: nil, action: nil)

    init(
      onActivate: @escaping (UUID) -> Void,
      onOpenSwitcher: @escaping () -> Void,
      onNewWorkspace: @escaping () -> Void,
      onManageWorkspaces: @escaping () -> Void,
      onSettings: @escaping () -> Void
    ) {
      self.onActivate = onActivate
      self.onOpenSwitcher = onOpenSwitcher
      self.onNewWorkspace = onNewWorkspace
      self.onManageWorkspaces = onManageWorkspaces
      self.onSettings = onSettings
      super.init()
      button.target = self
      button.action = #selector(showMenu)
      button.bezelStyle = .inline
      button.isBordered = false
      button.font = .systemFont(ofSize: 12, weight: .medium)
      button.contentTintColor = .secondaryLabelColor
      button.setContentHuggingPriority(.required, for: .horizontal)
    }

    func installIfNeeded(in window: NSWindow) {
      guard installedWindow !== window else { return }
      if let accessory, let installedWindow {
        if let index = installedWindow.titlebarAccessoryViewControllers.firstIndex(where: { $0 === accessory }) {
          installedWindow.removeTitlebarAccessoryViewController(at: index)
        }
      }

      installedWindow = window
      let controller = NSTitlebarAccessoryViewController()
      controller.layoutAttribute = .right
      controller.view = button
      accessory = controller
      window.addTitlebarAccessoryViewController(controller)
    }

    func updateTitle(in window: NSWindow) {
      window.title = title
      button.title = title
    }

    @objc private func showMenu() {
      let menu = NSMenu()
      menu.addItem(TitlebarMenuItem(title: "Switch Workspace...") { [weak self] in
        self?.onOpenSwitcher()
      })
      menu.addItem(TitlebarMenuItem(title: "New Workspace") { [weak self] in
        self?.onNewWorkspace()
      })

      if !workspaces.isEmpty {
        menu.addItem(.separator())
        for workspace in workspaces {
          let item = TitlebarMenuItem(title: workspace.name) { [weak self] in
            self?.onActivate(workspace.id)
          }
          item.state = workspace.id == activeWorkspaceID ? .on : .off
          menu.addItem(item)
        }
      }

      menu.addItem(.separator())
      menu.addItem(TitlebarMenuItem(title: "Manage Workspaces...") { [weak self] in
        self?.onManageWorkspaces()
      })
      menu.addItem(TitlebarMenuItem(title: "Settings...") { [weak self] in
        self?.onSettings()
      })

      menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY + 4), in: button)
    }
  }
}

@MainActor private final class TitlebarMenuItem: NSMenuItem {
  private let handler: () -> Void

  init(title: String, handler: @escaping () -> Void) {
    self.handler = handler
    super.init(title: title, action: #selector(run), keyEquivalent: "")
    target = self
  }

  required init(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  @objc private func run() {
    handler()
  }
}

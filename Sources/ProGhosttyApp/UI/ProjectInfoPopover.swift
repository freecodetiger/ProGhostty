import AppKit
import ProGhosttyCore

/// Titlebar project-info panel — a dashboard of the active pane's project: git
/// branch, dirty state, latest commit, ahead/behind, remote. Independent from
/// the in-terminal file popover (different data, anchor, module). Opens instantly
/// with the path, then fills git info once the async fetch returns.
@MainActor
final class ProjectInfoPopover {
  private var popover: NSPopover?
  private var controller: ProjectInfoPopoverController?

  struct Callbacks {
    var openRemote: (URL) -> Void
    var copyPath: (String) -> Void
    var revealInFinder: (String) -> Void
  }

  /// Show the panel anchored at `anchor` in `view`, seeded with `initial` (path +
  /// "loading"), then call `load` off-main and fill the result in.
  func present(
    initial: ProjectInfo,
    anchor: NSRect,
    in view: NSView,
    palette: TerminalSurfacePalette,
    usesDarkAppearance: Bool,
    text: AppText,
    callbacks: Callbacks,
    load: @escaping () -> ProjectInfo
  ) {
    guard view.window != nil else { return }
    dismiss()
    let controller = ProjectInfoPopoverController(
      info: initial, isLoading: true, palette: palette, text: text, callbacks: callbacks)
    let popover = NSPopover()
    popover.behavior = .transient
    popover.animates = true
    popover.appearance = NSAppearance(named: usesDarkAppearance ? .darkAqua : .aqua)
    popover.contentViewController = controller
    popover.show(relativeTo: anchor, of: view, preferredEdge: .maxY)
    self.popover = popover
    self.controller = controller

    DispatchQueue.global(qos: .userInitiated).async {
      let info = load()
      DispatchQueue.main.async { [weak controller] in
        controller?.update(info: info, isLoading: false)
      }
    }
  }

  func dismiss() {
    popover?.performClose(nil)
    popover = nil
    controller = nil
  }
}

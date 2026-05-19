import AppKit
import ProGhosttyCore
import SwiftUI

struct RootView: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    ZStack {
      TerminalCanvasView()
        .blur(radius: model.isWorkspaceSwitcherPresented
          ? ProGhosttyOverlayStyle.workspaceSwitcherTerminalBlurRadius
          : 0)

      if model.isWorkspaceSwitcherPresented {
        WorkspaceSwitcherView()
          .environmentObject(model)
          .transition(.opacity.combined(with: .scale(scale: 0.98)))
      }

      if model.isHistoryPresented {
        UtilityOverlay(
          width: 820,
          height: 560,
          onClose: { model.closeHistory() }
        ) {
          HistoryView()
        }
        .transition(.opacity.combined(with: .scale(scale: 0.985)))
      }

      if model.isAICompanionPresented {
        UtilityOverlay(
          width: 860,
          height: 620,
          onClose: { model.closeAICompanion() }
        ) {
          AICompanionView()
        }
        .transition(.opacity.combined(with: .scale(scale: 0.985)))
      }

      if model.commandCapsuleState.isPresented {
        VStack {
          Spacer()
          CodexCommandCapsuleView()
            .environmentObject(model)
            .padding(.bottom, 28)
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
      }
    }
    .animation(.easeOut(duration: 0.12), value: model.isWorkspaceSwitcherPresented)
    .animation(.easeOut(duration: 0.12), value: model.isHistoryPresented)
    .animation(.easeOut(duration: 0.12), value: model.isAICompanionPresented)
    .animation(.easeOut(duration: 0.14), value: model.commandCapsuleState.isPresented)
    .animation(.easeOut(duration: 0.14), value: model.titlebarToast)
    .preferredColorScheme(model.appColorScheme)
    .background(Color(nsColor: model.terminalBackgroundColor).ignoresSafeArea())
    .background(
      WorkspaceTitlebarView(
        title: model.activeTitlebarLabel,
        tooltip: model.activeTitlebarTooltip,
        backgroundColor: model.terminalBackgroundColor,
        usesDarkAppearance: model.usesDarkAppearance,
        toast: model.titlebarToast,
        onSettings: { model.openSettingsWindow() },
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
      CommandCapsuleShortcutHost(
        binding: model.settings.keyboardShortcuts.shortcut(for: .openCodexCommandCapsule),
        onOpen: { model.handleCodexCommandCapsuleShortcut() }
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
    hasher.combine(model.isHistoryPresented)
    hasher.combine(model.isAICompanionPresented)
    hasher.combine(model.commandCapsuleState.isPresented)
    hasher.combine(model.commandCapsuleState.phase.rawValue)
    hasher.combine(model.titlebarToast?.message)
    hasher.combine(String(describing: model.titlebarToast?.style))
    hasher.combine(String(describing: model.titlebarToast?.lifetime))
    hasher.combine(model.usesDarkAppearance)
    hasher.combine(model.terminalBackgroundColor.rgbSignature)
    return hasher.finalize()
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

private struct CommandCapsuleShortcutHost: NSViewRepresentable {
  let binding: KeyboardShortcutBinding
  let onOpen: () -> Void

  func makeNSView(context: Context) -> KeyView {
    let view = KeyView()
    view.binding = binding
    view.onOpen = onOpen
    view.installMonitor()
    return view
  }

  func updateNSView(_ view: KeyView, context: Context) {
    view.binding = binding
    view.onOpen = onOpen
    view.installMonitor()
  }

  static func dismantleNSView(_ view: KeyView, coordinator: ()) {
    view.removeMonitor()
  }

  final class KeyView: NSView {
    var binding: KeyboardShortcutBinding?
    var onOpen: (() -> Void)?
    private var monitor: Any?

    func installMonitor() {
      guard monitor == nil else { return }
      monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
        guard let self else { return event }
        guard NSApp.modalWindow == nil else { return event }
        guard let window, event.window === window else { return event }
        guard binding?.matches(key: event.proGhosttyShortcutKey, modifiers: event.proGhosttyShortcutModifiers) == true else {
          return event
        }
        onOpen?()
        return nil
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

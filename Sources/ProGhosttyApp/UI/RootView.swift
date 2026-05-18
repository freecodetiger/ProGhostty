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
    }
    .animation(.easeOut(duration: 0.12), value: model.isWorkspaceSwitcherPresented)
    .animation(.easeOut(duration: 0.12), value: model.isHistoryPresented)
    .animation(.easeOut(duration: 0.12), value: model.isAICompanionPresented)
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
  }

  private var terminalChromeSyncToken: Int {
    var hasher = Hasher()
    hasher.combine(model.isWorkspaceSwitcherPresented)
    hasher.combine(model.isHistoryPresented)
    hasher.combine(model.isAICompanionPresented)
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

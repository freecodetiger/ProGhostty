import AppKit
import ProGhosttyCore
import SwiftUI

struct RootView: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    ZStack {
      TerminalCanvasView()

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

      if model.isPluginManagerPresented {
        UtilityOverlay(
          width: 720,
          height: 560,
          showsCloseButton: false,
          onClose: { model.closePlugins() }
        ) {
          PluginManagerView()
        }
        .transition(.opacity.combined(with: .scale(scale: 0.985)))
      }

      if let toast = model.titlebarToast {
        TitlebarToastView(toast: toast)
          .padding(.top, 9)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
          .transition(.opacity.combined(with: .scale(scale: 0.98)))
          .allowsHitTesting(false)
      }
    }
    .animation(.easeOut(duration: 0.12), value: model.isWorkspaceSwitcherPresented)
    .animation(.easeOut(duration: 0.12), value: model.isHistoryPresented)
    .animation(.easeOut(duration: 0.12), value: model.isPluginManagerPresented)
    .animation(.easeOut(duration: 0.14), value: model.titlebarToast)
    .preferredColorScheme(model.appColorScheme)
    .background(Color(nsColor: model.terminalBackgroundColor).ignoresSafeArea())
    .background(
      WorkspaceTitlebarView(
        title: model.activeTitlebarLabel,
        tooltip: model.activeTitlebarTooltip,
        backgroundColor: model.terminalBackgroundColor,
        usesDarkAppearance: model.usesDarkAppearance,
        onSettings: { model.openSettingsWindow() }
      )
      .frame(width: 0, height: 0)
    )
  }
}

private struct TitlebarToastView: View {
  let toast: AppModel.TitlebarToast

  var body: some View {
    Text(toast.message)
      .font(.system(size: 12, weight: .semibold))
      .foregroundStyle(foreground)
      .padding(.horizontal, 11)
      .padding(.vertical, 5)
      .background(background)
      .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .stroke(border, lineWidth: 1)
      )
      .shadow(color: .black.opacity(0.12), radius: 10, x: 0, y: 4)
  }

  private var foreground: Color {
    switch toast.style {
    case .success:
      return Color(nsColor: .labelColor)
    }
  }

  private var background: Color {
    switch toast.style {
    case .success:
      return Color.green.opacity(0.22)
    }
  }

  private var border: Color {
    switch toast.style {
    case .success:
      return Color.green.opacity(0.38)
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

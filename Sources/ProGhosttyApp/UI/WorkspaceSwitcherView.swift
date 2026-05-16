import AppKit
import ProGhosttyCore
import SwiftUI

struct WorkspaceSwitcherView: View {
  @EnvironmentObject private var model: AppModel
  @FocusState private var isSearchFocused: Bool

  var body: some View {
    let text = model.appText

    ZStack {
      Color.black.opacity(0.18)
        .ignoresSafeArea()
        .onTapGesture {
          model.closeWorkspaceSwitcher()
        }

      VStack(spacing: 0) {
        TextField(text.searchWorkspaces, text: Binding(
          get: { model.workspaceSwitcherState.query },
          set: { model.updateWorkspaceSwitcherQuery($0) }
        ))
        .textFieldStyle(.plain)
        .font(.system(size: 16, weight: .regular))
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .focused($isSearchFocused)

        Divider()
          .opacity(0.45)

        VStack(spacing: 2) {
          ForEach(model.workspaceSwitcherState.decoratedWorkspaces) { item in
            WorkspaceSwitcherRow(
              item: item,
              isSelected: model.workspaceSwitcherState.selectedWorkspaceID == item.workspace.id,
              sessionCount: model.sessionCount(forWorkspaceListID: item.workspace.id),
              canDelete: item.status == .saved,
              text: text
            ) {
              model.activateWorkspaceFromSwitcher(item.workspace.id)
            } deleteAction: {
              model.deleteWorkspaceFromSwitcher(item.workspace.id)
            }
          }

          if model.workspaceSwitcherState.canCreateWorkspaceFromQuery {
            Button {
              model.createAndOpenWorkspace(name: model.workspaceSwitcherState.query)
              model.closeWorkspaceSwitcher()
            } label: {
              HStack(spacing: 10) {
                Image(systemName: "plus")
                  .font(.system(size: 13, weight: .medium))
                Text(text.createWorkspace(model.workspaceSwitcherState.query.trimmingCharacters(in: .whitespacesAndNewlines)))
                  .lineLimit(1)
                Spacer()
              }
              .padding(.horizontal, 14)
              .padding(.vertical, 10)
            }
            .buttonStyle(.plain)
          }
        }
        .padding(8)
      }
      .frame(width: 580)
      .background(.regularMaterial)
      .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .stroke(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 1)
      )
      .shadow(color: .black.opacity(0.22), radius: 24, x: 0, y: 18)
      .background(WorkspaceSwitcherKeyHandler(
        onUp: { model.moveWorkspaceSwitcherSelection(delta: -1) },
        onDown: { model.moveWorkspaceSwitcherSelection(delta: 1) },
        onEnter: { model.activateWorkspaceSwitcherSelection() },
        onEscape: { model.closeWorkspaceSwitcher() }
      ))
    }
    .onAppear {
      isSearchFocused = true
    }
  }
}

private struct WorkspaceSwitcherRow: View {
  let item: WorkspaceSwitcherState.DecoratedWorkspace
  let isSelected: Bool
  let sessionCount: Int
  let canDelete: Bool
  let text: AppText
  let action: () -> Void
  let deleteAction: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: iconName)
        .font(.system(size: 12, weight: .semibold))
        .frame(width: 14)
        .foregroundStyle(iconColor)

      VStack(alignment: .leading, spacing: 2) {
        Text(item.workspace.name)
          .font(.system(size: 13, weight: .medium))
          .lineLimit(1)
        Text(subtitle)
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }

      Spacer()

      HStack(spacing: 8) {
        Text(statusTitle)
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(.secondary)

        if sessionCount > 0 {
          Text("\(sessionCount)")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }

        if canDelete {
          Button(role: .destructive) {
            deleteAction()
          } label: {
            Image(systemName: "trash")
              .font(.system(size: 11, weight: .medium))
              .frame(width: 20, height: 20)
          }
          .buttonStyle(.plain)
          .foregroundStyle(.secondary)
          .opacity(isSelected ? 1 : 0.38)
        }
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(background)
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    .contentShape(Rectangle())
    .onTapGesture(perform: action)
  }

  private var subtitle: String {
    item.workspace.rootPath ?? "No root path"
  }

  private var iconName: String {
    switch item.status {
    case .active:
      return "checkmark"
    case .running:
      return "circle.fill"
    case .saved:
      return ""
    }
  }

  private var iconColor: Color {
    item.status == .active ? .primary : .secondary
  }

  private var statusTitle: String {
    switch item.status {
    case .active:
      return text.current
    case .running:
      return text.running
    case .saved:
      return text.savedStatus
    }
  }

  private var background: Color {
    if item.status == .active {
      return Color.primary.opacity(0.10)
    }
    return isSelected ? Color.primary.opacity(0.06) : Color.clear
  }
}

private struct WorkspaceSwitcherKeyHandler: NSViewRepresentable {
  let onUp: () -> Void
  let onDown: () -> Void
  let onEnter: () -> Void
  let onEscape: () -> Void

  func makeNSView(context: Context) -> KeyView {
    let view = KeyView()
    view.onUp = onUp
    view.onDown = onDown
    view.onEnter = onEnter
    view.onEscape = onEscape
    view.installMonitor()
    return view
  }

  func updateNSView(_ view: KeyView, context: Context) {
    view.onUp = onUp
    view.onDown = onDown
    view.onEnter = onEnter
    view.onEscape = onEscape
    view.installMonitor()
  }

  static func dismantleNSView(_ view: KeyView, coordinator: ()) {
    view.removeMonitor()
  }

  final class KeyView: NSView {
    var onUp: (() -> Void)?
    var onDown: (() -> Void)?
    var onEnter: (() -> Void)?
    var onEscape: (() -> Void)?
    private var monitor: Any?

    func installMonitor() {
      guard monitor == nil else { return }
      monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
        guard let self else { return event }
        switch event.keyCode {
        case 126:
          onUp?()
          return nil
        case 125:
          onDown?()
          return nil
        case 36, 76:
          onEnter?()
          return nil
        case 53:
          onEscape?()
          return nil
        default:
          return event
        }
      }
    }

    func removeMonitor() {
      if let monitor {
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
      }
    }
  }
}

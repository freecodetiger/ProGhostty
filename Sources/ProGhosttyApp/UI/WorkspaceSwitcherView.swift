import AppKit
import ProGhosttyCore
import SwiftUI

struct WorkspaceSwitcherView: View {
  @EnvironmentObject private var model: AppModel
  @FocusState private var isSearchFocused: Bool

  var body: some View {
    ZStack {
      Color.black.opacity(0.18)
        .ignoresSafeArea()
        .onTapGesture {
          model.closeWorkspaceSwitcher()
        }

      VStack(spacing: 0) {
        TextField("Search workspaces", text: Binding(
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
          ForEach(model.workspaceSwitcherState.filteredWorkspaces) { workspace in
            WorkspaceSwitcherRow(
              workspace: workspace,
              isActive: model.workspaceSwitcherState.activeWorkspaceID == workspace.id,
              isSelected: model.workspaceSwitcherState.selectedWorkspaceID == workspace.id,
              sessionCount: model.sessionCount(forWorkspaceListID: workspace.id)
            ) {
              model.activateWorkspaceFromSwitcher(workspace.id)
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
                Text("Create \"\(model.workspaceSwitcherState.query.trimmingCharacters(in: .whitespacesAndNewlines))\"")
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
  let workspace: Workspace
  let isActive: Bool
  let isSelected: Bool
  let sessionCount: Int
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 10) {
        Image(systemName: isActive ? "checkmark" : "")
          .font(.system(size: 12, weight: .semibold))
          .frame(width: 14)
          .foregroundStyle(.secondary)

        VStack(alignment: .leading, spacing: 2) {
          Text(workspace.name)
            .font(.system(size: 13, weight: .medium))
            .lineLimit(1)
          Text(subtitle)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }

        Spacer()

        Text("\(sessionCount)")
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(.secondary)
          .monospacedDigit()
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .background(isSelected ? Color.accentColor.opacity(0.16) : Color.clear)
      .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
    .buttonStyle(.plain)
  }

  private var subtitle: String {
    workspace.rootPath ?? "No root path"
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

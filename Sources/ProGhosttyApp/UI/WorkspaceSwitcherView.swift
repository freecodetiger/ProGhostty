import AppKit
import ProGhosttyCore
import SwiftUI

struct WorkspaceSwitcherView: View {
  @EnvironmentObject private var model: AppModel
  @State private var renamingWorkspaceID: UUID?
  @State private var renameDraft = ""
  @State private var isCreatingWorkspace = false
  @State private var createDraft = ""
  @FocusState private var focusedField: FocusTarget?

  private enum FocusTarget: Hashable {
    case create
    case rename
  }

  var body: some View {
    let text = model.appText

    ZStack {
      Color.black.opacity(0.18)
        .ignoresSafeArea()
        .onTapGesture {
          model.closeWorkspaceSwitcher()
        }

      VStack(spacing: 0) {
        VStack(spacing: 2) {
          ForEach(model.workspaceSwitcherState.decoratedWorkspaces) { item in
            let isRenaming = renamingWorkspaceID == item.workspace.id
            WorkspaceSwitcherRow(
              item: item,
              isSelected: !isCreatingWorkspace
                && model.workspaceSwitcherState.selectedWorkspaceID == item.workspace.id,
              isRenaming: isRenaming,
              renameDraft: $renameDraft,
              sessionCount: model.sessionCount(forWorkspaceListID: item.workspace.id),
              canDelete: true,
              text: text
            ) {
              model.activateWorkspaceFromSwitcher(item.workspace.id)
            } deleteAction: {
              model.deleteWorkspaceFromSwitcher(item.workspace.id)
            } renameAction: {
              beginRenaming(item.workspace)
            } commitRename: {
              commitRenaming()
            } cancelRename: {
              cancelRenaming()
            }
          }

          WorkspaceCreateRow(
            title: createTitle(text),
            caption: text.createWorkspaceCaption,
            placeholder: text.newWorkspaceName,
            isSelected: model.workspaceSwitcherState.isCreateWorkspaceSelected,
            isCreating: isCreatingWorkspace,
            draft: $createDraft,
            begin: { beginCreatingWorkspace() },
            commit: { commitCreatingWorkspace() }
          )
          .focused($focusedField, equals: .create)
          .onChange(of: isCreatingWorkspace) { value in
            if value {
              focusedField = .create
            }
          }
        }
        .padding(8)

        HStack(spacing: 12) {
          Text(text.enterWorkspaceHint)
          Text(text.renameShortcutHint)
          Text(text.deleteWorkspaceHint)
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
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
        onEnter: { activateSelectedItem() },
        onTab: { activateSelectedItem() },
        onSpace: { beginRenamingSelectedWorkspace() },
        onDelete: { deleteSelectedWorkspace() },
        onEscape: { model.closeWorkspaceSwitcher() },
        onCommitRename: { commitRenaming() },
        onCancelRename: { cancelRenaming() },
        onCommitCreate: { commitCreatingWorkspace() },
        onCancelCreate: { cancelCreatingWorkspace() },
        isRenaming: { renamingWorkspaceID != nil },
        isCreating: { isCreatingWorkspace },
        canBeginRename: {
          renamingWorkspaceID == nil
            && !isCreatingWorkspace
            && model.workspaceSwitcherState.selectedWorkspaceID != nil
        }
      ))
    }
  }

  private func createTitle(_ text: AppText) -> String {
    text.newWorkspace
  }

  private func activateSelectedItem() {
    if model.workspaceSwitcherState.isCreateWorkspaceSelected {
      beginCreatingWorkspace()
    } else {
      model.activateWorkspaceSwitcherSelection()
    }
  }

  private func beginCreatingWorkspace() {
    model.selectWorkspaceCreationCard()
    isCreatingWorkspace = true
    createDraft = ""
    focusedField = .create
  }

  private func commitCreatingWorkspace() {
    guard isCreatingWorkspace else { return }
    guard !createDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      NSSound.beep()
      focusedField = .create
      return
    }
    model.createAndOpenWorkspace(name: createDraft)
    isCreatingWorkspace = false
    createDraft = ""
    model.closeWorkspaceSwitcher()
  }

  private func cancelCreatingWorkspace() {
    isCreatingWorkspace = false
    createDraft = ""
  }

  private func beginRenamingSelectedWorkspace() {
    guard
      let selectedID = model.workspaceSwitcherState.selectedWorkspaceID,
      let workspace = model.workspaceSwitcherState.workspaces.first(where: { $0.id == selectedID })
    else {
      return
    }
    beginRenaming(workspace)
  }

  private func beginRenaming(_ workspace: Workspace) {
    renamingWorkspaceID = workspace.id
    renameDraft = workspace.name
    focusedField = .rename
  }

  private func commitRenaming() {
    guard let renamingWorkspaceID else { return }
    model.renameWorkspaceFromSwitcher(renamingWorkspaceID, to: renameDraft)
    self.renamingWorkspaceID = nil
    renameDraft = ""
  }

  private func cancelRenaming() {
    renamingWorkspaceID = nil
    renameDraft = ""
  }

  private func deleteSelectedWorkspace() {
    guard
      let selectedID = model.workspaceSwitcherState.selectedWorkspaceID
    else {
      return
    }
    model.deleteWorkspaceFromSwitcher(selectedID)
  }
}

private struct WorkspaceSwitcherRow: View {
  let item: WorkspaceSwitcherState.DecoratedWorkspace
  let isSelected: Bool
  let isRenaming: Bool
  @Binding var renameDraft: String
  let sessionCount: Int
  let canDelete: Bool
  let text: AppText
  let action: () -> Void
  let deleteAction: () -> Void
  let renameAction: () -> Void
  let commitRename: () -> Void
  let cancelRename: () -> Void
  @FocusState private var isRenameFocused: Bool

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: iconName)
        .font(.system(size: 12, weight: .semibold))
        .frame(width: 14)
        .foregroundStyle(iconColor)

      VStack(alignment: .leading, spacing: 2) {
        if isRenaming {
          TextField(text.renameWorkspace, text: $renameDraft)
            .textFieldStyle(.plain)
            .font(.system(size: 13, weight: .medium))
            .focused($isRenameFocused)
            .onSubmit(commitRename)
        } else {
          Text(item.workspace.name)
            .font(.system(size: 13, weight: .medium))
            .lineLimit(1)
        }
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
    .onTapGesture {
      if !isRenaming {
        action()
      }
    }
    .onAppear {
      if isRenaming {
        isRenameFocused = true
      }
    }
    .onChange(of: isRenaming) { value in
      isRenameFocused = value
    }
    .contextMenu {
      Button(text.renameWorkspace) {
        renameAction()
      }
      if canDelete {
        Button(role: .destructive) {
          deleteAction()
        } label: {
          Text(text.deleteWorkspace)
        }
      }
    }
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
    switch (isSelected, item.status == .active) {
    case (true, true):
      return Color.primary.opacity(0.14)
    case (true, false):
      return Color.primary.opacity(0.08)
    case (false, true):
      return Color.primary.opacity(0.045)
    case (false, false):
      return Color.clear
    }
  }
}

private struct WorkspaceCreateRow: View {
  let title: String
  let caption: String
  let placeholder: String
  let isSelected: Bool
  let isCreating: Bool
  @Binding var draft: String
  let begin: () -> Void
  let commit: () -> Void
  @FocusState private var isFocused: Bool

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: "plus")
        .font(.system(size: 12, weight: .semibold))
        .frame(width: 14)
      VStack(alignment: .leading, spacing: 2) {
        if isCreating {
          TextField(placeholder, text: $draft)
            .textFieldStyle(.plain)
            .font(.system(size: 13, weight: .medium))
            .focused($isFocused)
            .onSubmit(commit)
        } else {
          Text(title)
            .font(.system(size: 13, weight: .medium))
            .lineLimit(1)
        }
        Text(caption)
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      Spacer()
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .contentShape(Rectangle())
    .foregroundStyle(.secondary)
    .background(background)
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    .onTapGesture {
      begin()
    }
    .onAppear {
      if isCreating {
        isFocused = true
      }
    }
    .onChange(of: isCreating) { value in
      isFocused = value
    }
  }

  private var background: Color {
    if isCreating {
      return Color.primary.opacity(0.12)
    }
    return isSelected ? Color.primary.opacity(0.08) : Color.clear
  }
}

private struct WorkspaceSwitcherKeyHandler: NSViewRepresentable {
  let onUp: () -> Void
  let onDown: () -> Void
  let onEnter: () -> Void
  let onTab: () -> Void
  let onSpace: () -> Void
  let onDelete: () -> Void
  let onEscape: () -> Void
  let onCommitRename: () -> Void
  let onCancelRename: () -> Void
  let onCommitCreate: () -> Void
  let onCancelCreate: () -> Void
  let isRenaming: () -> Bool
  let isCreating: () -> Bool
  let canBeginRename: () -> Bool

  func makeNSView(context: Context) -> KeyView {
    let view = KeyView()
    view.onUp = onUp
    view.onDown = onDown
    view.onEnter = onEnter
    view.onTab = onTab
    view.onSpace = onSpace
    view.onDelete = onDelete
    view.onEscape = onEscape
    view.onCommitRename = onCommitRename
    view.onCancelRename = onCancelRename
    view.onCommitCreate = onCommitCreate
    view.onCancelCreate = onCancelCreate
    view.isRenaming = isRenaming
    view.isCreating = isCreating
    view.canBeginRename = canBeginRename
    view.installMonitor()
    return view
  }

  func updateNSView(_ view: KeyView, context: Context) {
    view.onUp = onUp
    view.onDown = onDown
    view.onEnter = onEnter
    view.onTab = onTab
    view.onSpace = onSpace
    view.onDelete = onDelete
    view.onEscape = onEscape
    view.onCommitRename = onCommitRename
    view.onCancelRename = onCancelRename
    view.onCommitCreate = onCommitCreate
    view.onCancelCreate = onCancelCreate
    view.isRenaming = isRenaming
    view.isCreating = isCreating
    view.canBeginRename = canBeginRename
    view.installMonitor()
  }

  static func dismantleNSView(_ view: KeyView, coordinator: ()) {
    view.removeMonitor()
  }

  final class KeyView: NSView {
    var onUp: (() -> Void)?
    var onDown: (() -> Void)?
    var onEnter: (() -> Void)?
    var onTab: (() -> Void)?
    var onSpace: (() -> Void)?
    var onDelete: (() -> Void)?
    var onEscape: (() -> Void)?
    var onCommitRename: (() -> Void)?
    var onCancelRename: (() -> Void)?
    var onCommitCreate: (() -> Void)?
    var onCancelCreate: (() -> Void)?
    var isRenaming: (() -> Bool)?
    var isCreating: (() -> Bool)?
    var canBeginRename: (() -> Bool)?
    private var monitor: Any?

    func installMonitor() {
      guard monitor == nil else { return }
      monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
        guard let self else { return event }
        guard NSApp.modalWindow == nil else { return event }
        let isRenaming = isRenaming?() == true
        let isCreating = isCreating?() == true
        let isEditingName = isRenaming || isCreating
        switch event.keyCode {
        case 126:
          guard !isEditingName else { return event }
          onUp?()
          return nil
        case 125:
          guard !isEditingName else { return event }
          onDown?()
          return nil
        case 36, 76:
          if isRenaming {
            onCommitRename?()
            return nil
          }
          if isCreating {
            onCommitCreate?()
            return nil
          }
          onEnter?()
          return nil
        case 48:
          if isRenaming {
            onCommitRename?()
          } else if isCreating {
            onCommitCreate?()
          } else {
            onTab?()
          }
          return nil
        case 49:
          guard !isEditingName, canBeginRename?() == true else { return event }
          onSpace?()
          return nil
        case 51, 117:
          guard !isEditingName else { return event }
          onDelete?()
          return nil
        case 53:
          if isRenaming {
            onCancelRename?()
            return nil
          }
          if isCreating {
            onCancelCreate?()
            return nil
          }
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

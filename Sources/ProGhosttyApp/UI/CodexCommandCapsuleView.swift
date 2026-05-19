import ProGhosttyCore
import SwiftUI

struct CodexCommandCapsuleView: View {
  @EnvironmentObject private var model: AppModel
  @FocusState private var requestFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      header
      requestEditor
      if model.commandCapsuleState.phase == .listening || model.commandCapsuleState.phase == .paused {
        listeningRow
      }
      if shouldShowDraft {
        draftEditor
      }
      contextChips
      if let error = model.commandCapsuleState.errorMessage {
        Text(error)
          .font(.system(size: 12))
          .foregroundStyle(.red)
      }
      actions
    }
    .padding(14)
    .frame(width: 640)
    .background(Color(nsColor: model.terminalBackgroundColor).opacity(model.usesDarkAppearance ? 0.94 : 0.98))
    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .stroke(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 1)
    )
    .shadow(color: .black.opacity(model.usesDarkAppearance ? 0.32 : 0.18), radius: 22, x: 0, y: 14)
    .onAppear {
      requestFocused = true
    }
  }

  private var header: some View {
    HStack {
      Text("Codex Command")
        .font(.system(size: 13, weight: .semibold))
      Spacer()
      phaseLabel
      Button {
        model.dismissCodexCommandCapsule()
      } label: {
        Image(systemName: "xmark")
      }
      .buttonStyle(.borderless)
      .keyboardShortcut(.escape, modifiers: [])
    }
  }

  private var phaseLabel: some View {
    Text(label(for: model.commandCapsuleState.phase))
      .font(.system(size: 11, weight: .medium))
      .foregroundStyle(.secondary)
  }

  private var requestEditor: some View {
    TextEditor(text: $model.commandCapsuleState.request)
      .focused($requestFocused)
      .font(.system(size: 13))
      .frame(height: 72)
      .scrollContentBackground(.hidden)
      .background(Color(nsColor: .textBackgroundColor).opacity(model.usesDarkAppearance ? 0.16 : 0.62))
      .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .stroke(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 1)
      )
  }

  private var listeningRow: some View {
    HStack(spacing: 8) {
      Circle()
        .fill(model.commandCapsuleState.phase == .listening ? Color.red : Color.secondary.opacity(0.65))
        .frame(width: 8, height: 8)
      Text(voiceStatusText)
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .lineLimit(2)
      Spacer()
      if model.commandCapsuleState.phase == .paused {
        Button("Resume") {
          model.toggleCommandCapsuleVoiceInput()
        }
      } else {
        Button("Pause") {
          model.toggleCommandCapsuleVoiceInput()
        }
      }
      Button("Stop") {
        model.stopCommandCapsuleVoiceInput()
      }
    }
  }

  private var voiceStatusText: String {
    if model.commandCapsuleState.phase == .paused {
      return "Paused"
    }
    return model.commandCapsuleState.voicePartial.isEmpty ? "Listening..." : model.commandCapsuleState.voicePartial
  }

  private var shouldShowDraft: Bool {
    !model.commandCapsuleState.draft.isEmpty || model.commandCapsuleState.phase == .ready
  }

  private var draftEditor: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Draft for Codex")
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.secondary)
      TextEditor(text: $model.commandCapsuleState.draft)
        .font(.system(size: 12, design: .monospaced))
        .frame(height: 140)
        .scrollContentBackground(.hidden)
        .background(Color(nsColor: .textBackgroundColor).opacity(model.usesDarkAppearance ? 0.16 : 0.62))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 1)
        )
    }
  }

  private var contextChips: some View {
    HStack(spacing: 6) {
      ForEach(contextOptions, id: \.self) { option in
        Button(label(for: option)) {
          model.toggleCommandCapsuleContext(option)
        }
        .buttonStyle(.borderless)
        .font(.system(size: 11, weight: .medium))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
          model.commandCapsuleState.includedContext.contains(option)
            ? Color.accentColor.opacity(0.16)
            : Color(nsColor: .separatorColor).opacity(0.16)
        )
        .clipShape(Capsule())
      }
    }
  }

  private var actions: some View {
    HStack(spacing: 8) {
      Button(voiceButtonTitle) {
        model.toggleCommandCapsuleVoiceInput()
      }
      Button("Use Raw") {
        model.useRawCommandCapsuleRequestAsDraft()
      }
      Button("Refine") {
        model.refineCommandCapsulePrompt()
      }
      .disabled(model.commandCapsuleState.phase == .refining || model.commandCapsuleState.request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      Spacer()
      Button("Paste") {
        model.sendCommandCapsuleDraftToCodex(enter: false)
      }
      Button("Paste + Enter") {
        model.sendCommandCapsuleDraftToCodex(enter: true)
      }
      .keyboardShortcut(.return, modifiers: [.command])
    }
  }

  private var contextOptions: [AIPromptContextOption] {
    [.workspacePath, .gitBranch, .gitStatus, .changedFileList, .selectedTerminalText]
  }

  private var voiceButtonTitle: String {
    switch model.commandCapsuleState.phase {
    case .listening:
      return "Pause Voice"
    case .paused:
      return "Resume Voice"
    default:
      return "Voice"
    }
  }

  private func label(for option: AIPromptContextOption) -> String {
    switch option {
    case .workspacePath: return "Workspace"
    case .gitBranch: return "Branch"
    case .gitStatus: return "Status"
    case .gitDiff: return "Diff"
    case .selectedTerminalText: return "Selection"
    case .changedFileList: return "Files"
    }
  }

  private func label(for phase: CommandCapsulePhase) -> String {
    switch phase {
    case .idle: return "Ready"
    case .listening: return "Listening"
    case .paused: return "Paused"
    case .refining: return "Refining"
    case .ready: return "Draft"
    case .error: return "Needs attention"
    case .sent: return "Sent"
    }
  }
}

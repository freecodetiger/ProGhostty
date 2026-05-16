import AppKit
import ProGhosttyCore
import SwiftUI

struct AICompanionView: View {
  @EnvironmentObject private var model: AppModel
  @State private var profile = AICLIProfile.codex
  @State private var openMode = AIOpenMode.rightSplit
  @State private var template = AIPromptTemplate.fixError
  @State private var request = ""
  @State private var prompt = ""
  @State private var includeWorkspacePath = true
  @State private var includeGitBranch = true
  @State private var includeGitStatus = true
  @State private var includeGitDiff = false
  @State private var includeSelectedTerminalText = false
  @State private var includeChangedFiles = true
  @State private var includeFileContents = false
  @State private var changedFiles: [GitModifiedFile] = []
  @State private var voicePartial = ""
  @State private var isRecording = false
  @State private var voiceTask: Task<Void, Never>?

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      HStack(alignment: .top, spacing: 0) {
        modifiedFilesSection
          .frame(width: 280)
        Divider()
        promptSection
        Divider()
        voiceSection
          .frame(width: 220)
      }
      Divider()
      footer
    }
    .background(Color(nsColor: .windowBackgroundColor))
    .onAppear {
      refreshChangedFiles()
      generatePrompt()
      if let active = model.activeAISession?.profile {
        profile = active
      }
    }
    .onDisappear {
      stopRecording()
    }
  }

  private var header: some View {
    HStack(spacing: 12) {
      Picker("Profile", selection: $profile) {
        ForEach(AICLIProfile.builtIns) { profile in
          Text(profile.name).tag(profile)
        }
      }
      .pickerStyle(.segmented)
      .frame(width: 260)

      Picker("Open", selection: $openMode) {
        Text("Current").tag(AIOpenMode.currentPane)
        Text("Right").tag(AIOpenMode.rightSplit)
        Text("Bottom").tag(AIOpenMode.bottomSplit)
      }
      .pickerStyle(.segmented)
      .frame(width: 250)

      Button("Start") {
        model.launchAI(profile: profile, mode: openMode)
      }

      Spacer()

      Text(model.activeAISession?.profile.name ?? "No AI session")
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.secondary)
    }
    .padding(.horizontal, 18)
    .padding(.vertical, 14)
  }

  private var modifiedFilesSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("Modified Files")
          .font(.system(size: 13, weight: .semibold))
        Spacer()
        Button(action: refreshChangedFiles) {
          Image(systemName: "arrow.clockwise")
        }
        .buttonStyle(.borderless)
      }

      Toggle("Include file contents", isOn: $includeFileContents)
        .font(.system(size: 12))
        .onChange(of: includeFileContents) { _ in generatePrompt() }

      ScrollView {
        LazyVStack(alignment: .leading, spacing: 6) {
          ForEach(changedFiles) { file in
            Button {
              NSPasteboard.general.clearContents()
              NSPasteboard.general.setString(file.path, forType: .string)
            } label: {
              HStack(spacing: 8) {
                Text(file.status.label.prefix(1))
                  .font(.system(size: 11, weight: .bold, design: .monospaced))
                  .frame(width: 18, height: 18)
                  .background(Color(nsColor: .controlAccentColor).opacity(0.16))
                  .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                Text(file.path)
                  .font(.system(size: 12, design: .monospaced))
                  .lineLimit(2)
                Spacer(minLength: 0)
              }
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
          }
        }
      }

      Button("Insert changed files into prompt") {
        let list = changedFiles.map { "- \($0.status.label): \($0.path)" }.joined(separator: "\n")
        request = [request, list].filter { !$0.isEmpty }.joined(separator: "\n\n")
        generatePrompt()
      }
      .disabled(changedFiles.isEmpty)
    }
    .padding(16)
  }

  private var promptSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Prompt Composer")
        .font(.system(size: 13, weight: .semibold))

      Picker("Template", selection: $template) {
        ForEach(AIPromptTemplate.allCases) { item in
          Text(item.rawValue).tag(item)
        }
      }
      .onChange(of: template) { _ in generatePrompt() }

      TextEditor(text: $request)
        .font(.system(size: 13))
        .frame(height: 90)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
        .onChange(of: request) { _ in generatePrompt() }

      VStack(alignment: .leading, spacing: 6) {
        Toggle("workspace path", isOn: $includeWorkspacePath)
        Toggle("git branch", isOn: $includeGitBranch)
        Toggle("git status", isOn: $includeGitStatus)
        Toggle("git diff", isOn: $includeGitDiff)
        Toggle("selected terminal text", isOn: $includeSelectedTerminalText)
        Toggle("changed file list", isOn: $includeChangedFiles)
      }
      .font(.system(size: 12))
      .onChange(of: includeWorkspacePath) { _ in generatePrompt() }
      .onChange(of: includeGitBranch) { _ in generatePrompt() }
      .onChange(of: includeGitStatus) { _ in generatePrompt() }
      .onChange(of: includeGitDiff) { _ in generatePrompt() }
      .onChange(of: includeSelectedTerminalText) { _ in generatePrompt() }
      .onChange(of: includeChangedFiles) { _ in generatePrompt() }

      TextEditor(text: $prompt)
        .font(.system(size: 12, design: .monospaced))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
    }
    .padding(16)
  }

  private var voiceSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Voice Input")
        .font(.system(size: 13, weight: .semibold))

      Button(isRecording ? "Stop" : "Record") {
        isRecording ? stopRecording() : startRecording()
      }
      .controlSize(.large)

      HStack {
        Button("Cancel") {
          voicePartial = ""
          stopRecording()
        }
        Button("Retry") {
          voicePartial = ""
          stopRecording()
          startRecording()
        }
      }
      .disabled(!isRecording && voicePartial.isEmpty)

      Text(voicePartial.isEmpty ? "Intermediate transcript appears here." : voicePartial)
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)

      if let message = model.aiErrorMessage {
        Text(message)
          .font(.system(size: 12))
          .foregroundStyle(.red)
      }

      Spacer()
    }
    .padding(16)
  }

  private var footer: some View {
    HStack(spacing: 10) {
      Button("Copy") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(prompt, forType: .string)
      }
      Spacer()
      Button("Paste to AI CLI") {
        model.pastePromptToAI(prompt, send: false)
      }
      Button("Paste and Send") {
        model.pastePromptToAI(prompt, send: true)
      }
      .keyboardShortcut(.defaultAction)
    }
    .padding(.horizontal, 18)
    .padding(.vertical, 14)
  }

  private func refreshChangedFiles() {
    guard let path = model.aiWorkspacePath else {
      changedFiles = []
      return
    }
    changedFiles = (try? GitContextCollector.modifiedFiles(workspacePath: path)) ?? []
    generatePrompt()
  }

  private func generatePrompt() {
    var included: Set<AIPromptContextOption> = []
    if includeWorkspacePath { included.insert(.workspacePath) }
    if includeGitBranch { included.insert(.gitBranch) }
    if includeGitStatus { included.insert(.gitStatus) }
    if includeGitDiff { included.insert(.gitDiff) }
    if includeSelectedTerminalText { included.insert(.selectedTerminalText) }
    if includeChangedFiles { included.insert(.changedFileList) }
    var context = model.makeAIContext(includeDiff: includeGitDiff)
    context.changedFiles = changedFiles
    var composed = AIPromptComposer.compose(
      request: request,
      template: template,
      context: context,
      includedContext: included
    )
    if includeFileContents {
      let contents = model.loadChangedFileContents(changedFiles)
      if !contents.isEmpty {
        composed += "\n\nSelected file contents:\n\(contents)"
      }
    }
    prompt = composed
  }

  private func startRecording() {
    guard !isRecording else { return }
    isRecording = true
    voicePartial = ""
    let service = model.makeASRService()
    voiceTask = Task {
      for await event in service.transcribe() {
        await MainActor.run {
          switch event {
          case .partial(let text):
            voicePartial = text
          case .final(let text):
            request = [request, text].filter { !$0.isEmpty }.joined(separator: request.isEmpty ? "" : "\n")
            voicePartial = ""
            generatePrompt()
          case .error(let message):
            model.aiErrorMessage = message
            isRecording = false
          case .completed:
            isRecording = false
          }
        }
      }
    }
  }

  private func stopRecording() {
    isRecording = false
    voiceTask?.cancel()
    voiceTask = nil
  }
}

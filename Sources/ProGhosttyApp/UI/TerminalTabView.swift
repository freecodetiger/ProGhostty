import ProGhosttyCore
import SwiftUI

struct TerminalTabView: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Picker("Terminal", selection: $model.selectedTabID) {
          ForEach(model.tabs) { tab in
            Text(tab.title).tag(Optional(tab.id))
          }
        }
        .labelsHidden()
        Button("New Tab") { model.openTerminal() }
        Button("Close") { model.closeSelectedTerminal() }
          .disabled(model.selectedTabID == nil)
        Spacer()
        Text("Shell Integration: \(model.shellIntegrationState)")
          .foregroundStyle(.secondary)
      }
      .padding(10)

      Divider()

      HStack(spacing: 0) {
        TerminalView()
        InspectorView()
          .frame(width: 260)
          .background(.quaternary.opacity(0.2))
      }

      Divider()

      HStack {
        TextField("Command", text: $model.commandLine)
          .textFieldStyle(.roundedBorder)
          .onSubmit { model.sendCommand() }
        Button("Send") { model.sendCommand() }
          .disabled(model.selectedTabID == nil || model.commandLine.isEmpty)
      }
      .padding(10)
    }
  }
}

struct TerminalView: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    ScrollView {
      Text(selectedOutput)
        .font(.system(size: model.settings.fontSize, design: .monospaced))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .textSelection(.enabled)
    }
    .background(Color(nsColor: .textBackgroundColor))
  }

  private var selectedOutput: String {
    guard
      let selected = model.selectedTabID,
      let tab = model.tabs.first(where: { $0.id == selected })
    else {
      return "No terminal session"
    }
    return tab.output.isEmpty ? "Mock terminal ready. Type a command below." : tab.output
  }
}

struct InspectorView: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Session")
        .font(.headline)
      Text("cwd: \(selectedTab?.cwd ?? "-")")
        .font(.caption)
        .textSelection(.enabled)
      Text("integration: \(model.shellIntegrationState)")
        .font(.caption)

      Divider()

      Text("Recent Block")
        .font(.headline)
      if let block = selectedTab?.lastBlock {
        CommandBlockMarkerView(block: block)
        Text(block.command ?? "(command unavailable)")
          .font(.system(.caption, design: .monospaced))
          .textSelection(.enabled)
      } else {
        Text("No command block yet")
          .foregroundStyle(.secondary)
      }
      Spacer()
    }
    .padding(12)
  }

  private var selectedTab: AppModel.TerminalTab? {
    guard let selected = model.selectedTabID else { return nil }
    return model.tabs.first { $0.id == selected }
  }
}

struct CommandBlockMarkerView: View {
  let block: CommandBlock

  var body: some View {
    HStack {
      Text(symbol)
      Text(block.status.rawValue)
      if let duration = block.durationMs {
        Text("\(duration) ms")
      }
      if let exitCode = block.exitCode {
        Text("exit \(exitCode)")
      }
    }
    .font(.caption)
    .padding(6)
    .background(.quaternary)
    .clipShape(RoundedRectangle(cornerRadius: 6))
  }

  private var symbol: String {
    switch block.status {
    case .running: "..."
    case .success: "✓"
    case .failed: "✗"
    case .cancelled: "!"
    case .unknown, .partial: "?"
    }
  }
}

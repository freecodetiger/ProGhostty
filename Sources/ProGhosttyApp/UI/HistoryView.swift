import ProGhosttyCore
import SwiftUI

struct HistoryView: View {
  @EnvironmentObject private var model: AppModel
  @State private var selected: CommandBlock.ID?

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        TextField("Search command, output, or cwd", text: $model.historySearch)
          .textFieldStyle(.roundedBorder)
          .onSubmit { model.searchHistory() }
        Button("Search") { model.searchHistory() }
        Button("Clear History", role: .destructive) { model.clearHistory() }
      }
      .padding(10)

      Divider()

      HStack(spacing: 0) {
        List(model.historyResults, selection: $selected) { block in
          VStack(alignment: .leading, spacing: 4) {
            HStack {
              Text(block.command ?? "(unknown command)")
                .font(.system(.body, design: .monospaced))
              Spacer()
              Text(block.status.rawValue)
                .foregroundStyle(block.status == .failed ? .red : .secondary)
            }
            Text(block.cwd ?? "")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          .tag(block.id)
        }
        .frame(minWidth: 380)

        Divider()

        if let block = selectedBlock {
          VStack(alignment: .leading, spacing: 10) {
            CommandBlockMarkerView(block: block)
            Text(block.command ?? "(command unavailable)")
              .font(.system(.body, design: .monospaced))
              .textSelection(.enabled)
            Text(block.outputPreview.isEmpty ? "(no output preview)" : block.outputPreview)
              .font(.system(.caption, design: .monospaced))
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            HStack {
              Button("Copy Command") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(block.command ?? "", forType: .string)
              }
              Button("Copy Output") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(block.outputPreview, forType: .string)
              }
              Button("Rerun") { model.rerun(block) }
                .disabled(block.command == nil)
            }
          }
          .padding(12)
        } else {
          Text("Select a history item")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      }
    }
    .onAppear { model.searchHistory() }
  }

  private var selectedBlock: CommandBlock? {
    guard let selected else { return nil }
    return model.historyResults.first { $0.id == selected }
  }
}

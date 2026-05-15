import SwiftUI

struct PluginManagerView: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        VStack(alignment: .leading) {
          Text("Default shell: \(model.pluginReport.defaultShell)")
          Text("zsh: \(model.pluginReport.zshExists ? "installed" : "missing")")
          Text("Homebrew: \(model.pluginReport.homebrewExists ? "installed" : "missing")")
          Text("oh-my-zsh: \(model.pluginReport.ohMyZshExists ? "installed" : "missing")")
        }
        Spacer()
        Button("Refresh") { model.refreshPlugins() }
      }
      .padding(12)

      Divider()

      List(model.pluginReport.recommendations) { recommendation in
        VStack(alignment: .leading, spacing: 6) {
          HStack {
            Text(recommendation.plan.name)
              .font(.headline)
            Spacer()
            Text(recommendation.isInstalled ? "Installed" : "Not installed")
              .foregroundStyle(recommendation.isInstalled ? .green : .secondary)
          }
          Text(recommendation.plan.reason)
            .foregroundStyle(.secondary)
          Text(recommendation.plan.commands.joined(separator: "\n"))
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
          if let snippet = recommendation.plan.configSnippet {
            Text(snippet)
              .font(.system(.caption, design: .monospaced))
              .textSelection(.enabled)
          }
        }
        .padding(.vertical, 6)
      }
    }
  }
}

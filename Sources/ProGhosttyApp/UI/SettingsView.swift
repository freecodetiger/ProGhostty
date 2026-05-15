import ProGhosttyCore
import SwiftUI

struct SettingsView: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    Form {
      Section("Terminal") {
        TextField("Default shell", text: $model.settings.defaultShell)
        TextField(
          "Default working directory",
          text: Binding(
            get: { model.settings.defaultWorkingDirectory ?? "" },
            set: { model.settings.defaultWorkingDirectory = $0.isEmpty ? nil : $0 }
          )
        )
        Stepper(value: $model.settings.fontSize, in: 10...28, step: 1) {
          Text("Font size: \(Int(model.settings.fontSize))")
        }
        Picker("Theme", selection: $model.settings.themeName) {
          ForEach(ThemeManager.builtInThemes, id: \.self) { theme in
            Text(theme).tag(theme)
          }
        }
      }

      Section("History and Blocks") {
        Toggle("Command blocks enabled", isOn: $model.settings.commandBlocksEnabled)
        Toggle("History enabled", isOn: $model.settings.historyEnabled)
        Toggle("Save output preview", isOn: $model.settings.saveOutputPreview)
        Stepper(value: $model.settings.maxOutputPreviewKB, in: 1...512, step: 1) {
          Text("Output preview limit: \(model.settings.maxOutputPreviewKB) KB")
        }
        Toggle("Rerun auto-enter", isOn: $model.settings.rerunAutoEnter)
      }

      Button("Save Settings") {
        model.saveSettings()
      }
    }
    .padding()
  }
}

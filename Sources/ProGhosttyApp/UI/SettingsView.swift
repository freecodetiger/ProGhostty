import AppKit
import ProGhosttyCore
import SwiftUI

struct SettingsView: View {
  @EnvironmentObject private var model: AppModel
  @State private var saveMessage = ""

  var body: some View {
    let text = model.appText

    VStack(spacing: 0) {
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 3) {
          Text(text.settings)
            .font(.system(size: 20, weight: .semibold))
          Text(text.settingsCaption)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
        }
        Spacer()
      }
      .padding(.horizontal, 24)
      .padding(.top, 22)
      .padding(.bottom, 14)

      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          SettingsSection(text.terminal) {
            SettingsRow(text.defaultShell) {
              TextField("/bin/zsh", text: $model.settings.defaultShell)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13, design: .monospaced))
            }

            SettingsRow(text.workingDirectory) {
              HStack(spacing: 8) {
                TextField(text.currentDirectory, text: Binding(
                  get: { model.settings.defaultWorkingDirectory ?? "" },
                  set: { model.settings.defaultWorkingDirectory = $0.isEmpty ? nil : $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13, design: .monospaced))

                Button(text.choose) {
                  chooseWorkingDirectory()
                }
              }
            }
          }

          SettingsSection(text.appearance) {
            SettingsRow(text.appLanguage) {
              Picker("", selection: $model.settings.appLanguage) {
                Text("System").tag("system")
                Text("English").tag("en")
                Text("简体中文").tag("zh-Hans")
              }
              .pickerStyle(.segmented)
              .labelsHidden()
            }

            SettingsRow(text.font) {
              Picker("", selection: $model.settings.fontFamily) {
                ForEach(FontManager.monospacedFonts(), id: \.self) { font in
                  Text(font).tag(font)
                }
              }
              .labelsHidden()
            }

            SettingsRow(text.fontSize) {
              HStack(spacing: 10) {
                Slider(value: $model.settings.fontSize, in: 10...28, step: 1)
                Text("\(Int(model.settings.fontSize))")
                  .font(.system(size: 12, weight: .medium, design: .monospaced))
                  .frame(width: 28, alignment: .trailing)
                  .foregroundStyle(.secondary)
              }
            }

            FontPreview(
              title: text.fontPreview,
              sample: text.fontPreviewSample,
              detail: text.fontPreviewDetail,
              fontFamily: model.settings.fontFamily,
              fontSize: model.settings.fontSize
            )

            Toggle(text.followSystem, isOn: $model.settings.followSystemAppearance)

            SettingsRow(text.theme) {
              Picker("", selection: $model.settings.themeName) {
                Text(text.light).tag("light")
                Text(text.dark).tag("dark")
              }
              .pickerStyle(.segmented)
              .labelsHidden()
              .disabled(model.settings.followSystemAppearance)
              .opacity(model.settings.followSystemAppearance ? 0.55 : 1)
            }
          }

          SettingsSection(text.history) {
            Toggle(text.commandBlocks, isOn: $model.settings.commandBlocksEnabled)
            Toggle(text.history, isOn: $model.settings.historyEnabled)
            Toggle(text.outputPreviews, isOn: $model.settings.saveOutputPreview)

            SettingsRow(text.previewLimit) {
              HStack(spacing: 10) {
                Stepper(value: $model.settings.maxOutputPreviewKB, in: 1...512, step: 1) {
                  Text("\(model.settings.maxOutputPreviewKB) KB")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                }
              }
            }

            Toggle(text.rerunCommandsWithReturn, isOn: $model.settings.rerunAutoEnter)
          }

          SettingsSection(text.shellEnhancements) {
            Toggle(text.pgControlCommands, isOn: $model.settings.pgControlCommandsEnabled)

            HStack(spacing: 12) {
              VStack(alignment: .leading, spacing: 4) {
                Text(text.shellTools)
                  .font(.system(size: 13, weight: .medium))
                Text(text.shellToolsCaption)
                  .font(.system(size: 12))
                  .foregroundStyle(.secondary)
              }
              Spacer()
              Button(text.open) {
                model.openPlugins()
              }
            }
          }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 22)
      }
      .scrollContentBackground(.hidden)

      Divider()
        .opacity(0.5)

      HStack(spacing: 10) {
        Text(saveMessage)
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
        Spacer()
        Button(text.restoreDefaults) {
          model.resetSettings()
          saveMessage = text.defaultsRestored
        }
        Button(text.save) {
          model.saveSettings()
          saveMessage = text.saved
        }
        .keyboardShortcut(.defaultAction)
      }
      .padding(.horizontal, 24)
      .padding(.vertical, 14)
      .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
    }
    .frame(minWidth: 560, minHeight: 460)
    .preferredColorScheme(model.appColorScheme)
    .background(Color(nsColor: .windowBackgroundColor))
  }

  private func chooseWorkingDirectory() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.directoryURL = model.settings.defaultWorkingDirectory.map {
      URL(fileURLWithPath: $0, isDirectory: true)
    }
    guard panel.runModal() == .OK, let url = panel.url else { return }
    model.settings.defaultWorkingDirectory = url.path
  }
}

private struct FontPreview: View {
  let title: String
  let sample: String
  let detail: String
  let fontFamily: String
  let fontSize: Double

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title)
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.secondary)

      VStack(alignment: .leading, spacing: 5) {
        Text(sample)
          .font(.custom(fontFamily, fixedSize: fontSize))
          .lineLimit(1)
          .minimumScaleFactor(0.82)
        Text(detail)
          .font(.custom(fontFamily, fixedSize: max(10, fontSize - 2)))
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .minimumScaleFactor(0.82)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Color(nsColor: .textBackgroundColor))
      .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .stroke(Color(nsColor: .separatorColor).opacity(0.36), lineWidth: 1)
      )
    }
  }
}

private struct SettingsSection<Content: View>: View {
  let title: String
  @ViewBuilder var content: Content

  init(_ title: String, @ViewBuilder content: () -> Content) {
    self.title = title
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(title)
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.secondary)

      VStack(alignment: .leading, spacing: 10) {
        content
      }
      .padding(14)
      .background(Color(nsColor: .controlBackgroundColor).opacity(0.72))
      .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .stroke(Color(nsColor: .separatorColor).opacity(0.38), lineWidth: 1)
      )
    }
  }
}

private struct SettingsRow<Content: View>: View {
  let title: String
  @ViewBuilder var content: Content

  init(_ title: String, @ViewBuilder content: () -> Content) {
    self.title = title
    self.content = content()
  }

  var body: some View {
    HStack(alignment: .center, spacing: 14) {
      Text(title)
        .font(.system(size: 13))
        .foregroundStyle(.primary)
        .frame(width: 150, alignment: .leading)
      content
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

import AppKit
import ProGhosttyCore
import SwiftUI

struct SettingsView: View {
  @EnvironmentObject private var model: AppModel
  @State private var shortcutRecorderState = ShortcutRecorderState(settings: .defaults)
  @State private var fontSearchText = ""
  @State private var showsAllFonts = false
  @State private var cjkFontSearchText = ""
  @State private var showsAllCJKFonts = false

  var body: some View {
    let text = model.appText
    let fontOptions = FontManager.fontOptions(
      currentFamily: model.settings.fontFamily,
      searchText: fontSearchText,
      includeAllFonts: showsAllFonts
    )
    let selectedFontOption = FontManager.fontOption(for: model.settings.fontFamily)
    let cjkFontOptions = FontManager.cjkFallbackOptions(
      currentFamily: model.settings.cjkFallbackFontFamily,
      searchText: cjkFontSearchText,
      includeAllFonts: showsAllCJKFonts
    )
    let selectedCJKFontOption = model.settings.cjkFallbackFontFamily.map(FontManager.fontOption(for:))

    VStack(spacing: 0) {
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 3) {
          Text(text.settings)
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(Color(nsColor: model.configurationPrimaryTextColor))
          Text(text.settingsCaption)
            .font(.system(size: 12))
            .foregroundStyle(Color(nsColor: model.configurationSecondaryTextColor))
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
                .foregroundColor(Color(nsColor: model.configurationPrimaryTextColor))
            }

            SettingsRow(text.workingDirectory) {
              HStack(spacing: 8) {
                TextField(text.currentDirectory, text: Binding(
                  get: { model.settings.defaultWorkingDirectory ?? "" },
                  set: { model.settings.defaultWorkingDirectory = $0.isEmpty ? nil : $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13, design: .monospaced))
                .foregroundColor(Color(nsColor: model.configurationPrimaryTextColor))

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

            SettingsRow(text.theme) {
              VStack(alignment: .leading, spacing: 8) {
                Toggle(text.followSystem, isOn: $model.settings.followSystemAppearance)
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

          }

          SettingsSection(text.font) {
            VStack(alignment: .leading, spacing: 10) {
              HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                  Text(text.font)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(nsColor: model.configurationPrimaryTextColor))

                  HStack(alignment: .center, spacing: 8) {
                    TextField(text.fontSearchPlaceholder, text: $fontSearchText)
                      .textFieldStyle(.roundedBorder)
                      .font(.system(size: 12))
                      .foregroundColor(Color(nsColor: model.configurationPrimaryTextColor))

                    Toggle(text.showAllFonts, isOn: $showsAllFonts)
                      .toggleStyle(.checkbox)
                      .font(.system(size: 11))
                      .fixedSize()
                  }

                  Picker("", selection: $model.settings.fontFamily) {
                    ForEach(fontOptions) { option in
                      Text(fontOptionLabel(option, text: text)).tag(option.familyName)
                    }
                  }
                  .labelsHidden()

                  HStack(spacing: 10) {
                    Slider(value: $model.settings.fontSize, in: 10...28, step: 1)
                    Text("\(Int(model.settings.fontSize))")
                      .font(.system(size: 12, weight: .medium, design: .monospaced))
                      .frame(width: 28, alignment: .trailing)
                      .foregroundStyle(Color(nsColor: model.configurationSecondaryTextColor))
                  }

                  HStack(alignment: .firstTextBaseline, spacing: 8) {
                    TextField(text.customFontName, text: $model.settings.fontFamily)
                      .textFieldStyle(.roundedBorder)
                      .font(.system(size: 12, design: .monospaced))
                      .foregroundColor(Color(nsColor: model.configurationPrimaryTextColor))

                    if let status = fontStatusLabel(selectedFontOption, text: text) {
                      Text(status)
                        .font(.system(size: 11))
                        .foregroundStyle(fontStatusColor(selectedFontOption))
                        .lineLimit(1)
                        .fixedSize()
                    }
                  }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)

                Rectangle()
                  .fill(Color(nsColor: model.configurationSeparatorColor).opacity(0.5))
                  .frame(width: 1)

                VStack(alignment: .leading, spacing: 8) {
                  Text(text.cjkFallbackFont)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(nsColor: model.configurationPrimaryTextColor))

                  HStack(alignment: .center, spacing: 8) {
                    TextField(text.fontSearchPlaceholder, text: $cjkFontSearchText)
                      .textFieldStyle(.roundedBorder)
                      .font(.system(size: 12))
                      .foregroundColor(Color(nsColor: model.configurationPrimaryTextColor))

                    Toggle(text.showAllFonts, isOn: $showsAllCJKFonts)
                      .toggleStyle(.checkbox)
                      .font(.system(size: 11))
                      .fixedSize()
                  }

                  Picker("", selection: cjkFallbackSelection) {
                    Text(text.systemCJKFallback).tag("")
                    ForEach(cjkFontOptions) { option in
                      Text(cjkFontOptionLabel(option, text: text)).tag(option.familyName)
                    }
                  }
                  .labelsHidden()

                  HStack(alignment: .firstTextBaseline, spacing: 8) {
                    TextField(text.customCJKFallbackName, text: cjkFallbackSelection)
                      .textFieldStyle(.roundedBorder)
                      .font(.system(size: 12, design: .monospaced))
                      .foregroundColor(Color(nsColor: model.configurationPrimaryTextColor))

                    if let status = cjkFontStatusLabel(selectedCJKFontOption, text: text) {
                      Text(status)
                        .font(.system(size: 11))
                        .foregroundStyle(cjkFontStatusColor(selectedCJKFontOption))
                        .lineLimit(1)
                        .fixedSize()
                    }
                  }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
              }

              HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(text.installedMonospacedFontsHint)
                Text(text.cjkFallbackHint)
              }
              .font(.system(size: 11))
              .foregroundStyle(Color(nsColor: model.configurationTertiaryTextColor))
              .lineLimit(2)
              .fixedSize(horizontal: false, vertical: true)

              FontPreview(
                title: text.fontPreview,
                sample: text.fontPreviewSample,
                detail: text.fontPreviewDetail,
                fontFamily: model.settings.fontFamily,
                cjkFallbackFontFamily: model.settings.cjkFallbackFontFamily,
                fontSize: model.settings.fontSize
              )
            }
          }

          SettingsSection(text.shortcuts) {
            ForEach(KeyboardShortcutAction.allCases) { action in
              ShortcutSettingsRow(
                title: shortcutTitle(action, text: text),
                binding: shortcutRecorderState.settings.shortcut(for: action),
                isRecording: shortcutRecorderState.recordingAction == action,
                text: text,
                beginRecording: {
                  shortcutRecorderState.settings = model.settings.keyboardShortcuts
                  shortcutRecorderState.beginRecording(action)
                },
                reset: {
                  shortcutRecorderState.settings = model.settings.keyboardShortcuts
                  shortcutRecorderState.reset(action)
                  model.settings.keyboardShortcuts = shortcutRecorderState.settings
                }
              )
            }

            if let conflict = shortcutRecorderState.conflictAction {
              Text("\(text.shortcutConflict) \(shortcutTitle(conflict, text: text))")
                .font(.system(size: 12))
                .foregroundStyle(.red)
            }
          }

          SettingsSection(text.taskCompletionNotifications) {
            VStack(alignment: .leading, spacing: 4) {
              Toggle(text.enableNotifications, isOn: $model.settings.notificationsEnabled)
              Text(text.enableNotificationsCaption)
                .font(.system(size: 12))
                .foregroundStyle(Color(nsColor: model.configurationSecondaryTextColor))
            }

            // Level-2 toggle: subordinate to the master switch above. Indented,
            // and disabled + dimmed until notifications are enabled.
            VStack(alignment: .leading, spacing: 4) {
              Toggle(text.notifyWhenFocused, isOn: $model.settings.notifyWhenFocused)
              Text(text.notifyWhenFocusedCaption)
                .font(.system(size: 12))
                .foregroundStyle(Color(nsColor: model.configurationSecondaryTextColor))
            }
            .padding(.leading, 18)
            .disabled(!model.settings.notificationsEnabled)
            .opacity(model.settings.notificationsEnabled ? 1 : 0.45)

            if model.settings.notificationsEnabled, !model.systemNotificationsAuthorized {
              HStack(spacing: 10) {
                Text(text.notificationsPermissionHint)
                  .font(.system(size: 12))
                  .foregroundStyle(Color(nsColor: model.configurationSecondaryTextColor))
                Spacer()
                Button(text.openSystemSettings) {
                  model.openSystemNotificationSettings()
                }
              }
            }
          }

          SettingsSection(text.pgControlSection) {
            Toggle(text.pgControlCommands, isOn: $model.settings.pgControlCommandsEnabled)
          }

          SettingsSection(text.about) {
            SettingsRow(text.version) {
              HStack(spacing: 10) {
                Text(model.appVersionString())
                  .font(.system(size: 13, design: .monospaced))
                  .foregroundStyle(Color(nsColor: model.configurationSecondaryTextColor))
                Spacer()
                Button(model.isCheckingForUpdates ? text.checkingForUpdates : text.checkForUpdates) {
                  Task { await model.checkForUpdates(manual: true) }
                }
                .disabled(model.isCheckingForUpdates)
              }
            }

            HStack {
              Spacer()
              Button(text.restoreDefaults, role: .destructive) {
                if confirmRestoreDefaults(text: text) {
                  model.resetSettings()
                  shortcutRecorderState = ShortcutRecorderState(settings: model.settings.keyboardShortcuts)
                }
              }
            }
          }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 22)
      }
      .scrollContentBackground(.hidden)

    }
    .frame(minWidth: 560, minHeight: 460)
    .preferredColorScheme(model.configurationColorScheme)
    .environment(\.colorScheme, model.configurationColorScheme)
    .foregroundStyle(Color(nsColor: model.configurationPrimaryTextColor))
    .background(Color(nsColor: model.configurationWindowBackgroundColor))
    .background(SettingsFocusResetHost())
    .background(ShortcutRecorderHost(
      isActive: shortcutRecorderState.recordingAction != nil,
      onRecord: { binding in
        commitShortcut(binding)
      },
      onCancel: {
        shortcutRecorderState.cancelRecording()
      }
    ))
    .onAppear {
      shortcutRecorderState = ShortcutRecorderState(settings: model.settings.keyboardShortcuts)
    }
  }

  private func fontOptionLabel(_ option: TerminalFontOption, text: AppText) -> String {
    if !option.isInstalled {
      return "\(option.familyName) · \(text.fontMissingStatus)"
    }
    return option.familyName
  }

  private var cjkFallbackSelection: Binding<String> {
    Binding(
      get: { model.settings.cjkFallbackFontFamily ?? "" },
      set: {
        let trimmed = $0.trimmingCharacters(in: .whitespacesAndNewlines)
        model.settings.cjkFallbackFontFamily = trimmed.isEmpty ? nil : trimmed
      }
    )
  }

  private func cjkFontOptionLabel(_ option: TerminalFontOption, text: AppText) -> String {
    if !option.isInstalled {
      return "\(option.familyName) · \(text.fontMissingStatus)"
    }
    return option.familyName
  }

  private func cjkFontStatusLabel(_ option: TerminalFontOption?, text: AppText) -> String? {
    guard let option else { return nil }
    if !option.isInstalled {
      return text.fontMissingStatus
    }
    return nil
  }

  private func cjkFontStatusColor(_ option: TerminalFontOption?) -> Color {
    guard let option else { return Color(nsColor: model.configurationTertiaryTextColor) }
    if !option.isInstalled {
      return .orange
    }
    return Color(nsColor: model.configurationTertiaryTextColor)
  }

  private func fontStatusLabel(_ option: TerminalFontOption, text: AppText) -> String? {
    if !option.isInstalled {
      return text.fontMissingStatus
    }
    return option.isRecommendedForTerminal ? nil : text.fontInstalledStatus
  }

  private func fontStatusColor(_ option: TerminalFontOption) -> Color {
    if !option.isInstalled {
      return .orange
    }
    return Color(nsColor: model.configurationTertiaryTextColor)
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

  private func commitShortcut(_ binding: KeyboardShortcutBinding) {
    shortcutRecorderState.settings = model.settings.keyboardShortcuts
    if shortcutRecorderState.record(binding) {
      model.settings.keyboardShortcuts = shortcutRecorderState.settings
    } else {
      NSSound.beep()
    }
  }

  private func confirmRestoreDefaults(text: AppText) -> Bool {
    let alert = NSAlert()
    alert.messageText = text.restoreDefaultsTitle
    alert.informativeText = text.restoreDefaultsMessage
    alert.alertStyle = .warning
    alert.addButton(withTitle: text.restoreDefaults)
    alert.addButton(withTitle: text.cancel)
    return alert.runModal() == .alertFirstButtonReturn
  }

  private func shortcutTitle(_ action: KeyboardShortcutAction, text: AppText) -> String {
    switch action {
    case .openSettings:
      return text.settings
    case .openWorkspaceSwitcher:
      return text.openWorkspaceSwitcher
    case .sideInput:
      return text.sideInput
    case .splitRight:
      return text.splitRight
    case .splitDown:
      return text.splitDown
    case .closePane:
      return text.closePane
    case .focusPreviousPane:
      return text.focusPreviousPane
    case .focusNextPane:
      return text.focusNextPane
    }
  }
}

private struct SettingsFocusResetHost: NSViewRepresentable {
  func makeNSView(context: Context) -> FocusResetView {
    let view = FocusResetView()
    view.installMonitor()
    return view
  }

  func updateNSView(_ view: FocusResetView, context: Context) {
    view.installMonitor()
  }

  final class FocusResetView: NSView {
    private var monitor: Any?

    func installMonitor() {
      guard monitor == nil else { return }
      monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
        guard
          let self,
          let window,
          event.window === window,
          let contentView = window.contentView
        else {
          return event
        }

        let point = contentView.convert(event.locationInWindow, from: nil)
        let hitView = contentView.hitTest(point)
        if hitView?.hasTextInputAncestor == true {
          return event
        }
        window.makeFirstResponder(nil)
        return event
      }
    }

    deinit {
      MainActor.assumeIsolated {
        if let monitor {
          NSEvent.removeMonitor(monitor)
        }
      }
    }
  }
}

private extension NSView {
  var hasTextInputAncestor: Bool {
    if self is NSTextView || self is NSTextField {
      return true
    }
    return superview?.hasTextInputAncestor ?? false
  }
}

private struct ShortcutSettingsRow: View {
  @EnvironmentObject private var model: AppModel
  let title: String
  let binding: KeyboardShortcutBinding
  let isRecording: Bool
  let text: AppText
  let beginRecording: () -> Void
  let reset: () -> Void

  var body: some View {
    SettingsRow(title) {
      HStack(spacing: 8) {
        Text(isRecording ? text.recordingShortcut : binding.displayString)
          .font(.system(size: 12, weight: .medium, design: .monospaced))
          .foregroundStyle(isRecording ? .primary : .secondary)
          .frame(minWidth: 84, alignment: .leading)
          .padding(.horizontal, 9)
          .padding(.vertical, 5)
          .background(Color(nsColor: model.configurationTextBackgroundColor))
          .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
          .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
              .stroke(Color(nsColor: model.configurationSeparatorColor).opacity(isRecording ? 0.72 : 0.36), lineWidth: 1)
          )

        Button(text.recordShortcut, action: beginRecording)
        Button(text.resetShortcut, action: reset)
          .foregroundStyle(Color(nsColor: model.configurationSecondaryTextColor))
      }
    }
  }
}

private struct ShortcutRecorderHost: NSViewRepresentable {
  let isActive: Bool
  let onRecord: (KeyboardShortcutBinding) -> Void
  let onCancel: () -> Void

  func makeNSView(context: Context) -> RecorderView {
    let view = RecorderView()
    view.onRecord = onRecord
    view.onCancel = onCancel
    view.isActive = isActive
    view.installMonitor()
    return view
  }

  func updateNSView(_ view: RecorderView, context: Context) {
    view.onRecord = onRecord
    view.onCancel = onCancel
    view.isActive = isActive
    view.installMonitor()
  }

  final class RecorderView: NSView {
    var isActive = false
    var onRecord: ((KeyboardShortcutBinding) -> Void)?
    var onCancel: (() -> Void)?
    private var monitor: Any?

    func installMonitor() {
      guard monitor == nil else { return }
      monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
        guard let self, isActive else { return event }
        if event.keyCode == 53 {
          onCancel?()
          return nil
        }
        guard let binding = KeyboardShortcutBinding(event: event) else {
          NSSound.beep()
          return nil
        }
        onRecord?(binding)
        return nil
      }
    }

    deinit {
      MainActor.assumeIsolated {
        if let monitor {
          NSEvent.removeMonitor(monitor)
        }
      }
    }
  }
}

private extension KeyboardShortcutBinding {
  init?(event: NSEvent) {
    let modifiers = event.proGhosttyShortcutModifiers
    guard !modifiers.isEmpty, let key = event.proGhosttyShortcutKey else { return nil }
    self.init(key: key, modifiers: modifiers)
  }
}

private extension NSEvent {
  var proGhosttyShortcutModifiers: Set<KeyboardShortcutModifier> {
    var result: Set<KeyboardShortcutModifier> = []
    if modifierFlags.contains(.command) {
      result.insert(.command)
    }
    if modifierFlags.contains(.control) {
      result.insert(.control)
    }
    if modifierFlags.contains(.option) {
      result.insert(.option)
    }
    if modifierFlags.contains(.shift) {
      result.insert(.shift)
    }
    return result
  }

  var proGhosttyShortcutKey: String? {
    switch keyCode {
    case 36, 76:
      return "return"
    case 48:
      return "tab"
    case 49:
      return "space"
    case 51, 117:
      return "delete"
    case 53:
      return "escape"
    case 123:
      return "leftArrow"
    case 124:
      return "rightArrow"
    case 125:
      return "downArrow"
    case 126:
      return "upArrow"
    default:
      return charactersIgnoringModifiers?.lowercased()
    }
  }
}

private struct FontPreview: View {
  @EnvironmentObject private var model: AppModel
  let title: String
  let sample: String
  let detail: String
  let fontFamily: String
  let cjkFallbackFontFamily: String?
  let fontSize: Double

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(title)
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(Color(nsColor: model.configurationSecondaryTextColor))

      VStack(alignment: .leading, spacing: 3) {
        Text(sample)
          .font(.custom(fontFamily, fixedSize: fontSize))
          .lineLimit(1)
          .minimumScaleFactor(0.82)
        Text(detail)
          .font(.custom(cjkFallbackFontFamily ?? fontFamily, fixedSize: max(10, fontSize - 2)))
          .foregroundStyle(Color(nsColor: model.configurationSecondaryTextColor))
          .lineLimit(1)
          .minimumScaleFactor(0.82)
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 7)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Color(nsColor: model.configurationTextBackgroundColor))
      .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .stroke(Color(nsColor: model.configurationSeparatorColor).opacity(0.36), lineWidth: 1)
      )
    }
  }
}

private struct SettingsSection<Content: View>: View {
  @EnvironmentObject private var model: AppModel
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
        .foregroundStyle(Color(nsColor: model.configurationSecondaryTextColor))

      VStack(alignment: .leading, spacing: 10) {
        content
      }
      .padding(14)
      .background(Color(nsColor: model.configurationSectionBackgroundColor).opacity(0.72))
      .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .stroke(Color(nsColor: model.configurationSeparatorColor).opacity(0.38), lineWidth: 1)
      )
    }
  }
}

private struct SettingsRow<Content: View>: View {
  @EnvironmentObject private var model: AppModel
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
        .foregroundStyle(Color(nsColor: model.configurationPrimaryTextColor))
        .frame(width: 150, alignment: .leading)
      content
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

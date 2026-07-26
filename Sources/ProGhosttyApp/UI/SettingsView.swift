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
  @State private var selectedCategory: SettingsCategory = .terminal
  @State private var searchText = ""
  @State private var highlightedItemID: String?
  @State private var notificationsToggle = false

  var body: some View {
    let text = model.appText

    VStack(spacing: 0) {
      NavigationSplitView {
        sidebar(text: text)
          .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 240)
      } detail: {
        detail(text: text)
      }
      .navigationSplitViewStyle(.balanced)

      Divider()
        .overlay(Color(nsColor: model.configurationSeparatorColor).opacity(0.5))
      HStack {
        Spacer()
        Button(text.restoreDefaults, role: .destructive) {
          if confirmRestoreDefaults(text: text) {
            model.resetSettings()
            shortcutRecorderState = ShortcutRecorderState(settings: model.settings.keyboardShortcuts)
          }
        }
      }
      .padding(.horizontal, 24)
      .padding(.vertical, 12)
    }
    .frame(minWidth: 680, minHeight: 480)
    .preferredColorScheme(model.configurationColorScheme)
    .environment(\.colorScheme, model.configurationColorScheme)
    .foregroundStyle(Color(nsColor: model.configurationPrimaryTextColor))
    .background(Color(nsColor: model.configurationWindowBackgroundColor))
    .background(SettingsFocusResetHost())
    .background(ShortcutRecorderHost(
      isActive: shortcutRecorderState.recordingAction != nil,
      onRecord: { binding in commitShortcut(binding) },
      onCancel: { shortcutRecorderState.cancelRecording() }
    ))
    .onAppear {
      shortcutRecorderState = ShortcutRecorderState(settings: model.settings.keyboardShortcuts)
      notificationsToggle = model.settings.notificationsEnabled
      model.refreshAgentNotifyHookStatus()
    }
    .onChange(of: model.settings.notificationsEnabled) { enabled in
      notificationsToggle = enabled
    }
    .onChange(of: selectedCategory) { _ in
      // NavigationSplitView relayout can reinstate the system window title.
      model.reassertSettingsWindowChrome()
    }
    .sheet(isPresented: $model.showAgentNotifyInstallSheet) {
      agentNotifyInstallSheet(text: text)
    }
    .sheet(isPresented: $model.showAgentNotifyUninstallSheet) {
      agentNotifyUninstallSheet(text: text)
    }
  }

  // MARK: Sidebar

  @ViewBuilder
  private func sidebar(text: AppText) -> some View {
    let results = SettingsIndex.results(query: searchText, text: text)
    VStack(spacing: 0) {
      HStack(spacing: 6) {
        Image(systemName: "magnifyingglass")
          .foregroundStyle(Color(nsColor: model.configurationSecondaryTextColor))
          .font(.system(size: 12))
        TextField(text.settingsSearchPlaceholder, text: $searchText)
          .textFieldStyle(.plain)
          .font(.system(size: 12))
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 7)
      .background(Color(nsColor: model.configurationSectionBackgroundColor).opacity(0.6))
      .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
      .padding(.horizontal, 10)
      .padding(.top, 10)

      if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        List(SettingsCategory.allCases, selection: $selectedCategory) { category in
          Label(category.title(text), systemImage: category.systemImage)
            .tag(category)
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
      } else if results.isEmpty {
        VStack {
          Spacer()
          Text(text.noSearchResults)
            .font(.system(size: 12))
            .foregroundStyle(Color(nsColor: model.configurationSecondaryTextColor))
          Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        List {
          ForEach(results) { item in
            Button {
              openSearchResult(item)
            } label: {
              VStack(alignment: .leading, spacing: 2) {
                Text(item.title(text))
                  .font(.system(size: 13))
                  .foregroundStyle(Color(nsColor: model.configurationPrimaryTextColor))
                Text(item.category.title(text))
                  .font(.system(size: 11))
                  .foregroundStyle(Color(nsColor: model.configurationSecondaryTextColor))
              }
            }
            .buttonStyle(.plain)
          }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
      }
    }
    .background(Color(nsColor: model.configurationWindowBackgroundColor))
  }

  private func openSearchResult(_ item: SettingsItem) {
    selectedCategory = item.category
    searchText = ""
    highlightedItemID = item.id
    Task { @MainActor in
      try? await Task.sleep(nanoseconds: 1_500_000_000)
      if highlightedItemID == item.id { highlightedItemID = nil }
    }
  }

  // MARK: Detail

  @ViewBuilder
  private func detail(text: AppText) -> some View {
    ScrollViewReader { proxy in
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          switch selectedCategory {
          case .terminal: terminalPane(text: text)
          case .appearance: appearancePane(text: text)
          case .font: fontPane(text: text)
          case .shortcuts: shortcutsPane(text: text)
          case .notifications: notificationsPane(text: text)
          case .about: aboutPane(text: text)
          }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 22)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .scrollContentBackground(.hidden)
      .onChange(of: highlightedItemID) { id in
        guard let id else { return }
        withAnimation { proxy.scrollTo(id, anchor: .center) }
      }
    }
  }

  // MARK: Panes

  @ViewBuilder
  private func terminalPane(text: AppText) -> some View {
    SettingsSection(text.terminal) {
      SettingsRow(text.defaultShell) {
        TextField("/bin/zsh", text: $model.settings.defaultShell)
          .textFieldStyle(.roundedBorder)
          .font(.system(size: 13, design: .monospaced))
          .foregroundColor(Color(nsColor: model.configurationPrimaryTextColor))
      }
      .id("terminal.shell")

      SettingsRow(text.workingDirectory) {
        HStack(spacing: 8) {
          TextField(text.currentDirectory, text: Binding(
            get: { model.settings.defaultWorkingDirectory ?? "" },
            set: { model.settings.defaultWorkingDirectory = $0.isEmpty ? nil : $0 }
          ))
          .textFieldStyle(.roundedBorder)
          .font(.system(size: 13, design: .monospaced))
          .foregroundColor(Color(nsColor: model.configurationPrimaryTextColor))

          Button(text.choose) { chooseWorkingDirectory() }
        }
      }
      .id("terminal.cwd")

      VStack(alignment: .leading, spacing: 4) {
        Toggle(text.programTitleReporting, isOn: $model.settings.programTitleReportingEnabled)
        Text(text.programTitleReportingCaption)
          .font(.system(size: 12))
          .foregroundStyle(Color(nsColor: model.configurationSecondaryTextColor))
      }
      .id("terminal.programTitle")
    }
    .settingsHighlight(id: "terminal.shell", current: highlightedItemID)
  }

  @ViewBuilder
  private func appearancePane(text: AppText) -> some View {
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
      .id("appearance.language")

      SettingsRow(text.theme) {
        VStack(alignment: .leading, spacing: 10) {
          Toggle(text.followSystem, isOn: $model.settings.followSystemAppearance)

          if model.settings.followSystemAppearance {
            VStack(alignment: .leading, spacing: 6) {
              Text(text.darkPreset)
                .font(.system(size: 12))
                .foregroundStyle(Color(nsColor: model.configurationSecondaryTextColor))
              Picker("", selection: softDarkPreferredBinding) {
                Text(text.dark).tag(false)
                Text(text.softDark).tag(true)
              }
              .pickerStyle(.segmented)
              .labelsHidden()

              Text(text.lightPreset)
                .font(.system(size: 12))
                .foregroundStyle(Color(nsColor: model.configurationSecondaryTextColor))
              Picker("", selection: softLightPreferredBinding) {
                Text(text.light).tag(false)
                Text(text.softLight).tag(true)
              }
              .pickerStyle(.segmented)
              .labelsHidden()
            }
          } else {
            Picker("", selection: themeNameBinding) {
              Text(text.dark).tag("dark")
              Text(text.softDark).tag("soft-dark")
              Text(text.light).tag("light")
              Text(text.softLight).tag("soft-light")
            }
            .pickerStyle(.menu)
            .labelsHidden()
          }
        }
      }
      .id("appearance.theme")
    }
  }

  @ViewBuilder
  private func shortcutsPane(text: AppText) -> some View {
    SettingsSection(text.shortcuts) {
      ForEach(KeyboardShortcutAction.allCases) { action in
        ShortcutSettingsRow(
          title: AppText.shortcutActionTitle(action, text: text),
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
        .id("shortcut.\(action.rawValue)")
      }

      if let conflict = shortcutRecorderState.conflictAction {
        Text("\(text.shortcutConflict) \(AppText.shortcutActionTitle(conflict, text: text))")
          .font(.system(size: 12))
          .foregroundStyle(.red)
      }
    }
  }

  @ViewBuilder
  private func notificationsPane(text: AppText) -> some View {
    SettingsSection(text.taskCompletionNotifications) {
      VStack(alignment: .leading, spacing: 4) {
        Toggle(text.enableNotifications, isOn: notificationsEnabledBinding)
        Text(text.enableNotificationsCaption)
          .font(.system(size: 12))
          .foregroundStyle(Color(nsColor: model.configurationSecondaryTextColor))
      }
      .id("notifications.enable")

      agentHooksStatusRow(text: text)
        .id("notifications.hooks")

      if let error = model.agentNotifyHookError, !error.isEmpty {
        Text(error)
          .font(.system(size: 12))
          .foregroundStyle(.red)
      }

      VStack(alignment: .leading, spacing: 4) {
        Toggle(text.notifyWhenFocused, isOn: $model.settings.notifyWhenFocused)
        Text(text.notifyWhenFocusedCaption)
          .font(.system(size: 12))
          .foregroundStyle(Color(nsColor: model.configurationSecondaryTextColor))
      }
      .settingsSubordinate(enabled: model.settings.notificationsEnabled && model.agentNotifyHooksStatus.isReady)
      .id("notifications.focused")

      if model.settings.notificationsEnabled, !model.systemNotificationsAuthorized {
        HStack(spacing: 10) {
          Text(text.notificationsPermissionHint)
            .font(.system(size: 12))
            .foregroundStyle(Color(nsColor: model.configurationSecondaryTextColor))
          Spacer()
          Button(text.openSystemSettings) { model.openSystemNotificationSettings() }
        }
      }
    }
    .settingsHighlight(id: "notifications.enable", current: highlightedItemID)
    .onAppear { model.refreshAgentNotifyHookStatus() }
  }

  private var notificationsEnabledBinding: Binding<Bool> {
    Binding(
      get: { notificationsToggle },
      set: { newValue in
        notificationsToggle = newValue
        model.setNotificationsEnabled(newValue)
        // If install was cancelled, model leaves settings off — resync toggle.
        notificationsToggle = model.settings.notificationsEnabled
      }
    )
  }

  /// Manual theme picker: keep Soft family prefs in sync with the chosen id.
  private var themeNameBinding: Binding<String> {
    Binding(
      get: { model.settings.themeName },
      set: { name in
        let normalized = ThemeManager.normalizedThemeName(name)
        model.settings.themeName = normalized
        switch normalized {
        case "soft-dark":
          model.settings.softDarkPreferred = true
        case "dark":
          model.settings.softDarkPreferred = false
        case "soft-light":
          model.settings.softLightPreferred = true
        case "light":
          model.settings.softLightPreferred = false
        default:
          break
        }
      }
    )
  }

  private var softDarkPreferredBinding: Binding<Bool> {
    Binding(
      get: { model.settings.softDarkPreferred },
      set: { preferred in
        model.settings.softDarkPreferred = preferred
        if !model.settings.followSystemAppearance, ThemeManager.isDarkFamily(model.settings.themeName) {
          model.settings.themeName = preferred ? "soft-dark" : "dark"
        }
      }
    )
  }

  private var softLightPreferredBinding: Binding<Bool> {
    Binding(
      get: { model.settings.softLightPreferred },
      set: { preferred in
        model.settings.softLightPreferred = preferred
        if !model.settings.followSystemAppearance, !ThemeManager.isDarkFamily(model.settings.themeName) {
          model.settings.themeName = preferred ? "soft-light" : "light"
        }
      }
    )
  }

  @ViewBuilder
  private func agentHooksStatusRow(text: AppText) -> some View {
    let status = model.agentNotifyHooksStatus
    HStack(alignment: .top, spacing: 10) {
      VStack(alignment: .leading, spacing: 2) {
        Text(agentHooksStatusLabel(status: status, text: text))
          .font(.system(size: 12))
          .foregroundStyle(Color(nsColor: model.configurationSecondaryTextColor))
        if let detail = status.detail, !detail.isEmpty {
          Text(detail)
            .font(.system(size: 11))
            .foregroundStyle(Color(nsColor: model.configurationSecondaryTextColor).opacity(0.85))
        }
      }
      Spacer()
      if status.isReady {
        EmptyView()
      } else if status.isMissing {
        Button(text.agentHooksInstall) { model.repairAgentNotifyHooks() }
          .disabled(model.isInstallingAgentNotifyHooks)
      } else {
        Button(text.agentHooksRepair) { model.repairAgentNotifyHooks() }
          .disabled(model.isInstallingAgentNotifyHooks)
      }
    }
  }

  private func agentHooksStatusLabel(status: AgentNotifyHookStatus, text: AppText) -> String {
    if status.isReady { return text.agentHooksReady }
    if status.isMissing { return text.agentHooksMissing }
    return text.agentHooksPartial
  }

  @ViewBuilder
  private func agentNotifyInstallSheet(text: AppText) -> some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(text.agentHooksInstallTitle)
        .font(.system(size: 15, weight: .semibold))
      Text(text.agentHooksInstallMessage)
        .font(.system(size: 12))
        .foregroundStyle(Color(nsColor: model.configurationSecondaryTextColor))
        .fixedSize(horizontal: false, vertical: true)
      if let error = model.agentNotifyHookError, !error.isEmpty {
        Text(error)
          .font(.system(size: 12))
          .foregroundStyle(.red)
      }
      HStack {
        Spacer()
        Button(text.cancel) { model.cancelInstallAgentNotifyHooks() }
          .keyboardShortcut(.cancelAction)
        Button(text.agentHooksInstallConfirm) { model.confirmInstallAgentNotifyHooks() }
          .keyboardShortcut(.defaultAction)
          .disabled(model.isInstallingAgentNotifyHooks)
      }
    }
    .padding(20)
    .frame(minWidth: 420)
  }

  @ViewBuilder
  private func agentNotifyUninstallSheet(text: AppText) -> some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(text.agentHooksUninstallTitle)
        .font(.system(size: 15, weight: .semibold))
      Text(text.agentHooksUninstallMessage)
        .font(.system(size: 12))
        .foregroundStyle(Color(nsColor: model.configurationSecondaryTextColor))
        .fixedSize(horizontal: false, vertical: true)
      HStack {
        Spacer()
        Button(text.agentHooksUninstallKeep) {
          model.confirmUninstallAgentNotifyHooks(removeHooks: false)
        }
        Button(text.agentHooksUninstallConfirm, role: .destructive) {
          model.confirmUninstallAgentNotifyHooks(removeHooks: true)
        }
        .keyboardShortcut(.defaultAction)
      }
    }
    .padding(20)
    .frame(minWidth: 400)
  }

  @ViewBuilder
  private func aboutPane(text: AppText) -> some View {
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
      .id("about.version")
    }
  }

  @ViewBuilder
  private func fontPane(text: AppText) -> some View {
    let fontOptions = FontCatalog.fontOptions(
      currentFamily: model.settings.fontFamily,
      searchText: fontSearchText,
      includeAllFonts: showsAllFonts
    )
    let selectedFontOption = FontCatalog.fontOption(for: model.settings.fontFamily)
    let cjkFontOptions = FontCatalog.cjkFallbackOptions(
      currentFamily: model.settings.cjkFallbackFontFamily,
      searchText: cjkFontSearchText,
      includeAllFonts: showsAllCJKFonts
    )
    let selectedCJKFontOption = model.settings.cjkFallbackFontFamily.map(FontCatalog.fontOption(for:))

    SettingsSection(text.font) {
      // Primary font — the first-class control, always visible.
      VStack(alignment: .leading, spacing: 8) {
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
        .id("font.size")

        FontPreview(
          title: text.fontPreview,
          sample: text.fontPreviewSample,
          detail: text.fontPreviewDetail,
          fontFamily: model.settings.fontFamily,
          cjkFallbackFontFamily: model.settings.cjkFallbackFontFamily,
          fontSize: model.settings.fontSize
        )
      }
      .id("font.family")

      // Advanced — search, show-all, exact name. Collapsed by default.
      DisclosureGroup(text.fontAdvanced) {
        VStack(alignment: .leading, spacing: 8) {
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

          Text(text.installedMonospacedFontsHint)
            .font(.system(size: 11))
            .foregroundStyle(Color(nsColor: model.configurationTertiaryTextColor))
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 6)
      }
      .id("font.advanced")

      // CJK fallback — advanced, collapsed by default.
      DisclosureGroup(text.cjkFallbackFont) {
        VStack(alignment: .leading, spacing: 8) {
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

          Text(text.cjkFallbackHint)
            .font(.system(size: 11))
            .foregroundStyle(Color(nsColor: model.configurationTertiaryTextColor))
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 6)
      }
      .id("font.cjk")
    }
    .settingsHighlight(id: "font.family", current: highlightedItemID)
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
    AppText.shortcutActionTitle(action, text: text)
  }
}

extension View {
  /// Briefly highlights a settings group when the user jumps to it from a
  /// search result (matched by `id`).
  @ViewBuilder
  func settingsHighlight(id: String, current: String?) -> some View {
    overlay(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .stroke(Color.accentColor, lineWidth: current == id ? 2 : 0)
        .animation(.easeInOut(duration: 0.25), value: current)
        .allowsHitTesting(false)
    )
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

extension View {
  /// Expresses a settings control that is subordinate to a parent toggle:
  /// indented, and disabled + dimmed when the parent is off. Used to keep the
  /// "child option depends on parent switch" hierarchy consistent across panes.
  func settingsSubordinate(enabled: Bool) -> some View {
    padding(.leading, 18)
      .disabled(!enabled)
      .opacity(enabled ? 1 : 0.45)
  }
}

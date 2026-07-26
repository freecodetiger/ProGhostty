import AppKit
import ProGhosttyCore

/// Stateless NSAlert wrappers for destructive-action confirmations.
///
/// Extracted from `AppModel` (debt spec 3-2). Each prompt is a RunLoop-blocking
/// modal; localized copy comes in via `AppText` per call so runtime language
/// switches stay honored.
@MainActor
struct ConfirmationPrompts {
  func confirmLayoutRestoreClosingPanes(count: Int) -> Bool {
    let alert = NSAlert()
    alert.messageText = "Restore layout?"
    alert.informativeText = "Restoring this layout will close \(count) pane session\(count == 1 ? "" : "s")."
    alert.alertStyle = .warning
    alert.addButton(withTitle: "Restore")
    alert.addButton(withTitle: "Cancel")
    return alert.runModal() == .alertFirstButtonReturn
  }

  func confirmWorkspaceDeletion(_ workspace: Workspace, runningPaneCount: Int, text: AppText) -> Bool {
    let alert = NSAlert()
    alert.messageText = text.deleteWorkspaceConfirmationTitle
    alert.informativeText = text.deleteWorkspaceConfirmationMessage(
      workspace.name,
      runningPaneCount: runningPaneCount
    )
    alert.alertStyle = .warning
    alert.addButton(withTitle: text.deleteWorkspace)
    alert.addButton(withTitle: text.cancel)
    alert.buttons.first?.keyEquivalent = "\r"
    return alert.runModal() == .alertFirstButtonReturn
  }

  /// Quit-specific variant of the foreground-process guard (⌘Q path).
  func confirmQuitWithForegroundProcess(text: AppText) -> Bool {
    let alert = NSAlert()
    alert.messageText = text.localized(
      "A foreground process is running. Quit anyway?",
      "有前台进程正在运行。确定退出吗？"
    )
    alert.informativeText = text.localized(
      "Quitting will close all panes and terminate any running processes.",
      "退出将关闭所有分屏并终止所有运行中的进程。"
    )
    alert.addButton(withTitle: text.localized("Quit", "退出"))
    alert.addButton(withTitle: text.cancel)
    alert.alertStyle = .warning
    return alert.runModal() == .alertFirstButtonReturn
  }

  func confirmPaneCloseWithForegroundProcess(text: AppText) -> Bool {
    let alert = NSAlert()
    alert.messageText = text.closePaneConfirmationTitle
    alert.informativeText = text.closePaneConfirmationMessage
    alert.alertStyle = .warning
    alert.addButton(withTitle: text.closePane)
    alert.addButton(withTitle: text.cancel)
    alert.buttons.first?.keyEquivalent = "\r"
    return alert.runModal() == .alertFirstButtonReturn
  }

  /// Modal rename prompt with an inline text field. Returns the entered name,
  /// or nil when cancelled.
  func promptRenamePane(currentLabel: String, text: AppText) -> String? {
    let alert = NSAlert()
    alert.messageText = text.renamePane
    alert.informativeText = ""
    alert.alertStyle = .informational
    alert.addButton(withTitle: text.ok)
    alert.addButton(withTitle: text.cancel)

    let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
    textField.stringValue = currentLabel
    textField.font = .systemFont(ofSize: 13)
    textField.placeholderString = text.renamePanePlaceholder
    alert.accessoryView = textField
    textField.selectText(nil)

    alert.window.initialFirstResponder = textField
    guard alert.runModal() == .alertFirstButtonReturn else { return nil }
    return textField.stringValue
  }
}

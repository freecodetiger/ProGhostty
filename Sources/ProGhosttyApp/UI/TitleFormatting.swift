import Foundation

/// Pure string/path formatting for titlebar labels and workspace names.
///
/// Stateless namespace extracted from `AppModel` (debt spec 3-1) so titlebar
/// text rules are directly testable and reusable outside the view model.
enum TitleFormatting {
  /// Collapses a workspace title to its compact titlebar form: trimmed, path
  /// titles reduced to their last component, empty falls back to "ProGhostty".
  static func compactTitlebarTitle(_ title: String) -> String {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "ProGhostty" }
    return compactPathComponent(trimmed) ?? trimmed
  }

  /// Reduces an absolute or `~`-prefixed path to its last component; `/` and
  /// the home directory keep their symbolic forms. Non-path strings pass
  /// through unchanged; nil/empty yields nil.
  static func compactPathComponent(_ path: String?) -> String? {
    guard let path, !path.isEmpty else { return nil }
    if path == "/" { return "/" }
    if path == NSHomeDirectory() { return "~" }
    guard path.hasPrefix("/") || path.hasPrefix("~") else { return path }
    let component = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath).lastPathComponent
    return component.isEmpty ? path : component
  }

  /// Trims a user-entered workspace name; empty falls back to "Workspace".
  static func normalizedWorkspaceName(_ name: String) -> String {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "Workspace" : trimmed
  }
}

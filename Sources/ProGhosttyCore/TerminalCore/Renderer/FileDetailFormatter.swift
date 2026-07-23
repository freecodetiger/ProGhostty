import Foundation

/// Formats a clicked file's raw facts into the icon+text detail rows shown above
/// the actions in the semantic-object popover. Pure — no filesystem access; the
/// App layer resolves the facts. The absolute path is NOT shown (too long); it
/// is used only for Copy Path. Relative times + byte sizes localized via
/// `text.locale`.
public enum FileDetailFormatter {
  /// One quiet grey info row: an SF Symbol + its localized value.
  public struct Row: Equatable, Sendable {
    public var symbol: String
    public var text: String
    public init(symbol: String, text: String) {
      self.symbol = symbol
      self.text = text
    }
  }

  public static func rows(
    for facts: TerminalFileFacts,
    text: SemanticLinkText,
    now: Date = Date()
  ) -> [Row] {
    let relative = RelativeDateTimeFormatter()
    relative.unitsStyle = .full
    relative.locale = text.locale

    var out: [Row] = []
    if let modified = facts.modified {
      out.append(Row(symbol: "clock",
                     text: "\(text.modifiedLabel) · \(relative.localizedString(for: modified, relativeTo: now))"))
    }
    if let created = facts.created {
      out.append(Row(symbol: "calendar",
                     text: "\(text.createdLabel) · \(relative.localizedString(for: created, relativeTo: now))"))
    }
    if facts.isDirectory {
      out.append(Row(symbol: "folder", text: text.folderLabel))
    } else if let size = facts.size {
      let formatter = ByteCountFormatter()
      formatter.countStyle = .file
      out.append(Row(symbol: "internaldrive", text: formatter.string(fromByteCount: Int64(size))))
    }
    return out
  }
}

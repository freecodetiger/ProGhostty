import Foundation

public enum TerminalDraggedPathFormatter {
  public static func formattedText(for urls: [URL]) -> String? {
    let arguments = urls.compactMap { url -> String? in
      guard url.isFileURL else { return nil }
      return shellSingleQuotedArgument(url.path)
    }
    guard !arguments.isEmpty else { return nil }
    return arguments.joined(separator: " ")
  }

  public static func shellSingleQuotedArgument(_ path: String) -> String {
    "'\(path.replacingOccurrences(of: "'", with: "'\\''"))'"
  }
}

import Foundation

/// Decides whether a resolved filesystem path should open the markdown preview
/// float instead of the link popover. Pure and unit-testable; the grid view
/// resolves a clicked `.filePath` target via `fileInfoProvider` and consults
/// this with the resulting absolute path.
public enum MarkdownPath {
  public static func isMarkdown(_ absolutePath: String) -> Bool {
    let ext = URL(fileURLWithPath: absolutePath).pathExtension.lowercased()
    return ext == "md" || ext == "markdown"
  }
}

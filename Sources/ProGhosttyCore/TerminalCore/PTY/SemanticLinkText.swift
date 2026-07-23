import Foundation

/// Localized labels for the semantic-object popover + file detail lines. Pushed
/// from the App layer (which owns `AppText` / the language setting) into the
/// grid view, mirroring how the palette is pushed in. Core stays free of the
/// localization table; defaults are English so Core is usable standalone.
public struct SemanticLinkText: Sendable, Equatable {
  public var openInBrowser: String
  public var copyLink: String
  public var revealInFinder: String
  public var openFolder: String
  public var copyPath: String
  public var modifiedLabel: String
  public var createdLabel: String
  public var folderLabel: String
  /// Locale for relative-time + byte-size formatting, so detail lines follow the
  /// app language rather than the system locale.
  public var locale: Locale

  public init(
    openInBrowser: String = "Open in Browser",
    copyLink: String = "Copy Link",
    revealInFinder: String = "Reveal in Finder",
    openFolder: String = "Open Folder",
    copyPath: String = "Copy Path",
    modifiedLabel: String = "Modified",
    createdLabel: String = "Created",
    folderLabel: String = "Folder",
    locale: Locale = .current
  ) {
    self.openInBrowser = openInBrowser
    self.copyLink = copyLink
    self.revealInFinder = revealInFinder
    self.openFolder = openFolder
    self.copyPath = copyPath
    self.modifiedLabel = modifiedLabel
    self.createdLabel = createdLabel
    self.folderLabel = folderLabel
    self.locale = locale
  }
}

import Foundation

public enum PaneSplitCwdResolver {
  public static func cwd(
    forPane paneID: UUID,
    in root: PaneNode,
    cwdBySession: [TerminalSessionID: String],
    liveWorkingDirectory: String? = nil,
    workspaceRootPath: String?,
    defaultWorkingDirectory: String?
  ) -> String {
    if let liveWorkingDirectory = firstNonEmpty(liveWorkingDirectory) {
      return liveWorkingDirectory
    }
    return PaneTreeReducer.cwd(
      forPane: paneID,
      in: root,
      cwdBySession: cwdBySession,
      fallback: firstNonEmpty(workspaceRootPath, defaultWorkingDirectory)
    )
    ?? firstNonEmpty(workspaceRootPath, defaultWorkingDirectory)
    ?? FileManager.default.homeDirectoryForCurrentUser.path
  }

  private static func firstNonEmpty(_ values: String?...) -> String? {
    for value in values {
      let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      if !trimmed.isEmpty {
        return trimmed
      }
    }
    return nil
  }
}

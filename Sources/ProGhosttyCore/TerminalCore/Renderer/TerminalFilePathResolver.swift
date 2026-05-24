import Foundation

public enum TerminalFilePathResolver {
  public enum Error: Swift.Error, Equatable {
    case missingWorkingDirectory
    case pathNotFound
  }

  public static func resolve(
    _ target: TerminalFilePathTarget,
    cwd: String?,
    homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
    fileManager: FileManager = .default
  ) throws -> URL {
    let expandedPath: String
    if target.rawPath.hasPrefix("/") {
      expandedPath = target.rawPath
    } else if target.rawPath == "~" {
      expandedPath = homeDirectory
    } else if target.rawPath.hasPrefix("~/") {
      expandedPath = homeDirectory + String(target.rawPath.dropFirst())
    } else {
      guard let cwd, !cwd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw Error.missingWorkingDirectory
      }
      expandedPath = URL(fileURLWithPath: cwd).appendingPathComponent(target.rawPath).standardizedFileURL.path
    }

    let url = URL(fileURLWithPath: expandedPath).standardizedFileURL
    guard fileManager.fileExists(atPath: url.path) else {
      throw Error.pathNotFound
    }
    return url
  }
}

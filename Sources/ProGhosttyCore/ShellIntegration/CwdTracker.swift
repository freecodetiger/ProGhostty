import Foundation

public enum CwdTracker {
  public static func cwd(from sequence: OscSequence) -> String? {
    guard sequence.command == "7", let rawURI = sequence.parameters.first else {
      return nil
    }

    if let kittyCwd = cwdFromKittyShellCwd(rawURI) {
      return kittyCwd
    }

    guard let url = URL(string: rawURI), url.scheme == "file" else {
      return rawURI.hasPrefix("/") ? rawURI : nil
    }

    return url.path.removingPercentEncoding ?? url.path
  }

  private static func cwdFromKittyShellCwd(_ rawURI: String) -> String? {
    let prefix = "kitty-shell-cwd://"
    guard rawURI.hasPrefix(prefix) else { return nil }

    let remainder = rawURI.dropFirst(prefix.count)
    guard let pathStart = remainder.firstIndex(of: "/") else { return nil }
    let path = String(remainder[pathStart...])
    return path.isEmpty ? nil : path
  }
}

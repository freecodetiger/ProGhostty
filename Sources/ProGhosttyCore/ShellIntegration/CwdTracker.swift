import Foundation

public enum CwdTracker {
  public static func cwd(from sequence: OscSequence) -> String? {
    guard sequence.command == "7", let rawURI = sequence.parameters.first else {
      return nil
    }

    guard let url = URL(string: rawURI), url.scheme == "file" else {
      return rawURI.hasPrefix("/") ? rawURI : nil
    }

    return url.path.removingPercentEncoding ?? url.path
  }
}

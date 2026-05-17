import Foundation

@MainActor
enum DebugLog {
  private static let url = URL(fileURLWithPath: "/tmp/proghostty-debug.log")
  private static let isEnabled = ProcessInfo.processInfo.environment["PROGHOSTTY_DEBUG_LOG"] == "1"

  static func write(_ message: String) {
    guard isEnabled else { return }
    let line = "[\(Date())] \(message)\n"
    guard let data = line.data(using: .utf8) else { return }
    if FileManager.default.fileExists(atPath: url.path) {
      if let handle = try? FileHandle(forWritingTo: url) {
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
      }
    } else {
      try? data.write(to: url)
    }
  }
}

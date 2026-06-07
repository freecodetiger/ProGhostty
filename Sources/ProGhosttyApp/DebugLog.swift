import Foundation
import ProGhosttyCore

@MainActor
enum DebugLog {
  private static let url = URL(fileURLWithPath: "/tmp/proghostty-debug.log")
  private static let isEnabled = ProcessInfo.processInfo.environment["PROGHOSTTY_DEBUG_LOG"] == "1"
  private static let maxBytes = Int(ProcessInfo.processInfo.environment["PROGHOSTTY_DEBUG_LOG_MAX_BYTES"] ?? "")
    ?? 2 * 1024 * 1024
  private static let sink = BoundedDebugLogSink(url: url, maxBytes: maxBytes, batchSize: 32)

  static func write(_ message: String) {
    guard isEnabled else { return }
    sink.write(message)
  }
}

import Foundation

public enum ClipboardTracker {
  /// Extracts clipboard content from an OSC 52 sequence (`ESC]52;Pc;Pd …`).
  ///
  /// Returns the base64-decoded payload as UTF-8 text, or nil when:
  /// - the sequence is not OSC 52,
  /// - the payload is `?` (a read query, which ProGhostty does not support),
  /// - the payload is not valid base64, or not valid UTF-8 after decoding.
  ///
  /// An empty payload decodes to `""`, which callers treat as "clear the
  /// clipboard". The selection (`c`/`s`/`p`) is ignored: macOS has a single
  /// system clipboard.
  public static func content(from sequence: OscSequence) -> String? {
    guard sequence.command == "52", !sequence.parameters.isEmpty else { return nil }
    let payload = sequence.parameters.dropFirst().joined(separator: ";")
    guard payload != "?" else { return nil }
    guard let decoded = Data(base64Encoded: payload) else { return nil }
    // ponytail: text-only. Binary clipboard payloads (non-UTF8) are dropped.
    return String(data: decoded, encoding: .utf8)
  }
}

import Foundation

public enum TitleTracker {
  /// Extracts the reported title from an OSC 0/1/2 sequence.
  /// Returns nil for other commands or when the sequence carries no payload
  /// (`ESC]0 BEL` without a `;`). An empty payload (`ESC]0; BEL`) yields ""
  /// so callers can treat it as "reset title".
  public static func title(from sequence: OscSequence) -> String? {
    guard
      sequence.command == "0" || sequence.command == "1" || sequence.command == "2",
      !sequence.parameters.isEmpty
    else {
      return nil
    }
    return sequence.parameters.joined(separator: ";")
  }
}

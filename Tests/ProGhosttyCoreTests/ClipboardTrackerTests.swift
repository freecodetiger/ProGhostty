import Foundation
import Testing

@testable import ProGhosttyCore

@Suite("Clipboard tracker")
struct ClipboardTrackerTests {
  private func sequence(_ raw: String) -> OscSequence {
    var parser = OscParser()
    let sequences = parser.parse(Data("\u{1B}]\(raw)\u{07}".utf8))
    #expect(sequences.count == 1)
    return sequences[0]
  }

  @Test func decodesOsc52Write() {
    // "abc" base64 == "YWJj"
    #expect(ClipboardTracker.content(from: sequence("52;c;YWJj")) == "abc")
  }

  @Test func decodesOsc52WithDefaultSelection() {
    #expect(ClipboardTracker.content(from: sequence("52;;YWJj")) == "abc")
  }

  @Test func emptyPayloadClearsClipboard() {
    #expect(ClipboardTracker.content(from: sequence("52;c;")) == "")
  }

  @Test func readQueryIsIgnored() {
    #expect(ClipboardTracker.content(from: sequence("52;c;?")) == nil)
  }

  @Test func ignoresOtherCommands() {
    #expect(ClipboardTracker.content(from: sequence("0;hello")) == nil)
    #expect(ClipboardTracker.content(from: sequence("7;file:///tmp")) == nil)
  }

  @Test func invalidBase64IsIgnored() {
    #expect(ClipboardTracker.content(from: sequence("52;c;not!base64")) == nil)
  }
}

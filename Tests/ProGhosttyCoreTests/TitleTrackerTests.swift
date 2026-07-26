import Foundation
import Testing

@testable import ProGhosttyCore

@Suite("Title tracker")
struct TitleTrackerTests {
  private func sequence(_ raw: String) -> OscSequence {
    var parser = OscParser()
    let sequences = parser.parse(Data("\u{1B}]\(raw)\u{07}".utf8))
    #expect(sequences.count == 1)
    return sequences[0]
  }

  @Test func extractsOsc0Title() {
    #expect(TitleTracker.title(from: sequence("0;hello")) == "hello")
  }

  @Test func extractsOsc1AndOsc2Titles() {
    #expect(TitleTracker.title(from: sequence("1;icon name")) == "icon name")
    #expect(TitleTracker.title(from: sequence("2;window name")) == "window name")
  }

  @Test func preservesSemicolonsInsideTitle() {
    #expect(TitleTracker.title(from: sequence("0;build;deploy;done")) == "build;deploy;done")
  }

  @Test func emptyPayloadYieldsEmptyStringForReset() {
    #expect(TitleTracker.title(from: sequence("0;")) == "")
  }

  @Test func missingPayloadYieldsNil() {
    #expect(TitleTracker.title(from: OscSequence(raw: "0", command: "0", parameters: [])) == nil)
  }

  @Test func ignoresOtherCommands() {
    #expect(TitleTracker.title(from: sequence("7;file:///tmp")) == nil)
    #expect(TitleTracker.title(from: sequence("133;A")) == nil)
  }

  @Test func keepsUnicodeTitlesIntact() {
    #expect(TitleTracker.title(from: sequence("0;✳ 修复滚动 bug…")) == "✳ 修复滚动 bug…")
  }
}

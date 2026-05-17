import Foundation
import Testing

@testable import ProGhosttyCore

@Suite("OSC parser")
struct OscParserTests {
  @Test func parsePromptStart() {
    var parser = OscParser()
    let sequences = parser.parse(Data("\u{1B}]133;A\u{07}".utf8))
    #expect(sequences == [OscSequence(raw: "133;A", command: "133", parameters: ["A"])])
  }

  @Test func parsePromptEnd() {
    var parser = OscParser()
    let sequences = parser.parse(Data("\u{1B}]133;B\u{07}".utf8))
    #expect(sequences.first?.parameters == ["B"])
  }

  @Test func parseCommandStart() {
    var parser = OscParser()
    let sequences = parser.parse(Data("\u{1B}]133;C;echo hi\u{07}".utf8))
    #expect(sequences.first?.parameters == ["C", "echo hi"])
  }

  @Test func parseCommandFinishZero() {
    var parser = OscParser()
    let sequences = parser.parse(Data("\u{1B}]133;D;0\u{07}".utf8))
    #expect(sequences.first?.parameters == ["D", "0"])
  }

  @Test func parseCommandFinishNonZero() {
    var parser = OscParser()
    let sequences = parser.parse(Data("\u{1B}]133;D;1\u{07}".utf8))
    #expect(sequences.first?.parameters == ["D", "1"])
  }

  @Test func parseCwd() {
    var parser = OscParser()
    let sequences = parser.parse(Data("\u{1B}]7;file://localhost/Users/zpc/project\u{07}".utf8))
    #expect(sequences.first?.command == "7")
    #expect(CwdTracker.cwd(from: sequences[0]) == "/Users/zpc/project")
  }

  @Test func parseChunkedOsc() {
    var parser = OscParser()
    #expect(parser.parse(Data("\u{1B}]133".utf8)).isEmpty)
    #expect(parser.parse(Data(";D;0\u{07}".utf8)).first?.parameters == ["D", "0"])
  }

  @Test func invalidOscDoesNotCrash() {
    var parser = OscParser(maxSequenceBytes: 12)
    let sequences = parser.parse(Data("\u{1B}]133;AAAAAAAAAAAAAAAAAAAAAAAA\u{07}".utf8))
    #expect(sequences.isEmpty)
  }

  @Test func parseMixedTextAndMultipleOsc() {
    var parser = OscParser()
    let data = Data("one\u{1B}]133;A\u{07}two\u{1B}]133;B\u{1B}\\three".utf8)
    let sequences = parser.parse(data)
    #expect(sequences.map(\.parameters) == [["A"], ["B"]])
  }

  @MainActor @Test func rendererSelectionDoesNotAffectOscSideChannelParsing() throws {
    let payload = Data("prompt\u{1B}]133;C;echo hi\u{07}\u{1B}]777;precmd\u{07}".utf8)
    for mode in [TerminalRendererMode.auto, .ghosttyVTCellGrid, .ghosttyVTTextFallback] {
      let registry = PTYTerminalSurfaceRegistry()
      registry.applyRendererOptions(TerminalRendererOptions(mode: mode))
      let session = TerminalSessionID()
      registry.createSurface(session: session)
      let bridge = try GhosttyVTBridge(cols: 40, rows: 4, maxScrollback: 100)
      var parser = OscParser()

      bridge.write(payload)
      registry.render(bridge, session: session)
      registry.flushPendingRenderers()
      let sequences = parser.parse(payload)

      #expect(sequences.map(\.command) == ["133", "777"])
      #expect(sequences.first?.parameters == ["C", "echo hi"])
    }
  }
}

import Foundation
import Testing

@testable import ProGhosttyCore

@Suite("Terminal link detector")
struct TerminalLinkDetectorTests {
  @Test func detectsHTTPURLAsURLTarget() throws {
    let frame = frame(rows: ["open https://example.com/docs now"], cols: 40)

    let hit = try #require(TerminalLinkDetector.hitTest(row: 0, col: 8, in: frame))

    #expect(hit.target == .url(URL(string: "https://example.com/docs")!))
    #expect(hit.text == "https://example.com/docs")
  }

  @Test func detectsAbsolutePathAsFilePathTarget() throws {
    let frame = frame(rows: ["cat /Users/me/project/README.md"], cols: 40)

    let hit = try #require(TerminalLinkDetector.hitTest(row: 0, col: 8, in: frame))

    #expect(hit.target == .filePath(TerminalFilePathTarget(rawPath: "/Users/me/project/README.md", line: nil, column: nil)))
  }

  @Test func detectsHomeRelativePathAsFilePathTarget() throws {
    let frame = frame(rows: ["open ~/notes/today.md"], cols: 32)

    let hit = try #require(TerminalLinkDetector.hitTest(row: 0, col: 8, in: frame))

    #expect(hit.target == .filePath(TerminalFilePathTarget(rawPath: "~/notes/today.md", line: nil, column: nil)))
  }

  @Test func detectsDotRelativePathAsFilePathTarget() throws {
    let frame = frame(rows: ["vim ./Sources/App.swift"], cols: 36)

    let hit = try #require(TerminalLinkDetector.hitTest(row: 0, col: 8, in: frame))

    #expect(hit.target == .filePath(TerminalFilePathTarget(rawPath: "./Sources/App.swift", line: nil, column: nil)))
  }

  @Test func detectsParentRelativePathAsFilePathTarget() throws {
    let frame = frame(rows: ["cat ../README.md"], cols: 28)

    let hit = try #require(TerminalLinkDetector.hitTest(row: 0, col: 6, in: frame))

    #expect(hit.target == .filePath(TerminalFilePathTarget(rawPath: "../README.md", line: nil, column: nil)))
  }

  @Test func detectsCwdRelativeFileLookingPathAsFilePathTarget() throws {
    let frame = frame(rows: ["error Sources/App.swift:42:3"], cols: 40)

    let hit = try #require(TerminalLinkDetector.hitTest(row: 0, col: 10, in: frame))

    #expect(hit.target == .filePath(TerminalFilePathTarget(rawPath: "Sources/App.swift", line: 42, column: 3)))
    #expect(hit.text == "Sources/App.swift:42:3")
  }

  @Test func detectsAbsolutePathWrappedAcrossVisualRows() throws {
    let frame = frame(rows: ["/Users/zpc/projects/", "proghostty/README.md"], cols: 20)

    let firstRowHit = try #require(TerminalLinkDetector.hitTest(row: 0, col: 8, in: frame))
    let secondRowHit = try #require(TerminalLinkDetector.hitTest(row: 1, col: 4, in: frame))

    let target = TerminalLinkTarget.filePath(TerminalFilePathTarget(rawPath: "/Users/zpc/projects/proghostty/README.md"))
    #expect(firstRowHit.target == target)
    #expect(firstRowHit.text == "/Users/zpc/projects/proghostty/README.md")
    #expect(secondRowHit.target == target)
    #expect(secondRowHit.text == "/Users/zpc/projects/proghostty/README.md")
  }

  @Test func detectsRelativePathWithLineColumnWrappedAcrossVisualRows() throws {
    let frame = frame(rows: ["Sources/App.swift", ":42:3"], cols: 17)

    let hit = try #require(TerminalLinkDetector.hitTest(row: 1, col: 2, in: frame))

    #expect(hit.target == .filePath(TerminalFilePathTarget(rawPath: "Sources/App.swift", line: 42, column: 3)))
    #expect(hit.text == "Sources/App.swift:42:3")
  }

  @Test func ignoresNonOverlappingRowsInWrappedPathCandidateGroup() throws {
    let frame = frame(rows: ["prefix-without-space", "see docs/readme.md"], cols: 20)

    let hit = try #require(TerminalLinkDetector.hitTest(row: 1, col: 6, in: frame))

    #expect(hit.target == .filePath(TerminalFilePathTarget(rawPath: "docs/readme.md", line: nil, column: nil)))
  }

  @Test func stripsTrailingSentencePunctuationFromPath() throws {
    let frame = frame(rows: ["see docs/readme.md."], cols: 28)

    let hit = try #require(TerminalLinkDetector.hitTest(row: 0, col: 6, in: frame))

    #expect(hit.target == .filePath(TerminalFilePathTarget(rawPath: "docs/readme.md", line: nil, column: nil)))
    #expect(hit.text == "docs/readme.md")
  }

  @Test func prefersOSC8HyperlinkOverVisiblePath() throws {
    var frame = frame(rows: ["docs/readme.md"], cols: 24)
    for col in 0..<14 {
      frame.cells[col].hyperlink = "https://docs.example/readme"
    }

    let hit = try #require(TerminalLinkDetector.hitTest(row: 0, col: 4, in: frame))

    #expect(hit.target == .url(URL(string: "https://docs.example/readme")!))
  }

  @Test func doesNotTreatPlainWordsAsPaths() {
    let frame = frame(rows: ["plain words only"], cols: 24)

    #expect(TerminalLinkDetector.hitTest(row: 0, col: 2, in: frame) == nil)
  }

  private func frame(rows: [String], cols: Int) -> GhosttyTerminalFrame {
    let cells = rows.flatMap { row in
      let padded = row.padding(toLength: cols, withPad: " ", startingAt: 0)
      return padded.unicodeScalars.prefix(cols).map {
        GhosttyTerminalFrame.Cell(
          scalar: $0,
          foreground: GhosttyTerminalFrame.RGB(r: 255, g: 255, b: 255),
          background: GhosttyTerminalFrame.RGB(r: 0, g: 0, b: 0),
          bold: false,
          italic: false,
          faint: false,
          underline: false,
          inverse: false,
          usesDefaultForeground: true,
          usesDefaultBackground: true
        )
      }
    }
    return GhosttyTerminalFrame(
      cols: cols,
      rows: rows.count,
      cursorVisible: true,
      cursorX: 0,
      cursorY: 0,
      cursorShape: .bar,
      cursorBlinking: false,
      isAlternateScreen: false,
      cells: cells
    )
  }
}

import Foundation
import Testing

@testable import ProGhosttyCore

@Suite("Terminal URL detector")
struct TerminalURLDetectorTests {
  @Test func detectsStandardHTTPURLAtCellCoordinate() throws {
    let frame = frame(rows: ["open https://example.com:8443/path?q=1 now"], cols: 48)

    let hit = try #require(TerminalURLDetector.hitTest(row: 0, col: 8, in: frame))

    #expect(hit.url.absoluteString == "https://example.com:8443/path?q=1")
    #expect(hit.row == 0)
    #expect(hit.range.contains(8))
  }

  @Test func normalizesLocalhostDevelopmentServerURL() throws {
    let frame = frame(rows: ["  Local:   localhost:5173/"], cols: 32)

    let hit = try #require(TerminalURLDetector.hitTest(row: 0, col: 12, in: frame))

    #expect(hit.url.absoluteString == "http://localhost:5173/")
    #expect(hit.text == "localhost:5173/")
  }

  @Test func trimsTrailingSentencePunctuationFromURL() throws {
    let frame = frame(rows: ["ready at http://127.0.0.1:3000."], cols: 40)

    let hit = try #require(TerminalURLDetector.hitTest(row: 0, col: 14, in: frame))

    #expect(hit.url.absoluteString == "http://127.0.0.1:3000")
    #expect(!hit.range.contains(31))
  }

  @Test func normalizesWildcardDevelopmentServerURL() throws {
    let frame = frame(rows: ["Network: 0.0.0.0:8080/app"], cols: 36)

    let hit = try #require(TerminalURLDetector.hitTest(row: 0, col: 12, in: frame))

    #expect(hit.url.absoluteString == "http://0.0.0.0:8080/app")
  }

  @Test func normalizesIPv6LoopbackDevelopmentServerURL() throws {
    let frame = frame(rows: ["Local: [::1]:3000"], cols: 28)

    let hit = try #require(TerminalURLDetector.hitTest(row: 0, col: 9, in: frame))

    #expect(hit.url.absoluteString == "http://[::1]:3000")
  }

  @Test func prefersCellHyperlinkMetadataOverVisibleText() throws {
    var frame = frame(rows: ["link text https://visible.example"], cols: 40)
    for col in 0..<9 {
      frame.cells[col].hyperlink = "https://metadata.example/path"
    }

    let hit = try #require(TerminalURLDetector.hitTest(row: 0, col: 2, in: frame))

    #expect(hit.url.absoluteString == "https://metadata.example/path")
    #expect(hit.text == "link text")
  }

  @Test func returnsNilOutsideURLCells() {
    let frame = frame(rows: ["open https://example.com now"], cols: 32)

    #expect(TerminalURLDetector.hitTest(row: 0, col: 0, in: frame) == nil)
    #expect(TerminalURLDetector.hitTest(row: 0, col: 27, in: frame) == nil)
  }

  @Test func joinsSoftWrappedURLAcrossRows() throws {
    // A long URL soft-wrapped across two rows: row 0 fills to the last cell (no
    // trailing space → treated as wrapped), row 1 holds the continuation.
    let frame = frame(
      rows: [
        "see https://example.com/very/long",
        "/path/segment?query=value done",
      ],
      cols: 33
    )

    let expected = "https://example.com/very/long/path/segment?query=value"

    // Clicking the first-row prefix resolves the whole joined URL.
    let firstRowHit = try #require(TerminalURLDetector.hitTest(row: 0, col: 10, in: frame))
    #expect(firstRowHit.url.absoluteString == expected)
    #expect(firstRowHit.row == 0)

    // Clicking the continuation on the second row resolves the same URL.
    let secondRowHit = try #require(TerminalURLDetector.hitTest(row: 1, col: 2, in: frame))
    #expect(secondRowHit.url.absoluteString == expected)
    #expect(secondRowHit.row == 1)
  }

  @Test func doesNotJoinURLAcrossHardLineBreak() throws {
    // Row 0 ends with a trailing space → not wrapped. The second row's text must
    // not be appended to the first row's URL.
    let frame = frame(
      rows: [
        "open https://example.com/first ",
        "https://example.com/second",
      ],
      cols: 33
    )

    let hit = try #require(TerminalURLDetector.hitTest(row: 0, col: 10, in: frame))
    #expect(hit.url.absoluteString == "https://example.com/first")
    #expect(hit.row == 0)
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

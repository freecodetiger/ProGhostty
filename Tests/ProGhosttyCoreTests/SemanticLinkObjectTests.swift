import Foundation
import Testing

@testable import ProGhosttyCore

@Suite("Semantic link object")
struct SemanticLinkObjectTests {
  @Test func singleLineURLIsOneSegment() throws {
    let frame = frame(rows: ["open https://example.com/path done"], cols: 40)
    let object = try #require(SemanticLinkObjectResolver.object(at: 0, col: 10, in: frame))
    guard case .url(let url) = object.target else { Issue.record("not a url"); return }
    #expect(url.absoluteString == "https://example.com/path")
    #expect(object.segments.count == 1)
    #expect(object.segments[0].row == 0)
  }

  @Test func wrappedURLGroupsAllSegmentsIntoOneObject() throws {
    let frame = frame(
      rows: [
        "see https://example.com/very/long",
        "/path/segment?query=value done",
      ],
      cols: 33
    )
    // Hover the first-row prefix.
    let fromFirst = try #require(SemanticLinkObjectResolver.object(at: 0, col: 10, in: frame))
    #expect(fromFirst.segments.count == 2)
    #expect(fromFirst.segments.map(\.row) == [0, 1])

    // Hover the continuation on row 1 — same object identity.
    let fromSecond = try #require(SemanticLinkObjectResolver.object(at: 1, col: 2, in: frame))
    #expect(fromSecond.id == fromFirst.id)
    #expect(fromSecond.segments.count == 2)
  }

  @Test func logicalEndIsTrailingCellOfLastSegment() throws {
    let frame = frame(
      rows: [
        "see https://example.com/very/long",
        "/path/segment?query=value done",
      ],
      cols: 33
    )
    let object = try #require(SemanticLinkObjectResolver.object(at: 0, col: 10, in: frame))
    let end = try #require(object.logicalEnd)
    let lastSegment = try #require(object.segments.last)
    #expect(end.row == lastSegment.row)
    #expect(end.cols.upperBound == lastSegment.cols.upperBound)
    #expect(end.cols.count == 1)
  }

  @Test func containsChecksAllSegments() throws {
    let frame = frame(
      rows: [
        "see https://example.com/very/long",
        "/path/segment?query=value done",
      ],
      cols: 33
    )
    let object = try #require(SemanticLinkObjectResolver.object(at: 0, col: 10, in: frame))
    // A column inside the first segment and one inside the second both belong.
    #expect(object.contains(row: 0, col: 10))
    #expect(object.contains(row: 1, col: 2))
    #expect(!object.contains(row: 0, col: 0)) // "see " prefix, not the link
  }

  @Test func returnsNilOffAnyLink() {
    let frame = frame(rows: ["just some plain words here"], cols: 32)
    #expect(SemanticLinkObjectResolver.object(at: 0, col: 5, in: frame) == nil)
  }

  private func frame(rows: [String], cols: Int) -> GhosttyTerminalFrame {
    let cells = rows.flatMap { row -> [GhosttyTerminalFrame.Cell] in
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

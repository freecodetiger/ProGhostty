import Foundation
import Testing

@testable import ProGhosttyCore

@Suite("Terminal dragged path formatter")
struct TerminalDraggedPathFormatterTests {
  @Test func formatsSimpleAbsolutePathAsSingleQuotedArgument() {
    let urls = [URL(fileURLWithPath: "/Users/me/file.txt")]

    let text = TerminalDraggedPathFormatter.formattedText(for: urls)

    #expect(text == "'/Users/me/file.txt'")
  }

  @Test func preservesSpacesInsideSingleQuotedPath() {
    let urls = [URL(fileURLWithPath: "/Users/me/My Folder/a file.txt")]

    let text = TerminalDraggedPathFormatter.formattedText(for: urls)

    #expect(text == "'/Users/me/My Folder/a file.txt'")
  }

  @Test func escapesSingleQuotesUsingPosixShellSequence() {
    let urls = [URL(fileURLWithPath: "/Users/me/it's here/file.txt")]

    let text = TerminalDraggedPathFormatter.formattedText(for: urls)

    #expect(text == "'/Users/me/it'\\''s here/file.txt'")
  }

  @Test func joinsMultiplePathsWithSingleSpaceAndNoTrailingNewline() {
    let urls = [
      URL(fileURLWithPath: "/tmp/a file.txt"),
      URL(fileURLWithPath: "/tmp/folder b"),
    ]

    let text = TerminalDraggedPathFormatter.formattedText(for: urls)

    #expect(text == "'/tmp/a file.txt' '/tmp/folder b'")
    #expect(text?.hasSuffix("\n") == false)
    #expect(text?.hasSuffix("\r") == false)
  }

  @Test func returnsNilForEmptyURLList() {
    #expect(TerminalDraggedPathFormatter.formattedText(for: []) == nil)
  }

  @Test func ignoresNonFileURLs() {
    let urls = [
      URL(string: "https://example.com/file.txt")!,
      URL(fileURLWithPath: "/Users/me/local.txt"),
    ]

    let text = TerminalDraggedPathFormatter.formattedText(for: urls)

    #expect(text == "'/Users/me/local.txt'")
  }

  @Test func returnsNilWhenNoLocalFileURLsRemain() {
    let urls = [URL(string: "https://example.com/file.txt")!]

    let text = TerminalDraggedPathFormatter.formattedText(for: urls)

    #expect(text == nil)
  }
}

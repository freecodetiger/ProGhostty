import Foundation
import Testing

@testable import ProGhosttyCore

@Suite("Markdown path detection")
struct MarkdownPathTests {
  @Test func recognizesLowercaseMd() {
    #expect(MarkdownPath.isMarkdown("/Users/dev/docs/README.md"))
  }

  @Test func recognizesUppercaseExtension() {
    #expect(MarkdownPath.isMarkdown("/tmp/NOTES.MD"))
  }

  @Test func recognizesMarkdownExtension() {
    #expect(MarkdownPath.isMarkdown("/tmp/CHANGELOG.markdown"))
  }

  @Test func rejectsNonMarkdownExtensions() {
    #expect(!MarkdownPath.isMarkdown("/tmp/README.txt"))
    #expect(!MarkdownPath.isMarkdown("/tmp/README.mdx"))
    #expect(!MarkdownPath.isMarkdown("/tmp/README"))
    #expect(!MarkdownPath.isMarkdown(""))
  }

  @Test func matchesOnlyPathExtensionNotSubstring() {
    // `.md` must be the extension, not a substring inside another extension.
    #expect(!MarkdownPath.isMarkdown("/tmp/note.mdnotes"))
    #expect(MarkdownPath.isMarkdown("/tmp/note.md"))
  }
}

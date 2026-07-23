import Foundation
import Testing

@testable import ProGhosttyCore

@Suite("File detail formatter")
struct FileDetailFormatterTests {
  private let now = Date(timeIntervalSince1970: 1_000_000)
  private let text = SemanticLinkText()

  private func facts(isDirectory: Bool = false, modified: Date? = nil, created: Date? = nil, size: Int? = nil)
    -> TerminalFileFacts {
    TerminalFileFacts(absolutePath: "/tmp/x", isDirectory: isDirectory, modified: modified, created: created, size: size)
  }

  @Test func missingDatesSkipTheirRows() {
    let rows = FileDetailFormatter.rows(for: facts(size: 100), text: text, now: now)
    #expect(!rows.contains { $0.text.hasPrefix("Modified") })
    #expect(!rows.contains { $0.text.hasPrefix("Created") })
  }

  @Test func directorySkipsSizeAndLabelsFolder() {
    let rows = FileDetailFormatter.rows(for: facts(isDirectory: true, size: 4096), text: text, now: now)
    #expect(rows.map(\.text) == ["Folder"])
    #expect(rows.first?.symbol == "folder")
  }

  @Test func fileWithSizeEmitsAByteCountRow() {
    let rows = FileDetailFormatter.rows(for: facts(size: 2048), text: text, now: now)
    #expect(rows.count == 1)
    #expect(rows.first?.symbol == "internaldrive")
    #expect(!rows.contains { $0.text == "Folder" })
  }

  @Test func datesProduceRelativeRowsWithIcons() {
    let rows = FileDetailFormatter.rows(
      for: facts(modified: now.addingTimeInterval(-3600), created: now.addingTimeInterval(-86400), size: 10),
      text: text, now: now)
    #expect(rows.contains { $0.symbol == "clock" && $0.text.hasPrefix("Modified · ") })
    #expect(rows.contains { $0.symbol == "calendar" && $0.text.hasPrefix("Created · ") })
  }

  @Test func labelsFollowTheProvidedText() {
    let zh = SemanticLinkText(modifiedLabel: "修改于", createdLabel: "创建于", folderLabel: "文件夹")
    let rows = FileDetailFormatter.rows(
      for: facts(isDirectory: true, modified: now.addingTimeInterval(-60)), text: zh, now: now)
    #expect(rows.contains { $0.text.hasPrefix("修改于 · ") })
    #expect(rows.contains { $0.text == "文件夹" })
  }
}

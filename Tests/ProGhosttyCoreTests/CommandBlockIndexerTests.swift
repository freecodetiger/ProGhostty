import Foundation
import Testing

@testable import ProGhosttyCore

@Suite("Command block indexer")
struct CommandBlockIndexerTests {
  @Test func commandStartCreatesRunningBlock() {
    let session = TerminalSessionID()
    var indexer = CommandBlockIndexer()
    _ = indexer.process(.cwdChanged(session: session, cwd: "/tmp/project"))
    let changes = indexer.process(.commandStarted(session: session, command: "ls"))

    #expect(changes.first?.status == .running)
    #expect(changes.first?.cwd == "/tmp/project")
    #expect(changes.first?.command == "ls")
  }

  @Test func outputAppendsPreview() {
    let session = TerminalSessionID()
    var indexer = CommandBlockIndexer()
    _ = indexer.process(.commandStarted(session: session, command: "echo hi"))
    let changes = indexer.process(.output(session: session, data: Data("hi\n".utf8)))

    #expect(changes.first?.outputPreview == "hi\n")
  }

  @Test func commandFinishSuccess() {
    let session = TerminalSessionID()
    var indexer = CommandBlockIndexer()
    _ = indexer.process(.commandStarted(session: session, command: "true"))
    let changes = indexer.process(.commandFinished(session: session, exitCode: 0))

    #expect(changes.first?.status == .success)
    #expect(changes.first?.exitCode == 0)
    #expect(changes.first?.durationMs != nil)
  }

  @Test func commandFinishFailed() {
    let session = TerminalSessionID()
    var indexer = CommandBlockIndexer()
    _ = indexer.process(.commandStarted(session: session, command: "false"))
    let changes = indexer.process(.commandFinished(session: session, exitCode: 1))

    #expect(changes.first?.status == .failed)
    #expect(changes.first?.exitCode == 1)
  }

  @Test func cancelledBlockOnSessionClose() {
    let session = TerminalSessionID()
    var indexer = CommandBlockIndexer()
    _ = indexer.process(.commandStarted(session: session, command: "sleep 100"))
    let changes = indexer.process(.sessionClosed(session))

    #expect(changes.first?.status == .cancelled)
    #expect(changes.first?.endedAt != nil)
  }

  @Test func previewTruncationWorks() {
    let session = TerminalSessionID()
    var indexer = CommandBlockIndexer(maxPreviewBytes: 10)
    _ = indexer.process(.commandStarted(session: session, command: "yes"))
    let changes = indexer.process(.output(session: session, data: Data("abcdefghijklmnop".utf8)))

    #expect(changes.first?.outputPreview.contains("[output truncated]") == true)
  }
}

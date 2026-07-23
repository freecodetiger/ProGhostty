import Foundation
import Testing

@testable import ProGhosttyApp

@Suite("Git status parser")
struct GitStatusParserTests {
  @Test func changeCountsSplitsTrackedAndUntracked() {
    #expect(GitStatusParser.changeCounts(porcelain: "").modified == 0)
    let counts = GitStatusParser.changeCounts(porcelain: " M a.swift\nM  b.swift\n?? c.swift\n?? d.swift\n")
    #expect(counts.modified == 2)
    #expect(counts.added == 2)
  }

  @Test func commitParsesUnitSeparatedFieldsWithAuthor() {
    let commit = GitStatusParser.commit(record: "a1b2c3\u{1f}fix: thing\u{1f}2026-07-22T10:00:00Z\u{1f}zpc")
    #expect(commit?.shortHash == "a1b2c3")
    #expect(commit?.subject == "fix: thing")
    #expect(commit?.date != nil)
    #expect(commit?.author == "zpc")
  }

  @Test func commitSurvivesMissingDateAndAuthor() {
    let commit = GitStatusParser.commit(record: "a1b2c3\u{1f}subject only")
    #expect(commit?.shortHash == "a1b2c3")
    #expect(commit?.subject == "subject only")
    #expect(commit?.date == nil)
    #expect(commit?.author == nil)
  }

  @Test func emptyRecordYieldsNil() {
    #expect(GitStatusParser.commit(record: "  \n") == nil)
  }

  @Test func commitsSplitsRecordsBySeparatorNewestFirst() {
    let log = "a1\u{1f}first\u{1f}2026-07-22T10:00:00Z\u{1f}zpc\u{1e}"
      + "b2\u{1f}second\u{1f}2026-07-21T10:00:00Z\u{1f}zpc\u{1e}"
    let commits = GitStatusParser.commits(log: log)
    #expect(commits.count == 2)
    #expect(commits.first?.shortHash == "a1")
    #expect(commits.first?.subject == "first")
    #expect(commits.last?.shortHash == "b2")
  }

  @Test func commitsIgnoresBlankTrailingRecord() {
    #expect(GitStatusParser.commits(log: "").isEmpty)
    #expect(GitStatusParser.commits(log: "a1\u{1f}only\u{1e}").count == 1)
  }

  @Test func normalizesScpStyleRemote() {
    let url = GitStatusParser.browsableRemoteURL(remote: "git@github.com:owner/repo.git")
    #expect(url?.absoluteString == "https://github.com/owner/repo")
  }

  @Test func normalizesHttpsRemoteAndStripsDotGit() {
    let url = GitStatusParser.browsableRemoteURL(remote: "https://gitlab.com/group/proj.git")
    #expect(url?.absoluteString == "https://gitlab.com/group/proj")
  }

  @Test func normalizesSshSchemeRemote() {
    let url = GitStatusParser.browsableRemoteURL(remote: "ssh://git@example.com/a/b.git")
    #expect(url?.absoluteString == "https://example.com/a/b")
  }

  @Test func rejectsEmptyOrPathOnlyRemote() {
    #expect(GitStatusParser.browsableRemoteURL(remote: "") == nil)
    #expect(GitStatusParser.browsableRemoteURL(remote: "   ") == nil)
  }
}

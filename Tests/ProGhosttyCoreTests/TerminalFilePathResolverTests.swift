import Foundation
import Testing

@testable import ProGhosttyCore

@Suite("Terminal file path resolver")
struct TerminalFilePathResolverTests {
  @Test func resolvesExistingAbsolutePathWithoutCwd() throws {
    let file = try makeTempFile(name: "absolute.md")

    let resolved = try TerminalFilePathResolver.resolve(
      TerminalFilePathTarget(rawPath: file.path),
      cwd: nil,
      homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path
    )

    #expect(resolved == file)
  }

  @Test func resolvesHomeRelativePath() throws {
    let home = try makeTempDirectory()
    let file = home.appendingPathComponent("notes/today.md")
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "note".write(to: file, atomically: true, encoding: .utf8)

    let resolved = try TerminalFilePathResolver.resolve(
      TerminalFilePathTarget(rawPath: "~/notes/today.md"),
      cwd: nil,
      homeDirectory: home.path
    )

    #expect(resolved == file)
  }

  @Test func resolvesRelativePathAgainstCwd() throws {
    let cwd = try makeTempDirectory()
    let file = cwd.appendingPathComponent("Sources/App.swift")
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "print(1)".write(to: file, atomically: true, encoding: .utf8)

    let resolved = try TerminalFilePathResolver.resolve(
      TerminalFilePathTarget(rawPath: "Sources/App.swift"),
      cwd: cwd.path,
      homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path
    )

    #expect(resolved == file)
  }

  @Test func rejectsRelativePathWithoutCwd() {
    #expect(throws: TerminalFilePathResolver.Error.missingWorkingDirectory) {
      try TerminalFilePathResolver.resolve(
        TerminalFilePathTarget(rawPath: "Sources/App.swift"),
        cwd: nil,
        homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path
      )
    }
  }

  @Test func rejectsMissingPathInsteadOfOpeningParent() throws {
    let cwd = try makeTempDirectory()

    #expect(throws: TerminalFilePathResolver.Error.pathNotFound) {
      try TerminalFilePathResolver.resolve(
        TerminalFilePathTarget(rawPath: "missing/file.md"),
        cwd: cwd.path,
        homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path
      )
    }
  }

  private func makeTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func makeTempFile(name: String) throws -> URL {
    let directory = try makeTempDirectory()
    let file = directory.appendingPathComponent(name)
    try "content".write(to: file, atomically: true, encoding: .utf8)
    return file
  }
}

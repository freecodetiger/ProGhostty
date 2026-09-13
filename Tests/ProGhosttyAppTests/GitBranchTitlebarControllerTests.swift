import Foundation
import Testing
import os
@testable import ProGhosttyApp

@MainActor
struct GitBranchTitlebarControllerTests {
  @Test(arguments: [false, true])
  func refreshDetectsRepeatedSwitchesWithoutChangingDirectory(periodic: Bool) async throws {
    let repo = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: repo) }
    try git(repo, ["init", "-b", "main"])
    try git(repo, ["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "--allow-empty", "-m", "initial"])
    let controller = GitBranchTitlebarController(refreshInterval: periodic ? .milliseconds(40) : .seconds(3600), onChange: {})
    #expect(controller.branch(for: repo.path) == nil)
    try await expectBranch("main", controller: controller, cwd: repo.path)
    for branch in ["feature-one", "feature-two"] {
      try git(repo, ["switch", "-c", branch])
      if !periodic { controller.refresh(cwd: repo.path) }
      #expect(controller.branch(for: repo.path) != nil) // retain old label while fetching
      try await expectBranch(branch, controller: controller, cwd: repo.path)
    }
  }

  @Test func cachedNonRepositoryDoesNotRefetchOnEveryLabelRead() async throws {
    let reads = OSAllocatedUnfairLock(initialState: 0)
    let controller = GitBranchTitlebarController(refreshInterval: .seconds(3600), readBranch: { _ in
      reads.withLock { $0 += 1 }
      return nil
    }, onChange: {})
    #expect(controller.branch(for: "/not-a-repository") == nil)
    try await Task.sleep(for: .milliseconds(100))
    for _ in 0..<30 { #expect(controller.branch(for: "/not-a-repository") == nil) }
    try await Task.sleep(for: .milliseconds(50))
    #expect(reads.withLock { $0 } == 1)
    controller.invalidate()
  }

  @Test func switchingAwayAndBackRejectsOldLookup() async throws {
    let reads = OSAllocatedUnfairLock(initialState: 0)
    let releaseFirst = DispatchSemaphore(value: 0)
    defer { releaseFirst.signal() }
    let controller = GitBranchTitlebarController(refreshInterval: .seconds(3600), readBranch: { _ in
      let call = reads.withLock { count in count += 1; return count }
      if call == 1 {
        _ = releaseFirst.wait(timeout: .now() + 3)
        return "stale"
      }
      return call == 2 ? "other" : "latest"
    }, onChange: {})
    _ = controller.branch(for: "/repo-a")
    for _ in 0..<100 {
      if reads.withLock({ $0 }) == 1 { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(reads.withLock { $0 } == 1)
    _ = controller.branch(for: "/repo-b")
    try await expectBranch("other", controller: controller, cwd: "/repo-b")
    _ = controller.branch(for: "/repo-a")
    try await expectBranch("latest", controller: controller, cwd: "/repo-a")
    releaseFirst.signal()
    try await Task.sleep(for: .milliseconds(100))
    #expect(controller.branch(for: "/repo-a") == "latest")
    controller.invalidate()
  }

  private func expectBranch(_ expected: String, controller: GitBranchTitlebarController, cwd: String) async throws {
    for _ in 0..<100 {
      if controller.branch(for: cwd) == expected { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(controller.branch(for: cwd) == expected)
  }

  private func git(_ directory: URL, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", directory.path] + arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
  }
}

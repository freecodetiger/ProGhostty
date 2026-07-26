import Foundation
import Testing

@testable import ProGhosttyApp

@Suite("Title formatting")
struct TitleFormattingTests {
  @Test func compactTitlebarTitleFallsBackForEmptyAndWhitespace() {
    #expect(TitleFormatting.compactTitlebarTitle("") == "ProGhostty")
    #expect(TitleFormatting.compactTitlebarTitle("   \n") == "ProGhostty")
  }

  @Test func compactTitlebarTitleReducesPathsAndKeepsPlainTitles() {
    #expect(TitleFormatting.compactTitlebarTitle("/Users/dev/projects/proghostty") == "proghostty")
    #expect(TitleFormatting.compactTitlebarTitle("  my session  ") == "my session")
  }

  @Test func compactPathComponentKeepsSymbolicRootAndHome() {
    #expect(TitleFormatting.compactPathComponent("/") == "/")
    #expect(TitleFormatting.compactPathComponent(NSHomeDirectory()) == "~")
  }

  @Test func compactPathComponentReducesAbsoluteAndTildePaths() {
    #expect(TitleFormatting.compactPathComponent("/tmp/deep/dir") == "dir")
    #expect(TitleFormatting.compactPathComponent("~/projects/app") == "app")
  }

  @Test func compactPathComponentPassesThroughNonPathsAndNil() {
    #expect(TitleFormatting.compactPathComponent("plain title") == "plain title")
    #expect(TitleFormatting.compactPathComponent(nil) == nil)
    #expect(TitleFormatting.compactPathComponent("") == nil)
  }

  @Test func normalizedWorkspaceNameTrimsAndFallsBack() {
    #expect(TitleFormatting.normalizedWorkspaceName("  dev  ") == "dev")
    #expect(TitleFormatting.normalizedWorkspaceName("   ") == "Workspace")
  }
}

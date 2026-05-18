import Foundation
import Testing

@testable import ProGhosttyCore

@Suite("App update checker")
struct AppUpdateCheckerTests {
  @Test func semanticVersionsStripVPrefixAndCompareNumerically() throws {
    let current = try #require(AppVersion("v0.1.9"))
    let latest = try #require(AppVersion("0.1.10"))

    #expect(latest > current)
    #expect(AppVersion("v0.1.0") == AppVersion("0.1.0"))
  }

  @Test func newerLatestReleaseReturnsAvailableUpdateWithDMGAsset() async throws {
    let payload = """
      {
        "tag_name": "v0.2.0",
        "name": "ProGhostty v0.2.0",
        "html_url": "https://github.com/freecodetiger/ProGhostty/releases/tag/v0.2.0",
        "body": "Release notes",
        "draft": false,
        "prerelease": false,
        "assets": [
          {
            "name": "ProGhostty-0.2.0-arm64.dmg",
            "browser_download_url": "https://github.com/freecodetiger/ProGhostty/releases/download/v0.2.0/ProGhostty-0.2.0-arm64.dmg"
          }
        ]
      }
      """.data(using: .utf8)!
    let checker = AppUpdateChecker(fetchLatestReleaseData: { payload })

    let availability = try await checker.check(currentVersion: "0.1.0")

    guard case .available(let update) = availability else {
      Issue.record("Expected an available update")
      return
    }
    #expect(update.version == AppVersion("0.2.0"))
    #expect(update.releaseURL.absoluteString == "https://github.com/freecodetiger/ProGhostty/releases/tag/v0.2.0")
    #expect(update.downloadURL?.absoluteString.hasSuffix(".dmg") == true)
    #expect(update.releaseNotes == "Release notes")
  }

  @Test func sameVersionIsUpToDate() async throws {
    let checker = AppUpdateChecker(fetchLatestReleaseData: {
      latestReleaseJSON(tag: "v0.1.0", draft: false, prerelease: false)
    })

    let availability = try await checker.check(currentVersion: "0.1.0")

    #expect(availability == .upToDate)
  }

  @Test func draftAndPrereleaseDoNotProduceUpdate() async throws {
    let draftChecker = AppUpdateChecker(fetchLatestReleaseData: {
      latestReleaseJSON(tag: "v9.0.0", draft: true, prerelease: false)
    })
    let prereleaseChecker = AppUpdateChecker(fetchLatestReleaseData: {
      latestReleaseJSON(tag: "v9.0.0", draft: false, prerelease: true)
    })

    #expect(try await draftChecker.check(currentVersion: "0.1.0") == .upToDate)
    #expect(try await prereleaseChecker.check(currentVersion: "0.1.0") == .upToDate)
  }
}

private func latestReleaseJSON(tag: String, draft: Bool, prerelease: Bool) -> Data {
  """
  {
    "tag_name": "\(tag)",
    "name": "ProGhostty \(tag)",
    "html_url": "https://github.com/freecodetiger/ProGhostty/releases/tag/\(tag)",
    "body": "",
    "draft": \(draft),
    "prerelease": \(prerelease),
    "assets": []
  }
  """.data(using: .utf8)!
}

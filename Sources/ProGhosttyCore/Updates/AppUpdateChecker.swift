import Foundation

public struct AppVersion: Comparable, CustomStringConvertible, Sendable {
  public let components: [Int]

  public init?(_ value: String) {
    let normalized = value
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .trimmingPrefix { $0 == "v" || $0 == "V" }
      .split(separator: "-", maxSplits: 1, omittingEmptySubsequences: true)
      .first?
      .split(separator: "+", maxSplits: 1, omittingEmptySubsequences: true)
      .first ?? ""
    let parsed = normalized.split(separator: ".").compactMap { Int($0) }
    guard !parsed.isEmpty else { return nil }
    components = parsed
  }

  public var description: String {
    components.map(String.init).joined(separator: ".")
  }

  public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
    let count = max(lhs.components.count, rhs.components.count)
    for index in 0..<count {
      let left = index < lhs.components.count ? lhs.components[index] : 0
      let right = index < rhs.components.count ? rhs.components[index] : 0
      if left != right { return left < right }
    }
    return false
  }
}

public struct AppUpdate: Equatable, Sendable {
  public var version: AppVersion
  public var releaseURL: URL
  public var downloadURL: URL?
  public var releaseNotes: String?

  public init(version: AppVersion, releaseURL: URL, downloadURL: URL?, releaseNotes: String?) {
    self.version = version
    self.releaseURL = releaseURL
    self.downloadURL = downloadURL
    self.releaseNotes = releaseNotes
  }
}

public enum AppUpdateAvailability: Equatable, Sendable {
  case upToDate
  case available(AppUpdate)
}

public enum AppUpdateError: Error, Equatable, Sendable {
  case invalidCurrentVersion(String)
  case invalidLatestVersion(String)
  case invalidReleaseURL
  case httpStatus(Int)
}

public struct AppUpdateChecker: Sendable {
  public typealias FetchLatestReleaseData = @Sendable () async throws -> Data

  private let fetchLatestReleaseData: FetchLatestReleaseData

  public init(
    repository: String = "freecodetiger/ProGhostty",
    fetchLatestReleaseData: FetchLatestReleaseData? = nil
  ) {
    if let fetchLatestReleaseData {
      self.fetchLatestReleaseData = fetchLatestReleaseData
    } else {
      self.fetchLatestReleaseData = {
        guard let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest") else {
          throw AppUpdateError.invalidReleaseURL
        }
        var request = URLRequest(url: url)
        request.setValue("ProGhostty", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 200
        guard (200..<300).contains(statusCode) else {
          throw AppUpdateError.httpStatus(statusCode)
        }
        return data
      }
    }
  }

  public func check(currentVersion: String) async throws -> AppUpdateAvailability {
    guard let current = AppVersion(currentVersion) else {
      throw AppUpdateError.invalidCurrentVersion(currentVersion)
    }

    let data = try await fetchLatestReleaseData()
    let release = try JSONDecoder().decode(GitHubLatestRelease.self, from: data)
    guard !release.draft, !release.prerelease else { return .upToDate }
    guard let latest = AppVersion(release.tagName) else {
      throw AppUpdateError.invalidLatestVersion(release.tagName)
    }
    guard latest > current else { return .upToDate }

    let update = AppUpdate(
      version: latest,
      releaseURL: release.htmlURL,
      downloadURL: release.dmgAssetURL,
      releaseNotes: release.body.nilIfEmpty
    )
    return .available(update)
  }
}

private struct GitHubLatestRelease: Decodable {
  var tagName: String
  var htmlURL: URL
  var body: String
  var draft: Bool
  var prerelease: Bool
  var assets: [GitHubReleaseAsset]

  enum CodingKeys: String, CodingKey {
    case tagName = "tag_name"
    case htmlURL = "html_url"
    case body
    case draft
    case prerelease
    case assets
  }

  var dmgAssetURL: URL? {
    assets.first { asset in
      asset.name.lowercased().hasSuffix(".dmg")
    }?.downloadURL
  }
}

private struct GitHubReleaseAsset: Decodable {
  var name: String
  var downloadURL: URL

  enum CodingKeys: String, CodingKey {
    case name
    case downloadURL = "browser_download_url"
  }
}

private extension String {
  var nilIfEmpty: String? {
    isEmpty ? nil : self
  }
}

import Foundation

/// Immutable snapshot of a project's git + filesystem state, shown in the
/// titlebar project-info panel. Assembled by `ProjectInfoService` off the main
/// thread. All git fields are nil when the directory is not a git work tree.
struct ProjectInfo: Equatable, Sendable {
  var absolutePath: String
  var displayName: String

  var isGitRepository: Bool
  var branch: String?
  /// Tracked files with staged/unstaged changes (porcelain XY != "??").
  var modifiedCount: Int
  /// Untracked new files (porcelain "??").
  var addedCount: Int
  /// Most recent commits on the current branch, newest first (default 5).
  var recentCommits: [GitCommit]
  /// Normalized web URL for `origin`, if it maps to a browsable host. Nil hides
  /// the "Open Remote" action.
  var remoteURL: URL?
}

struct GitCommit: Equatable, Sendable {
  var shortHash: String
  var subject: String
  var date: Date?
  var author: String?
}

/// Pure parsing of `git` command output into `ProjectInfo` fields. No process
/// spawning, no filesystem — spawning lives in `ProjectInfoService`. This is the
/// only branchy logic in the feature, so it carries the tests.
enum GitStatusParser {
  /// Split `git status --porcelain` into (modified tracked, added untracked).
  /// Each line's first two chars are the XY status code; "??" is untracked.
  static func changeCounts(porcelain: String) -> (modified: Int, added: Int) {
    var modified = 0
    var added = 0
    for line in porcelain.split(separator: "\n", omittingEmptySubsequences: true) {
      if line.hasPrefix("??") {
        added += 1
      } else {
        modified += 1
      }
    }
    return (modified, added)
  }

  /// Parse one `git log --format=%h%x1f%s%x1f%cI%x1f%an` record (unit-separator
  /// \u{1f} delimited).
  static func commit(record: String) -> GitCommit? {
    let trimmed = record.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let fields = trimmed.components(separatedBy: "\u{1f}")
    guard fields.count >= 2, !fields[0].isEmpty else { return nil }
    let date = fields.count >= 3 ? ISO8601DateFormatter().date(from: fields[2]) : nil
    let author = fields.count >= 4 && !fields[3].isEmpty ? fields[3] : nil
    return GitCommit(shortHash: fields[0], subject: fields[1], date: date, author: author)
  }

  /// Parse multi-commit `git log -<N> --format=…%x1e` output — records separated
  /// by the record separator \u{1e}, fields by \u{1f}. Newest first.
  static func commits(log: String) -> [GitCommit] {
    log.split(separator: "\u{1e}", omittingEmptySubsequences: true)
      .compactMap { commit(record: String($0)) }
  }

  /// Normalize a git remote URL (SSH or HTTPS) to a browsable https URL.
  /// `git@github.com:a/b.git` → `https://github.com/a/b`
  /// `https://github.com/a/b.git` → `https://github.com/a/b`
  /// `ssh://git@host/a/b.git` → `https://host/a/b`
  /// Returns nil for anything that doesn't look like a hosted repo.
  static func browsableRemoteURL(remote: String) -> URL? {
    var s = remote.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !s.isEmpty else { return nil }
    if s.hasSuffix(".git") { s = String(s.dropLast(4)) }

    // scp-like syntax: [user@]host:path
    if !s.contains("://"), let colon = s.firstIndex(of: ":") {
      let host = String(s[..<colon]).components(separatedBy: "@").last ?? ""
      let path = String(s[s.index(after: colon)...])
      guard !host.isEmpty, !path.isEmpty else { return nil }
      return URL(string: "https://\(host)/\(path)")
    }

    // URL syntax: scheme://[user@]host/path
    guard let comps = URLComponents(string: s), let host = comps.host, !comps.path.isEmpty else {
      return nil
    }
    let path = comps.path.hasPrefix("/") ? String(comps.path.dropFirst()) : comps.path
    guard !path.isEmpty else { return nil }
    return URL(string: "https://\(host)/\(path)")
  }
}

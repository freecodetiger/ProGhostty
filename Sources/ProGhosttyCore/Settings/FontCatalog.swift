import AppKit
import Foundation

/// Font availability, recommendation, and CJK classification for terminal
/// rendering and the settings font picker.
///
/// Extracted from `AppSettings.swift` (debt spec 5-1) so the settings schema
/// file stays pure Foundation; this file owns the Core settings domain's only
/// AppKit dependency (`NSFont`/`NSFontManager` probing).
public struct TerminalFontOption: Equatable, Identifiable, Sendable {
  public var id: String { familyName }
  public let familyName: String
  public let isInstalled: Bool
  public let isRecommendedForTerminal: Bool
  public let isRecommendedForCJKFallback: Bool

  public init(
    familyName: String,
    isInstalled: Bool,
    isRecommendedForTerminal: Bool,
    isRecommendedForCJKFallback: Bool = false
  ) {
    self.familyName = familyName
    self.isInstalled = isInstalled
    self.isRecommendedForTerminal = isRecommendedForTerminal
    self.isRecommendedForCJKFallback = isRecommendedForCJKFallback
  }
}

public enum FontCatalog {
  public static func defaultMonospacedFontName() -> String {
    NSFont(name: "JetBrains Mono", size: 14) == nil ? "Menlo" : "JetBrains Mono"
  }

  public static func monospacedFonts() -> [String] {
    fontOptions(currentFamily: defaultMonospacedFontName(), searchText: "", includeAllFonts: false)
      .filter(\.isInstalled)
      .map(\.familyName)
  }

  public static func allFontFamilies() -> [String] {
    NSFontManager.shared.availableFontFamilies.sorted {
      $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
    }
  }

  public static func fontOptions(
    currentFamily: String,
    searchText: String,
    includeAllFonts: Bool
  ) -> [TerminalFontOption] {
    fontOptions(
      availableFamilies: allFontFamilies(),
      currentFamily: currentFamily,
      searchText: searchText,
      includeAllFonts: includeAllFonts
    )
  }

  public static func fontOptions(
    availableFamilies: [String],
    currentFamily: String,
    searchText: String,
    includeAllFonts: Bool
  ) -> [TerminalFontOption] {
    fontOptions(
      availableFamilies: availableFamilies,
      currentFamily: currentFamily,
      searchText: searchText,
      includeAllFonts: includeAllFonts,
      recommendation: isRecommendedTerminalFamily
    )
  }

  private static func fontOptions(
    availableFamilies: [String],
    currentFamily: String,
    searchText: String,
    includeAllFonts: Bool,
    recommendation: (String) -> Bool
  ) -> [TerminalFontOption] {
    let installedFamilies = Set(availableFamilies)
    let normalizedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    let uniqueFamilies = Array(installedFamilies).sorted {
      $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
    }

    var options = uniqueFamilies
      .filter { family in
        includeAllFonts || recommendation(family)
      }
      .filter { family in
        normalizedSearch.isEmpty || family.localizedCaseInsensitiveContains(normalizedSearch)
      }
      .map { family in
        TerminalFontOption(
          familyName: family,
          isInstalled: true,
          isRecommendedForTerminal: isRecommendedTerminalFamily(family),
          isRecommendedForCJKFallback: isRecommendedCJKFallbackFamily(family)
        )
      }

    let current = currentFamily.trimmingCharacters(in: .whitespacesAndNewlines)
    if !current.isEmpty,
       !options.contains(where: { $0.familyName == current }),
       normalizedSearch.isEmpty || current.localizedCaseInsensitiveContains(normalizedSearch)
    {
      options.append(TerminalFontOption(
        familyName: current,
        isInstalled: installedFamilies.contains(current),
        isRecommendedForTerminal: isRecommendedTerminalFamily(current),
        isRecommendedForCJKFallback: isRecommendedCJKFallbackFamily(current)
      ))
      options.sort { $0.familyName.localizedCaseInsensitiveCompare($1.familyName) == .orderedAscending }
    }

    return options
  }

  public static func fontOption(for family: String) -> TerminalFontOption {
    let trimmed = family.trimmingCharacters(in: .whitespacesAndNewlines)
    return TerminalFontOption(
      familyName: trimmed,
      isInstalled: NSFont(name: trimmed, size: 14) != nil,
      isRecommendedForTerminal: isRecommendedTerminalFamily(trimmed),
      isRecommendedForCJKFallback: isRecommendedCJKFallbackFamily(trimmed)
    )
  }

  public static func cjkFallbackOptions(
    currentFamily: String?,
    searchText: String,
    includeAllFonts: Bool
  ) -> [TerminalFontOption] {
    cjkFallbackOptions(
      availableFamilies: allFontFamilies(),
      currentFamily: currentFamily,
      searchText: searchText,
      includeAllFonts: includeAllFonts
    )
  }

  public static func cjkFallbackOptions(
    availableFamilies: [String],
    currentFamily: String?,
    searchText: String,
    includeAllFonts: Bool
  ) -> [TerminalFontOption] {
    fontOptions(
      availableFamilies: availableFamilies,
      currentFamily: currentFamily ?? "",
      searchText: searchText,
      includeAllFonts: includeAllFonts,
      recommendation: isRecommendedCJKFallbackFamily
    )
  }

  public static func isRecommendedTerminalFamily(_ family: String) -> Bool {
    let lowercased = family.lowercased()
    if family == "Menlo" || family == "Monaco" {
      return true
    }

    let terminalNameFragments = [
      "mono",
      "code",
      "console",
      "terminal",
      "hack",
      "iosevka",
      "cascadia",
      "meslo",
      "monaspace",
      "source code",
      "courier",
      "maple",
      "sarasa",
    ]
    if terminalNameFragments.contains(where: { lowercased.contains($0) }) {
      return true
    }

    return isMonospacedByMetrics(family)
  }

  public static func isRecommendedCJKFallbackFamily(_ family: String) -> Bool {
    let lowercased = family.lowercased()
    let cjkNameFragments = [
      "cjk",
      " sc",
      " tc",
      " cn",
      "pingfang",
      "heiti",
      "songti",
      "kaiti",
      "sarasa",
      "lxgw",
      "noto sans cjk",
      "source han",
      "maple",
    ]
    return cjkNameFragments.contains { lowercased.contains($0) }
  }

  public static func containsCJK(_ text: String) -> Bool {
    text.unicodeScalars.contains { scalar in
      switch scalar.value {
      case 0x3400...0x4DBF,
           0x4E00...0x9FFF,
           0xF900...0xFAFF,
           0x20000...0x2A6DF,
           0x2A700...0x2B73F,
           0x2B740...0x2B81F,
           0x2B820...0x2CEAF,
           0x3000...0x303F,
           0x3040...0x30FF,
           0xAC00...0xD7AF:
        return true
      default:
        return false
      }
    }
  }

  private static func isMonospacedByMetrics(_ family: String) -> Bool {
    guard let font = NSFont(name: family, size: 14) else { return false }
    let samples = ["i", "W", "0", " "]
    let widths = samples.map { sample in
      ceil((sample as NSString).size(withAttributes: [.font: font]).width * 100) / 100
    }
    guard let first = widths.first else { return false }
    return widths.dropFirst().allSatisfy { abs($0 - first) < 0.01 }
  }
}

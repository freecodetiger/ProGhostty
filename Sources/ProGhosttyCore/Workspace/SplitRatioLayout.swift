import Foundation

public enum SplitRatioLayout {
  public static let minimumPaneLength: Double = 120

  public static func firstLength(
    totalLength: Double,
    dividerThickness: Double,
    ratio: Double
  ) -> Double {
    let availableLength = max(0, totalLength - max(0, dividerThickness))
    return availableLength * SplitPane.clampedRatio(ratio)
  }

  public static func canSplit(
    totalLength: Double,
    dividerThickness: Double,
    minimumChildLength: Double = minimumPaneLength
  ) -> Bool {
    let divider = max(0, dividerThickness)
    let minimum = max(1, minimumChildLength)
    return totalLength >= minimum * 2 + divider
  }

  public static func safeFirstLength(
    totalLength: Double,
    dividerThickness: Double,
    ratio: Double,
    minimumChildLength: Double = minimumPaneLength
  ) -> Double? {
    guard canSplit(
      totalLength: totalLength,
      dividerThickness: dividerThickness,
      minimumChildLength: minimumChildLength
    ) else {
      return nil
    }

    let availableLength = max(0, totalLength - max(0, dividerThickness))
    let minimum = max(1, minimumChildLength)
    let proposed = availableLength * SplitPane.clampedRatio(ratio)
    return min(max(proposed, minimum), availableLength - minimum)
  }

  public static func ratio(
    firstLength: Double,
    totalLength: Double,
    dividerThickness: Double
  ) -> Double {
    let availableLength = max(1, totalLength - max(0, dividerThickness))
    return SplitPane.clampedRatio(firstLength / availableLength)
  }

  public static func shouldPersistRatioChange(
    isUserInitiated: Bool,
    hasAppliedInitialRatio: Bool,
    isApplyingProgrammaticRatio: Bool
  ) -> Bool {
    isUserInitiated && hasAppliedInitialRatio && !isApplyingProgrammaticRatio
  }
}

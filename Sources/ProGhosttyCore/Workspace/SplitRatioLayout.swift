import Foundation

public enum SplitRatioLayout {
  public struct ContentSize: Equatable, Sendable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
      self.width = max(0, width)
      self.height = max(0, height)
    }
  }

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

  public static func minimumContentSize(
    for node: PaneNode,
    leafWidth: Double = minimumPaneLength,
    leafHeight: Double = minimumPaneLength,
    dividerThickness: Double = 1
  ) -> ContentSize {
    switch node {
    case .leaf:
      return ContentSize(width: leafWidth, height: leafHeight)
    case .split(let split):
      let first = minimumContentSize(
        for: split.first,
        leafWidth: leafWidth,
        leafHeight: leafHeight,
        dividerThickness: dividerThickness
      )
      let second = minimumContentSize(
        for: split.second,
        leafWidth: leafWidth,
        leafHeight: leafHeight,
        dividerThickness: dividerThickness
      )
      let divider = max(0, dividerThickness)
      switch split.axis {
      case .horizontal:
        return ContentSize(
          width: first.width + divider + second.width,
          height: max(first.height, second.height)
        )
      case .vertical:
        return ContentSize(
          width: max(first.width, second.width),
          height: first.height + divider + second.height
        )
      }
    }
  }

  public static func workspaceSwitchTargetContentSize(
    current: ContentSize,
    remembered: ContentSize?,
    layoutMinimum: ContentSize
  ) -> ContentSize {
    ContentSize(
      width: max(current.width, remembered?.width ?? 0, layoutMinimum.width),
      height: max(current.height, remembered?.height ?? 0, layoutMinimum.height)
    )
  }
}

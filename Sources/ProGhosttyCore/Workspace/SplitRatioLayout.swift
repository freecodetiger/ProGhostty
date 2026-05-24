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
  public static let minimumPaneWidth: Double = 240
  public static let minimumPaneHeight: Double = 96

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
    canSplit(
      totalLength: totalLength,
      dividerThickness: dividerThickness,
      minimumFirstLength: minimumChildLength,
      minimumSecondLength: minimumChildLength
    )
  }

  public static func canSplit(
    totalLength: Double,
    dividerThickness: Double,
    minimumFirstLength: Double,
    minimumSecondLength: Double
  ) -> Bool {
    let divider = max(0, dividerThickness)
    let firstMinimum = max(1, minimumFirstLength)
    let secondMinimum = max(1, minimumSecondLength)
    return totalLength >= firstMinimum + secondMinimum + divider
  }

  public static func safeFirstLength(
    totalLength: Double,
    dividerThickness: Double,
    ratio: Double,
    minimumChildLength: Double = minimumPaneLength
  ) -> Double? {
    safeFirstLength(
      totalLength: totalLength,
      dividerThickness: dividerThickness,
      ratio: ratio,
      minimumFirstLength: minimumChildLength,
      minimumSecondLength: minimumChildLength
    )
  }

  public static func safeFirstLength(
    totalLength: Double,
    dividerThickness: Double,
    ratio: Double,
    minimumFirstLength: Double,
    minimumSecondLength: Double
  ) -> Double? {
    guard canSplit(
      totalLength: totalLength,
      dividerThickness: dividerThickness,
      minimumFirstLength: minimumFirstLength,
      minimumSecondLength: minimumSecondLength
    ) else {
      return nil
    }

    let availableLength = max(0, totalLength - max(0, dividerThickness))
    let firstMinimum = max(1, minimumFirstLength)
    let secondMinimum = max(1, minimumSecondLength)
    let proposed = availableLength * SplitPane.clampedRatio(ratio)
    return min(max(proposed, firstMinimum), availableLength - secondMinimum)
  }

  public static func clampedDividerPosition(
    proposedPosition: Double,
    totalLength: Double,
    dividerThickness: Double,
    minimumChildLength: Double = minimumPaneLength
  ) -> Double? {
    clampedDividerPosition(
      proposedPosition: proposedPosition,
      totalLength: totalLength,
      dividerThickness: dividerThickness,
      minimumFirstLength: minimumChildLength,
      minimumSecondLength: minimumChildLength
    )
  }

  public static func clampedDividerPosition(
    proposedPosition: Double,
    totalLength: Double,
    dividerThickness: Double,
    minimumFirstLength: Double,
    minimumSecondLength: Double
  ) -> Double? {
    guard canSplit(
      totalLength: totalLength,
      dividerThickness: dividerThickness,
      minimumFirstLength: minimumFirstLength,
      minimumSecondLength: minimumSecondLength
    ) else {
      return nil
    }

    let availableLength = max(0, totalLength - max(0, dividerThickness))
    let firstMinimum = max(1, minimumFirstLength)
    let secondMinimum = max(1, minimumSecondLength)
    return min(max(proposedPosition, firstMinimum), availableLength - secondMinimum)
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
    leafWidth: Double = minimumPaneWidth,
    leafHeight: Double = minimumPaneHeight,
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

  public static func windowMinimumContentSize(
    for node: PaneNode,
    baseWidth: Double,
    baseHeight: Double,
    leafWidth: Double = minimumPaneWidth,
    leafHeight: Double = minimumPaneHeight,
    dividerThickness: Double = 1
  ) -> ContentSize {
    let treeMinimum = minimumContentSize(
      for: node,
      leafWidth: leafWidth,
      leafHeight: leafHeight,
      dividerThickness: dividerThickness
    )
    return ContentSize(
      width: max(baseWidth, treeMinimum.width),
      height: max(baseHeight, treeMinimum.height)
    )
  }

  public static func windowMinimumContentSizeAfterSplit(
    root: PaneNode,
    targetPaneId: UUID,
    axis: SplitAxis,
    baseWidth: Double,
    baseHeight: Double,
    leafWidth: Double = minimumPaneWidth,
    leafHeight: Double = minimumPaneHeight,
    dividerThickness: Double = 1
  ) -> ContentSize? {
    var prospectiveRoot = root
    let placeholderPane = TerminalPane(sessionId: TerminalSessionID(), title: "new")
    guard PaneTreeReducer.splitPane(
      in: &prospectiveRoot,
      targetPaneId: targetPaneId,
      axis: axis,
      newPane: placeholderPane
    ) else {
      return nil
    }

    return windowMinimumContentSize(
      for: prospectiveRoot,
      baseWidth: baseWidth,
      baseHeight: baseHeight,
      leafWidth: leafWidth,
      leafHeight: leafHeight,
      dividerThickness: dividerThickness
    )
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

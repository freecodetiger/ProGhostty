import Foundation

public enum ProGhosttyWindowSizing {
  public static let defaultContentWidth: Double = 980
  public static let defaultContentHeight: Double = 640

  public static let minimumContentWidth: Double = 560
  public static let minimumContentHeight: Double = 360

  public static let pluginManagerDefaultContentWidth: Double = 820
  public static let pluginManagerDefaultContentHeight: Double = 640

  public static let pluginManagerMinimumContentWidth: Double = 680
  public static let pluginManagerMinimumContentHeight: Double = 520
}

public enum ProGhosttyOverlaySizing {
  public static let edgeMargin: Double = 24
  public static let workspaceSwitcherIdealWidth: Double = 580
  public static let workspaceSwitcherMinimumWidth: Double = 320
  public static let workspaceSwitcherMinimumHeight: Double = 132
  public static let workspaceSwitcherCardMinimumHeight: Double = 52
  public static let workspaceSwitcherRowHeight: Double = workspaceSwitcherCardMinimumHeight
  public static let workspaceSwitcherRowSpacing: Double = 2
  public static let workspaceSwitcherListVerticalPadding: Double = 16
  public static let workspaceSwitcherFooterHeight: Double = 28

  public static func workspaceSwitcherWidth(containerWidth: Double) -> Double {
    let available = max(1, containerWidth - edgeMargin * 2)
    return min(workspaceSwitcherIdealWidth, max(workspaceSwitcherMinimumWidth, available))
  }

  public static func workspaceSwitcherPanelHeight(workspaceCount: Int, containerHeight: Double) -> Double {
    let available = max(1, containerHeight - edgeMargin * 2)
    let rowCount = max(1, workspaceCount + 1)
    let listHeight = Double(rowCount) * workspaceSwitcherRowHeight
      + Double(max(0, rowCount - 1)) * workspaceSwitcherRowSpacing
      + workspaceSwitcherListVerticalPadding
    let desired = listHeight + workspaceSwitcherFooterHeight
    return min(available, max(workspaceSwitcherMinimumHeight, desired))
  }

  public static func workspaceSwitcherListHeight(workspaceCount: Int, containerHeight: Double) -> Double {
    max(1, workspaceSwitcherPanelHeight(
      workspaceCount: workspaceCount,
      containerHeight: containerHeight
    ) - workspaceSwitcherFooterHeight)
  }
}

public enum ProGhosttyContextMenuSizing {
  public static let splitButtonLength: Double = 42
  public static let splitButtonSpacing: Double = 8
  public static let splitControlHorizontalPadding: Double = 12
  public static let splitControlVerticalPadding: Double = 8
  public static let splitControlTitleHeight: Double = 14
  public static let splitControlTitleSpacing: Double = 4

  public static let splitControlWidth: Double =
    splitControlHorizontalPadding * 2
    + splitButtonLength * 2
    + splitButtonSpacing

  public static let splitControlHeight: Double =
    splitControlVerticalPadding * 2
    + splitControlTitleHeight
    + splitControlTitleSpacing
    + splitButtonLength
}

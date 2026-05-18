import Testing

@testable import ProGhosttyCore

@Suite("Split ratio layout")
struct SplitRatioLayoutTests {
  @Test func mainWindowMinimumIsLowerThanLegacyLargeDefault() {
    #expect(ProGhosttyWindowSizing.minimumContentWidth < 980)
    #expect(ProGhosttyWindowSizing.minimumContentHeight < 640)
  }

  @Test func mainWindowMinimumStillLeavesRoomForStableSinglePane() {
    #expect(ProGhosttyWindowSizing.minimumContentWidth >= SplitRatioLayout.minimumPaneLength * 3)
    #expect(ProGhosttyWindowSizing.minimumContentHeight >= SplitRatioLayout.minimumPaneLength * 2)
  }

  @Test func mainWindowDefaultCanStayLargerThanMinimum() {
    #expect(ProGhosttyWindowSizing.defaultContentWidth >= ProGhosttyWindowSizing.minimumContentWidth)
    #expect(ProGhosttyWindowSizing.defaultContentHeight >= ProGhosttyWindowSizing.minimumContentHeight)
  }

  @Test func pluginManagerWindowHasIndependentConfigurationSize() {
    #expect(ProGhosttyWindowSizing.pluginManagerDefaultContentWidth > ProGhosttyWindowSizing.minimumContentWidth)
    #expect(ProGhosttyWindowSizing.pluginManagerDefaultContentHeight > ProGhosttyWindowSizing.minimumContentHeight)
    #expect(ProGhosttyWindowSizing.pluginManagerMinimumContentWidth >= 680)
    #expect(ProGhosttyWindowSizing.pluginManagerMinimumContentHeight >= 520)
  }

  @Test func workspaceSwitcherOverlayFitsSmallMainWindow() {
    let width = ProGhosttyOverlaySizing.workspaceSwitcherWidth(
      containerWidth: ProGhosttyWindowSizing.minimumContentWidth
    )

    #expect(width < ProGhosttyOverlaySizing.workspaceSwitcherIdealWidth)
    #expect(width <= ProGhosttyWindowSizing.minimumContentWidth - ProGhosttyOverlaySizing.edgeMargin * 2)
    #expect(width >= ProGhosttyOverlaySizing.workspaceSwitcherMinimumWidth)
  }

  @Test func workspaceSwitcherHeightShrinksForFewWorkspaces() {
    let panelHeight = ProGhosttyOverlaySizing.workspaceSwitcherPanelHeight(
      workspaceCount: 2,
      containerHeight: ProGhosttyWindowSizing.defaultContentHeight
    )

    let maxHeight = ProGhosttyWindowSizing.defaultContentHeight - ProGhosttyOverlaySizing.edgeMargin * 2
    #expect(panelHeight < maxHeight * 0.55)
    #expect(panelHeight >= ProGhosttyOverlaySizing.workspaceSwitcherMinimumHeight)
  }

  @Test func workspaceSwitcherHeightCapsForManyWorkspaces() {
    let panelHeight = ProGhosttyOverlaySizing.workspaceSwitcherPanelHeight(
      workspaceCount: 24,
      containerHeight: ProGhosttyWindowSizing.defaultContentHeight
    )

    let maxHeight = ProGhosttyWindowSizing.defaultContentHeight - ProGhosttyOverlaySizing.edgeMargin * 2
    #expect(panelHeight == maxHeight)
  }

  @Test func workspaceSwitcherListHeightShowsCreateCardCompletelyForFewWorkspaces() {
    let workspaceCount = 2
    let rowCountIncludingCreateCard = workspaceCount + 1
    let listHeight = ProGhosttyOverlaySizing.workspaceSwitcherListHeight(
      workspaceCount: workspaceCount,
      containerHeight: ProGhosttyWindowSizing.defaultContentHeight
    )

    let requiredHeight = Double(rowCountIncludingCreateCard)
      * ProGhosttyOverlaySizing.workspaceSwitcherCardMinimumHeight
      + Double(rowCountIncludingCreateCard - 1)
      * ProGhosttyOverlaySizing.workspaceSwitcherRowSpacing
      + ProGhosttyOverlaySizing.workspaceSwitcherListVerticalPadding

    #expect(listHeight >= requiredHeight)
  }

  @Test func splitContextMenuControlsStayCompact() {
    #expect(ProGhosttyContextMenuSizing.splitButtonLength == 42)
    #expect(ProGhosttyContextMenuSizing.splitButtonSpacing == 8)
    #expect(ProGhosttyContextMenuSizing.splitControlWidth <= 180)
    #expect(ProGhosttyContextMenuSizing.splitControlHeight <= 76)
  }

  @Test func equalRatioUsesHalfOfAvailableSpaceAfterDivider() {
    let firstLength = SplitRatioLayout.firstLength(totalLength: 1000, dividerThickness: 8, ratio: 0.5)

    #expect(firstLength == 496)
  }

  @Test func ratioFromSubviewLengthIgnoresDividerThickness() {
    let ratio = SplitRatioLayout.ratio(firstLength: 496, totalLength: 1000, dividerThickness: 8)

    #expect(ratio == 0.5)
  }

  @Test func cannotSplitWhenAvailableSpaceCannotFitBothChildren() {
    #expect(SplitRatioLayout.canSplit(totalLength: 69.5, dividerThickness: 1, minimumChildLength: 120) == false)
  }

  @Test func canSplitWhenAvailableSpaceFitsBothChildrenAndDivider() {
    #expect(SplitRatioLayout.canSplit(totalLength: 241, dividerThickness: 1, minimumChildLength: 120) == true)
  }

  @Test func safeFirstLengthReturnsNilWhenSplitWouldCreateUndersizedChildren() {
    let firstLength = SplitRatioLayout.safeFirstLength(
      totalLength: 69.5,
      dividerThickness: 1,
      ratio: 0.5,
      minimumChildLength: 120
    )

    #expect(firstLength == nil)
  }

  @Test func safeFirstLengthClampsToKeepSiblingAboveMinimum() throws {
    let firstLength = try #require(SplitRatioLayout.safeFirstLength(
      totalLength: 300,
      dividerThickness: 0,
      ratio: 0.9,
      minimumChildLength: 120
    ))

    #expect(firstLength == 180)
  }

  @Test func layoutDrivenResizeShouldNotPersistRatio() {
    #expect(SplitRatioLayout.shouldPersistRatioChange(
      isUserInitiated: false,
      hasAppliedInitialRatio: true,
      isApplyingProgrammaticRatio: false
    ) == false)
  }

  @Test func userInitiatedResizeShouldPersistRatio() {
    #expect(SplitRatioLayout.shouldPersistRatioChange(
      isUserInitiated: true,
      hasAppliedInitialRatio: true,
      isApplyingProgrammaticRatio: false
    ) == true)
  }
}

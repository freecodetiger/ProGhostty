import Testing

@testable import ProGhosttyCore

@Suite("Split ratio layout")
struct SplitRatioLayoutTests {
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

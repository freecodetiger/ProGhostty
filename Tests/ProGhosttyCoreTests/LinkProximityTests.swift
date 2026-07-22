import CoreGraphics
import Testing

@testable import ProGhosttyCore

@Suite("Link proximity (distance helper)")
struct LinkProximityTests {
  @Test func distanceToRectIsZeroInside() {
    let rect = CGRect(x: 10, y: 10, width: 40, height: 20)
    #expect(LinkProximity.distance(from: CGPoint(x: 30, y: 20), to: rect) == 0)
  }

  @Test func distanceToRectMeasuresNearestEdge() {
    let rect = CGRect(x: 10, y: 10, width: 40, height: 20)
    // 10px to the right of the right edge (x 50).
    #expect(LinkProximity.distance(from: CGPoint(x: 60, y: 20), to: rect) == 10)
    // Directly above by 5px.
    #expect(LinkProximity.distance(from: CGPoint(x: 30, y: 5), to: rect) == 5)
  }

  @Test func distanceToRectMeasuresCornerDiagonally() {
    let rect = CGRect(x: 0, y: 0, width: 10, height: 10)
    // 3-4-5 triangle off the top-right corner (10,0).
    #expect(LinkProximity.distance(from: CGPoint(x: 13, y: -4), to: rect) == 5)
  }
}

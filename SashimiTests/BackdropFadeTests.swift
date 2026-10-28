import XCTest
@testable import Sashimi

/// "Lightest" backdrop fade (#765): backdrops used to fade over their left
/// 35% and bottom 40%, hiding text and artwork near their edges.
final class BackdropFadeTests: XCTestCase {
    func testTheLeftEdgeIsOpaqueFromTenPercent() {
        XCTAssertEqual(BackdropFade.leadingOpaqueAt, 0.10, accuracy: 0.0001)
    }

    func testTheBottomStaysOpaqueToNinetyTwoPercent() {
        XCTAssertEqual(BackdropFade.bottomFadeStartsAt, 0.92, accuracy: 0.0001)
    }

    /// The home hero's picture starts below the screen's top edge, which was
    /// a hard line (#787). Its top feathers like its bottom.
    func testAnOnScreenTopEdgeFeathersLikeTheBottom() {
        XCTAssertEqual(BackdropFade.topOpaqueAt, 0.08, accuracy: 0.0001)
        let stops = BackdropFade.verticalStops(fadesTop: true)
        XCTAssertEqual(stops.first?.location, 0)
        XCTAssertEqual(stops.first?.opacity, 0, "transparent at the very top")
        XCTAssertEqual(stops[1].location, 0.08, accuracy: 0.0001)
        XCTAssertEqual(stops[1].opacity, 1)
        XCTAssertEqual(stops.last?.opacity, 0)
    }

    func testAnOffScreenTopEdgeStaysOpaque() {
        let stops = BackdropFade.verticalStops(fadesTop: false)
        XCTAssertEqual(stops.first?.opacity, 1)
        XCTAssertEqual(stops.map(\.location), [0, 0.92, 1])
    }
}

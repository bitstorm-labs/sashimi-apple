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
}

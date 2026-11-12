import XCTest
@testable import SashimiMobile

/// Settings on iPad and Mac keeps to a centred readable column (#904);
/// iPhone keeps the list's own margins.
final class ReadableColumnTests: XCTestCase {
    func testIPadLandscapeCentresAColumnOfTheMaximumWidth() throws {
        // iPad Pro 11-inch landscape detail area beside the side menu.
        let width: CGFloat = 1134
        let margin = try XCTUnwrap(ReadableColumn.horizontalMargin(containerWidth: width))
        XCTAssertEqual(margin, 227)
        XCTAssertLessThanOrEqual(width - 2 * margin, ReadableColumn.maxWidth + 1)
        XCTAssertGreaterThanOrEqual(width - 2 * margin, ReadableColumn.maxWidth)
    }

    func testPhoneAndNarrowSplitViewKeepTheSystemMargins() {
        XCTAssertNil(ReadableColumn.horizontalMargin(containerWidth: 393))   // iPhone portrait
        XCTAssertNil(ReadableColumn.horizontalMargin(containerWidth: 0))     // before layout
        XCTAssertNil(ReadableColumn.horizontalMargin(containerWidth: ReadableColumn.maxWidth))
    }

    func testNeverNarrowerThanTheListsOwnMargin() {
        // 10pt would be tighter than the inset-grouped list's own margin.
        XCTAssertNil(ReadableColumn.horizontalMargin(containerWidth: 700))
        // iPad Pro 11-inch portrait detail area.
        XCTAssertEqual(ReadableColumn.horizontalMargin(containerWidth: 760), 40)
    }
}

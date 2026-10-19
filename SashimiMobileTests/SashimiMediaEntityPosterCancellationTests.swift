import Nuke
import XCTest
@testable import SashimiMobile

/// Nuke 13 reports a cancelled load as `ImagePipeline.Error.cancelled` instead
/// of `CancellationError`; the Siri/Spotlight poster loader must still treat it
/// as a cancellation (no image) rather than a failure (fallback symbol).
final class SashimiMediaEntityPosterCancellationTests: XCTestCase {
    func testNukeCancellationCountsAsCancellation() {
        XCTAssertTrue(SashimiMediaEntity.isCancellation(ImagePipeline.Error.cancelled))
    }

    func testSwiftCancellationCountsAsCancellation() {
        XCTAssertTrue(SashimiMediaEntity.isCancellation(CancellationError()))
    }

    func testLoadFailuresAreNotCancellation() {
        XCTAssertFalse(SashimiMediaEntity.isCancellation(ImagePipeline.Error.imageRequestMissing))
        XCTAssertFalse(SashimiMediaEntity.isCancellation(URLError(.notConnectedToInternet)))
    }
}

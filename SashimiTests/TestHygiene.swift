import XCTest
@testable import Sashimi

/// The test bundle's principal class (`NSPrincipalClass` in project.yml).
/// XCTest creates it once before any test runs. It cleans up process-wide
/// state that would otherwise leak from one test case into the next.
@objc(TestHygiene)
final class TestHygiene: NSObject, XCTestObservation {
    override init() {
        super.init()
        XCTestObservationCenter.shared.addTestObserver(self)
    }

    func testCaseDidFinish(_ testCase: XCTestCase) {
        // A probe outlives the test that started it and retries for over a
        // minute. Its retries would land in whatever stub a later test
        // installs (a stray BitrateTest broke RemoteControlClientTests).
        BandwidthMeasurementStore.shared.cancelAllProbes()
    }
}

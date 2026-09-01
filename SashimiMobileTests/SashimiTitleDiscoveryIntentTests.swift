import XCTest
@testable import SashimiMobile

final class SashimiTitleDiscoveryIntentTests: XCTestCase {
    func testFindIntentRejectsBlankQueryBeforeNetworkWork() async {
        var intent = FindSashimiTitlesIntent()
        intent.query = " \n  "

        do {
            _ = try await intent.perform()
            XCTFail("Expected a blank query to be rejected")
        } catch let error as SashimiTitleDiscoveryIntentError {
            XCTAssertEqual(error, .emptySearchQuery)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

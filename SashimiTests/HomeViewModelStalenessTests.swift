import XCTest
@testable import Sashimi

@MainActor
final class HomeViewModelStalenessTests: XCTestCase {
    func testNeverLoadedIsStale() {
        let viewModel = HomeViewModel()
        XCTAssertNil(viewModel.lastLoadedAt)
        XCTAssertTrue(viewModel.isStale())
    }

    func testFreshUntilTheThresholdThenStale() {
        let viewModel = HomeViewModel()
        let loaded = Date(timeIntervalSince1970: 1_000_000)
        viewModel.setLastLoadedForTesting(loaded)
        viewModel.now = { loaded.addingTimeInterval(HomeViewModel.staleAfter - 1) }
        XCTAssertFalse(viewModel.isStale(), "Just loaded: no reload on every focus change")
        viewModel.now = { loaded.addingTimeInterval(HomeViewModel.staleAfter) }
        XCTAssertTrue(viewModel.isStale(), "Coming back after a while must reload")
        viewModel.now = { loaded.addingTimeInterval(3_600) }
        XCTAssertTrue(viewModel.isStale())
    }
}

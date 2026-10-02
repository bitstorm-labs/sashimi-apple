import XCTest
@testable import SashimiMobile

final class DownloadNetworkPolicyTests: XCTestCase {
    private typealias Policy = DownloadNetworkPolicy

    private let wifi = DownloadNetworkStatus(isConnected: true, isExpensive: false, isConstrained: false)
    private let cellular = DownloadNetworkStatus(isConnected: true, isExpensive: true, isConstrained: false)
    private let lowDataWiFi = DownloadNetworkStatus(isConnected: true, isExpensive: false, isConstrained: true)
    private let offline = DownloadNetworkStatus(isConnected: false, isExpensive: false, isConstrained: false)

    // MARK: - Whether downloads (and keep-next's enqueue) may run now

    func testWiFiOnlyDownloadsOnWiFi() {
        XCTAssertTrue(Policy.canDownloadNow(allowCellular: false, network: wifi))
        XCTAssertNil(Policy.waitReason(allowCellular: false, network: wifi))
    }

    func testWiFiOnlyWaitsOnCellularAndHotspots() {
        XCTAssertFalse(Policy.canDownloadNow(allowCellular: false, network: cellular))
        XCTAssertEqual(Policy.waitReason(allowCellular: false, network: cellular), .cellular)
    }

    func testWiFiOnlyWaitsInLowDataMode() {
        XCTAssertFalse(Policy.canDownloadNow(allowCellular: false, network: lowDataWiFi))
        XCTAssertEqual(Policy.waitReason(allowCellular: false, network: lowDataWiFi), .lowDataMode)
    }

    func testCellularAllowedDownloadsAnywhereConnected() {
        XCTAssertTrue(Policy.canDownloadNow(allowCellular: true, network: cellular))
        XCTAssertTrue(Policy.canDownloadNow(allowCellular: true, network: lowDataWiFi))
    }

    func testNothingDownloadsOffline() {
        XCTAssertEqual(Policy.waitReason(allowCellular: true, network: offline), .offline)
        XCTAssertEqual(Policy.waitReason(allowCellular: false, network: offline), .offline)
    }

    func testSettingDefaultsToWiFiOnly() {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: Policy.allowCellularKey)
        defer { defaults.set(saved, forKey: Policy.allowCellularKey) }
        defaults.removeObject(forKey: Policy.allowCellularKey)
        XCTAssertFalse(Policy.allowsCellular)
    }

    // MARK: - Request access

    func testWiFiOnlyRequestRefusesCellularHotspotAndLowDataMode() throws {
        var request = URLRequest(url: try XCTUnwrap(URL(string: "https://example.invalid/Items/1/Download")))
        Policy.apply(to: &request, allowCellular: false)
        XCTAssertFalse(request.allowsCellularAccess)
        XCTAssertFalse(request.allowsExpensiveNetworkAccess)
        XCTAssertFalse(request.allowsConstrainedNetworkAccess)
    }

    func testCellularRequestAllowsEverything() throws {
        var request = URLRequest(url: try XCTUnwrap(URL(string: "https://example.invalid/Items/1/Download")))
        Policy.apply(to: &request, allowCellular: false)
        Policy.apply(to: &request, allowCellular: true)
        XCTAssertTrue(request.allowsCellularAccess)
        XCTAssertTrue(request.allowsExpensiveNetworkAccess)
        XCTAssertTrue(request.allowsConstrainedNetworkAccess)
    }

    // MARK: - Recreating a task after the setting or network changes

    func testWaitingWiFiOnlyTaskRestartsWhenCellularIsAllowedOnCellular() {
        XCTAssertTrue(Policy.shouldRestartTask(taskAllowsCellular: false, allowCellular: true, network: cellular))
    }

    func testCellularTaskRestartsWhenSettingTurnsOffOnCellular() {
        XCTAssertTrue(Policy.shouldRestartTask(taskAllowsCellular: true, allowCellular: false, network: cellular))
    }

    func testNoRestartOnWiFiWhereBothTasksBehaveTheSame() {
        XCTAssertFalse(Policy.shouldRestartTask(taskAllowsCellular: false, allowCellular: true, network: wifi))
        XCTAssertFalse(Policy.shouldRestartTask(taskAllowsCellular: true, allowCellular: false, network: wifi))
    }

    func testNoRestartWhenTaskAlreadyMatchesTheSetting() {
        XCTAssertFalse(Policy.shouldRestartTask(taskAllowsCellular: false, allowCellular: false, network: cellular))
        XCTAssertFalse(Policy.shouldRestartTask(taskAllowsCellular: true, allowCellular: true, network: cellular))
    }

    func testNoRestartOffline() {
        XCTAssertFalse(Policy.shouldRestartTask(taskAllowsCellular: false, allowCellular: true, network: offline))
    }
}

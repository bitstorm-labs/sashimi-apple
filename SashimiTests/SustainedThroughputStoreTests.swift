import XCTest
@testable import Sashimi

/// What playback itself downloaded at, remembered per server and link kind
/// for the Wi-Fi copy-or-transcode ceiling.
final class SustainedThroughputStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!
    private let server = URL(string: "http://192.168.86.151:9096")!

    override func setUp() {
        super.setUp()
        suite = "SustainedThroughputStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private let enough = BandwidthMeasurementStore.sustainedMinimumBytes

    func testNothingRememberedIsNil() {
        let store = BandwidthMeasurementStore(defaults: defaults)
        XCTAssertNil(store.sustainedBitrate(for: server, isWired: false))
        XCTAssertNil(store.sustainedBitrate(for: nil, isWired: false))
    }

    func testTheLowestRecentReadingWins() {
        let store = BandwidthMeasurementStore(defaults: defaults)
        for rate in [380_000_000.0, 120_000_000, 300_000_000] {
            store.recordSustained(bitsPerSecond: rate, bytesTransferred: enough, for: server, isWired: false)
        }
        XCTAssertEqual(store.sustainedBitrate(for: server, isWired: false), 120_000_000)
    }

    func testOnlyTheLastFewReadingsCount() {
        let store = BandwidthMeasurementStore(defaults: defaults)
        store.recordSustained(bitsPerSecond: 10_000_000, bytesTransferred: enough, for: server, isWired: false)
        for _ in 0..<BandwidthMeasurementStore.sustainedSampleLimit {
            store.recordSustained(bitsPerSecond: 200_000_000, bytesTransferred: enough, for: server, isWired: false)
        }
        XCTAssertEqual(store.sustainedBitrate(for: server, isWired: false), 200_000_000,
                       "an old slow reading ages out once the link has proven itself again")
    }

    func testWiredAndWirelessAreSeparate() {
        let store = BandwidthMeasurementStore(defaults: defaults)
        store.recordSustained(bitsPerSecond: 900_000_000, bytesTransferred: enough, for: server, isWired: true)
        XCTAssertNil(store.sustainedBitrate(for: server, isWired: false))
        XCTAssertEqual(store.sustainedBitrate(for: server, isWired: true), 900_000_000)
    }

    func testABurstOverTooLittleVideoIsIgnored() {
        let store = BandwidthMeasurementStore(defaults: defaults)
        store.recordSustained(bitsPerSecond: 900_000_000, bytesTransferred: enough - 1, for: server, isWired: false)
        store.recordSustained(bitsPerSecond: .nan, bytesTransferred: enough, for: server, isWired: false)
        store.recordSustained(bitsPerSecond: -1, bytesTransferred: enough, for: server, isWired: false)
        XCTAssertNil(store.sustainedBitrate(for: server, isWired: false))
    }

    func testRememberedAcrossLaunches() {
        BandwidthMeasurementStore(defaults: defaults)
            .recordSustained(bitsPerSecond: 250_000_000, bytesTransferred: enough, for: server, isWired: false)
        XCTAssertEqual(BandwidthMeasurementStore(defaults: defaults).sustainedBitrate(for: server, isWired: false), 250_000_000)
    }
}

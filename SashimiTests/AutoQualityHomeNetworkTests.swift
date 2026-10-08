import XCTest
@testable import Sashimi

/// #631: a living-room Apple TV reaching its home server through a public
/// hostname played a 9.75 Mbps 1080p episode at 854x480 / 3.36 Mbps. The
/// probe had measured ~300 Mbps through the proxy, but the player plays
/// through its own per-server client, which never saw the measurement. Auto
/// then used the 4 Mbps default, which was keyed on the hostname and not on
/// the device's network, and nothing raised the stream afterwards.
final class AutoQualityHomeNetworkTests: XCTestCase {
    private func uniqueServer(_ scheme: String = "https") -> URL {
        URL(string: "\(scheme)://fin-\(UUID().uuidString.prefix(8).lowercased()).example.com")!
    }

    // MARK: - Measurements are shared per server, not per client

    func testPlayerClientSeesTheMeasurementTheSessionClientTook() async {
        // The session probes on one client; the player builds its own
        // (SessionManager.makeClient) for the same server.
        let server = uniqueServer()
        let sessionClient = JellyfinClient(serverURL: server, accessToken: "token", userId: "user")
        let playerClient = JellyfinClient(serverURL: server, accessToken: "token", userId: "user")

        await sessionClient.recordBandwidthMeasurement(bitsPerSecond: 300_000_000)

        let status = await playerClient.bandwidthStatus
        XCTAssertEqual(status.measuredBitrate, 300_000_000)
        XCTAssertEqual(status.capSource, "measured")
        XCTAssertEqual(status.cap, PlaybackSelection.maximumMeasuredBitrateCap)
    }

    func testRepointingTheSharedClientAndBackKeepsTheMeasurement() async {
        // A server-scoped route (multi-server search result) repoints the
        // shared client and restores it afterwards. That used to wipe the
        // active server's measurement, and nothing re-probed.
        let home = uniqueServer()
        let other = uniqueServer()
        let client = JellyfinClient()
        await client.configure(serverURL: home, accessToken: "token", userId: "user")
        await client.recordBandwidthMeasurement(bitsPerSecond: 80_000_000)

        await client.configure(serverURL: other, accessToken: "token", userId: "user")
        await client.configure(serverURL: home, accessToken: "token", userId: "user")

        let measured = await client.bandwidthStatus.measuredBitrate
        XCTAssertEqual(measured, 80_000_000)
    }

    func testAnotherServerDoesNotInheritTheMeasurement() async {
        let home = uniqueServer()
        let other = uniqueServer()
        let homeClient = JellyfinClient(serverURL: home, accessToken: "token", userId: "user")
        let otherClient = JellyfinClient(serverURL: other, accessToken: "token", userId: "user")

        await homeClient.recordBandwidthMeasurement(bitsPerSecond: 80_000_000)

        let measured = await otherClient.bandwidthStatus.measuredBitrate
        XCTAssertNil(measured)
    }

    func testStoreKeyIgnoresHostCaseAndTrailingSlash() throws {
        let plain = try XCTUnwrap(URL(string: "https://Fin.Example.com"))
        let slashed = try XCTUnwrap(URL(string: "https://fin.example.com/"))
        let otherPort = try XCTUnwrap(URL(string: "https://fin.example.com:8920"))
        XCTAssertEqual(BandwidthMeasurementStore.key(for: plain), BandwidthMeasurementStore.key(for: slashed))
        XCTAssertNotEqual(BandwidthMeasurementStore.key(for: plain), BandwidthMeasurementStore.key(for: otherPort))
    }

    func testIsolatedStoreDoesNotLeakIntoTheSharedOne() async {
        let server = uniqueServer()
        let store = BandwidthMeasurementStore()
        let isolated = JellyfinClient(serverURL: server, accessToken: "token", userId: "user", bandwidthStore: store)
        let shared = JellyfinClient(serverURL: server, accessToken: "token", userId: "user")

        await isolated.recordBandwidthMeasurement(bitsPerSecond: 50_000_000)

        XCTAssertEqual(store.measurement(for: server)?.bitsPerSecond, 50_000_000)
        let sharedMeasured = await shared.bandwidthStatus.measuredBitrate
        XCTAssertNil(sharedMeasured)
    }

    // MARK: - Unmeasured default follows the device's network

    func testUnmeasuredPublicServerOnThisUnmeteredNetworkGets1080p() async throws {
        // The test host's network is unmetered (Mac Wi-Fi/Ethernet), exactly
        // like an Apple TV. Before #631 this returned the 4 Mbps default.
        try XCTSkipIf(NetworkConnectionMonitor.shared.isMetered, "test host is on a metered network")
        let client = JellyfinClient(serverURL: uniqueServer(), accessToken: "token", userId: "user")

        let status = await client.bandwidthStatus

        XCTAssertFalse(status.isLocalServer)
        XCTAssertNil(status.measuredBitrate)
        XCTAssertEqual(status.cap, 20_000_000)
    }

    // MARK: - Upward renegotiation

    private typealias Context = PlaybackSelection.UpwardRenegotiationContext

    /// The live case: Auto on a 4 Mbps default, transcoding a 9.75 Mbps
    /// source, and the probe has since read ~300 Mbps (cap 100 Mbps).
    private func liveCase() -> Context {
        Context(
            isAuto: true,
            startedOnUnmeasuredDefault: true,
            activeCap: 4_000_000,
            measuredCap: 100_000_000,
            hasSteppedDown: false,
            alreadyRenegotiated: false,
            isTranscoding: true,
            sourceBitrate: 9_750_000,
            isBusy: false,
            secondsSinceRecovery: nil
        )
    }

    func testLateMeasurementRaisesAStreamStartedOnADefault() {
        XCTAssertEqual(PlaybackSelection.upwardRenegotiation(liveCase()), .now)
    }

    func testNoMeasurementMeansNoRebuild() {
        var context = liveCase()
        context.measuredCap = nil
        XCTAssertEqual(PlaybackSelection.upwardRenegotiation(context), .none)
    }

    func testOnlyOnce() {
        var context = liveCase()
        context.alreadyRenegotiated = true
        XCTAssertEqual(PlaybackSelection.upwardRenegotiation(context), .none)
    }

    func testAStreamBuiltOnAMeasurementIsLeftAlone() {
        var context = liveCase()
        context.startedOnUnmeasuredDefault = false
        XCTAssertEqual(PlaybackSelection.upwardRenegotiation(context), .none)
    }

    func testAnExplicitQualityPickIsLeftAlone() {
        var context = liveCase()
        context.isAuto = false
        XCTAssertEqual(PlaybackSelection.upwardRenegotiation(context), .none)
    }

    func testAStallStepDownIsACeilingForTheSession() {
        var context = liveCase()
        context.hasSteppedDown = true
        XCTAssertEqual(PlaybackSelection.upwardRenegotiation(context), .none)
    }

    func testRiseMustBeAtLeastDouble() {
        // 4 -> 7.9 Mbps also crosses 854 -> 1280, but is not worth a rebuild.
        var context = liveCase()
        context.measuredCap = 7_900_000
        XCTAssertEqual(PlaybackSelection.upwardRenegotiation(context), .none)
        context.measuredCap = 8_000_000
        XCTAssertEqual(PlaybackSelection.upwardRenegotiation(context), .now)
    }

    func testRiseMustCrossAWidthTier() {
        // 25 -> 60 Mbps doubles, but both are "no width cap".
        var context = liveCase()
        context.activeCap = 25_000_000
        context.measuredCap = 60_000_000
        context.sourceBitrate = 68_000_000
        XCTAssertEqual(PlaybackSelection.upwardRenegotiation(context), .none)
    }

    func testADirectPlayedStreamIsLeftAlone() {
        var context = liveCase()
        context.isTranscoding = false
        XCTAssertEqual(PlaybackSelection.upwardRenegotiation(context), .none)
    }

    func testASourceTheOldCapCoveredIsLeftAlone() {
        // A 3 Mbps source remuxed under a 4 Mbps cap is the source already.
        var context = liveCase()
        context.sourceBitrate = 3_000_000
        XCTAssertEqual(PlaybackSelection.upwardRenegotiation(context), .none)
    }

    func testWaitsWhileARecoveryOrStallIsInFlight() {
        var context = liveCase()
        context.isBusy = true
        XCTAssertEqual(
            PlaybackSelection.upwardRenegotiation(context),
            .after(PlaybackSelection.upwardRenegotiationRecoveryQuietPeriod)
        )
    }

    func testWaitsOutTheFirstSecondsAfterAStallRecovery() {
        var context = liveCase()
        context.secondsSinceRecovery = 4
        XCTAssertEqual(
            PlaybackSelection.upwardRenegotiation(context),
            .after(PlaybackSelection.upwardRenegotiationRecoveryQuietPeriod - 4)
        )
        context.secondsSinceRecovery = PlaybackSelection.upwardRenegotiationRecoveryQuietPeriod
        XCTAssertEqual(PlaybackSelection.upwardRenegotiation(context), .now)
    }

    // MARK: - The player's own state feeds the decision

    private func transcodingSource(bitrate: Int) throws -> MediaSourceInfo {
        let json = """
        { "Id": "source-1", "TranscodingUrl": "/videos/x/master.m3u8", "Bitrate": \(bitrate) }
        """
        return try JSONDecoder().decode(MediaSourceInfo.self, from: Data(json.utf8))
    }

    @MainActor
    private func playerOnADefault() throws -> PlayerViewModel {
        let model = PlayerViewModel(client: JellyfinClient(serverURL: uniqueServer(), accessToken: "token", userId: "user"))
        model.selectedQuality = .auto
        model.activeBitrateCap = 4_000_000
        model.activeCapIsUnmeasuredDefault = true
        model.currentMediaSource = try transcodingSource(bitrate: 9_750_000)
        return model
    }

    @MainActor
    func testPlayerOnADefaultRenegotiatesWhenAMeasurementLands() throws {
        try XCTSkipIf(PlaybackSettings.shared.maxBitrate != 0, "Settings cap set on this host")
        let model = try playerOnADefault()
        XCTAssertEqual(model.upwardRenegotiation(measuredCap: 100_000_000), .now)
    }

    @MainActor
    func testPlayerThatSteppedDownNeverRenegotiatesUp() throws {
        let model = try playerOnADefault()
        // What a stall step-down leaves behind (attemptPlaybackRecovery).
        model.qualityStepDowns = 1
        model.selectedQuality = .quality480p
        XCTAssertEqual(model.upwardRenegotiation(measuredCap: 100_000_000), .none)
    }

    @MainActor
    func testPlayerWaitsOutARecentRecovery() throws {
        try XCTSkipIf(PlaybackSettings.shared.maxBitrate != 0, "Settings cap set on this host")
        let model = try playerOnADefault()
        let now = Date()
        model.lastRecoveryAt = now.addingTimeInterval(-3)
        XCTAssertEqual(
            model.upwardRenegotiation(measuredCap: 100_000_000, now: now),
            .after(PlaybackSelection.upwardRenegotiationRecoveryQuietPeriod - 3)
        )
    }

    @MainActor
    func testPlayerRenegotiatesOnlyOnce() throws {
        let model = try playerOnADefault()
        model.bandwidthUpgradeDone = true
        XCTAssertEqual(model.upwardRenegotiation(measuredCap: 100_000_000), .none)
    }
}

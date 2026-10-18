import XCTest
@testable import Sashimi

/// A dashboard server whose answers and failures the test sets, counting
/// every request so polling can be observed.
private actor FakeDashboardServer: ServerDashboardClient {
    var sessions: [DashboardSession] = []
    var activity: [ActivityLogEntry] = []
    var tasks: [ScheduledTaskInfo] = []
    var storage: SystemStorageInfo?
    var activityError: Error?
    var sessionsError: Error?
    private(set) var requests = 0
    private(set) var sessionRequests = 0
    private(set) var activityRequests = 0
    private(set) var stopped: [String] = []
    private(set) var messages: [(String, String)] = []

    func set(sessions: [DashboardSession]) { self.sessions = sessions }
    func set(activity: [ActivityLogEntry]) { self.activity = activity }
    func set(storage: SystemStorageInfo?) { self.storage = storage }
    func set(activityError: Error?) { self.activityError = activityError }
    func set(sessionsError: Error?) { self.sessionsError = sessionsError }

    func getActiveSessions() async throws -> [DashboardSession] {
        requests += 1
        sessionRequests += 1
        if let sessionsError { throw sessionsError }
        return sessions
    }

    func getActivityLog(limit: Int) async throws -> [ActivityLogEntry] {
        requests += 1
        activityRequests += 1
        if let activityError { throw activityError }
        return Array(activity.prefix(limit))
    }

    func getScheduledTasks() async throws -> [ScheduledTaskInfo] {
        requests += 1
        return tasks
    }

    func getDashboardSystemInfo() async throws -> DashboardSystemInfo {
        requests += 1
        return try JSONDecoder().decode(DashboardSystemInfo.self, from: Data(#"{"ServerName":"JellyPal","Version":"12.2.0"}"#.utf8))
    }

    func getStorageInfo() async throws -> SystemStorageInfo? {
        requests += 1
        return storage
    }

    func getEncodingOptions() async throws -> EncodingOptionsSummary {
        requests += 1
        return EncodingOptionsSummary(hardwareAccelerationType: "qsv")
    }

    func stopPlayback(sessionId: String) async throws {
        stopped.append(sessionId)
    }

    func sendMessage(sessionId: String, text: String) async throws {
        messages.append((sessionId, text))
    }
}

@MainActor
final class ServerDashboardViewModelTests: XCTestCase {
    private func playing(_ id: String, user: String, remote: Bool = true, bitrate: Int = 8_000_000) -> DashboardSession {
        DashboardSession(
            id: id,
            userName: user,
            client: "Jellyfin Web",
            applicationVersion: nil,
            deviceName: "Chrome",
            supportsRemoteControl: remote,
            nowPlayingItem: DashboardNowPlaying(
                id: "item-\(id)", name: "300", type: "Movie", seriesName: nil, seriesId: nil,
                parentIndexNumber: nil, indexNumber: nil, runTimeTicks: 100, container: nil, mediaStreams: []
            ),
            playState: nil,
            transcodingInfo: DashboardTranscodingInfo(
                audioCodec: nil, videoCodec: nil, container: nil, isVideoDirect: false, isAudioDirect: true,
                bitrate: bitrate, width: nil, height: nil, hardwareAccelerationType: "qsv", transcodeReasons: []
            )
        )
    }

    private func idle(_ id: String) -> DashboardSession {
        DashboardSession(
            id: id, userName: "kid", client: "Sashimi", applicationVersion: nil, deviceName: "iPad",
            supportsRemoteControl: true, nowPlayingItem: nil, playState: nil, transcodingInfo: nil
        )
    }

    private func storage() throws -> SystemStorageInfo {
        let json = #"{"TranscodingTempFolder":{"FreeSpace":10,"UsedSpace":90},"Libraries":[]}"#
        return try JSONDecoder().decode(SystemStorageInfo.self, from: Data(json.utf8))
    }

    private func waitUntil(_ timeout: Duration = .seconds(3), _ condition: () async -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("condition never became true")
    }

    func testRefreshFillsEverySectionWithOnlyPlayingSessions() async throws {
        let server = FakeDashboardServer()
        await server.set(sessions: [playing("a", user: "ozzy"), idle("b"), playing("c", user: "mom", bitrate: 38_000_000)])
        await server.set(storage: try storage())
        let model = ServerDashboardViewModel(client: server, onDenied: {})

        await model.refreshAll()

        XCTAssertEqual(model.state, .loaded)
        XCTAssertEqual(model.sessions.map(\.id), ["c", "a"], "playing sessions only, ordered by user")
        XCTAssertEqual(model.convertingCount, 2)
        XCTAssertEqual(model.totalBitrate, 46_000_000)
        XCTAssertEqual(model.serverLine, "JellyPal · Jellyfin 12.2.0")
        XCTAssertEqual(model.health.map(\.title), ["Cache drive", "Hardware transcoding (QSV)"])
        XCTAssertEqual(model.attention.map(\.text), ["Cache drive 90% full"])
    }

    func testAForbiddenAnswerClearsEverythingAndReportsTheDenial() async throws {
        let server = FakeDashboardServer()
        await server.set(sessions: [playing("a", user: "ozzy")])
        var denied = 0
        let model = ServerDashboardViewModel(client: server, onDenied: { denied += 1 })
        await model.refreshAll()
        XCTAssertFalse(model.sessions.isEmpty)

        await server.set(activityError: JellyfinError.httpError(statusCode: 403))
        await model.refreshAll()

        XCTAssertEqual(model.state, .denied)
        XCTAssertTrue(model.sessions.isEmpty)
        XCTAssertTrue(model.health.isEmpty)
        XCTAssertNil(model.systemInfo)
        XCTAssertEqual(denied, 1)
    }

    func testADeniedDashboardNeverPolls() async throws {
        let server = FakeDashboardServer()
        await server.set(sessionsError: JellyfinError.httpError(statusCode: 403))
        let model = ServerDashboardViewModel(client: server, sessionInterval: .milliseconds(10), onDenied: {})
        model.attach()
        try await waitUntil { model.state == .denied }
        XCTAssertFalse(model.isPolling)
        model.detach()
        model.attach()
        XCTAssertFalse(model.isPolling, "re-showing the screen must not start asking again")
    }

    func testNoStorageEndpointDropsOnlyTheStorageRows() async throws {
        let server = FakeDashboardServer()
        let model = ServerDashboardViewModel(client: server, onDenied: {})
        await model.refreshAll()
        XCTAssertEqual(model.health.map(\.title), ["Hardware transcoding (QSV)"])
    }

    func testAnUnreachableServerShowsNothingStaleAndRecovers() async throws {
        let server = FakeDashboardServer()
        await server.set(sessions: [playing("a", user: "ozzy")])
        let model = ServerDashboardViewModel(client: server, onDenied: {})
        await model.refreshAll()

        await server.set(sessionsError: JellyfinError.httpError(statusCode: 502))
        await model.refreshSessions()
        XCTAssertEqual(model.state, .failed)
        XCTAssertTrue(model.sessions.isEmpty)

        await server.set(sessionsError: nil)
        await model.refreshSessions()
        XCTAssertEqual(model.state, .loaded)
        XCTAssertEqual(model.sessions.map(\.id), ["a"])
    }

    func testPollingStopsWhenTheLastScreenGoes() async throws {
        let server = FakeDashboardServer()
        let model = ServerDashboardViewModel(client: server, sessionInterval: .milliseconds(10), onDenied: {})

        model.attach()
        model.attach()
        try await waitUntil { await server.requests >= 8 }
        model.detach()
        XCTAssertTrue(model.isPolling, "one screen is still showing")
        let before = await server.requests
        try await waitUntil { await server.requests > before + 2 }

        model.detach()
        XCTAssertFalse(model.isPolling)
        try await Task.sleep(for: .milliseconds(30))
        let settled = await server.requests
        try await Task.sleep(for: .milliseconds(150))
        let after = await server.requests
        XCTAssertEqual(after, settled, "no request once the dashboard is gone")
    }

    func testBackgroundingStopsPolling() async throws {
        let server = FakeDashboardServer()
        let model = ServerDashboardViewModel(client: server, sessionInterval: .milliseconds(10), onDenied: {})
        model.attach()
        XCTAssertTrue(model.isPolling)
        model.setSceneActive(false)
        XCTAssertFalse(model.isPolling)
        model.setSceneActive(true)
        XCTAssertTrue(model.isPolling)
        model.detach()
    }

    func testSessionsRefreshFasterThanActivity() async throws {
        let server = FakeDashboardServer()
        let model = ServerDashboardViewModel(
            client: server, sessionInterval: .milliseconds(10), slowInterval: .seconds(60), onDenied: {}
        )
        model.attach()
        try await waitUntil { await server.sessionRequests >= 5 }
        model.detach()
        let activityReads = await server.activityRequests
        XCTAssertEqual(activityReads, 1, "activity and health are re-read on the slow interval, not every tick")
        XCTAssertEqual(model.state, .loaded)
    }

    func testStopStopsThatSessionAndRefreshes() async throws {
        let server = FakeDashboardServer()
        await server.set(sessions: [playing("a", user: "ozzy")])
        let model = ServerDashboardViewModel(client: server, onDenied: {})
        await model.refreshAll()

        await server.set(sessions: [])
        await model.stop(playing("a", user: "ozzy"))

        let stopped = await server.stopped
        XCTAssertEqual(stopped, ["a"])
        XCTAssertTrue(model.sessions.isEmpty, "the list was re-read after stopping")
    }

    func testSessionsThatCannotBeControlledAreNeverStoppedOrMessaged() async throws {
        let server = FakeDashboardServer()
        let model = ServerDashboardViewModel(client: server, onDenied: {})
        let locked = playing("a", user: "mondo", remote: false)

        await model.stop(locked)
        let sent = await model.message(locked, text: "hi")

        let stopped = await server.stopped
        let messages = await server.messages
        XCTAssertTrue(stopped.isEmpty)
        XCTAssertTrue(messages.isEmpty)
        XCTAssertFalse(sent)
    }

    func testMessagesAreTrimmedAndBlankOnesAreNotSent() async throws {
        let server = FakeDashboardServer()
        let model = ServerDashboardViewModel(client: server, onDenied: {})
        let session = playing("a", user: "mom")

        let blank = await model.message(session, text: "   ")
        let sent = await model.message(session, text: "  Server restarting in 5 min \n")

        let messages = await server.messages
        XCTAssertFalse(blank)
        XCTAssertTrue(sent)
        XCTAssertEqual(messages.map(\.0), ["a"])
        XCTAssertEqual(messages.map(\.1), ["Server restarting in 5 min"])
    }
}

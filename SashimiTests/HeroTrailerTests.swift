import XCTest
@testable import Sashimi

private func item(_ json: String) throws -> BaseItemDto {
    try JSONDecoder().decode(BaseItemDto.self, from: Data(json.utf8))
}

/// The rules behind the detail-screen hero trailer (#658).
final class HeroTrailerPolicyTests: XCTestCase {
    func testMoviesAndSeriesUseTheirOwnTrailer() throws {
        XCTAssertEqual(HeroTrailerPolicy.trailerSourceId(for: try item(#"{"Id":"m1","Name":"M","Type":"Movie","LocalTrailerCount":1}"#)), "m1")
        XCTAssertEqual(HeroTrailerPolicy.trailerSourceId(for: try item(#"{"Id":"s1","Name":"S","Type":"Series"}"#)), "s1",
                       "an unknown count still asks the server")
    }

    func testSeasonsAndEpisodesUseTheSeriesTrailer() throws {
        XCTAssertEqual(HeroTrailerPolicy.trailerSourceId(for: try item(#"{"Id":"e1","Name":"E","Type":"Episode","SeriesId":"s1"}"#)), "s1")
        XCTAssertEqual(HeroTrailerPolicy.trailerSourceId(for: try item(#"{"Id":"z1","Name":"Z","Type":"Season","SeriesId":"s1"}"#)), "s1")
    }

    func testNoTrailerWhenTheServerSaysThereIsNoneOrTheTypeHasNone() throws {
        XCTAssertNil(HeroTrailerPolicy.trailerSourceId(for: try item(#"{"Id":"m1","Name":"M","Type":"Movie","LocalTrailerCount":0}"#)))
        XCTAssertNil(HeroTrailerPolicy.trailerSourceId(for: try item(#"{"Id":"b1","Name":"B","Type":"BoxSet"}"#)))
        XCTAssertNil(HeroTrailerPolicy.trailerSourceId(for: try item(#"{"Id":"e1","Name":"E","Type":"Episode"}"#)),
                     "an episode without a series has nothing to play")
    }

    func testEligibility() {
        func eligible(
            setting: Bool = true, online: Bool = true, expensive: Bool = false, constrained: Bool = false,
            screen: String? = nil, active: String? = "a"
        ) -> Bool {
            HeroTrailerPolicy.Conditions(
                settingOn: setting, isOnline: online, isExpensive: expensive, isConstrained: constrained,
                screenServerId: screen, activeServerId: active
            ).isEligible
        }
        XCTAssertTrue(eligible())
        XCTAssertTrue(eligible(screen: "a"))
        XCTAssertFalse(eligible(setting: false))
        XCTAssertFalse(eligible(online: false))
        XCTAssertFalse(eligible(expensive: true))
        XCTAssertFalse(eligible(constrained: true))
        XCTAssertFalse(eligible(screen: "b"), "a screen for another server can't stream through the active client")
    }

    func testSilentUnderAThemeAudibleOtherwise() {
        XCTAssertTrue(HeroTrailerPolicy.shouldMute(themeIsPlaying: true))
        XCTAssertFalse(HeroTrailerPolicy.shouldMute(themeIsPlaying: false))
    }

    func testAFullTrailerSkipsItsOpeningAndPlaysThirtySeconds() {
        XCTAssertEqual(HeroTrailerPolicy.clip(trailerSeconds: 121), HeroTrailerClip(start: 10, end: 40))
        XCTAssertEqual(HeroTrailerPolicy.clip(trailerSeconds: 45), HeroTrailerClip(start: 10, end: 40),
                       "the threshold itself counts as a full trailer")
    }

    func testAShortClipOrUnknownLengthPlaysFromTheStart() {
        XCTAssertEqual(HeroTrailerPolicy.clip(trailerSeconds: 44.9), HeroTrailerClip(start: 0, end: 30))
        XCTAssertEqual(HeroTrailerPolicy.clip(trailerSeconds: nil), HeroTrailerClip(start: 0, end: 30))
    }

    func testTheSourceIsTheFirstTrailerWithItsLengthInSeconds() throws {
        let first = try item(#"{"Id":"t1","Name":"T","Type":"Trailer","RunTimeTicks":1215000000}"#)
        let second = try item(#"{"Id":"t2","Name":"T","Type":"Trailer"}"#)
        XCTAssertEqual(HeroTrailerSource(trailers: [first, second]), HeroTrailerSource(id: "t1", seconds: 121.5))
        XCTAssertEqual(HeroTrailerSource(trailers: [second]), HeroTrailerSource(id: "t2", seconds: nil))
        XCTAssertNil(HeroTrailerSource(trailers: []))
    }
}

final class HeroTrailerOwnersTests: XCTestCase {
    private let series = UUID(), season = UUID(), episode = UUID(), other = UUID()

    func testFirstScreenStartsItsTrailer() {
        var owners = HeroTrailerOwners()
        XCTAssertEqual(owners.appeared(owner: series, sourceId: "s1", playingSourceId: nil), .start(sourceId: "s1"))
        XCTAssertEqual(owners.topOwner, series)
    }

    func testDrillingIntoTheSameShowHandsTheTrailerOver() {
        var owners = HeroTrailerOwners()
        _ = owners.appeared(owner: series, sourceId: "s1", playingSourceId: nil)
        XCTAssertEqual(owners.appeared(owner: season, sourceId: "s1", playingSourceId: "s1"), .handOff)
        XCTAssertEqual(owners.topOwner, season)
        XCTAssertEqual(owners.dismissed(owner: season, playingSourceId: "s1"), .handOff)
        XCTAssertEqual(owners.topOwner, series)
    }

    func testAFinishedTrailerDoesNotReplayInTheSameVisit() {
        var owners = HeroTrailerOwners()
        _ = owners.appeared(owner: series, sourceId: "s1", playingSourceId: nil)
        XCTAssertEqual(owners.appeared(owner: episode, sourceId: "s1", playingSourceId: nil), .stop)
    }

    func testANewVisitPlaysItAgain() {
        var owners = HeroTrailerOwners()
        _ = owners.appeared(owner: series, sourceId: "s1", playingSourceId: nil)
        XCTAssertEqual(owners.dismissed(owner: series, playingSourceId: nil), .stop)
        XCTAssertEqual(owners.appeared(owner: other, sourceId: "s1", playingSourceId: nil), .start(sourceId: "s1"))
    }

    func testADifferentTitleOnTopStartsItsOwnAndBackingOutStops() {
        var owners = HeroTrailerOwners()
        _ = owners.appeared(owner: series, sourceId: "s1", playingSourceId: nil)
        XCTAssertEqual(owners.appeared(owner: other, sourceId: "m2", playingSourceId: "s1"), .start(sourceId: "m2"))
        XCTAssertEqual(owners.dismissed(owner: other, playingSourceId: "m2"), .stop,
                       "the screen underneath shows its image, it doesn't restart")
        XCTAssertEqual(owners.topOwner, series)
    }

    func testAScreenWithoutATrailerCoveringStopsIt() {
        var owners = HeroTrailerOwners()
        _ = owners.appeared(owner: series, sourceId: "s1", playingSourceId: nil)
        XCTAssertEqual(owners.appeared(owner: other, sourceId: nil, playingSourceId: "s1"), .stop)
    }

    func testDismissingACoveredScreenChangesNothing() {
        var owners = HeroTrailerOwners()
        _ = owners.appeared(owner: series, sourceId: "s1", playingSourceId: nil)
        _ = owners.appeared(owner: other, sourceId: "m2", playingSourceId: nil)
        XCTAssertEqual(owners.dismissed(owner: series, playingSourceId: "m2"), .ignore)
        XCTAssertEqual(owners.topOwner, other)
        XCTAssertEqual(owners.dismissed(owner: UUID(), playingSourceId: "m2"), .ignore)
    }
}

@MainActor
final class HeroTrailerControllerTests: XCTestCase {
    private var resolved: [String] = []
    private var stopped: [String] = []
    private var themePlaying = false
    private var eligible = true
    private var trailers: [String: HeroTrailerSource?] = ["m1": HeroTrailerSource(id: "t1", seconds: 121)]

    private func controller() throws -> HeroTrailerController {
        let c = HeroTrailerController(timings: HeroTrailerTimings(startDelay: 0, crossFade: 0))
        let url = try XCTUnwrap(URL(string: "http://stub.local/videos/t1/main.m3u8"))
        c.resolver = { [unowned self] id in
            resolved.append(id)
            return trailers[id].flatMap { $0 }
        }
        c.streamBuilder = { _ in HeroTrailerStream(url: url, playSessionId: "ps1") }
        c.encodingStopper = { [unowned self] id in stopped.append(id) }
        c.themeIsPlaying = { [unowned self] in themePlaying }
        c.isEligible = { [unowned self] _ in eligible }
        return c
    }

    private func movie(_ id: String = "m1") throws -> BaseItemDto {
        try item(#"{"Id":"\#(id)","Name":"M","Type":"Movie"}"#)
    }

    func testAMovieWithATrailerPlaysWithSound() async throws {
        let c = try controller()
        let owner = UUID()
        c.screenAppeared(owner: owner, item: try movie(), serverID: nil)
        await c.waitForStartForTest()

        XCTAssertEqual(c.activeOwner, owner)
        XCTAssertNotNil(c.player)
        XCTAssertEqual(c.playingSourceIdForTest, "m1")
        XCTAssertEqual(c.player?.isMuted, false)
    }

    func testSilentWhenAThemeIsPlaying() async throws {
        themePlaying = true
        let c = try controller()
        c.screenAppeared(owner: UUID(), item: try movie(), serverID: nil)
        await c.waitForStartForTest()
        XCTAssertEqual(c.player?.isMuted, true)
    }

    func testAThemeStartingLaterSilencesItAndItStaysSilent() async throws {
        let c = try controller()
        c.screenAppeared(owner: UUID(), item: try movie(), serverID: nil)
        await c.waitForStartForTest()
        c.themeStateChanged(isPlaying: true)
        XCTAssertEqual(c.player?.isMuted, true)
        c.themeStateChanged(isPlaying: false)
        XCTAssertEqual(c.player?.isMuted, true, "no sound out of nowhere when the theme ends")
    }

    func testItPlaysTheClipNotTheWholeTrailer() async throws {
        let c = try controller()
        c.screenAppeared(owner: UUID(), item: try movie(), serverID: nil)
        await c.waitForStartForTest()
        XCTAssertEqual(c.clipForTest, HeroTrailerClip(start: 10, end: 40))
        XCTAssertEqual(c.player?.currentItem?.forwardPlaybackEndTime.seconds, 40)
    }

    func testNoTrailerMeansNoPlayer() async throws {
        trailers = ["m1": nil]
        let c = try controller()
        c.screenAppeared(owner: UUID(), item: try movie(), serverID: nil)
        await c.waitForStartForTest()
        XCTAssertNil(c.player)
    }

    func testIneligibleNeverAsksTheServer() async throws {
        eligible = false
        let c = try controller()
        c.screenAppeared(owner: UUID(), item: try movie(), serverID: nil)
        await c.waitForStartForTest()
        XCTAssertNil(c.player)
        XCTAssertEqual(resolved, [])
    }

    func testPlayStopsItAndEndsTheServerEncoding() async throws {
        let c = try controller()
        c.screenAppeared(owner: UUID(), item: try movie(), serverID: nil)
        await c.waitForStartForTest()
        c.stopForPlayback()
        XCTAssertNil(c.player)
        await Task.yield()
        await Task.yield()
        XCTAssertEqual(stopped, ["ps1"])
    }

    func testClosingTheScreenStopsIt() async throws {
        let c = try controller()
        let owner = UUID()
        c.screenAppeared(owner: owner, item: try movie(), serverID: nil)
        await c.waitForStartForTest()
        c.screenDismissed(owner: owner)
        XCTAssertNil(c.player)
        XCTAssertNil(c.activeOwner)
    }

    func testTheEndReturnsToTheImage() async throws {
        let c = try controller()
        c.screenAppeared(owner: UUID(), item: try movie(), serverID: nil)
        await c.waitForStartForTest()
        c.finishForTest()
        XCTAssertFalse(c.isVisible)
        for _ in 0..<5 { await Task.yield() }
        XCTAssertNil(c.player)
    }

    func testATrailerlessTitleIsOnlyLookedUpOnce() async throws {
        trailers = ["m1": nil]
        let c = try controller()
        let first = UUID()
        c.screenAppeared(owner: first, item: try movie(), serverID: nil)
        await c.waitForStartForTest()
        c.screenDismissed(owner: first)
        c.screenAppeared(owner: UUID(), item: try movie(), serverID: nil)
        await c.waitForStartForTest()
        XCTAssertEqual(resolved, ["m1"])
    }
}

/// Captures every request the client makes, with its method, query and body.
private final class RecordingServer: URLProtocol {
    struct Seen { let method: String; let url: URL; let body: Data? }
    nonisolated(unsafe) static var seen: [Seen] = []
    nonisolated(unsafe) static var routes: [String: (Int, String)] = [:]
    private static let lock = NSLock()

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url ?? URL(fileURLWithPath: "/")
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            stream.close()
            body = data
        }
        let (status, text) = Self.lock.withLock {
            Self.seen.append(Seen(method: request.httpMethod ?? "GET", url: url, body: body))
            return Self.routes[url.path] ?? (404, "")
        }
        if let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]) {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        }
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class HeroTrailerClientTests: XCTestCase {
    override func setUp() {
        super.setUp()
        RecordingServer.seen = []
        RecordingServer.routes = [:]
        JellyfinClient.testURLProtocolClasses = [RecordingServer.self]
    }

    override func tearDown() {
        JellyfinClient.testURLProtocolClasses = []
        super.tearDown()
    }

    private func client() throws -> JellyfinClient {
        JellyfinClient(serverURL: try XCTUnwrap(URL(string: "http://stub.local")), accessToken: "token", userId: "u1")
    }

    func testTheTrailerStreamIsAForcedSmallTranscode() async throws {
        RecordingServer.routes["/Items/t1/PlaybackInfo"] = (200, #"""
        {"MediaSources":[{"Id":"t1","TranscodingUrl":"/videos/t1/master.m3u8?MediaSourceId=t1"}],"PlaySessionId":"ps9"}
        """#)

        let stream = await (try client()).heroTrailerStream(trailerId: "t1")

        XCTAssertEqual(stream?.playSessionId, "ps9")
        XCTAssertEqual(stream?.url.path, "/videos/t1/master.m3u8")
        let post = try XCTUnwrap(RecordingServer.seen.first { $0.url.path == "/Items/t1/PlaybackInfo" })
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(post.body)) as? [String: Any])
        XCTAssertEqual(body["EnableDirectPlay"] as? Bool, false, "MKV/VP9 trailers can't direct play")
        XCTAssertEqual(body["AllowVideoStreamCopy"] as? Bool, false, "VP9 must be re-encoded for AVPlayer")
        XCTAssertEqual(body["MaxStreamingBitrate"] as? Int, HeroTrailerStream.maxBitrate)
    }

    func testNoStreamWhenTheServerOffersNoTranscode() async throws {
        RecordingServer.routes["/Items/t1/PlaybackInfo"] = (200, #"{"MediaSources":[{"Id":"t1"}],"PlaySessionId":"ps9"}"#)
        let stream = await (try client()).heroTrailerStream(trailerId: "t1")
        XCTAssertNil(stream)
    }

    func testStoppingTheEncodingDeletesThatSession() async throws {
        RecordingServer.routes["/Videos/ActiveEncodings"] = (204, "")
        try await (try client()).stopActiveEncoding(playSessionId: "ps9")
        let call = try XCTUnwrap(RecordingServer.seen.first)
        XCTAssertEqual(call.method, "DELETE")
        XCTAssertEqual(call.url.path, "/Videos/ActiveEncodings")
        let query = URLComponents(url: call.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(query.first { $0.name == "playSessionId" }?.value, "ps9")
    }
}

/// The hero trailer stays silent under a theme by reading this flag.
@MainActor
final class ThemeSongIsPlayingTests: XCTestCase {
    func testIsPlayingFollowsTheThemesLifetime() throws {
        let player = ThemeSongPlayer(timings: ThemeSongTimings(
            startDelay: 0, volume: 0.6, fadeIn: 0, fadeOutEnding: 0, fadeOutShowChange: 0, fadeOutHard: 0
        ))
        XCTAssertFalse(player.isPlaying)
        player.playForTest(url: try XCTUnwrap(URL(string: "http://stub.local/theme.mp3")))
        XCTAssertTrue(player.isPlaying)
        player.stopForPlayback()
        XCTAssertFalse(player.isPlaying)
    }
}

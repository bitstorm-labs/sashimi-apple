import AVFoundation
import SwiftUI
import XCTest
@testable import Sashimi

/// Answers the player's requests after a short delay, like a real server.
private final class SlowStubServer: URLProtocol {
    nonisolated(unsafe) static var routes: [String: (Int, String)] = [:]
    nonisolated(unsafe) static var delay: TimeInterval = 0.15
    private static let lock = NSLock()

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        let (status, body) = Self.lock.withLock { Self.routes[path] ?? (404, "") }
        let url = request.url ?? URL(fileURLWithPath: "/")
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.delay) { [weak self] in
            guard let self else { return }
            if let response = HTTPURLResponse(
                url: url, statusCode: status, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            ) {
                self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            }
            self.client?.urlProtocol(self, didLoad: Data(body.utf8))
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

@MainActor
final class PlayerScreenTransitionTests: XCTestCase {
    private let user = "u1"

    override func setUp() {
        super.setUp()
        SlowStubServer.routes = [:]
        JellyfinClient.testURLProtocolClasses = [SlowStubServer.self]
    }

    override func tearDown() {
        JellyfinClient.testURLProtocolClasses = []
        super.tearDown()
    }

    private func episodeJSON(_ id: String, index: Int) -> String {
        "{\"Id\":\"\(id)\",\"Name\":\"\(id)\",\"Type\":\"Episode\",\"SeriesId\":\"series\","
            + "\"SeasonId\":\"season-1\",\"ParentId\":\"season-1\",\"IndexNumber\":\(index),\"ParentIndexNumber\":1}"
    }

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    private func phase(_ viewModel: PlayerViewModel) -> PlayerScreenPhase {
        PlayerScreenPhase.resolve(
            isLoading: viewModel.isLoading,
            hasError: viewModel.error != nil || viewModel.errorMessage != nil,
            hasEpisodeUpNext: viewModel.episodeUpNext != nil,
            hasPlayer: viewModel.player != nil
        )
    }

    /// Up Next → Play runs the real `loadMedia` against a server that takes a
    /// moment to answer (the transcode DELETE, the item, PlaybackInfo). The
    /// state is sampled every 2 ms on the main actor, which is when SwiftUI
    /// can draw a frame.
    ///
    /// The tvOS player used to draw nothing — a black screen between the Up
    /// Next screen and the spinner — for the whole of the transcode DELETE,
    /// because `loadMedia` dropped the player and only set `isLoading` after
    /// that request came back.
    func testStartingTheNextEpisodeFromUpNextNeverLeavesTheScreenEmpty() async throws {
        SlowStubServer.routes["/Users/\(user)/Items/e2"] = (200, episodeJSON("e2", index: 2))
        SlowStubServer.routes["/Items/e2/PlaybackInfo"] = (200,
            "{\"MediaSources\":[{\"Id\":\"e2\",\"Container\":\"mp4\",\"SupportsDirectPlay\":true}],\"PlaySessionId\":\"ps2\"}")
        SlowStubServer.routes["/Videos/ActiveEncodings"] = (204, "")
        // Nothing listens on port 9: AVPlayer's own requests fail at once.
        let client = JellyfinClient(
            serverURL: try XCTUnwrap(URL(string: "http://127.0.0.1:9")),
            accessToken: "token",
            userId: user
        )
        let viewModel = PlayerViewModel(client: client, reporter: NullReporter())
        let finished = try decode(BaseItemDto.self, episodeJSON("e1", index: 1))
        let next = try decode(BaseItemDto.self, episodeJSON("e2", index: 2))
        // Mid-session state of a transcoded episode that has just ended.
        viewModel.currentItem = finished
        viewModel.player = AVPlayer()
        viewModel.isLoading = false
        viewModel.playSessionId = "ps1"
        viewModel.currentMediaSource = try decode(MediaSourceInfo.self, "{\"Id\":\"e1\",\"TranscodingUrl\":\"/videos/e1/master.m3u8\"}")
        guard case .showUpNext(let upNext) = EpisodeUpNext.decide(EpisodeUpNext.Context(
            finishedItem: finished,
            lookupStatus: .available,
            nextEpisode: next,
            autoPlayNextEpisode: true,
            isOffline: false,
            isPictureInPicture: false,
            now: Date()
        )) else { return XCTFail("expected the Up Next screen") }
        viewModel.presentEpisodeUpNext(upNext)

        var emptyFrames = 0
        var phases: [PlayerScreenPhase] = [phase(viewModel)]
        let sampler = Timer.scheduledTimer(withTimeInterval: 0.002, repeats: true) { _ in
            MainActor.assumeIsolated {
                // Nothing to show: no player, no Up Next, no error, not loading.
                if viewModel.player == nil, !viewModel.isLoading, viewModel.episodeUpNext == nil,
                   viewModel.error == nil, viewModel.errorMessage == nil {
                    emptyFrames += 1
                }
                let current = self.phase(viewModel)
                if phases.last != current { phases.append(current) }
            }
        }
        await viewModel.playUpNextEpisode()
        sampler.invalidate()

        XCTAssertEqual(emptyFrames, 0, "the player had nothing to show while the next episode loaded")
        XCTAssertEqual(Array(phases.prefix(3)), [.upNext, .loading, .playing])
        XCTAssertEqual(viewModel.currentItem?.id, "e2")
    }

    /// The real AVKit controller inside the real `TVPlayerView`: the cover
    /// lifts on `isReadyForDisplay`, so that report has to arrive — if it did
    /// not, every start would sit under the spinner until the fallback.
    func testThePlayerReportsItsFirstFrame() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "hero-trailer-2s", withExtension: "mp4"))
        let player = AVPlayer(url: url)
        player.isMuted = true
        let viewModel = PlayerViewModel(reporter: NullReporter())
        viewModel.player = player
        viewModel.isLoading = false
        let ready = expectation(description: "first frame")
        var reports: [Bool] = []
        let view = TVPlayerView(
            player: player,
            viewModel: viewModel,
            item: try decode(BaseItemDto.self, episodeJSON("e1", index: 1)),
            onDismiss: {},
            onReadyForDisplay: { isReady in
                reports.append(isReady)
                if isReady { ready.fulfill() }
            }
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        window.rootViewController = UIHostingController(rootView: view)
        window.makeKeyAndVisible()
        player.play()

        await fulfillment(of: [ready], timeout: 10)
        XCTAssertEqual(reports.first, false, "not ready before a frame")
        player.pause()
        window.isHidden = true
    }

    func testNoPlayerAndNothingElseIsStillLoading() {
        XCTAssertEqual(
            PlayerScreenPhase.resolve(isLoading: false, hasError: false, hasEpisodeUpNext: false, hasPlayer: false),
            .loading
        )
    }

    func testPhasePrecedence() {
        XCTAssertEqual(PlayerScreenPhase.resolve(isLoading: true, hasError: true, hasEpisodeUpNext: true, hasPlayer: true), .loading)
        XCTAssertEqual(PlayerScreenPhase.resolve(isLoading: false, hasError: true, hasEpisodeUpNext: true, hasPlayer: true), .error)
        XCTAssertEqual(PlayerScreenPhase.resolve(isLoading: false, hasError: false, hasEpisodeUpNext: true, hasPlayer: true), .upNext)
        XCTAssertEqual(PlayerScreenPhase.resolve(isLoading: false, hasError: false, hasEpisodeUpNext: false, hasPlayer: true), .playing)
    }

    /// The spinner stays until the new player's first frame, so it never
    /// hands over to a black AVKit screen first.
    func testLoadingCoversANewPlayerUntilItsFirstFrame() {
        XCTAssertTrue(PlayerScreenPhase.coversPlayer(phase: .playing, isReadyForDisplay: false, gaveUp: false))
        XCTAssertFalse(PlayerScreenPhase.coversPlayer(phase: .playing, isReadyForDisplay: true, gaveUp: false))
        XCTAssertFalse(PlayerScreenPhase.coversPlayer(phase: .playing, isReadyForDisplay: false, gaveUp: true),
                       "a stream with no picture is not covered for good")
        XCTAssertFalse(PlayerScreenPhase.coversPlayer(phase: .upNext, isReadyForDisplay: false, gaveUp: false))
        XCTAssertFalse(PlayerScreenPhase.coversPlayer(phase: .error, isReadyForDisplay: false, gaveUp: false))
    }
}

@MainActor
private final class NullReporter: PlayerPlaybackReporting {
    func reset() {}
    func prepareStopped(itemID: String, positionTicks: Int64, playSessionID: String?) {}
    func start(itemID: String, positionTicks: Int64, playSessionID: String?, playMethod: String) async {}
    func progress(itemID: String, positionTicks: Int64, isPaused: Bool, playSessionID: String?) async {}
    func stopped(itemID: String, positionTicks: Int64, playSessionID: String?) async {}
    func completed(itemID: String, positionTicks: Int64, playSessionID: String?) async {}
}

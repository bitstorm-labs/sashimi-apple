import AVFoundation
import Network
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

    private static func phase(_ viewModel: PlayerViewModel) -> PlayerScreenPhase {
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
        // AVPlayer fetches the stream itself, past the URLProtocol stub, so
        // the server it is pointed at has to really answer with media. This
        // used to be a dead port: the stream then failed while `loadMedia`
        // was still awaiting the asset's tracks, and whether that failure
        // landed before or after `isLoading` cleared was a coin toss — the
        // phases read [upNext, loading, error] about half the time.
        let media = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "hero-trailer-2s", withExtension: "mp4"))
        let streamServer = try await LocalMediaServer.start(serving: Data(contentsOf: media))
        defer { streamServer.stop() }
        let client = JellyfinClient(
            serverURL: try XCTUnwrap(URL(string: "http://127.0.0.1:\(streamServer.port)")),
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
        var phases: [PlayerScreenPhase] = [Self.phase(viewModel)]
        let sampler = Timer.scheduledTimer(withTimeInterval: 0.002, repeats: true) { _ in
            MainActor.assumeIsolated {
                // Nothing to show: no player, no Up Next, no error, not loading.
                if viewModel.player == nil, !viewModel.isLoading, viewModel.episodeUpNext == nil,
                   viewModel.error == nil, viewModel.errorMessage == nil {
                    emptyFrames += 1
                }
                let current = Self.phase(viewModel)
                if phases.last != current { phases.append(current) }
            }
        }
        await viewModel.playUpNextEpisode()
        sampler.invalidate()

        XCTAssertEqual(emptyFrames, 0, "the player had nothing to show while the next episode loaded")
        XCTAssertEqual(Array(phases.prefix(3)), [.upNext, .loading, .playing])
        XCTAssertEqual(viewModel.currentItem?.id, "e2")
        XCTAssertNil(viewModel.errorMessage, "the next episode's stream is playable")
        XCTAssertGreaterThan(streamServer.requestCount, 0, "AVPlayer fetched the stream from the local server")
        viewModel.player?.pause()
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

/// A localhost HTTP server for one media file, with the byte-range support
/// AVFoundation needs to play an mp4 over HTTP.
private final class LocalMediaServer: @unchecked Sendable {
    private let listener: NWListener
    private let body: Data
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var requests = 0
    let port: UInt16

    var requestCount: Int { lock.withLock { requests } }

    private init(listener: NWListener, body: Data, queue: DispatchQueue, port: UInt16) {
        self.listener = listener
        self.body = body
        self.queue = queue
        self.port = port
    }

    static func start(serving body: Data) async throws -> LocalMediaServer {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let queue = DispatchQueue(label: "LocalMediaServer")
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let once = NSLock()
            nonisolated(unsafe) var resumed = false
            listener.stateUpdateHandler = { state in
                once.lock(); defer { once.unlock() }
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    continuation.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error):
                    resumed = true
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.newConnectionHandler = { $0.cancel() }
            listener.start(queue: queue)
        }
        let server = LocalMediaServer(listener: listener, body: body, queue: queue, port: port)
        listener.newConnectionHandler = { [server] connection in
            connection.start(queue: queue)
            server.readRequest(on: connection, buffered: Data())
        }
        return server
    }

    func stop() { listener.cancel() }

    private func readRequest(on connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [self] data, _, isComplete, error in
            var request = buffered
            if let data { request.append(data) }
            guard let end = request.range(of: Data("\r\n\r\n".utf8)) else {
                if isComplete || error != nil {
                    connection.cancel()
                } else {
                    readRequest(on: connection, buffered: request)
                }
                return
            }
            let head = String(data: request[..<end.lowerBound], encoding: .utf8) ?? ""
            lock.withLock { requests += 1 }
            respond(to: head, on: connection)
        }
    }

    private func respond(to head: String, on connection: NWConnection) {
        let lines = head.components(separatedBy: "\r\n")
        let isHead = lines.first?.hasPrefix("HEAD ") ?? false
        let rangeSpec = lines.lazy
            .first { $0.lowercased().hasPrefix("range:") }
            .map { $0.dropFirst("range:".count).trimmingCharacters(in: .whitespaces) }
        var status = "200 OK"
        var slice = 0..<body.count
        var extra = ""
        if let spec = rangeSpec, spec.hasPrefix("bytes=") {
            let bounds = spec.dropFirst("bytes=".count).split(separator: "-", omittingEmptySubsequences: false)
            let start = Int(bounds.first ?? "") ?? 0
            let last = min(Int(bounds.dropFirst().first ?? "") ?? body.count - 1, body.count - 1)
            if start <= last {
                slice = start..<(last + 1)
                status = "206 Partial Content"
                extra = "Content-Range: bytes \(start)-\(last)/\(body.count)\r\n"
            }
        }
        let header = "HTTP/1.1 \(status)\r\nContent-Type: video/mp4\r\nAccept-Ranges: bytes\r\n"
            + extra + "Content-Length: \(slice.count)\r\nConnection: close\r\n\r\n"
        let payload = Data(header.utf8) + (isHead ? Data() : body.subdata(in: slice))
        connection.send(content: payload, completion: .contentProcessed { _ in connection.cancel() })
    }
}

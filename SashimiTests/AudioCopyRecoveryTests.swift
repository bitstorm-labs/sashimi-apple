import XCTest
@testable import Sashimi

/// #806: Snake Eyes (h264 + EAC3 in MKV) stayed black at 0:00 on every
/// Apple platform. Its EAC3 track starts 11 s after the video, so the first
/// HLS segment holds no audio packet; ffmpeg writes the fMP4 init before it
/// has parsed any EAC3 ("Cannot write moov atom before EAC3 packets
/// parsed"), and the init comes out truncated. AVPlayer fails it at once
/// (CoreMediaErrorDomain -16172). Copying the video or re-encoding it makes
/// no difference: only re-encoding the AUDIO produces a valid init. Recovery
/// escalated only the video copy, so it never reached a playable stream, and
/// a quality switch afterwards copied the audio again.
final class AudioCopyRecoveryTests: XCTestCase {
    private typealias Plan = PlaybackRecoveryPlan

    // MARK: - Escalation policy

    func testTheFirstRebuildStillCopiesBothStreams() {
        XCTAssertEqual(
            Plan.decide(isStall: false, rebuildAttempts: 0, currentBitrate: 20_000_000, throughput: nil),
            .rebuild(allowVideoStreamCopy: true, allowAudioStreamCopy: true)
        )
    }

    func testTheLastResortRebuildReencodesTheAudioToo() {
        XCTAssertEqual(
            Plan.decide(isStall: false, rebuildAttempts: 1, currentBitrate: 20_000_000, throughput: nil),
            .rebuild(allowVideoStreamCopy: false, allowAudioStreamCopy: false)
        )
    }

    // MARK: - Request body

    func testTheBodyCarriesTheAudioCopyFlag() {
        let tracks = StreamTrackRequest(mediaSourceId: "item-1")
        let allowed = JellyfinClient.playbackInfoBody(
            userId: "user", streamingBitrate: 20_000_000, deviceProfile: [:], tracks: tracks
        )
        XCTAssertEqual(allowed["AllowAudioStreamCopy"] as? Bool, true, "copy stays the default (keeps EAC3/Atmos)")

        let disallowed = JellyfinClient.playbackInfoBody(
            userId: "user", streamingBitrate: 20_000_000, deviceProfile: [:],
            allowAudioStreamCopy: false, tracks: tracks
        )
        XCTAssertEqual(disallowed["AllowAudioStreamCopy"] as? Bool, false)
    }

    // MARK: - Through the view model

    @MainActor
    func testRecoveryReachesAnAudioReencodeAndAQualitySwitchKeepsIt() async throws {
        AudioCopyStubServer.reset()
        JellyfinClient.testURLProtocolClasses = [AudioCopyStubServer.self]
        defer { JellyfinClient.testURLProtocolClasses = [] }
        AudioCopyStubServer.routes["/Items/movie-1/PlaybackInfo"] = (200, #"""
        {"MediaSources":[{"Id":"movie-1","Container":"mkv","SupportsDirectPlay":false,"TranscodingUrl":"/videos/movie-1/master.m3u8?MediaSourceId=movie-1"}],"PlaySessionId":"ps1"}
        """#)

        let client = JellyfinClient(
            serverURL: try XCTUnwrap(URL(string: "http://stub.local")),
            accessToken: "token",
            userId: "u1"
        )
        let viewModel = PlayerViewModel(client: client)
        let item = Self.movie(id: "movie-1")
        viewModel.currentItem = item
        // An explicit tier, so setup does not wait on a bandwidth probe.
        viewModel.selectedQuality = .quality1080p

        // Two item failures: the start that never played, then its rebuild.
        for _ in 0..<2 {
            await viewModel.attemptPlaybackRecovery(reason: "item-failed", itemID: item.id, attempt: viewModel.playbackAttempt)
        }
        let recoveryBodies = try AudioCopyStubServer.playbackInfoBodies(itemID: item.id)
        XCTAssertEqual(recoveryBodies.count, 2)
        XCTAssertEqual(recoveryBodies.map { $0["AllowVideoStreamCopy"] as? Bool }, [true, false])
        XCTAssertEqual(
            recoveryBodies.map { $0["AllowAudioStreamCopy"] as? Bool }, [true, false],
            "the last-resort rebuild must re-encode the audio, or a broken EAC3 init is never escaped"
        )

        // The viewer then picks a quality: the stream that works must not be
        // traded back for the copied audio that did not.
        AudioCopyStubServer.clearSeen()
        await viewModel.changeQuality(.quality720p)
        let switchBody = try XCTUnwrap(try AudioCopyStubServer.playbackInfoBodies(itemID: item.id).first)
        XCTAssertEqual(switchBody["AllowAudioStreamCopy"] as? Bool, false)
    }

    @MainActor
    func testANewItemStartsWithAudioCopyAllowedAgain() {
        let viewModel = PlayerViewModel(client: JellyfinClient())
        viewModel.audioStreamCopyAllowed = false
        viewModel.resetRecoveryState()
        XCTAssertTrue(viewModel.audioStreamCopyAllowed)
    }

    // MARK: - Helpers

    static func movie(id: String) -> BaseItemDto {
        BaseItemDto(
            id: id, name: "Snake Eyes", type: .movie,
            seriesName: nil, seriesId: nil, seasonId: nil, parentId: nil,
            indexNumber: nil, parentIndexNumber: nil, overview: nil,
            runTimeTicks: nil, userData: nil, imageTags: nil,
            backdropImageTags: nil, parentBackdropImageTags: nil,
            primaryImageAspectRatio: nil, mediaType: nil, libraryName: nil, productionYear: nil,
            communityRating: nil, officialRating: nil, genres: nil,
            taglines: nil, people: nil, criticRating: nil,
            premiereDate: nil, chapters: nil, path: nil, remoteTrailers: nil, localTrailerCount: nil, mediaStreams: nil
        )
    }
}

/// Records every request and its body; answers from `routes`, 404 otherwise.
private final class AudioCopyStubServer: URLProtocol {
    struct Seen { let method: String; let url: URL; let body: Data? }
    nonisolated(unsafe) static var seen: [Seen] = []
    nonisolated(unsafe) static var routes: [String: (Int, String)] = [:]
    private static let lock = NSLock()

    static func reset() {
        lock.withLock {
            seen = []
            routes = [:]
        }
    }

    static func clearSeen() {
        lock.withLock { seen = [] }
    }

    static func playbackInfoBodies(itemID: String) throws -> [[String: Any]] {
        let posts = lock.withLock { seen.filter { $0.url.path == "/Items/\(itemID)/PlaybackInfo" } }
        return try posts.map { post in
            try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(post.body)) as? [String: Any])
        }
    }

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

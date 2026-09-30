import AVFoundation
import Network
import XCTest
@testable import Sashimi

/// The rewritten master (#449) reaches AVPlayer through a private URL scheme
/// answered from memory. These tests check the asset URL leaks nothing, the
/// byte slicing honours AVFoundation's data requests, and — end to end —
/// that AVFoundation actually reads the served master through the loader.
final class HLSPlaylistResourceLoaderTests: XCTestCase {
    private func playlist(host: String = "127.0.0.1:9") -> String {
        """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=15730824,AVERAGE-BANDWIDTH=15730824,VIDEO-RANGE=PQ,CODECS="hvc1.2.4.L150.B0,ec-3",RESOLUTION=3840x2160,FRAME-RATE=23.976
        http://\(host)/videos/abc/main.m3u8?VideoCodec=hevc,h264&ApiKey=REDACTED
        #EXT-X-IMAGE-STREAM-INF:BANDWIDTH=6794,RESOLUTION=320x180,CODECS="jpeg",URI="http://\(host)/videos/abc/Trickplay/320/tiles.m3u8?ApiKey=REDACTED"

        """
    }

    func testAssetURLUsesThePrivateSchemeAndCarriesNoQuery() throws {
        let loader = try XCTUnwrap(HLSPlaylistResourceLoader(playlist: playlist()))
        XCTAssertEqual(loader.assetURL.scheme, HLSPlaylistResourceLoader.scheme)
        XCTAssertNil(loader.assetURL.query)
        XCTAssertEqual(loader.assetURL.pathExtension, "m3u8")
        XCTAssertNotEqual(loader.assetURL, HLSPlaylistResourceLoader(playlist: playlist())?.assetURL)
    }

    func testSliceHonoursOffsetAndLength() {
        let data = Data("0123456789".utf8)
        XCTAssertEqual(HLSPlaylistResourceLoader.slice(of: data, offset: 0, length: nil), data)
        XCTAssertEqual(HLSPlaylistResourceLoader.slice(of: data, offset: 2, length: 3), Data("234".utf8))
        XCTAssertEqual(HLSPlaylistResourceLoader.slice(of: data, offset: 8, length: 100), Data("89".utf8))
        XCTAssertEqual(HLSPlaylistResourceLoader.slice(of: data, offset: 50, length: 2), Data())
    }

    /// End to end: AVFoundation reads the master through the loader and then
    /// fetches the (absolute) media playlist over plain HTTP from the server,
    /// which is what makes the private scheme safe to use for playback.
    func testAVFoundationReadsTheServedPlaylistAndFetchesTheVariantOverHTTP() async throws {
        let server = try await LocalPlaylistServer.start(body: """
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-TARGETDURATION:6
        #EXT-X-PLAYLIST-TYPE:VOD
        #EXT-X-MEDIA-SEQUENCE:0
        #EXTINF:6.0,
        seg0.mp4
        #EXT-X-ENDLIST

        """)
        defer { server.stop() }
        let loader = try XCTUnwrap(HLSPlaylistResourceLoader(playlist: playlist(host: "127.0.0.1:\(server.port)")))
        let asset = loader.makeAsset()

        let variants = try await asset.load(.variants)

        XCTAssertEqual(variants.count, 1)
        XCTAssertEqual(variants.first?.videoAttributes?.videoRange, .pq)
        XCTAssertEqual(variants.first?.peakBitRate, 15_730_824)
        XCTAssertTrue(server.requestedPaths.contains("/videos/abc/main.m3u8"), "\(server.requestedPaths)")
    }

    func testOnlyTVOSSwapsInTheLoader() {
        XCTAssertNil(PlayerViewModel.pinnedPlaylistLoader(for: nil))
        #if os(tvOS)
        XCTAssertNotNil(PlayerViewModel.pinnedPlaylistLoader(for: playlist()))
        #else
        XCTAssertNil(PlayerViewModel.pinnedPlaylistLoader(for: playlist()))
        #endif
    }
}

/// A one-response HTTP server on localhost, enough for AVFoundation to fetch
/// a media playlist from.
private final class LocalPlaylistServer: @unchecked Sendable {
    private let listener: NWListener
    private let body: Data
    private let lock = NSLock()
    private var paths: [String] = []
    let port: UInt16

    var requestedPaths: [String] {
        lock.lock(); defer { lock.unlock() }
        return paths
    }

    private init(listener: NWListener, body: String, port: UInt16) {
        self.listener = listener
        self.body = Data(body.utf8)
        self.port = port
    }

    static func start(body: String) async throws -> LocalPlaylistServer {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let queue = DispatchQueue(label: "LocalPlaylistServer")
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            listener.stateUpdateHandler = { state in
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
            listener.newConnectionHandler = { _ in }
            listener.start(queue: queue)
        }
        let server = LocalPlaylistServer(listener: listener, body: body, port: port)
        listener.newConnectionHandler = { [server] connection in server.serve(connection, on: queue) }
        return server
    }

    func stop() { listener.cancel() }

    private func serve(_ connection: NWConnection, on queue: DispatchQueue) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [self] data, _, _, _ in
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let target = request.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            let path = target.split(separator: "?").first.map(String.init) ?? target
            lock.lock(); paths.append(path); lock.unlock()
            let header = """
            HTTP/1.1 200 OK\r
            Content-Type: application/vnd.apple.mpegurl\r
            Content-Length: \(body.count)\r
            Connection: close\r
            \r

            """
            connection.send(content: Data(header.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}

import XCTest
@testable import SashimiMobile

/// Download posters/backdrops/subtitles go through the app's trust policy and
/// never save an error page (#604).
final class DownloadAssetFetcherTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DownloadAssetFetcherTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        StubAssetProtocol.response = nil
    }

    private func stubbedFetcher() -> DownloadAssetFetcher {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubAssetProtocol.self]
        return DownloadAssetFetcher(session: URLSession(configuration: configuration))
    }

    private let request = URLRequest(url: URL(string: "https://jellyfin.example.test/Items/abc/Images/Backdrop")!)

    func testLiveFetcherUsesTheAppCertificateTrustPolicy() async {
        // URLSession.shared has no delegate: a self-signed or pinned server's
        // challenge never reached CertificateValidationDelegate, so every
        // poster/backdrop/subtitle of a download failed there.
        let fetcher = await DownloadAssetFetcher.live()
        let appDelegate = await JellyfinClient.shared.certificateDelegate
        XCTAssertNotIdentical(fetcher.session, URLSession.shared)
        XCTAssertIdentical(fetcher.session.delegate, appDelegate)
    }

    func testSuccessfulResponseIsSaved() async throws {
        StubAssetProtocol.response = (200, Data("JPEGDATA".utf8))
        let destination = directory.appendingPathComponent("backdrop.jpg")

        try await stubbedFetcher().fetch(request, to: destination)

        XCTAssertEqual(try Data(contentsOf: destination), Data("JPEGDATA".utf8))
    }

    func testErrorPageIsNotSavedAsTheImage() async {
        // A proxy's HTML 404 for a missing backdrop used to land on disk as
        // backdrop.jpg.
        StubAssetProtocol.response = (404, Data("<html>Not Found</html>".utf8))
        let destination = directory.appendingPathComponent("backdrop.jpg")

        do {
            try await stubbedFetcher().fetch(request, to: destination)
            XCTFail("a 404 must throw")
        } catch {
            XCTAssertEqual(error as? DownloadAssetFetcher.FetchError, .badStatus(404))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testLogDescriptionNeverCarriesTheURL() {
        let error = URLError(.serverCertificateUntrusted, userInfo: [
            NSURLErrorFailingURLStringErrorKey: "https://jellyfin.example.test/Items/abc"
        ])
        let text = DownloadAssetFetcher.logDescription(of: error)
        XCTAssertFalse(text.contains("example.test"))
        XCTAssertEqual(text, "URLError \(URLError.Code.serverCertificateUntrusted.rawValue)")
    }
}

/// Serves one canned response for every request.
private final class StubAssetProtocol: URLProtocol {
    nonisolated(unsafe) static var response: (status: Int, body: Data)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let (status, body) = Self.response,
              let http = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

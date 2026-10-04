import Foundation

/// Fetches a download's side assets (poster, backdrop, subtitle files) to disk.
///
/// These used to go through `URLSession.shared`, which never sees the app's
/// `CertificateValidationDelegate`: on a self-signed or pinned server the video
/// downloaded (the background session has its own trust handling) while every
/// poster, backdrop and subtitle failed, with the error swallowed. The live
/// fetcher shares `JellyfinClient`'s session, so one trust policy covers the
/// API, artwork and downloads alike.
///
/// It also refuses a non-2xx answer: a proxy's HTML 404 for a missing backdrop
/// used to be saved as `backdrop.jpg`.
struct DownloadAssetFetcher: Sendable {
    enum FetchError: Error, Equatable {
        case badStatus(Int)
    }

    let session: URLSession

    /// The app's trust-aware session (the same one the API client uses).
    static func live() async -> DownloadAssetFetcher {
        DownloadAssetFetcher(session: await JellyfinClient.shared.urlSession)
    }

    /// Downloads `request` and moves the body to `destination`. Throws on a
    /// transport failure or a non-2xx status; nothing is written then.
    func fetch(_ request: URLRequest, to destination: URL) async throws {
        let (tempURL, response) = try await session.download(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: tempURL)
            throw FetchError.badStatus(http.statusCode)
        }
        try DownloadFileManager.moveFile(from: tempURL, to: destination)
    }

    /// A log-safe description: a URLError's description carries the request
    /// URL (the server address), so only its code is logged.
    static func logDescription(of error: Error) -> String {
        if let urlError = error as? URLError { return "URLError \(urlError.code.rawValue)" }
        if let fetchError = error as? FetchError, case .badStatus(let status) = fetchError { return "HTTP \(status)" }
        return String(describing: type(of: error))
    }
}

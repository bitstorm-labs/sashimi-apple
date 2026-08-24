import Foundation
import Nuke

private let scopedServerRequestHeader = "X-Sashimi-Scoped-Server"

/// Adds the active Jellyfin token to artwork requests without putting it in
/// the URL. Jellyfin protects image endpoints just like its JSON API, while
/// Nuke's default loader only knows about the URL and therefore sent these
/// requests unauthenticated.
private final class JellyfinImageDataLoader: DataLoading, @unchecked Sendable {
    private let loader: DataLoader

    init(configuration: URLSessionConfiguration, delegate: URLSessionDelegate) {
        loader = DataLoader(configuration: configuration)
        loader.delegate = delegate
    }

    func loadData(
        with request: URLRequest,
        didReceiveData: @escaping @Sendable (Data, URLResponse) -> Void,
        completion: @escaping @Sendable (Error?) -> Void
    ) -> any Cancellable {
        var authorizedRequest = request
        let isExplicitlyScoped = authorizedRequest.value(forHTTPHeaderField: scopedServerRequestHeader) == "true"
        if !isExplicitlyScoped,
           authorizedRequest.value(forHTTPHeaderField: "X-Emby-Token") == nil,
           let accessToken = SashimiImagePipeline.accessToken(for: request.url) {
            authorizedRequest.setValue(accessToken, forHTTPHeaderField: "X-Emby-Token")
        }
        authorizedRequest.setValue(nil, forHTTPHeaderField: scopedServerRequestHeader)
        return loader.loadData(
            with: authorizedRequest,
            didReceiveData: didReceiveData,
            completion: completion
        )
    }
}

/// The app's shared Nuke image pipeline.
///
/// Two things this exists to fix, both of which the tvOS target had because it
/// rendered every image through SwiftUI `AsyncImage`:
///
/// 1. **No decoded-image cache.** `AsyncImage` caches nothing, so every time a
///    view was re-instantiated the image was re-downloaded and re-decoded. The
///    codebase churns image identity deliberately (`.id(currentItem.id)`,
///    `.id(refreshID)`, and the fallback-probe ids inside `AsyncItemImage`), so
///    posters visibly re-flashed to placeholders on every scroll-back and every
///    return from a detail screen.
///
/// 2. **It bypassed the certificate trust delegate.** `AsyncImage` uses
///    `URLSession.shared`, which never sees `CertificateValidationDelegate`. On
///    a self-signed server the API worked — rows populated, playback started —
///    while every poster, backdrop, logo and avatar was a permanent grey
///    placeholder with no error shown.
///
/// The pipeline therefore loads through a session carrying the *same* delegate
/// instance as `JellyfinClient`, so there is exactly one trust policy.
enum SashimiImagePipeline {
    static let shared: ImagePipeline = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        configuration.waitsForConnectivity = true
        // Nuke owns caching (memory + its own disk cache), so URLCache would
        // only duplicate bytes on disk.
        configuration.urlCache = nil

        let dataLoader = JellyfinImageDataLoader(
            configuration: configuration,
            delegate: JellyfinClient.shared.certificateDelegate
        )

        return ImagePipeline {
            $0.dataLoader = dataLoader
            $0.dataCache = try? DataCache(name: "com.mondominator.sashimi.images")
            $0.imageCache = ImageCache.shared
            // Artwork is immutable for a given item+tag, and Jellyfin serves it
            // without useful cache headers, so honouring the response would mean
            // re-fetching constantly.
            $0.dataCachePolicy = .storeAll
        }
    }()

    /// Make even plain `LazyImage(url:)` calls use the authenticated loader.
    /// This keeps older mobile and shared views from silently bypassing the
    /// app's certificate and Jellyfin authentication policy.
    static func install() {
        ImagePipeline.shared = shared
    }

    /// Builds an authenticated request for artwork owned by a saved server.
    /// The token stays in the request header and never becomes part of the URL
    /// or Nuke's cache key.
    static func request(url: URL, serverID: String? = nil) -> ImageRequest {
        var urlRequest = URLRequest(url: url)
        if let serverID {
            // An explicitly scoped request must never fall back to the global
            // token if its server credential is missing. The private marker
            // tells the loader to fail closed; it is removed before transport.
            urlRequest.setValue("true", forHTTPHeaderField: scopedServerRequestHeader)
            if let accessToken = KeychainHelper.get(forKey: "accessToken.\(serverID)") {
                urlRequest.setValue(accessToken, forHTTPHeaderField: "X-Emby-Token")
            }
        } else if let accessToken = accessToken(for: url) {
            urlRequest.setValue(accessToken, forHTTPHeaderField: "X-Emby-Token")
        }
        return ImageRequest(urlRequest: urlRequest)
    }

    /// Resolve credentials from the URL's saved server rather than from the
    /// mutable global active-server slot. This keeps plain `LazyImage(url:)`
    /// callers safe while a temporary detail scope points the shared client at
    /// another server.
    fileprivate static func accessToken(for url: URL?) -> String? {
        guard let url else { return KeychainHelper.get(forKey: "accessToken") }
        guard let data = UserDefaults.standard.data(forKey: "servers"),
              let servers = try? JSONDecoder().decode([ServerConfig].self, from: data) else {
            return KeychainHelper.get(forKey: "accessToken")
        }
        let matchingServer = servers
            .filter { savedServer in
                serverURLMatches(savedServer.url, requestURL: url)
            }
            .max { lhs, rhs in
                normalizedPath(lhs.url.path).count < normalizedPath(rhs.url.path).count
            }
        guard let matchingServer else {
            return KeychainHelper.get(forKey: "accessToken")
        }
        // Once the URL identifies a saved server, fail closed if that server's
        // scoped credential is unavailable instead of leaking the global token.
        return KeychainHelper.get(forKey: "accessToken.\(matchingServer.id)")
    }

    private static func serverURLMatches(_ savedURL: URL, requestURL: URL) -> Bool {
        guard savedURL.scheme?.lowercased() == requestURL.scheme?.lowercased(),
              savedURL.host?.lowercased() == requestURL.host?.lowercased(),
              effectivePort(for: savedURL) == effectivePort(for: requestURL) else {
            return false
        }

        let basePath = normalizedPath(savedURL.path)
        let requestPath = normalizedPath(requestURL.path)
        return basePath.isEmpty
            || requestPath == basePath
            || requestPath.hasPrefix("\(basePath)/")
    }

    private static func normalizedPath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return trimmed.isEmpty ? "" : "/\(trimmed)"
    }

    private static func effectivePort(for url: URL) -> Int? {
        if let port = url.port { return port }
        switch url.scheme?.lowercased() {
        case "https": return 443
        case "http": return 80
        default: return nil
        }
    }

    /// Sized for a 4K-capable but memory-constrained Apple TV. The default is a
    /// share of physical RAM, which is generous on a phone and reckless on a box
    /// that also has to hold a decoded 1920-wide backdrop and a video pipeline.
    static func configureCaches() {
        #if os(tvOS)
        ImageCache.shared.costLimit = 96 * 1024 * 1024
        #else
        ImageCache.shared.costLimit = 128 * 1024 * 1024
        #endif
        ImageCache.shared.countLimit = 300
    }
}

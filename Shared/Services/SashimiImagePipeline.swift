import Foundation
import Nuke

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

        let dataLoader = DataLoader(configuration: configuration)
        dataLoader.delegate = JellyfinClient.shared.certificateDelegate

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

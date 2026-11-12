import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// How many pixels to ask the server for when an image is shown `N` points wide.
///
/// Jellyfin's `maxWidth` is in pixels and caps the response (it never upscales
/// past the source), so requesting `points × screen scale` gets a sharp image
/// without over-fetching. A hard-coded pixel width that ignores the scale
/// leaves art soft: a 440pt tvOS card asking for 600px is upscaled ~1.5×.
enum ImageSizing {
    /// Pixels per point: Apple TV 4K renders the 1920pt canvas @2x, iPhone @3x,
    /// iPad @2x. (An HD Apple TV or an @2x iPhone gets a little more than it
    /// needs, which is the cheap direction to be wrong in.)
    @MainActor static var screenScale: CGFloat {
        #if os(tvOS)
        return 2
        #else
        return isPhone ? 3 : 2
        #endif
    }

    @MainActor static var isPhone: Bool {
        #if os(tvOS)
        return false
        #else
        return UIDevice.current.userInterfaceIdiom == .phone
        #endif
    }

    /// `points × scale`, rounded up to a multiple of 40px so near-identical
    /// layouts (a few points apart) share one cache entry.
    static func pixelWidth(points: CGFloat, scale: CGFloat) -> Int {
        let raw = Int((points * scale).rounded(.up))
        let step = 40
        return max(step, ((raw + step - 1) / step) * step)
    }

    /// `pixelWidth(points:scale:)` at this device's `screenScale`.
    @MainActor static func pixelWidth(points: CGFloat) -> Int {
        pixelWidth(points: points, scale: screenScale)
    }

    /// Largest backdrop request: past this a big-screen picture gains nothing
    /// visible and decodes are expensive (2560x1440x4 is about 15 MB).
    static let maxBackdropWidth = 2560

    /// Largest Spotlight backdrop request (detail pages, list pages): a 4K
    /// screen's width. The Spotlight picture covers most of the screen, so it
    /// needs more than `maxBackdropWidth`.
    static let maxSpotlightBackdropWidth = 3840

    /// The display's pixels per point. tvOS reports 1 for 1080p output and 2
    /// for 4K, so a full-screen backdrop asks for what the TV shows; elsewhere
    /// `screenScale`.
    @MainActor static var displayScale: CGFloat {
        #if os(tvOS)
        return max(1, UIScreen.main.scale)
        #else
        return screenScale
        #endif
    }

    /// Pixel width for a backdrop drawn `points` wide, capped at
    /// `maxBackdropWidth`.
    static func backdropPixelWidth(points: CGFloat, scale: CGFloat) -> Int {
        min(pixelWidth(points: points, scale: scale), maxBackdropWidth)
    }

    @MainActor static func backdropPixelWidth(points: CGFloat) -> Int {
        backdropPixelWidth(points: points, scale: screenScale)
    }

    /// Series/movie logo on the mobile detail pages (≤300pt wide on iPad @2x,
    /// a ~70pt-tall full-width slot on iPhone @3x). One constant because
    /// `OfflineShowView` looks the exact same URL up cache-only.
    static let mobileLogoWidth = 1000
}

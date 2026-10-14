import SwiftUI
import UIKit
import XCTest
@testable import Sashimi

/// The tvOS focus ring is the app accent (purple), matching the Roku app.
///
/// Each test hosts one real component alone in a key window so the focus
/// engine gives it focus, then renders the window and counts accent-coloured
/// pixels. A white ring (the old `SashimiTheme.focus`) leaves none.
///
/// Set `TEST_RUNNER_FOCUS_SNAPSHOT_DIR` when running `xcodebuild test` to also
/// write each render there as a PNG.
@MainActor
final class FocusRingColorTests: XCTestCase {
    func testFocusedPosterCardHasAccentRing() async throws {
        let image = try await renderFocused(
            MediaPosterButton(item: Self.movie, onSelect: {}),
            size: CGSize(width: 420, height: 480),
            name: "poster-card"
        )
        XCTAssertGreaterThan(accentPixelCount(in: image), 500)
    }

    func testFocusedDetailButtonHasAccentRing() async throws {
        let image = try await renderFocused(
            ActionButton(title: "Trailer", icon: "film", action: {}),
            size: CGSize(width: 320, height: 140),
            name: "detail-button"
        )
        XCTAssertGreaterThan(accentPixelCount(in: image), 150)
    }

    func testFocusedPrimaryDetailButtonHasAccentRing() async throws {
        let image = try await renderFocused(
            ActionButton(title: "Play", icon: "play.fill", isPrimary: true, action: {}),
            size: CGSize(width: 320, height: 140),
            name: "detail-button-primary"
        )
        XCTAssertGreaterThan(accentPixelCount(in: image), 150)
    }

    func testFocusedSeasonTabHasAccentRing() async throws {
        let image = try await renderFocused(
            SeasonTab(season: Self.season, isSelected: false, action: {}),
            size: CGSize(width: 320, height: 140),
            name: "season-tab"
        )
        XCTAssertGreaterThan(accentPixelCount(in: image), 150)
    }

    func testFocusedGuideChipHasAccentRing() async throws {
        // Focus keeps the white platter so a focused chip still reads apart
        // from the selected (purple-filled) one; the ring carries the accent.
        let image = try await renderFocused(
            GuideChip(label: "Tonight", selected: false, action: {}),
            size: CGSize(width: 320, height: 140),
            name: "guide-chip"
        )
        XCTAssertGreaterThan(accentPixelCount(in: image), 150)
    }

    func testFocusedSettingsRowHasAccentRing() async throws {
        let image = try await renderFocused(
            SettingsOptionRow(icon: "gearshape", title: "Playback", subtitle: "Quality, subtitles", action: {}),
            size: CGSize(width: 760, height: 180),
            name: "settings-row"
        )
        XCTAssertGreaterThan(accentPixelCount(in: image), 500)
    }

    /// The current-episode marker is white and must stay white while focus is
    /// elsewhere, so "where am I" never reads as "what is focused".
    func testCurrentEpisodeMarkerStaysDistinctFromFocus() async throws {
        let image = try await renderFocused(
            HStack(spacing: 60) {
                ActionButton(title: "Play", icon: "play.fill", action: {})
                EpisodeCard(episode: Self.episode, isCurrentEpisode: true, action: {})
            },
            size: CGSize(width: 560, height: 360),
            name: "current-episode-unfocused"
        )
        // The card occupies the right ~45%; start past the button's glow.
        let full = try XCTUnwrap(image.cgImage)
        let episodeSide = try XCTUnwrap(full.cropping(to: CGRect(
            x: full.width * 11 / 20, y: 0, width: full.width * 9 / 20, height: full.height
        )))
        XCTAssertGreaterThan(accentPixelCount(in: image), 150, "the focused button carries the accent ring")
        XCTAssertEqual(accentPixelCount(in: UIImage(cgImage: episodeSide)), 0, "the current-episode marker is not purple")
    }

    // MARK: - Fixtures

    private static let movie = item(id: "movie", name: "Oppenheimer", type: .movie)
    private static let season = item(id: "season", name: "Season 1", type: .season)
    private static let episode = item(id: "episode", name: "Pilot", type: .episode)

    private static func item(id: String, name: String, type: ItemType) -> BaseItemDto {
        BaseItemDto(
            id: id, name: name, type: type,
            seriesName: nil, seriesId: nil, seasonId: nil, parentId: nil,
            indexNumber: nil, parentIndexNumber: nil, overview: nil,
            runTimeTicks: nil, userData: nil, imageTags: nil,
            backdropImageTags: nil, parentBackdropImageTags: nil,
            primaryImageAspectRatio: nil, mediaType: nil, libraryName: nil, productionYear: nil,
            communityRating: nil, officialRating: nil, genres: nil,
            taglines: nil, people: nil, criticRating: nil,
            premiereDate: nil, chapters: nil, path: nil, remoteTrailers: nil,
            localTrailerCount: nil, mediaStreams: nil
        )
    }

    // MARK: - Rendering

    /// Hosts `view` alone in a fresh key window, waits for the focus engine to
    /// focus something inside it and for the focus spring to settle, then
    /// renders the window.
    private func renderFocused<V: View>(_ view: V, size: CGSize, name: String) async throws -> UIImage {
        let host = UIHostingController(
            rootView: view
                .frame(width: size.width, height: size.height)
                .background(SashimiTheme.background)
        )
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
            "The test host has no window scene"
        )
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        var focused = false
        for _ in 0..<100 {
            window.setNeedsFocusUpdate()
            window.updateFocusIfNeeded()
            if isInside(window, UIFocusSystem.focusSystem(for: window)?.focusedItem) {
                focused = true
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        try XCTSkipUnless(focused, "The focus engine never focused the hosted view")
        // Let the focus spring (response 0.3) finish before rendering.
        try await Task.sleep(nanoseconds: 800_000_000)

        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        if let dir = ProcessInfo.processInfo.environment["FOCUS_SNAPSHOT_DIR"], let png = image.pngData() {
            let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name).png")
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try png.write(to: url)
        }
        return image
    }

    /// Whether `item` sits in `window`'s focus-environment chain. SwiftUI's
    /// focused items are responder proxies, not views, so walk the parents.
    private func isInside(_ window: UIWindow, _ item: UIFocusItem?) -> Bool {
        var environment: UIFocusEnvironment? = item
        while let current = environment {
            if let view = current as? UIView, view.isDescendant(of: window) { return true }
            environment = current.parentFocusEnvironment
        }
        return false
    }

    /// Pixels within a small tolerance of `SashimiTheme.accent` (#8C5CC7).
    private func accentPixelCount(in image: UIImage) -> Int {
        guard let cgImage = image.cgImage else { return 0 }
        let width = cgImage.width
        let height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return 0 }

        let target = [140, 92, 199]
        let tolerance = 24
        var count = 0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let red = Int(pixels[index])
            let green = Int(pixels[index + 1])
            let blue = Int(pixels[index + 2])
            if abs(red - target[0]) <= tolerance,
               abs(green - target[1]) <= tolerance,
               abs(blue - target[2]) <= tolerance {
                count += 1
            }
        }
        return count
    }
}

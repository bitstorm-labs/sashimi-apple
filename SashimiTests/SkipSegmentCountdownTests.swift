import AVFoundation
import SwiftUI
import XCTest
@testable import Sashimi

/// The countdown-fill skip pill (#696): what it says and how far its fill has
/// swept for a given playback position.
final class SkipSegmentCountdownTests: XCTestCase {
    func testFractionIsTheShareOfTheSegmentAlreadyPlayed() {
        XCTAssertEqual(SkipSegmentCountdown.fraction(start: 100, end: 140, current: 100), 0)
        XCTAssertEqual(SkipSegmentCountdown.fraction(start: 100, end: 140, current: 116), 0.4, accuracy: 1e-9)
        XCTAssertEqual(SkipSegmentCountdown.fraction(start: 100, end: 140, current: 140), 1)
    }

    func testFractionIsClampedAndSafe() {
        XCTAssertEqual(SkipSegmentCountdown.fraction(start: 100, end: 140, current: 90), 0, "before the segment")
        XCTAssertEqual(SkipSegmentCountdown.fraction(start: 100, end: 140, current: 200), 1, "after the segment")
        XCTAssertEqual(SkipSegmentCountdown.fraction(start: 100, end: 100, current: 100), 0, "zero-length segment")
        XCTAssertEqual(SkipSegmentCountdown.fraction(start: 100, end: 90, current: 95), 0, "inverted segment")
        XCTAssertEqual(SkipSegmentCountdown.fraction(start: 100, end: 140, current: .nan), 0, "player time not yet valid")
    }

    func testRemainingSecondsRoundUp() {
        XCTAssertEqual(SkipSegmentCountdown.secondsRemaining(start: 0, end: 40, current: 16), 24)
        XCTAssertEqual(SkipSegmentCountdown.secondsRemaining(start: 0, end: 40, current: 15.2), 25)
        XCTAssertEqual(SkipSegmentCountdown.secondsRemaining(start: 0, end: 40, current: 39.9), 1)
        XCTAssertEqual(SkipSegmentCountdown.secondsRemaining(start: 0, end: 40, current: 40), 0)
        XCTAssertEqual(SkipSegmentCountdown.secondsRemaining(start: 0, end: 40, current: 55), 0)
        XCTAssertEqual(SkipSegmentCountdown.secondsRemaining(start: 10, end: 40, current: 2), 30,
                       "before the segment the whole segment is left")
        XCTAssertEqual(SkipSegmentCountdown.secondsRemaining(start: 10, end: 40, current: .nan), 30)
    }

    func testRemainingTextIsMinutesAndSeconds() {
        XCTAssertEqual(SkipSegmentCountdown.clockText(seconds: 24), "0:24")
        XCTAssertEqual(SkipSegmentCountdown.clockText(seconds: 5), "0:05")
        XCTAssertEqual(SkipSegmentCountdown.clockText(seconds: 65), "1:05")
        XCTAssertEqual(SkipSegmentCountdown.clockText(seconds: 600), "10:00")
        XCTAssertEqual(SkipSegmentCountdown.clockText(seconds: -3), "0:00")
    }

    func testLabelsMatchTheSegmentType() {
        XCTAssertEqual(SkipSegmentCountdown.label(for: .intro), "Skip Intro")
        XCTAssertEqual(SkipSegmentCountdown.label(for: .outro), "Skip Credits")
        XCTAssertEqual(SkipSegmentCountdown.label(for: .recap), "Skip Recap")
        XCTAssertEqual(SkipSegmentCountdown.label(for: .preview), "Skip Preview")
    }

    func testAccessibilityLabelSpeaksTheTimeLeft() {
        let intro = SkipSegmentCountdown(type: .intro, start: 0, end: 40, current: 16)
        XCTAssertEqual(intro.accessibilityLabel, "Skip Intro, 24 seconds left")
        XCTAssertEqual(SkipSegmentCountdown(type: .outro, start: 0, end: 40, current: 39).accessibilityLabel,
                       "Skip Credits, 1 second left")
        XCTAssertEqual(SkipSegmentCountdown(type: .outro, start: 0, end: 125, current: 0).accessibilityLabel,
                       "Skip Credits, 2 minutes 5 seconds left")
        XCTAssertEqual(SkipSegmentCountdown(type: .intro, start: 0, end: 60, current: 0).accessibilityLabel,
                       "Skip Intro, 1 minute left")
    }

    func testSegmentInitialiserReadsTheSegment() {
        let segment = MediaSegmentDto(id: "s", type: .intro, startSeconds: 100, endSeconds: 140)
        let countdown = SkipSegmentCountdown(segment: segment, current: 116)
        XCTAssertEqual(countdown.fractionElapsed, 0.4, accuracy: 1e-9)
        XCTAssertEqual(countdown.remainingText, "0:24")
        XCTAssertEqual(countdown.label, "Skip Intro")
    }
}

// MARK: - Rendering

/// Renders the pill itself and checks the fill really covers the played share.
@MainActor
final class SkipSegmentPillRenderTests: XCTestCase {
    private func render<V: View>(_ view: V) throws -> CGImage {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        return try XCTUnwrap(renderer.cgImage)
    }

    /// RGBA of one pixel.
    private func pixel(_ image: CGImage, x: Int, y: Int) -> (r: Int, g: Int, b: Int) {
        var data = [UInt8](repeating: 0, count: 4)
        let context = CGContext(
            data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        context?.draw(image, in: CGRect(x: -x, y: y - image.height + 1, width: image.width, height: image.height))
        return (Int(data[0]), Int(data[1]), Int(data[2]))
    }

    func testFillCoversTheElapsedShareOnly() throws {
        let countdown = SkipSegmentCountdown(type: .intro, start: 0, end: 40, current: 16)
        let image = try render(
            SkipSegmentPill(countdown: countdown, accent: SashimiTheme.accent, metrics: .tv)
                .environment(\.skipPillHighlighted, true)
                .padding(40)
                .background(Color.black)
        )
        // Sample the band between the capsule's top edge and the text, at 30%
        // and 50% across the pill (the 40pt padding is on every side).
        let pillWidth = image.width - 80
        let row = 40 + Int(SkipSegmentPillMetrics.tv.verticalPadding / 2)
        let filled = pixel(image, x: 40 + pillWidth * 3 / 10, y: row)
        let unfilled = pixel(image, x: 40 + pillWidth / 2, y: row)
        XCTAssertGreaterThan(filled.b, 150, "40% played: 30% across is purple (\(filled))")
        XCTAssertGreaterThan(filled.r, 100, "purple, not blue (\(filled))")
        XCTAssertLessThan(unfilled.b, 80, "40% played: halfway across is still dark glass (\(unfilled))")
    }

    func testSkipButtonControllerShowsAndClearsThePill() {
        let controller = SkipButtonViewController()
        controller.loadViewIfNeeded()
        let segment = MediaSegmentDto(id: "s", type: .outro, startSeconds: 0, endSeconds: 40)
        controller.update(segment: segment) { 16 }
        XCTAssertEqual(controller.button.accessibilityLabel, "Skip Credits, 24 seconds left")
        controller.update(segment: nil)
        XCTAssertNil(controller.button.model.segment)
        XCTAssertNil(controller.button.accessibilityLabel)
    }
}

// MARK: - Screenshots

/// Writes idle and focused screenshots of the real tvOS skip control, at 40%
/// through the intro, over a dark frame — when `TEST_RUNNER_SKIP_PILL_SNAPSHOT_DIR`
/// is set. Without it the pictures are still rendered and checked for content.
@MainActor
final class SkipSegmentPillSnapshotTests: XCTestCase {
    func testTVSnapshots() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        for focused in [false, true] {
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
            // Mounted the way TVPlayerView mounts it: a full-screen sibling
            // pinned to the container, over the picture.
            let root = UIViewController()
            window.rootViewController = root
            let backdrop = UIHostingController(rootView: SkipPillSnapshotBackdrop())
            root.addChild(backdrop)
            backdrop.view.frame = root.view.bounds
            backdrop.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            root.view.addSubview(backdrop.view)
            backdrop.didMove(toParent: root)
            let skip = SkipButtonViewController()
            root.addChild(skip)
            skip.view.translatesAutoresizingMaskIntoConstraints = false
            root.view.addSubview(skip.view)
            skip.didMove(toParent: root)
            NSLayoutConstraint.activate([
                skip.view.leadingAnchor.constraint(equalTo: root.view.leadingAnchor),
                skip.view.trailingAnchor.constraint(equalTo: root.view.trailingAnchor),
                skip.view.topAnchor.constraint(equalTo: root.view.topAnchor),
                skip.view.bottomAnchor.constraint(equalTo: root.view.bottomAnchor),
            ])
            skip.update(segment: MediaSegmentDto(id: "i", type: .intro, startSeconds: 0, endSeconds: 40)) { 16 }
            window.makeKeyAndVisible()
            RunLoop.main.run(until: Date().addingTimeInterval(0.8))
            // The only focusable view on screen: the engine lands on it, and
            // the button hands that to the pill.
            XCTAssertTrue(skip.button.isFocused, "the focus engine focuses the skip button")
            XCTAssertTrue(skip.button.model.isFocused, "focus reaches the pill")
            // For the idle picture, draw the pill as it looks unfocused.
            skip.button.model.isFocused = focused
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            window.layoutIfNeeded()

            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let frame = skip.button.convert(skip.button.bounds, to: window)
            window.isHidden = true
            XCTAssertGreaterThan(frame.width, 200,
                                 "the pill sizes the button (host wants \(skip.button.host.view.intrinsicContentSize))")
            XCTAssertLessThan(frame.height, 100, "no safe-area padding inside the pill: \(frame)")
            XCTAssertEqual(frame.maxX, 1920 - 80 - root.view.safeAreaInsets.right, accuracy: 1, "bottom-right: \(frame)")
            try save(image, name: focused ? "tvos-focused.png" : "tvos-idle.png")
        }
    }

    private func save(_ image: UIImage, name: String) throws {
        let data = try XCTUnwrap(image.pngData())
        guard let dir = ProcessInfo.processInfo.environment["SKIP_PILL_SNAPSHOT_DIR"] else { return }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
    }
}

/// A dark stand-in for a video frame.
private struct SkipPillSnapshotBackdrop: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.10, green: 0.12, blue: 0.18), Color(red: 0.03, green: 0.03, blue: 0.05)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            Circle()
                .fill(Color(red: 0.55, green: 0.35, blue: 0.20).opacity(0.35))
                .frame(width: 900)
                .blur(radius: 120)
                .offset(x: 420, y: 260)
        }
        .ignoresSafeArea()
    }
}

// MARK: - Real playback

/// The fill follows a real AVPlayer: it advances as the clip plays and jumps
/// with a seek, read through the same `currentTime().seconds` path the apps use.
@MainActor
final class SkipSegmentPlaybackTests: XCTestCase {
    func testFractionAdvancesWithPlaybackAndFollowsSeeks() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "hero-trailer-2s", withExtension: "mp4"))
        let player = AVPlayer(url: url)
        player.isMuted = true
        let segment = MediaSegmentDto(id: "i", type: .intro, startSeconds: 0, endSeconds: 2)
        func countdown() -> SkipSegmentCountdown {
            SkipSegmentCountdown(segment: segment, current: player.currentTime().seconds)
        }

        XCTAssertEqual(countdown().fractionElapsed, 0)
        XCTAssertEqual(countdown().remainingText, "0:02")

        player.play()
        var samples: [Double] = []
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, (samples.last ?? 0) < 0.5 {
            try await Task.sleep(nanoseconds: 150_000_000)
            samples.append(countdown().fractionElapsed)
        }
        XCTAssertGreaterThanOrEqual(samples.last ?? 0, 0.5, "the fill passes halfway as the clip plays: \(samples)")
        XCTAssertEqual(samples, samples.sorted(), "the fill only moves forward during playback")
        XCTAssertEqual(countdown().remainingText, "0:01")

        player.pause()
        await player.seek(to: CMTime(seconds: 0.2, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        XCTAssertEqual(countdown().fractionElapsed, 0.1, accuracy: 0.03, "a seek back moves the fill back")
        XCTAssertEqual(countdown().remainingText, "0:02")
    }
}

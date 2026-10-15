import SwiftUI
import XCTest
@testable import SashimiMobile

/// Idle and pressed screenshots of the iPhone/iPad skip pill at 40% through
/// the intro, over a dark frame. Written to `TEST_RUNNER_SKIP_PILL_SNAPSHOT_DIR`
/// when it is set; otherwise only rendered and checked.
@MainActor
final class SkipSegmentPillSnapshotTests: XCTestCase {
    func testPhoneAndPadSnapshots() throws {
        let segment = MediaSegmentDto(id: "i", type: .intro, startSeconds: 0, endSeconds: 40)
        let cases: [(String, SkipSegmentPillMetrics, CGSize)] = [
            ("ios-phone", .phone, CGSize(width: 430, height: 240)),
            ("ios-pad", .pad, CGSize(width: 620, height: 300)),
        ]
        for (name, metrics, size) in cases {
            for highlighted in [false, true] {
                let view = ZStack(alignment: .bottomTrailing) {
                    LinearGradient(
                        colors: [Color(red: 0.10, green: 0.12, blue: 0.18), Color(red: 0.03, green: 0.03, blue: 0.05)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                    // A snapshot cannot hold a press, so set the value
                    // SkipSegmentPillButtonStyle passes from isPressed.
                    LiveSkipSegmentPill(segment: segment, accent: MobileColors.accent, metrics: metrics) { 16 }
                        .environment(\.skipPillHighlighted, highlighted)
                        .padding(32)
                }
                .frame(width: size.width, height: size.height)

                let renderer = ImageRenderer(content: view)
                renderer.scale = 3
                let image = try XCTUnwrap(renderer.uiImage)
                XCTAssertEqual(image.size, size)
                guard let dir = ProcessInfo.processInfo.environment["SKIP_PILL_SNAPSHOT_DIR"] else { continue }
                try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                let file = "\(name)-\(highlighted ? "pressed" : "idle").png"
                try XCTUnwrap(image.pngData()).write(to: URL(fileURLWithPath: dir).appendingPathComponent(file))
            }
        }
    }
}

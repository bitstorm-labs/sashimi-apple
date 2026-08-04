import XCTest
@testable import Sashimi

/// Phase 1 of the VLCKit work: the device profile is engine-shaped, and the
/// `.vlc` shape hinges on the `Container` key being *absent* from the
/// direct-play profile — an invariant no log line can show. These tests are
/// the acceptance guard for that, plus the pure track-index mapping.
final class PlaybackEngineProfileTests: XCTestCase {
    private func directPlayProfiles(_ profile: [String: Any]) -> [[String: Any]] {
        (profile["DirectPlayProfiles"] as? [[String: Any]]) ?? []
    }

    // MARK: - AVFoundation profile: unchanged, MP4-family only

    func testAVFoundationProfileConstrainsContainerToMP4Family() async {
        let client = JellyfinClient.shared
        let profile = await client.videoDeviceProfile(engine: .avFoundation, streamingBitrate: 20_000_000, maxWidth: nil)

        let entries = directPlayProfiles(profile)
        XCTAssertFalse(entries.isEmpty)
        for entry in entries {
            let container = entry["Container"] as? String
            XCTAssertNotNil(container, "AVFoundation direct play must name a container")
        }
        // The mp4,m4v entry is what makes MKV negotiate as a transcode.
        XCTAssertTrue(entries.contains { ($0["Container"] as? String) == "mp4,m4v" })
    }

    func testAVFoundationSubtitlesAreExternalOnly() async {
        let client = JellyfinClient.shared
        let profile = await client.videoDeviceProfile(engine: .avFoundation, streamingBitrate: 20_000_000, maxWidth: nil)
        let subs = (profile["SubtitleProfiles"] as? [[String: Any]]) ?? []
        XCTAssertFalse(subs.isEmpty)
        XCTAssertTrue(subs.allSatisfy { ($0["Method"] as? String) == "External" })
    }

    // MARK: - VLC profile: the Container key must be absent

    /// The whole mechanism. `Container: ""` becomes the one-element list [""]
    /// server-side and matches nothing (worse than today); only the key being
    /// absent parses as "no restriction" and lets MKV direct-play.
    func testVLCDirectPlayOmitsContainerKeyEntirely() async {
        let client = JellyfinClient.shared
        let profile = await client.videoDeviceProfile(engine: .vlc, streamingBitrate: 20_000_000, maxWidth: nil)

        let entries = directPlayProfiles(profile)
        XCTAssertFalse(entries.isEmpty, "VLC must still declare a direct-play profile")
        for entry in entries {
            XCTAssertNil(entry["Container"], "VLC direct play must NOT carry a Container key (absent, not empty)")
            XCTAssertNil(entry["Container"] as? String, "and certainly not an empty string")
        }
    }

    func testVLCProfileStillKeepsATranscodingProfile() async {
        let client = JellyfinClient.shared
        let profile = await client.videoDeviceProfile(engine: .vlc, streamingBitrate: 20_000_000, maxWidth: nil)
        let transcoding = (profile["TranscodingProfiles"] as? [[String: Any]]) ?? []
        XCTAssertFalse(transcoding.isEmpty, "explicit quality tiers need a transcode URL to come back")
        // Still fMP4, not ts — same reason as AVPlayer path.
        XCTAssertEqual(transcoding.first?["Container"] as? String, "mp4")
        // Widened to 7.1.
        XCTAssertEqual(transcoding.first?["MaxAudioChannels"] as? String, "8")
    }

    func testVLCProfileDeclaresEmbeddedSubtitles() async {
        let client = JellyfinClient.shared
        let profile = await client.videoDeviceProfile(engine: .vlc, streamingBitrate: 20_000_000, maxWidth: nil)
        let subs = (profile["SubtitleProfiles"] as? [[String: Any]]) ?? []
        let embedded = subs.filter { ($0["Method"] as? String) == "Embed" }
        XCTAssertTrue(embedded.contains { ($0["Format"] as? String) == "ass" }, "ASS must be Embed so VLC renders styling")
        XCTAssertTrue(embedded.contains { ($0["Format"] as? String) == "pgssub" }, "image subs must be Embed to avoid burn-in transcode")
    }

    // MARK: - Width condition applies to both engines

    func testWidthConditionPresentWhenMaxWidthGiven() async {
        let client = JellyfinClient.shared
        for engine in PlaybackEngineKind.allCases {
            let profile = await client.videoDeviceProfile(engine: engine, streamingBitrate: 8_000_000, maxWidth: 1280)
            let codecProfiles = (profile["CodecProfiles"] as? [[String: Any]]) ?? []
            XCTAssertFalse(codecProfiles.isEmpty, "\(engine) should carry a width condition when capped")
        }
    }

    func testNoWidthConditionWhenUnrestricted() async {
        let client = JellyfinClient.shared
        for engine in PlaybackEngineKind.allCases {
            let profile = await client.videoDeviceProfile(engine: engine, streamingBitrate: 8_000_000, maxWidth: nil)
            let codecProfiles = (profile["CodecProfiles"] as? [[String: Any]]) ?? []
            XCTAssertTrue(codecProfiles.isEmpty, "\(engine) unrestricted must not downscale")
        }
    }
}

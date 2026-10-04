import XCTest
@testable import Sashimi

/// Phase 1 of the VLCKit work: the device profile is engine-shaped, and the
/// `.vlc` shape hinges on the `Container` key being *absent* from the
/// direct-play profile — an invariant no log line can show. These tests are
/// the acceptance guard for that, plus the width and dynamic-range conditions.
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

    // MARK: - Forced re-encode must target a codec the Apple TV can decode at 4K

    /// `AllowVideoStreamCopy` is false (getPlaybackInfo), so an MKV always
    /// re-encodes. The Apple TV cannot decode 4K H.264 — it caps H.264 at 1080p;
    /// 4K needs HEVC — so the transcoding profile must offer HEVC FIRST. With
    /// H.264 first, the server emits undecodable 4K H.264: black picture, then a
    /// transcode restart storm and crash (the v1.2.3 Oppenheimer regression).
    /// HEVC first makes the forced re-encode produce 4K HEVC, which decodes
    /// natively (requires the server's AllowHevcEncoding to be enabled).
    func testAVFoundationTranscodeProfilePrefersHEVC() async {
        let client = JellyfinClient.shared
        let profile = await client.videoDeviceProfile(engine: .avFoundation, streamingBitrate: 120_000_000, maxWidth: nil)
        let transcoding = (profile["TranscodingProfiles"] as? [[String: Any]]) ?? []
        XCTAssertFalse(transcoding.isEmpty)
        XCTAssertEqual(transcoding.first?["VideoCodec"] as? String, "hevc,h264",
            "Forced re-encode must prefer HEVC; H.264-first yields undecodable 4K H.264 on Apple TV")
    }

    // MARK: - Width condition applies to both engines

    private func conditions(_ profile: [String: Any], property: String) -> [[String: Any]] {
        let codecProfiles = (profile["CodecProfiles"] as? [[String: Any]]) ?? []
        return codecProfiles
            .flatMap { ($0["Conditions"] as? [[String: Any]]) ?? [] }
            .filter { ($0["Property"] as? String) == property }
    }

    func testWidthConditionPresentWhenMaxWidthGiven() async {
        let client = JellyfinClient.shared
        for engine in PlaybackEngineKind.allCases {
            let profile = await client.videoDeviceProfile(engine: engine, streamingBitrate: 8_000_000, maxWidth: 1280)
            XCTAssertFalse(conditions(profile, property: "Width").isEmpty, "\(engine) should carry a width condition when capped")
        }
    }

    func testNoWidthConditionWhenUnrestricted() async {
        let client = JellyfinClient.shared
        for engine in PlaybackEngineKind.allCases {
            let profile = await client.videoDeviceProfile(engine: engine, streamingBitrate: 8_000_000, maxWidth: nil)
            XCTAssertTrue(conditions(profile, property: "Width").isEmpty, "\(engine) unrestricted must not downscale")
        }
    }

    // MARK: - Dynamic range (#606)

    private func hevcRangeTypes(_ profile: [String: Any]) -> Set<String>? {
        let codecProfiles = (profile["CodecProfiles"] as? [[String: Any]]) ?? []
        guard let hevc = codecProfiles.first(where: {
            ($0["Codec"] as? String) == "hevc"
                && (($0["Conditions"] as? [[String: Any]]) ?? []).contains { ($0["Property"] as? String) == "VideoRangeType" }
        }),
            let condition = (hevc["Conditions"] as? [[String: Any]])?.first(where: { ($0["Property"] as? String) == "VideoRangeType" }),
            (condition["Condition"] as? String) == "EqualsAny",
            let value = condition["Value"] as? String else { return nil }
        return Set(value.split(separator: "|").map(String.init))
    }

    func testNonDolbyVisionDisplayRefusesProfile5() async {
        // Single-layer DV (VideoRangeType "DOVI") has no base layer: without
        // DV it renders green/purple. Not listing it makes Jellyfin refuse
        // direct play (VideoRangeTypeNotSupported) and refuse stream copy
        // (EncodingHelper.CanStreamCopyVideo), so it is re-encoded.
        let profile = await JellyfinClient.shared.videoDeviceProfile(
            engine: .avFoundation, streamingBitrate: 100_000_000, maxWidth: nil, supportsDolbyVision: false
        )
        let ranges = hevcRangeTypes(profile)
        XCTAssertNotNil(ranges, "the HEVC profile must carry a VideoRangeType condition")
        XCTAssertEqual(ranges?.contains("DOVI"), false)
        XCTAssertEqual(ranges?.isSuperset(of: ["SDR", "HDR10", "HLG"]), true)
    }

    func testNonDolbyVisionDisplayPlaysDolbyVisionWithABaseLayerAsThatBase() async {
        // DOVIWithHDR10/HLG/SDR stay OFF the list: the server then copies them
        // as their HDR10/HLG/SDR base (CanStreamCopyVideo allows exactly that
        // for a client listing the base range) instead of direct-playing a
        // dvh1 file a non-DV player may refuse.
        let profile = await JellyfinClient.shared.videoDeviceProfile(
            engine: .avFoundation, streamingBitrate: 100_000_000, maxWidth: nil, supportsDolbyVision: false
        )
        let ranges = hevcRangeTypes(profile) ?? []
        XCTAssertTrue(ranges.isDisjoint(with: ["DOVIWithHDR10", "DOVIWithHLG", "DOVIWithSDR"]))
        XCTAssertTrue(ranges.isSuperset(of: ["HDR10", "HLG", "SDR"]))
    }

    func testDolbyVisionDisplayKeepsDolbyVision() async {
        let profile = await JellyfinClient.shared.videoDeviceProfile(
            engine: .avFoundation, streamingBitrate: 100_000_000, maxWidth: nil, supportsDolbyVision: true
        )
        let ranges = hevcRangeTypes(profile) ?? []
        XCTAssertTrue(ranges.isSuperset(of: ["DOVI", "DOVIWithHDR10", "DOVIWithHLG", "DOVIWithSDR", "HDR10", "SDR"]))
    }

    func testRangeConditionIsNotRequiredSoUnknownRangesStillDirectPlay() async {
        let profile = await JellyfinClient.shared.videoDeviceProfile(
            engine: .avFoundation, streamingBitrate: 100_000_000, maxWidth: nil, supportsDolbyVision: false
        )
        let range = conditions(profile, property: "VideoRangeType").first
        XCTAssertEqual(range?["IsRequired"] as? Bool, false)
    }

    func testRangeConditionAndWidthConditionCoexist() async {
        let profile = await JellyfinClient.shared.videoDeviceProfile(
            engine: .avFoundation, streamingBitrate: 8_000_000, maxWidth: 1280, supportsDolbyVision: false
        )
        XCTAssertEqual(conditions(profile, property: "Width").count, 1)
        XCTAssertNotNil(hevcRangeTypes(profile))
    }
}

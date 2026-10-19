import XCTest
@testable import Sashimi

/// Jellyfin marks `MediaSourceInfo.TranscodeReasons` `[JsonIgnore]`, so a
/// PlaybackInfo response never carries that field. The reasons travel only as
/// the `TranscodeReasons` query parameter of `TranscodingUrl` (checked against
/// a live 10.11 server). Reading the field meant Auto's re-encode width
/// override never fired and re-encode readings were saved as the link's rate.
final class MediaSourceTranscodeReasonsTests: XCTestCase {
    /// A re-encode as the live server returns it: no TranscodeReasons field.
    private func source(transcodingUrl: String?, sourceWidth: Int = 3840) throws -> MediaSourceInfo {
        var json: [String: Any] = [
            "Id": "src1",
            "Container": "mkv",
            "SupportsDirectPlay": false,
            "SupportsTranscoding": true,
            "Bitrate": 60_000_000,
            "MediaStreams": [["Type": "Video", "Codec": "hevc", "Width": sourceWidth, "Height": 2160]]
        ]
        if let transcodingUrl { json["TranscodingUrl"] = transcodingUrl }
        return try JSONDecoder().decode(MediaSourceInfo.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private let reencodeURL = "/videos/abc/master.m3u8?DeviceId=DEV&MediaSourceId=src1&VideoCodec=h264"
        + "&AudioCodec=aac&PlaySessionId=ps1&ApiKey=REDACTED"
        + "&TranscodeReasons=VideoCodecNotSupported%2CAudioCodecNotSupported%2CDirectPlayError"

    func testReasonsComeFromTheTranscodingUrl() throws {
        XCTAssertEqual(
            try source(transcodingUrl: reencodeURL).transcodeReasons,
            ["VideoCodecNotSupported", "AudioCodecNotSupported", "DirectPlayError"]
        )
    }

    func testUnescapedCommasAndSpacesAreSplitToo() throws {
        let url = "/videos/abc/master.m3u8?MediaSourceId=src1&TranscodeReasons=ContainerNotSupported,%20AudioCodecNotSupported"
        XCTAssertEqual(try source(transcodingUrl: url).transcodeReasons, ["ContainerNotSupported", "AudioCodecNotSupported"])
    }

    func testNoTranscodingUrlOrNoParameterMeansNoReasons() throws {
        XCTAssertNil(try source(transcodingUrl: nil).transcodeReasons)
        XCTAssertNil(try source(transcodingUrl: "/videos/abc/master.m3u8?MediaSourceId=src1").transcodeReasons)
        XCTAssertNil(try source(transcodingUrl: "/videos/abc/master.m3u8?TranscodeReasons=").transcodeReasons)
    }

    func testTheIgnoredFieldIsNotWhatDecides() throws {
        // Even if some server did send the field, the URL is what the server
        // actually acts on.
        let json = #"{"Id":"src1","TranscodeReasons":["ContainerNotSupported"]}"#
        XCTAssertNil(try JSONDecoder().decode(MediaSourceInfo.self, from: Data(json.utf8)).transcodeReasons)
    }

    // MARK: - What the reasons drive

    func testAutoReencodesALiveShapedReencodeAtTheCapsWidth() throws {
        let source = try source(transcodingUrl: reencodeURL)
        let override = PlaybackSelection.autoReencodeOverride(
            cap: 4_000_000,
            sourceWidth: source.mediaStreams?.first(where: { $0.type == "Video" })?.width,
            transcodeReasons: source.transcodeReasons
        )
        XCTAssertNotNil(override, "a 4K re-encode on a 4 Mbps cap must be re-requested narrower")
        XCTAssertLessThan(override?.maxWidth ?? .max, 3840)
    }

    func testALiveShapedReencodesReadingsDoNotMeasureTheLink() throws {
        let source = try source(transcodingUrl: reencodeURL)
        XCTAssertFalse(PlaybackSelection.readingsMeasureLink(
            isTranscode: source.transcodingUrl?.isEmpty == false,
            transcodeReasons: source.transcodeReasons,
            burnsInSubtitle: false,
            allowVideoStreamCopy: true
        ))
    }

    func testALiveShapedRemuxsReadingsStillMeasureTheLink() throws {
        let remux = "/videos/abc/master.m3u8?MediaSourceId=src1&VideoCodec=hevc&TranscodeReasons=ContainerNotSupported"
        let source = try source(transcodingUrl: remux)
        XCTAssertTrue(PlaybackSelection.readingsMeasureLink(
            isTranscode: true,
            transcodeReasons: source.transcodeReasons,
            burnsInSubtitle: false,
            allowVideoStreamCopy: true
        ))
    }
}

import AVFoundation
import XCTest
@testable import Sashimi

/// The load-bearing claim of the player diagnostics is that they are safe to
/// leave enabled in a release build: the stream URL carries `api_key`, so a
/// single unredacted URL in the log is a leaked credential. These tests pin
/// that claim down.
final class PlayerDiagnosticsTests: XCTestCase {

    // MARK: - scrub

    func testScrubRemovesFullURLs() {
        let text = "Failed to open https://jelly.example.com/videos/abc/master.m3u8?api_key=SECRET123&DeviceId=x"
        let scrubbed = PlayerDiagnostics.scrub(text)

        XCTAssertFalse(scrubbed.contains("SECRET123"), "api_key must never survive scrubbing")
        XCTAssertFalse(scrubbed.contains("https://"), "URLs must be replaced wholesale")
        XCTAssertFalse(scrubbed.contains("jelly.example.com"), "host must not leak")
        XCTAssertTrue(scrubbed.contains("<url-redacted>"))
        XCTAssertTrue(scrubbed.hasPrefix("Failed to open"), "non-URL text must be preserved")
    }

    func testScrubRemovesBareSecretParameters() {
        // A description that names the parameter without a full URL around it.
        let scrubbed = PlayerDiagnostics.scrub("request failed api_key=abc123 status=401")

        XCTAssertFalse(scrubbed.contains("abc123"))
        XCTAssertTrue(scrubbed.contains("<secret-redacted>"))
        XCTAssertTrue(scrubbed.contains("status=401"), "unrelated fields must survive")
    }

    func testScrubRemovesTokenVariants() {
        for parameter in ["api_key", "ApiKey", "X-Emby-Token", "token", "access_token", "accessToken", "password"] {
            let scrubbed = PlayerDiagnostics.scrub("\(parameter)=topsecret")
            XCTAssertFalse(scrubbed.contains("topsecret"), "\(parameter) was not redacted")
        }
    }

    func testScrubHandlesNonASCIIAndKeepsOneLine() {
        let scrubbed = PlayerDiagnostics.scrub("línea uno\nlínea dos\r\ntres")

        XCTAssertFalse(scrubbed.contains("\n"), "a diagnostic event must stay on one log line")
        XCTAssertFalse(scrubbed.contains("\r"))
        XCTAssertTrue(scrubbed.contains("línea uno"))
        XCTAssertTrue(scrubbed.contains("tres"))
    }

    func testScrubLeavesOrdinaryTextAlone() {
        let text = "The operation couldn't be completed. (CoreMediaErrorDomain error -12939.)"
        XCTAssertEqual(PlayerDiagnostics.scrub(text), text)
    }

    // MARK: - describe(url:)

    func testDescribeURLKeepsPathAndDropsQuery() {
        let url = URL(string: "https://jelly.example.com/videos/abc123/master.m3u8?api_key=SECRET&MediaSourceId=zzz")
        let described = PlayerDiagnostics.describe(url: url)

        XCTAssertFalse(described.contains("SECRET"), "the query string must never be logged")
        XCTAssertFalse(described.contains("api_key"))
        XCTAssertFalse(described.contains("jelly.example.com"))
        XCTAssertTrue(described.contains("path=/videos/abc123/master.m3u8"))
        XCTAssertTrue(described.contains("ext=m3u8"), "the container is the whole point of this field")
        XCTAssertTrue(described.contains("queryparams=2"), "count is enough to spot a malformed URL")
    }

    func testDescribeURLReportsMatroskaContainer() {
        // AVPlayer has no Matroska demuxer; a direct-stream URL that ends .mkv
        // is a stream it cannot render, and the log has to make that visible.
        let url = URL(string: "https://host/Videos/abc/stream.mkv?api_key=SECRET&Static=true")
        let described = PlayerDiagnostics.describe(url: url)

        XCTAssertTrue(described.contains("ext=mkv"))
        XCTAssertFalse(described.contains("SECRET"))
    }

    func testDescribeNilURL() {
        XCTAssertEqual(PlayerDiagnostics.describe(url: nil), "path=nil")
    }

    func testDescribeStreamPathDropsQuery() {
        let described = PlayerDiagnostics.describe(
            streamPath: "/videos/abc/master.m3u8?api_key=SECRET&PlaySessionId=1"
        )

        XCTAssertFalse(described.contains("SECRET"))
        XCTAssertTrue(described.contains("path=/videos/abc/master.m3u8"))
        XCTAssertTrue(described.contains("ext=m3u8"))
    }

    func testDescribeStreamPathWithoutExtension() {
        let described = PlayerDiagnostics.describe(streamPath: "/videos/abc/stream")
        XCTAssertTrue(described.contains("ext=none"))
    }

    // MARK: - field rendering

    func testFieldScrubsStringValues() {
        let rendered = PlayerDiagnostics.field("errorDescription", "cannot open https://host/x?api_key=SECRET")
        XCTAssertFalse(rendered.contains("SECRET"))
        XCTAssertTrue(rendered.hasPrefix("errorDescription="))
    }

    func testFieldRendersNilsExplicitly() {
        // "absent" and "false"/"0" are different diagnostic facts, so nil is
        // never rendered as a default value.
        XCTAssertEqual(PlayerDiagnostics.field("a", nil as String?), "a=nil")
        XCTAssertEqual(PlayerDiagnostics.field("b", nil as Int?), "b=nil")
        XCTAssertEqual(PlayerDiagnostics.field("c", nil as Bool?), "c=nil")
        XCTAssertEqual(PlayerDiagnostics.field("d", nil as Double?), "d=nil")
        XCTAssertEqual(PlayerDiagnostics.field("e", "" as String?), "e=nil")
    }

    func testFieldRendersValues() {
        XCTAssertEqual(PlayerDiagnostics.field("bitrate", 8_000_000), "bitrate=8000000")
        XCTAssertEqual(PlayerDiagnostics.field("direct", true), "direct=true")
        XCTAssertEqual(PlayerDiagnostics.field("direct", false), "direct=false")
        XCTAssertEqual(PlayerDiagnostics.field("pos", 12.3456), "pos=12.35")
    }

    func testFieldRendersNonFiniteDoublesAsNil() {
        // CMTime.seconds is NaN for an indefinite duration, which is routine
        // for a live/transcoding HLS item — it must not print as "nan".
        XCTAssertEqual(PlayerDiagnostics.field("dur", Double.nan), "dur=nil")
        XCTAssertEqual(PlayerDiagnostics.field("dur", Double.infinity), "dur=nil")
    }

    // MARK: - status naming

    func testStatusNames() {
        XCTAssertEqual(PlayerDiagnostics.name(itemStatus: .unknown), "unknown")
        XCTAssertEqual(PlayerDiagnostics.name(itemStatus: .readyToPlay), "readyToPlay")
        XCTAssertEqual(PlayerDiagnostics.name(itemStatus: .failed), "failed")
        XCTAssertEqual(PlayerDiagnostics.name(playerStatus: .failed), "failed")
        XCTAssertEqual(PlayerDiagnostics.name(timeControlStatus: .paused), "paused")
        XCTAssertEqual(PlayerDiagnostics.name(timeControlStatus: .waitingToPlayAtSpecifiedRate), "waiting")
        XCTAssertEqual(PlayerDiagnostics.name(timeControlStatus: .playing), "playing")
    }

    // MARK: - error fields

    func testErrorFieldsCarryDomainAndCode() {
        let underlying = NSError(domain: "CoreMediaErrorDomain", code: -12939)
        let error = NSError(
            domain: NSURLErrorDomain,
            code: -1001,
            userInfo: [
                NSLocalizedDescriptionKey: "timed out loading https://host/master.m3u8?api_key=SECRET",
                NSUnderlyingErrorKey: underlying
            ]
        )
        let joined = PlayerDiagnostics.fields(for: error).joined(separator: " ")

        XCTAssertTrue(joined.contains("errorDomain=NSURLErrorDomain"))
        XCTAssertTrue(joined.contains("errorCode=-1001"))
        XCTAssertTrue(joined.contains("underlyingDomain=CoreMediaErrorDomain"))
        XCTAssertTrue(joined.contains("underlyingCode=-12939"))
        XCTAssertFalse(joined.contains("SECRET"), "the description must be scrubbed")
    }

    func testErrorFieldsForNil() {
        XCTAssertEqual(PlayerDiagnostics.fields(for: nil), ["error=none"])
    }

    // MARK: - track summary

    func testTrackSummaryFieldsNameTheAudioOnlyCase() {
        let summary = PlayerDiagnostics.TrackSummary(
            videoCount: 1,
            audioCount: 1,
            enabledVideoCount: 0,
            enabledAudioCount: 1,
            presentationWidth: 0,
            presentationHeight: 0
        )
        let joined = summary.fields.joined(separator: " ")

        XCTAssertTrue(joined.contains("audioOnly=true"), "zero enabled video tracks IS the audio-only failure")
        XCTAssertTrue(joined.contains("videoEnabled=0"))
        XCTAssertTrue(joined.contains("presentation=0x0"))
    }

    func testTrackSummaryHealthyPlayback() {
        let summary = PlayerDiagnostics.TrackSummary(
            videoCount: 1,
            audioCount: 2,
            enabledVideoCount: 1,
            enabledAudioCount: 1,
            presentationWidth: 3840,
            presentationHeight: 2160
        )
        let joined = summary.fields.joined(separator: " ")

        XCTAssertTrue(joined.contains("audioOnly=false"))
        XCTAssertTrue(joined.contains("presentation=3840x2160"))
    }

    // MARK: - vocabulary stability

    func testStageAndReasonRawValuesAreGreppable() {
        // These strings are what a support capture is filtered on, so they are
        // API: renaming one silently breaks every saved grep.
        XCTAssertEqual(PlayerDiagnostics.prefix, "SASHIMI-PLAYER")
        XCTAssertEqual(PlayerDiagnostics.category, "player")
        XCTAssertEqual(PlayerDiagnostics.Stage.playbackInfoResponse.rawValue, "pbinfo.response")
        XCTAssertEqual(PlayerDiagnostics.Stage.streamSelected.rawValue, "stream.selected")
        XCTAssertEqual(PlayerDiagnostics.Stage.encodingStop.rawValue, "encoding.stop")
        XCTAssertEqual(PlayerDiagnostics.Stage.accessLog.rawValue, "avlog.access")
        XCTAssertEqual(PlayerDiagnostics.Stage.errorLog.rawValue, "avlog.error")
        XCTAssertEqual(PlayerDiagnostics.TeardownReason.newItem.rawValue, "new-item")
        XCTAssertEqual(PlayerDiagnostics.StreamKind.transcodeHLS.rawValue, "transcode-hls")
    }

    // MARK: - emit

    func testEmittingEventsDoesNotTrapAndRedactsFields() {
        // Exercises the real os_log path. There is no public API to read back
        // the unified log from a test, so the assertion here is only that the
        // emit path runs; that the lines actually appear at default level was
        // verified out-of-band with:
        //   log show --predicate 'subsystem == "com.mondominator.sashimi"
        //                         AND category == "player"'
        PlayerDiagnostics.event(.loadBegin, [
            PlayerDiagnostics.field("item", "abc"),
            PlayerDiagnostics.field("url", "https://host/x?api_key=SECRET")
        ])
        PlayerDiagnostics.failure(.loadFailed, PlayerDiagnostics.fields(for: NSError(domain: "d", code: 1)))
        PlayerDiagnostics.detail(.accessLog, [PlayerDiagnostics.field("observedBitrate", 1.0)])
        PlayerDiagnostics.event(.teardown)
    }

    // MARK: - model decoding

    func testMediaSourceDecodesTranscodeReasons() {
        // Newly decoded so the diagnostics can state WHY the server transcoded
        // instead of leaving it to be reconstructed from server logs.
        let json = """
        {
          "Id": "src1",
          "Container": "mkv",
          "SupportsDirectPlay": false,
          "SupportsDirectStream": true,
          "TranscodeReasons": ["ContainerNotSupported", "AudioCodecNotSupported"]
        }
        """.data(using: .utf8)!

        let source = try? JSONDecoder().decode(MediaSourceInfo.self, from: json)

        XCTAssertEqual(source?.transcodeReasons, ["ContainerNotSupported", "AudioCodecNotSupported"])
    }

    func testMediaSourceWithoutTranscodeReasonsStillDecodes() {
        let json = """
        { "Id": "src1", "Container": "mp4" }
        """.data(using: .utf8)!

        let source = try? JSONDecoder().decode(MediaSourceInfo.self, from: json)

        XCTAssertEqual(source?.id, "src1")
        XCTAssertNil(source?.transcodeReasons)
    }
}

import XCTest
@testable import SashimiMobile

/// #585: transcoded downloads were encoded at 1 kbps / 416 px because the URL
/// sent only MaxStreamingBitrate, which Jellyfin's progressive stream
/// endpoint does not take. The encode bitrate must be spelled out.
final class DownloadURLBuilderTests: XCTestCase {
    private let server = URL(string: "https://jellyfin.example.test:8920")!

    private func query(_ quality: DownloadQuality) throws -> [String: String] {
        let url = try XCTUnwrap(DownloadURLBuilder.downloadURL(itemId: "item1", quality: quality, serverURL: server))
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
    }

    func testTranscodedTiersSendAnExplicitVideoAndAudioBitrate() throws {
        let expected: [(DownloadQuality, video: String, audio: String, width: String, height: String, channels: String)] = [
            (.high, "19616000", "384000", "1920", "1080", "6"),
            (.medium, "7808000", "192000", "1280", "720", "2"),
            (.low, "3872000", "128000", "854", "480", "2")
        ]
        for tier in expected {
            let params = try query(tier.0)
            XCTAssertEqual(params["VideoBitRate"], tier.video, "\(tier.0) video bitrate")
            XCTAssertEqual(params["AudioBitRate"], tier.audio, "\(tier.0) audio bitrate")
            XCTAssertEqual(params["MaxWidth"], tier.width, "\(tier.0) width")
            XCTAssertEqual(params["MaxHeight"], tier.height, "\(tier.0) height")
            XCTAssertEqual(params["AudioChannels"], tier.channels, "\(tier.0) channels")
            XCTAssertEqual(params["MaxAudioChannels"], tier.channels, "\(tier.0) max channels")
            XCTAssertEqual(params["VideoCodec"], "h264")
            XCTAssertEqual(params["AudioCodec"], "aac")
            XCTAssertEqual(params["Container"], "mp4")
        }
    }

    func testVideoPlusAudioStaysWithinTheTierBitrate() throws {
        for quality in DownloadQuality.allCases where quality != .original {
            let params = try query(quality)
            let video = try XCTUnwrap(params["VideoBitRate"].flatMap(Int.init))
            let audio = try XCTUnwrap(params["AudioBitRate"].flatMap(Int.init))
            XCTAssertEqual(video + audio, quality.maxBitrate, "\(quality)")
            // The server clamped the missing value to 1000 bps; anything near
            // that is the bug again.
            XCTAssertGreaterThan(video, 1_000_000, "\(quality)")
        }
    }

    func testOriginalIsStillAStreamCopyRemux() throws {
        let params = try query(.original)
        XCTAssertEqual(params["AllowVideoStreamCopy"], "true")
        XCTAssertEqual(params["AllowAudioStreamCopy"], "true")
        XCTAssertNil(params["VideoBitRate"])
        XCTAssertNil(params["MaxWidth"])
    }

    func testDownloadURLTargetsTheProgressiveStreamEndpoint() throws {
        let url = try XCTUnwrap(DownloadURLBuilder.downloadURL(itemId: "item1", quality: .low, serverURL: server))
        XCTAssertEqual(url.path, "/Videos/item1/stream.mp4")
    }
}

final class DownloadEncodingAuditTests: XCTestCase {
    private var suiteName = ""
    private var defaults = UserDefaults.standard

    override func setUp() {
        super.setUp()
        suiteName = "DownloadEncodingAuditTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName) ?? .standard
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testPreFixTranscodedDownloadNeedsRedownload() {
        // Nothing was recorded by the fixed builder: made by the old URL.
        let ids = DownloadEncodingAudit.fixedRecordIDs(defaults: defaults)
        XCTAssertTrue(DownloadEncodingAudit.needsRedownload(quality: .low, isComplete: true, recordID: "s:a", fixedRecordIDs: ids))
        XCTAssertTrue(DownloadEncodingAudit.needsRedownload(quality: .high, isComplete: true, recordID: "s:a", fixedRecordIDs: ids))
    }

    func testDownloadBuiltByTheFixedURLIsFine() {
        DownloadEncodingAudit.markEncodedWithVideoBitrate(recordID: "s:a", defaults: defaults)
        let ids = DownloadEncodingAudit.fixedRecordIDs(defaults: defaults)
        XCTAssertFalse(DownloadEncodingAudit.needsRedownload(quality: .medium, isComplete: true, recordID: "s:a", fixedRecordIDs: ids))
    }

    func testOriginalAndUnfinishedDownloadsAreNeverFlagged() {
        let ids = DownloadEncodingAudit.fixedRecordIDs(defaults: defaults)
        XCTAssertFalse(DownloadEncodingAudit.needsRedownload(quality: .original, isComplete: true, recordID: "s:a", fixedRecordIDs: ids))
        XCTAssertFalse(DownloadEncodingAudit.needsRedownload(quality: .low, isComplete: false, recordID: "s:a", fixedRecordIDs: ids))
    }

    func testForgetRemovesTheRecord() {
        DownloadEncodingAudit.markEncodedWithVideoBitrate(recordID: "s:a", defaults: defaults)
        DownloadEncodingAudit.forget(recordID: "s:a", defaults: defaults)
        XCTAssertTrue(DownloadEncodingAudit.fixedRecordIDs(defaults: defaults).isEmpty)
    }
}

/// Audit F2: "Original" of an MKV used to degrade to High because the
/// compatibility gate demanded an mp4/mov container, so the stream-copy remux
/// it was written for never ran.
final class OriginalDownloadQualityTests: XCTestCase {
    private func source(container: String, video: String, audio: String) throws -> MediaSourceInfo {
        let json = """
        {"Id": "s1", "Container": "\(container)", "MediaStreams": [
            {"Type": "Video", "Codec": "\(video)"}, {"Type": "Audio", "Codec": "\(audio)"}]}
        """
        return try JSONDecoder().decode(MediaSourceInfo.self, from: Data(json.utf8))
    }

    func testH264AacMkvStaysOriginal() throws {
        let mkv = try source(container: "mkv", video: "h264", audio: "aac")
        let compatible = DeviceMediaCompatibility.canRemuxForDownload(mkv, deviceSupportsDolbyVision: false)
        XCTAssertEqual(DownloadQuality.effectiveQuality(requested: .original, sourceIsCompatible: compatible), .original)
    }

    func testUndecodableMkvStillDegradesToHigh() throws {
        let mkv = try source(container: "mkv", video: "av1", audio: "aac")
        let compatible = DeviceMediaCompatibility.canRemuxForDownload(mkv, deviceSupportsDolbyVision: false)
        XCTAssertEqual(DownloadQuality.effectiveQuality(requested: .original, sourceIsCompatible: compatible), .high)
    }
}

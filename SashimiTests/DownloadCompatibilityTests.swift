import XCTest
@testable import Sashimi

final class DownloadCompatibilityTests: XCTestCase {
    /// Decodes a MediaSourceInfo from JSON. `container` may be nil (omit the
    /// key by passing nil); video/audio codecs are supplied via MediaStreams.
    private func makeSource(
        container: String?,
        videoCodec: String?,
        audioCodec: String?
    ) throws -> MediaSourceInfo {
        var streams: [String] = []
        if let videoCodec {
            streams.append("{ \"Type\": \"Video\", \"Codec\": \"\(videoCodec)\" }")
        }
        if let audioCodec {
            streams.append("{ \"Type\": \"Audio\", \"Codec\": \"\(audioCodec)\" }")
        }
        let containerField = container.map { "\"Container\": \"\($0)\"," } ?? ""
        let json = """
        {
            "Id": "source-1",
            \(containerField)
            "MediaStreams": [\(streams.joined(separator: ","))]
        }
        """
        return try JSONDecoder().decode(MediaSourceInfo.self, from: Data(json.utf8))
    }

    func testMp4H264AacDirectPlays() throws {
        let source = try makeSource(container: "mp4", videoCodec: "h264", audioCodec: "aac")
        XCTAssertTrue(DeviceMediaCompatibility.canDirectPlayOnDevice(source))
    }

    func testMovHevcEac3DirectPlays() throws {
        let source = try makeSource(container: "mov", videoCodec: "hevc", audioCodec: "eac3")
        XCTAssertTrue(DeviceMediaCompatibility.canDirectPlayOnDevice(source))
    }

    func testMkvContainerFails() throws {
        let source = try makeSource(container: "mkv", videoCodec: "h264", audioCodec: "aac")
        XCTAssertFalse(DeviceMediaCompatibility.canDirectPlayOnDevice(source))
    }

    func testUnsupportedVideoCodecFails() throws {
        let source = try makeSource(container: "mp4", videoCodec: "vp9", audioCodec: "aac")
        XCTAssertFalse(DeviceMediaCompatibility.canDirectPlayOnDevice(source))
    }

    func testUnsupportedAudioCodecFails() throws {
        let source = try makeSource(container: "mp4", videoCodec: "h264", audioCodec: "dts")
        XCTAssertFalse(DeviceMediaCompatibility.canDirectPlayOnDevice(source))
    }

    func testCommaListContainerDirectPlays() throws {
        let source = try makeSource(container: "mp4,m4v", videoCodec: "h264", audioCodec: "aac")
        XCTAssertTrue(DeviceMediaCompatibility.canDirectPlayOnDevice(source))
    }

    func testNilContainerFailsClosed() throws {
        let source = try makeSource(container: nil, videoCodec: "h264", audioCodec: "aac")
        XCTAssertFalse(DeviceMediaCompatibility.canDirectPlayOnDevice(source))
    }

    func testNilCodecsFailClosed() throws {
        let source = try makeSource(container: "mp4", videoCodec: nil, audioCodec: nil)
        XCTAssertFalse(DeviceMediaCompatibility.canDirectPlayOnDevice(source))
    }

    func testH265AliasTreatedAsHevc() throws {
        let source = try makeSource(container: "mp4", videoCodec: "h265", audioCodec: "aac")
        XCTAssertTrue(DeviceMediaCompatibility.canDirectPlayOnDevice(source))
    }
}

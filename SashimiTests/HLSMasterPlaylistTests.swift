import XCTest
@testable import Sashimi

/// Jellyfin's master playlist for an HDR source that is being stream-copied
/// carries HDR→SDR fallback variants (`AllowVideoStreamCopy=false`) at the
/// SAME bandwidth as the copy variant. All of them share one transcoding
/// slot and one segment namespace with different segment grids, so every
/// AVPlayer variant switch restarts ffmpeg with a different codec and grid
/// and the stream stalls (#443). These tests pin the pure decision of which
/// media playlist, if any, AVPlayer should be pointed at instead of the
/// master.
final class HLSMasterPlaylistTests: XCTestCase {
    private let masterURL = URL(string: "http://jellyfin.test:8096/videos/abc/master.m3u8?DeviceId=DEV&ApiKey=REDACTED")!

    // Captured from Jellyfin 12.1 for a 4K HEVC Main 10 / HDR10+ MKV, ids
    // shortened and the key redacted. Line 1 is the copy variant, 2 and 3 the
    // fallback hack, then the trickplay image stream.
    private let hdrCopyMaster = """
    #EXTM3U
    #EXT-X-STREAM-INF:BANDWIDTH=15730824,AVERAGE-BANDWIDTH=15730824,VIDEO-RANGE=PQ,CODECS="hvc1.2.4.L150.B0,ec-3",SUPPLEMENTAL-CODECS="hvc1.2.4.L150.B0/cdm4",RESOLUTION=3840x2160,FRAME-RATE=23.976
    main.m3u8?DeviceId=DEV&MediaSourceId=src1&VideoCodec=hevc,h264&AudioCodec=copy&SegmentContainer=mp4&PlaySessionId=ps1&ApiKey=REDACTED&hevc-profile=main10&TranscodeReasons=ContainerNotSupported
    #EXT-X-STREAM-INF:BANDWIDTH=15730824,AVERAGE-BANDWIDTH=15730824,VIDEO-RANGE=SDR,CODECS="hvc1.2.4.L150.B0,ec-3",RESOLUTION=3840x2160,FRAME-RATE=23.976
    main.m3u8?DeviceId=DEV&MediaSourceId=src1&VideoCodec=hevc&AudioCodec=copy&SegmentContainer=mp4&PlaySessionId=ps1&ApiKey=REDACTED&hevc-profile=main&TranscodeReasons=ContainerNotSupported&AllowVideoStreamCopy=false
    #EXT-X-STREAM-INF:BANDWIDTH=15730824,AVERAGE-BANDWIDTH=15730824,VIDEO-RANGE=SDR,CODECS="avc1.424029,ec-3",RESOLUTION=3840x2160,FRAME-RATE=23.976
    main.m3u8?DeviceId=DEV&MediaSourceId=src1&VideoCodec=h264&AudioCodec=copy&SegmentContainer=mp4&PlaySessionId=ps1&ApiKey=REDACTED&hevc-profile=main&TranscodeReasons=ContainerNotSupported&AllowVideoStreamCopy=false
    #EXT-X-IMAGE-STREAM-INF:BANDWIDTH=6794,RESOLUTION=320x180,CODECS="jpeg",URI="Trickplay/320/tiles.m3u8?MediaSourceId=src1&ApiKey=REDACTED"

    """

    func testHDRCopyMasterPinsTheCopyVariant() {
        let pinned = HLSMasterPlaylist.singlePrimaryVariantURL(master: hdrCopyMaster, masterURL: masterURL)

        XCTAssertEqual(
            pinned?.absoluteString,
            "http://jellyfin.test:8096/videos/abc/main.m3u8?DeviceId=DEV&MediaSourceId=src1&VideoCodec=hevc,h264&AudioCodec=copy&SegmentContainer=mp4&PlaySessionId=ps1&ApiKey=REDACTED&hevc-profile=main10&TranscodeReasons=ContainerNotSupported"
        )
    }

    /// The trickplay line carries a `URI=` attribute; it must never be read as
    /// a variant URI line.
    func testImageStreamIsNotAVariant() {
        let variants = HLSMasterPlaylist.variants(in: hdrCopyMaster)
        XCTAssertEqual(variants.count, 3)
        XCTAssertFalse(variants.contains { $0.uri.contains("tiles.m3u8") })
        XCTAssertEqual(variants.filter(\.isStreamCopyFallback).count, 2)
    }

    /// The 1080p SDR case that already plays: one variant, no fallbacks.
    /// Nothing to pin — the master stays.
    func testSingleVariantMasterIsLeftAlone() {
        let master = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=8000000,VIDEO-RANGE=SDR,CODECS="hvc1.1.6.L120.B0,mp4a.40.2",RESOLUTION=1920x1080
        main.m3u8?VideoCodec=hevc,h264&PlaySessionId=ps1&ApiKey=REDACTED

        """
        XCTAssertNil(HLSMasterPlaylist.singlePrimaryVariantURL(master: master, masterURL: masterURL))
    }

    /// Recovery attempt 2 disables stream copy in the *request*, so the only
    /// variant is itself a forced re-encode and the server adds no fallbacks.
    /// There is no primary to pin; the master must stay.
    func testForcedReencodeMasterIsLeftAlone() {
        let master = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=8000000,VIDEO-RANGE=SDR,CODECS="hvc1.1.6.L153.B0,ec-3",RESOLUTION=3840x2160
        main.m3u8?VideoCodec=hevc,h264&PlaySessionId=ps1&ApiKey=REDACTED&AllowVideoStreamCopy=false

        """
        XCTAssertNil(HLSMasterPlaylist.singlePrimaryVariantURL(master: master, masterURL: masterURL))
    }

    /// An adaptive-bitrate ladder (no fallback hack) is a legitimate reason
    /// for several variants; AVPlayer must keep the master to switch rungs.
    func testAdaptiveLadderWithoutFallbacksIsLeftAlone() {
        let master = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=8000000,VIDEO-RANGE=SDR,CODECS="avc1.640028,mp4a.40.2",RESOLUTION=1920x1080
        main.m3u8?VideoCodec=h264&VideoBitrate=8000000&PlaySessionId=ps1&ApiKey=REDACTED
        #EXT-X-STREAM-INF:BANDWIDTH=4000000,VIDEO-RANGE=SDR,CODECS="avc1.640028,mp4a.40.2",RESOLUTION=1280x720
        main.m3u8?VideoCodec=h264&VideoBitrate=4000000&PlaySessionId=ps1&ApiKey=REDACTED

        """
        XCTAssertNil(HLSMasterPlaylist.singlePrimaryVariantURL(master: master, masterURL: masterURL))
    }

    /// Dolby Vision profile 5: the server lists a spec-compliant `dvh1`
    /// variant first, then the `hvc1` hack, then the SDR fallbacks. Both
    /// primaries are stream copies on the same grid; the server puts the one
    /// it wants Apple TV to take first, so that is the one to pin.
    func testDolbyVisionMasterPinsTheFirstPrimary() {
        let master = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=20000000,VIDEO-RANGE=PQ,CODECS="dvh1.05.06,ec-3",RESOLUTION=3840x2160
        main.m3u8?VideoCodec=hevc,h264&PlaySessionId=ps1&ApiKey=REDACTED&hevc-rangetype=DOVI
        #EXT-X-STREAM-INF:BANDWIDTH=20000000,VIDEO-RANGE=PQ,CODECS="hvc1.2.4.L153.B0,ec-3",RESOLUTION=3840x2160
        main.m3u8?VideoCodec=hevc,h264&PlaySessionId=ps1&ApiKey=REDACTED
        #EXT-X-STREAM-INF:BANDWIDTH=20000000,VIDEO-RANGE=SDR,CODECS="avc1.424029,ec-3",RESOLUTION=3840x2160
        main.m3u8?VideoCodec=h264&PlaySessionId=ps1&ApiKey=REDACTED&AllowVideoStreamCopy=false

        """
        let pinned = HLSMasterPlaylist.singlePrimaryVariantURL(master: master, masterURL: masterURL)
        XCTAssertEqual(pinned?.query, "VideoCodec=hevc,h264&PlaySessionId=ps1&ApiKey=REDACTED&hevc-rangetype=DOVI")
    }

    /// Jellyfin emits relative URIs, but a proxy could rewrite them absolute;
    /// both must resolve against the master's location.
    func testAbsoluteVariantURIIsKeptAsIs() {
        let master = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=1,VIDEO-RANGE=PQ,CODECS="hvc1.2.4.L150.B0"
        https://proxy.test/jf/videos/abc/main.m3u8?VideoCodec=hevc&ApiKey=REDACTED
        #EXT-X-STREAM-INF:BANDWIDTH=1,VIDEO-RANGE=SDR,CODECS="avc1.424029"
        https://proxy.test/jf/videos/abc/main.m3u8?VideoCodec=h264&ApiKey=REDACTED&AllowVideoStreamCopy=false

        """
        let pinned = HLSMasterPlaylist.singlePrimaryVariantURL(master: master, masterURL: masterURL)
        XCTAssertEqual(pinned?.absoluteString, "https://proxy.test/jf/videos/abc/main.m3u8?VideoCodec=hevc&ApiKey=REDACTED")
    }

    /// Garbage in (an HTML error page, an empty body) must never pin
    /// anything — the master URL is the safe default.
    func testNonPlaylistTextIsLeftAlone() {
        XCTAssertNil(HLSMasterPlaylist.singlePrimaryVariantURL(master: "<html>502</html>", masterURL: masterURL))
        XCTAssertNil(HLSMasterPlaylist.singlePrimaryVariantURL(master: "", masterURL: masterURL))
    }
}

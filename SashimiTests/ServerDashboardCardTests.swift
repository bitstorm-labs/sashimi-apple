import XCTest
@testable import Sashimi

/// The OpsDec-style Now playing card (design revision 2026-10-18, plus the
/// findings from the Roku 1.6.22 build). A port of sashimi-roku's
/// tests/AdminDashTests.brs card cases with the same inputs and the same
/// expected strings, so Apple, Roku and Android show the same card for the
/// same session.
final class ServerDashboardCardTests: XCTestCase {
    // MARK: - Fixtures (Roku's `session()`, `tcSession()`, `audioSession()`)

    private let video = DashboardMediaStream(
        type: "Video", codec: "hevc", width: 3840, height: 2160, videoRangeType: "DOVIWithHDR10",
        bitRate: 58_000_000, index: 0, isDefault: true, displayTitle: nil,
        realFrameRate: 23.976025, averageFrameRate: 23.976025
    )
    private let dts = DashboardMediaStream(
        type: "Audio", codec: "dts", width: nil, height: nil, videoRangeType: nil,
        bitRate: 1_509_000, index: 1, isDefault: true, displayTitle: nil, channels: 6
    )
    private let ac3 = DashboardMediaStream(
        type: "Audio", codec: "ac3", width: nil, height: nil, videoRangeType: nil,
        bitRate: 640_000, index: 2, isDefault: false, displayTitle: nil, channels: 2
    )

    private func session(
        _ info: DashboardTranscodingInfo? = nil,
        streams: [DashboardMediaStream]? = nil,
        playState: DashboardPlayState? = DashboardPlayState(
            positionTicks: 12_440_000_000, isPaused: false, playMethod: "Transcode", audioStreamIndex: nil
        ),
        item: DashboardNowPlaying? = nil,
        client: String? = "Sashimi",
        deviceName: String? = "Living Room Roku",
        network: DashboardNetwork? = nil
    ) -> DashboardSession {
        DashboardSession(
            id: "s1",
            userName: "mom",
            client: client,
            applicationVersion: nil,
            deviceName: deviceName,
            supportsRemoteControl: true,
            nowPlayingItem: item ?? DashboardNowPlaying(
                id: "i1", name: "300", type: "Movie", seriesName: nil, seriesId: nil,
                parentIndexNumber: nil, indexNumber: nil, runTimeTicks: 70_200_000_000, container: "mkv",
                mediaStreams: streams ?? [video, dts, ac3], productionYear: 2006
            ),
            playState: playState,
            transcodingInfo: info,
            network: network
        )
    }

    private func info(
        video: Bool,
        audio: Bool,
        videoCodec: String? = nil,
        audioCodec: String? = nil,
        width: Int? = nil,
        height: Int? = nil,
        bitrate: Int? = nil,
        framerate: Double? = nil,
        audioChannels: Int? = nil,
        hardware: String? = nil,
        reasons: [String] = []
    ) -> DashboardTranscodingInfo {
        DashboardTranscodingInfo(
            audioCodec: audioCodec, videoCodec: videoCodec, container: nil,
            isVideoDirect: video, isAudioDirect: audio, bitrate: bitrate, width: width, height: height,
            hardwareAccelerationType: hardware, transcodeReasons: reasons,
            audioChannels: audioChannels, framerate: framerate
        )
    }

    /// Video re-encoded by QSV at 43.2 fps from a 23.976 fps source, bitrate cap.
    private func tcInfo(framerate: Double? = 43.2, hardware: String? = "qsv") -> DashboardTranscodingInfo {
        info(
            video: false, audio: true, videoCodec: "h264", audioCodec: "dts", width: 1920, height: 1080,
            bitrate: 8_000_000, framerate: framerate, audioChannels: 6, hardware: hardware,
            reasons: ["ContainerBitrateExceedsLimit"]
        )
    }

    /// Video copied, DTS to AC3 at real time.
    private func audioInfo(framerate: Double? = 23.976) -> DashboardTranscodingInfo {
        info(
            video: true, audio: false, videoCodec: "hevc", audioCodec: "ac3", width: 3840, height: 2160,
            bitrate: 58_640_000, framerate: framerate, audioChannels: 6, hardware: "qsv",
            reasons: ["AudioCodecNotSupported"]
        )
    }

    private func episode(season: Int?, index: Int?, type: String = "Episode") -> DashboardNowPlaying {
        DashboardNowPlaying(
            id: "e", name: "Mercy", type: type, seriesName: "Vikings", seriesId: "v",
            parentIndexNumber: season, indexNumber: index, runTimeTicks: nil, container: nil, mediaStreams: []
        )
    }

    // MARK: - State dot

    func testStateDot() {
        XCTAssertEqual(ServerDashboardLogic.streamState(session()), .playing)
        let paused = DashboardPlayState(positionTicks: 0, isPaused: true, playMethod: nil, audioStreamIndex: nil)
        XCTAssertEqual(ServerDashboardLogic.streamState(session(playState: paused)), .paused)
        XCTAssertEqual(ServerDashboardLogic.streamState(session(playState: nil)), .other)
        let unsaid = DashboardPlayState(positionTicks: 0, isPaused: false, playMethod: nil, audioStreamIndex: nil, reportsPause: false)
        XCTAssertEqual(ServerDashboardLogic.streamState(session(playState: unsaid)), .other)
    }

    func testMissingPauseFlagDecodesAsUnknownNotPlaying() throws {
        let state = try JSONDecoder().decode(DashboardPlayState.self, from: Data(#"{"PositionTicks":0}"#.utf8))
        XCTAssertFalse(state.reportsPause)
        let session = DashboardSession(
            id: "s", userName: nil, client: nil, applicationVersion: nil, deviceName: nil, supportsRemoteControl: false,
            nowPlayingItem: nil, playState: state, transcodingInfo: nil
        )
        XCTAssertEqual(ServerDashboardLogic.streamState(session), .other)
    }

    // MARK: - Title

    func testCardTitle() {
        let title = ServerDashboardLogic.cardTitle(episode(season: 4, index: 3))
        XCTAssertEqual(title, DashboardCardTitle(title: "Mercy", sub: "Vikings", ep: "S04E03"))
        XCTAssertEqual(ServerDashboardLogic.episodeTag(episode(season: 12, index: 112)), "S12E112")
        XCTAssertEqual(ServerDashboardLogic.episodeTag(episode(season: 0, index: 2)), "S00E02")
        XCTAssertEqual(ServerDashboardLogic.episodeTag(episode(season: nil, index: 7)), "E07")
        XCTAssertEqual(ServerDashboardLogic.episodeTag(episode(season: nil, index: nil)), "")
        XCTAssertEqual(ServerDashboardLogic.episodeTag(episode(season: 1, index: 1, type: "Movie")), "")

        XCTAssertEqual(ServerDashboardLogic.cardTitle(session().nowPlayingItem), DashboardCardTitle(title: "300", sub: "Movie · 2006", ep: ""))
        let noYear = DashboardNowPlaying(
            id: "x", name: "X", type: "Movie", seriesName: nil, seriesId: nil, parentIndexNumber: nil,
            indexNumber: nil, runTimeTicks: nil, container: nil, mediaStreams: []
        )
        XCTAssertEqual(ServerDashboardLogic.cardTitle(noYear).sub, "Movie")
        let other = DashboardNowPlaying(
            id: "y", name: "Y", type: "MusicVideo", seriesName: nil, seriesId: nil, parentIndexNumber: nil,
            indexNumber: nil, runTimeTicks: nil, container: nil, mediaStreams: [], productionYear: 1999
        )
        XCTAssertEqual(ServerDashboardLogic.cardTitle(other).sub, "1999")
        XCTAssertEqual(ServerDashboardLogic.cardTitle(nil), DashboardCardTitle(title: "", sub: "", ep: ""))
    }

    func testDecodesProductionYear() throws {
        let json = #"{"Id":"i","Name":"300","Type":"Movie","ProductionYear":2006}"#
        let item = try JSONDecoder().decode(DashboardNowPlaying.self, from: Data(json.utf8))
        XCTAssertEqual(ServerDashboardLogic.cardTitle(item).sub, "Movie · 2006")
    }

    // MARK: - People

    func testDeviceLineAndInitial() {
        XCTAssertEqual(ServerDashboardLogic.deviceLine(session()), "Sashimi · Living Room Roku")
        XCTAssertEqual(ServerDashboardLogic.deviceLine(session(client: nil, deviceName: "Pixel 8")), "Pixel 8")
        XCTAssertEqual(ServerDashboardLogic.deviceLine(session(client: "Jellyfin Web", deviceName: nil)), "Jellyfin Web")
        XCTAssertEqual(ServerDashboardLogic.initial(of: "mom"), "M")
        XCTAssertEqual(ServerDashboardLogic.initial(of: ""), "?")
        XCTAssertEqual(ServerDashboardLogic.initial(of: nil), "?")
    }

    func testPercent() {
        XCTAssertEqual(ServerDashboardLogic.percentText(session()), "18%")
        let bare = DashboardNowPlaying(
            id: "x", name: nil, type: nil, seriesName: nil, seriesId: nil, parentIndexNumber: nil,
            indexNumber: nil, runTimeTicks: nil, container: nil, mediaStreams: []
        )
        XCTAssertEqual(ServerDashboardLogic.percentText(session(item: bare)), "")
    }

    // MARK: - Resolution

    func testResolutionTiersUseWidthAndHeight() {
        XCTAssertEqual(ServerDashboardLogic.resolutionLabel(width: 3840, height: 2160), "4K")
        XCTAssertEqual(ServerDashboardLogic.resolutionLabel(width: 3840, height: 1600), "4K")
        // Scope 1080p is 1920x800: width decides.
        XCTAssertEqual(ServerDashboardLogic.resolutionLabel(width: 1920, height: 800), "1080p")
        // A cropped 4:3 1080p is 1440x1080: height decides.
        XCTAssertEqual(ServerDashboardLogic.resolutionLabel(width: 1440, height: 1080), "1080p")
        XCTAssertEqual(ServerDashboardLogic.resolutionLabel(width: 1280, height: 720), "720p")
        XCTAssertEqual(ServerDashboardLogic.resolutionLabel(width: 720, height: 480), "480p")
        XCTAssertEqual(ServerDashboardLogic.resolutionLabel(width: 640, height: 360), "480p")
        XCTAssertEqual(ServerDashboardLogic.resolutionLabel(width: 480, height: 270), "SD")
        XCTAssertEqual(ServerDashboardLogic.resolutionLabel(width: nil, height: 1080), "1080p")
        XCTAssertEqual(ServerDashboardLogic.resolutionLabel(width: nil, height: nil), "")
        XCTAssertEqual(ServerDashboardLogic.resolutionLabel(width: 0, height: 0), "")
    }

    func testResolutionPill() {
        XCTAssertEqual(ServerDashboardLogic.resolutionPill(session()), "4K")
        XCTAssertEqual(ServerDashboardLogic.resolutionPill(session(tcInfo())), "4K → 1080p")
        // Video copied: the delivered size is the source, whatever the server says.
        XCTAssertEqual(ServerDashboardLogic.resolutionPill(session(audioInfo())), "4K")
        let same = info(video: false, audio: true, videoCodec: "h264", width: 3840, height: 2160)
        XCTAssertEqual(ServerDashboardLogic.resolutionPill(session(same)), "4K")
        XCTAssertEqual(ServerDashboardLogic.resolutionPill(session(info(video: false, audio: true, videoCodec: "h264"))), "4K")
        XCTAssertEqual(ServerDashboardLogic.resolutionPill(session(streams: [])), "")
    }

    // MARK: - Video

    func testVideoPillNamesCodecAndRange() {
        XCTAssertEqual(ServerDashboardLogic.videoPill(session()), "HEVC DV")
        let ranges = [("HDR10", "HEVC HDR10"), ("HDR10Plus", "HEVC HDR10+"), ("HLG", "HEVC HLG"), ("DOVIWithSDR", "HEVC DV"), ("SDR", "HEVC")]
        for (range, expected) in ranges {
            XCTAssertEqual(ServerDashboardLogic.videoPill(session(streams: [stream(video, range: range)])), expected, range)
        }
        XCTAssertEqual(ServerDashboardLogic.videoPill(session(streams: [stream(video, codec: "h265", range: "SDR")])), "HEVC")
        XCTAssertEqual(ServerDashboardLogic.videoPill(session(streams: [])), "")
    }

    func testVideoPillShowsTheChange() {
        XCTAssertEqual(ServerDashboardLogic.videoPill(session(tcInfo())), "HEVC DV → H264")
        // Tone-mapped in the same codec: the range is what changed.
        let toneMap = info(video: false, audio: true, videoCodec: "hevc", reasons: ["VideoRangeTypeNotSupported"])
        XCTAssertEqual(ServerDashboardLogic.videoPill(session(toneMap)), "HEVC DV → HEVC SDR")
        let toneMapH264 = info(video: false, audio: true, videoCodec: "h264", reasons: ["VideoRangeTypeNotSupported"])
        XCTAssertEqual(ServerDashboardLogic.videoPill(session(toneMapH264)), "HEVC DV → H264 SDR")
        // Re-encoded at another bitrate in the same codec and range: no arrow,
        // and never SDR without the tone-mapping reason (the server doesn't
        // report the output range).
        let sameCodec = info(video: false, audio: true, videoCodec: "hevc", reasons: ["ContainerBitrateExceedsLimit"])
        XCTAssertEqual(ServerDashboardLogic.videoPill(session(sameCodec)), "HEVC DV")
        XCTAssertEqual(ServerDashboardLogic.videoPill(session(audioInfo())), "HEVC DV")
    }

    // MARK: - Audio

    func testAudioPill() {
        XCTAssertEqual(ServerDashboardLogic.audioPill(session()), "DTS 5.1")
        // Same channel count either side: said once, after the arrow.
        XCTAssertEqual(ServerDashboardLogic.audioPill(session(audioInfo())), "DTS → AC3 5.1")
        let downmix = info(video: true, audio: false, audioCodec: "aac", audioChannels: 2)
        XCTAssertEqual(ServerDashboardLogic.audioPill(session(downmix)), "DTS 5.1 → AAC 2.0")
        XCTAssertEqual(ServerDashboardLogic.audioPill(session(info(video: true, audio: false, audioCodec: "aac"))), "DTS 5.1 → AAC")
        // Audio copied while the video converts: the source track as is.
        XCTAssertEqual(ServerDashboardLogic.audioPill(session(tcInfo())), "DTS 5.1")
        // The flag decides: a copied track is the source even if AudioCodec disagrees.
        let flagWins = info(video: false, audio: true, videoCodec: "h264", audioCodec: "aac", audioChannels: 2)
        XCTAssertEqual(ServerDashboardLogic.audioPill(session(flagWins)), "DTS 5.1")
        let second = DashboardPlayState(positionTicks: 0, isPaused: false, playMethod: nil, audioStreamIndex: 2)
        XCTAssertEqual(ServerDashboardLogic.audioPill(session(playState: second)), "AC3 2.0")
        let truehd = DashboardMediaStream(
            type: "Audio", codec: "truehd", width: nil, height: nil, videoRangeType: nil,
            bitRate: nil, index: 1, isDefault: true, displayTitle: nil, channels: 8
        )
        XCTAssertEqual(ServerDashboardLogic.audioPill(session(streams: [video, truehd])), "TRUEHD 7.1")
        XCTAssertEqual(ServerDashboardLogic.audioPill(session(streams: [])), "")
    }

    func testChannelLabels() {
        for (channels, label) in [(1, "1.0"), (2, "2.0"), (3, "2.1"), (6, "5.1"), (8, "7.1"), (4, "4ch")] {
            XCTAssertEqual(ServerDashboardLogic.channelsLabel(channels), label)
        }
        XCTAssertEqual(ServerDashboardLogic.channelsLabel(nil), "")
        XCTAssertEqual(ServerDashboardLogic.channelsLabel(0), "")
    }

    // MARK: - Bitrate

    func testRatePill() {
        XCTAssertEqual(ServerDashboardLogic.ratePill(session()), "60 Mbps")
        XCTAssertEqual(ServerDashboardLogic.ratePill(session(tcInfo())), "60 → 8 Mbps")
        // Video copied: the delivered rate, no arrow (it barely moves).
        XCTAssertEqual(ServerDashboardLogic.ratePill(session(audioInfo())), "59 Mbps")
        XCTAssertEqual(ServerDashboardLogic.ratePill(session(info(video: false, audio: true, bitrate: 720_000))), "60 Mbps → 720 kbps")
        XCTAssertEqual(ServerDashboardLogic.ratePill(session(info(video: false, audio: true, bitrate: 8_000_000), streams: [])), "8 Mbps")
        XCTAssertEqual(ServerDashboardLogic.ratePill(session(info(video: false, audio: true, bitrate: 59_509_000))), "60 Mbps")
        XCTAssertEqual(ServerDashboardLogic.ratePill(session(streams: [])), "")
    }

    func testFormatBitrateMatchesRoku() {
        XCTAssertEqual(ServerDashboardLogic.formatBitrate(8_460_000), "8.5 Mbps")
        XCTAssertEqual(ServerDashboardLogic.formatBitrate(8_000_000), "8 Mbps")
        XCTAssertEqual(ServerDashboardLogic.formatBitrate(61_400_000), "61 Mbps")
        XCTAssertEqual(ServerDashboardLogic.formatBitrate(720_000), "720 kbps")
        // Rounded, not truncated.
        XCTAssertEqual(ServerDashboardLogic.formatBitrate(639_600), "640 kbps")
        XCTAssertEqual(ServerDashboardLogic.formatBitrate(0), "")
    }

    // MARK: - Speed and play mode

    func testSpeed() {
        XCTAssertEqual(ServerDashboardLogic.speed(session(tcInfo())), "1.8x")
        XCTAssertEqual(ServerDashboardLogic.speed(session(audioInfo())), "1.0x")
        XCTAssertEqual(ServerDashboardLogic.speed(session(tcInfo(framerate: 100))), "4.2x")
        XCTAssertEqual(ServerDashboardLogic.speed(session(tcInfo(framerate: 12))), "0.5x")
        XCTAssertEqual(ServerDashboardLogic.speed(session(tcInfo(framerate: 300))), "13x")
        // No RealFrameRate: AverageFrameRate stands in.
        let averaged = DashboardMediaStream(
            type: "Video", codec: "hevc", width: 3840, height: 2160, videoRangeType: "DOVIWithHDR10",
            bitRate: 58_000_000, index: 0, isDefault: true, displayTitle: nil, realFrameRate: nil, averageFrameRate: 24
        )
        XCTAssertEqual(ServerDashboardLogic.speed(session(tcInfo(), streams: [averaged, dts])), "1.8x")
        let noFps = stream(video, fps: nil)
        XCTAssertEqual(ServerDashboardLogic.speed(session(tcInfo(), streams: [noFps, dts])), "")
        XCTAssertEqual(ServerDashboardLogic.speed(session(tcInfo(framerate: nil))), "")
        XCTAssertEqual(ServerDashboardLogic.speed(session(tcInfo(framerate: 0))), "")
        XCTAssertEqual(ServerDashboardLogic.speed(session()), "")
    }

    func testModeLabel() {
        XCTAssertEqual(ServerDashboardLogic.modeLabel(session()), "Direct Play")
        let remux = info(video: true, audio: true, framerate: 50, hardware: "qsv", reasons: ["ContainerNotSupported"])
        XCTAssertEqual(ServerDashboardLogic.modeLabel(session(remux)), "Direct Play")
        XCTAssertEqual(ServerDashboardLogic.modeLabel(session(audioInfo())), "Audio only · 1.0x")
        XCTAssertEqual(ServerDashboardLogic.modeLabel(session(audioInfo(framerate: nil))), "Audio only")
        XCTAssertEqual(ServerDashboardLogic.modeLabel(session(tcInfo())), "TC 1.8x HW")
        XCTAssertEqual(ServerDashboardLogic.modeLabel(session(tcInfo(hardware: "none"))), "TC 1.8x")
        XCTAssertEqual(ServerDashboardLogic.modeLabel(session(tcInfo(hardware: nil))), "TC 1.8x")
        XCTAssertEqual(ServerDashboardLogic.modeLabel(session(tcInfo(framerate: nil))), "TC HW")
    }

    /// The server names its configured accelerator on every TranscodingInfo,
    /// remuxes included (seen on the live server), so HW only means something
    /// when the picture is encoded.
    func testHardwareOnlyOnVideoConversions() {
        XCTAssertTrue(ServerDashboardLogic.isHardware(session(tcInfo())))
        XCTAssertFalse(ServerDashboardLogic.isHardware(session(audioInfo())))
        XCTAssertFalse(ServerDashboardLogic.isHardware(session(info(video: true, audio: true, hardware: "qsv"))))
        XCTAssertFalse(ServerDashboardLogic.isHardware(session()))
    }

    // MARK: - Pills

    func testPillsInCardOrder() {
        let pills = ServerDashboardLogic.pills(session(tcInfo()))
        XCTAssertEqual(pills.map(\.kind), [.resolution, .video, .audio, .bitrate, .mode])
        XCTAssertEqual(pills.map(\.text), ["4K → 1080p", "HEVC DV → H264", "DTS 5.1", "60 → 8 Mbps", "TC 1.8x HW"])
        XCTAssertEqual(ServerDashboardLogic.pills(session(audioInfo())).last?.text, "Audio only · 1.0x")
        // Nothing known about the file: only the play mode.
        let bare = ServerDashboardLogic.pills(session(streams: []))
        XCTAssertEqual(bare.map(\.text), ["Direct Play"])
    }

    // MARK: - Footer

    func testFooterReason() {
        XCTAssertEqual(ServerDashboardLogic.footerReason(session()), "Plays as-is")
        let remux = info(video: true, audio: true, reasons: ["ContainerNotSupported"])
        XCTAssertEqual(ServerDashboardLogic.footerReason(session(remux)), "Remux")
        XCTAssertEqual(ServerDashboardLogic.footerReason(session(audioInfo())), "Audio format not supported")
        XCTAssertEqual(ServerDashboardLogic.footerReason(session(tcInfo())), "Bitrate cap")
        let many = info(video: false, audio: true, reasons: ["VideoResolutionNotSupported", "SubtitleCodecNotSupported", "VideoResolutionNotSupported"])
        XCTAssertEqual(ServerDashboardLogic.footerReason(session(many)), "Resolution too high · Subtitles burned in")
        XCTAssertEqual(ServerDashboardLogic.footerReason(session(info(video: false, audio: true))), "Converting")
    }

    // MARK: - Local or Remote

    func testLocalAddresses() {
        let locals = [
            "192.168.86.30", "10.0.0.5", "10.255.255.255", "172.16.0.1", "172.31.255.255", "127.0.0.1",
            "169.254.10.1", "::1", "fe80::1", "FE80::ABCD", "febf::1", "fd12:3456::1", "fc00::1",
            "::ffff:192.168.1.5", "[fe80::1]:8096", "192.168.1.5:54321", " 10.1.2.3 "
        ]
        for address in locals {
            XCTAssertTrue(ServerDashboardLogic.isLocalAddress(address), address)
        }
        // CGNAT (100.64.0.0/10) is someone else's network, not this LAN.
        let remotes = [
            "100.64.0.1", "100.127.255.255", "172.15.0.1", "172.32.0.1", "8.8.8.8", "192.169.0.1", "11.0.0.1",
            "fec0::1", "fe7f::1", "2001:db8::1", "::ffff:8.8.8.8", "::ffff:100.64.0.1", "999.168.1.1",
            "192.168.1", "localhost", "", "::"
        ]
        for address in remotes {
            XCTAssertFalse(ServerDashboardLogic.isLocalAddress(address), address)
        }
        XCTAssertFalse(ServerDashboardLogic.isLocalAddress(nil))
    }

    func testWhereLabel() {
        XCTAssertEqual(ServerDashboardLogic.whereLabel(session(network: .local)), "Local")
        XCTAssertEqual(ServerDashboardLogic.whereLabel(session(network: .remote)), "Remote")
        XCTAssertEqual(ServerDashboardLogic.whereLabel(session()), "")
    }

    /// The address decides Local or Remote at decode time and is then gone.
    func testDecodingKeepsOnlyLocalOrRemote() throws {
        func decode(_ endPoint: String?) throws -> DashboardSession {
            var json = #"{"Id":"s""#
            if let endPoint { json += #","RemoteEndPoint":"\#(endPoint)""# }
            json += "}"
            return try JSONDecoder().decode(DashboardSession.self, from: Data(json.utf8))
        }
        XCTAssertEqual(try decode("192.168.86.30").network, .local)
        XCTAssertEqual(try decode("100.70.1.2").network, .remote)
        XCTAssertEqual(try decode("72.14.3.99").network, .remote)
        XCTAssertNil(try decode("").network)
        XCTAssertNil(try decode(nil).network)
        let mirror = Mirror(reflecting: try decode("72.14.3.99"))
        XCTAssertFalse(mirror.children.contains { "\($0.value)".contains("72.14") }, "the address is not kept")
    }

    // MARK: - Helpers

    private func stream(_ base: DashboardMediaStream, codec: String? = nil, range: String? = nil) -> DashboardMediaStream {
        DashboardMediaStream(
            type: base.type, codec: codec ?? base.codec, width: base.width, height: base.height,
            videoRangeType: range ?? base.videoRangeType, bitRate: base.bitRate, index: base.index,
            isDefault: base.isDefault, displayTitle: nil, channels: base.channels,
            realFrameRate: base.realFrameRate, averageFrameRate: base.averageFrameRate
        )
    }

    private func stream(_ base: DashboardMediaStream, fps: Double?) -> DashboardMediaStream {
        DashboardMediaStream(
            type: base.type, codec: base.codec, width: base.width, height: base.height,
            videoRangeType: base.videoRangeType, bitRate: base.bitRate, index: base.index,
            isDefault: base.isDefault, displayTitle: nil, realFrameRate: fps, averageFrameRate: fps
        )
    }
}
